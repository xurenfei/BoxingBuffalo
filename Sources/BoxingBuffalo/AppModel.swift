import Foundation
import AppKit
import Combine
import Darwin
import FatXCore

/// Cooperative cancellation flag shared between the main actor (button) and
/// the serial write queue (progress callback). A lock keeps the flag honest
/// without hopping actors on every 8 MiB window.
private final class WriteCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
}

/// One path step in the browser: where we came from and which cluster it lives in.
struct PathStep: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let cluster: UInt32
}

/// A mounted FATX volume plus the source it came from.
final class MountedVolume: Identifiable, ObservableObject {
    let id = UUID()
    let source: BlockSource
    let volume: FatXVolume
    let layout: FatXLayout
    let label: String
    let originName: String
    /// `disk8` for a raw device, nil for image files. Keeping the identifier on
    /// the volume means "unlock write" never has to guess which disk the volume
    /// came from by comparing display names.
    let deviceID: String?

    init(source: BlockSource, discovered: DiscoveredVolume, originName: String, deviceID: String? = nil) {
        self.source = source
        self.volume = discovered.volume
        self.layout = discovered.layout
        self.label = discovered.label
        self.originName = originName
        self.deviceID = deviceID
    }

    var title: String { "\(originName) · \(label)" }
    var isWritable: Bool { source.isWritable }
    var isRawDevice: Bool { source.isRawDevice }
}

enum SortField: String, CaseIterable, Identifiable {
    case name = "名称"
    case size = "大小"
    case modified = "修改时间"
    var id: String { rawValue }
}

/// All UI state lives here. FATX parsing itself is thread-agnostic, so heavy
/// work is pushed onto a serial queue and results are hopped back to the main
/// actor for publishing.
@MainActor
final class AppModel: ObservableObject {

    // Devices & volumes
    @Published private(set) var devices: [StorageDevice] = []
    @Published private(set) var volumes: [MountedVolume] = []
    @Published var selectedVolumeID: UUID?
    @Published private(set) var scanProgress: Double = 0
    @Published private(set) var isScanning = false
    @Published private(set) var scanMessage: String = ""

    // Browser
    @Published private(set) var entries: [FatXEntry] = []
    @Published private(set) var path: [PathStep] = []
    @Published private(set) var isLoadingEntries = false
    @Published var searchText: String = ""
    @Published var sortField: SortField = .name
    @Published var sortAscending: Bool = true
    @Published var showDeletedEntries: Bool = false
    @Published var selection: Set<FatXEntry.ID> = []
    @Published private(set) var forwardStack: [PathStep] = []

    // Status / errors
    @Published var errorMessage: String?
    @Published var statusMessage: String = "就绪"
    /// Why the last attempt at a read-write handle fell back to read-only.
    /// Only surfaced when the user explicitly asked to unlock writing.
    @Published private(set) var writeHandleIssue: String?
    private var pendingWriteUnlock = false
    private var pendingUnlockDetail = ""

    // Extraction
    @Published private(set) var isExtracting = false
    @Published private(set) var extractionProgress: Double = 0
    @Published private(set) var extractionLabel: String = ""

    private let workQueue = DispatchQueue(label: "boxingbuffalo.fatx", qos: .userInitiated)
    private var entryCache: [String: [FatXEntry]] = [:]

    var selectedVolume: MountedVolume? {
        volumes.first { $0.id == selectedVolumeID }
    }

    var canGoUp: Bool { !path.isEmpty }
    var canGoBack: Bool { !path.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    var currentCluster: UInt32 {
        path.last?.cluster ?? selectedVolume?.volume.rootDirectoryCluster ?? 1
    }

    var breadcrumb: [PathStep] {
        guard let volume = selectedVolume else { return [] }
        return [PathStep(name: volume.label, cluster: volume.volume.rootDirectoryCluster)] + path
    }

    var filteredEntries: [FatXEntry] {
        var result = entries.filter { showDeletedEntries || !$0.isDeleted }
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(needle) }
        }
        // Directories first, then the chosen field.
        return result.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let cmp: Bool
            switch sortField {
            case .name:
                cmp = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                cmp = lhs.size < rhs.size
            case .modified:
                cmp = (lhs.modified ?? .distantPast) < (rhs.modified ?? .distantPast)
            }
            return sortAscending ? cmp : !cmp
        }
    }

    var selectedEntries: [FatXEntry] {
        filteredEntries.filter { selection.contains($0.id) }
    }

    // MARK: - Devices

    static let lastDeviceKey = "boxingbuffalo.lastDeviceID"

    /// Re-mounts whatever physical disk was open last session, so the window
    /// comes back the way it was left.
    func reopenLastDevice() {
        guard let id = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
              let device = devices.first(where: { $0.id == id }) else { return }
        mount(device: device)
    }

    func refreshDevices() {
        devices = DeviceEnumerator.listPhysicalDisks()
        statusMessage = devices.isEmpty
            ? "没检测到外接磁盘。插上 Xbox 360 存储设备后点刷新。"
            : "检测到 \(devices.count) 个外接磁盘"
    }

    /// Opens a physical disk: probes for FATX volumes, requesting read access
    /// first if the device node is locked down (which it is by default).
    func mount(device: StorageDevice) {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0
        scanMessage = "准备读取 \(device.displayName)…"
        errorMessage = nil

        var needsPermission = !DeviceEnumerator.canReadRawDevice(device)
        if needsPermission {
            scanMessage = "需要管理员授权…"
            let granted = DeviceEnumerator.requestReadAccess(for: device)
            needsPermission = !granted || !DeviceEnumerator.canReadRawDevice(device)
        }
        if needsPermission {
            isScanning = false
            errorMessage = """
            没有 \(device.id) 的读取权限。

            BoxingBuffalo 用一次「chmod o+r /dev/\(device.id)」来放开设备节点的读权限，不向磁盘写入任何内容。如果刚才取消了授权，点设备再试一次。
            """
            return
        }

        let path = device.rawPath
        let originName = device.displayName.isEmpty ? device.id : device.displayName

        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                // Prefer a writable handle so uploads can work, but never make
                // browsing depend on it — a drive whose device node is only
                // world-readable still opens read-only. The reason a writable
                // handle was refused is kept, because "still read-only after
                // typing the password" has to name a cause.
                let source: BlockSource
                var writeIssue: String?
                if DeviceEnumerator.canWriteRawDevice(device) {
                    do {
                        source = try RawBlockSource(path: path, writable: true)
                        BoxingBuffaloLog.log("opened \(path) read-write")
                    } catch {
                        BoxingBuffaloLog.log("open \(path) O_RDWR failed: \(error)")
                        writeIssue = "设备节点有写权限，但无法以读写方式打开：\(error)"
                        source = try RawBlockSource(path: path)
                    }
                } else {
                    let code = errno
                    writeIssue = "设备节点没有写权限（open O_RDWR 返回 errno \(code)：\(String(cString: strerror(code)))）"
                    source = try RawBlockSource(path: path)
                }
                let discovered = try PartitionScanner.scan(source: source) { progress, message in
                    DispatchQueue.main.async {
                        self.scanProgress = progress
                        self.scanMessage = message
                    }
                }
                DispatchQueue.main.async {
                    self.writeHandleIssue = writeIssue
                    self.attach(volumes: discovered, source: source, originName: originName, deviceID: device.id)
                    UserDefaults.standard.set(device.id, forKey: AppModel.lastDeviceKey)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isScanning = false
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    func openImage(url: URL) {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0
        scanMessage = "读取镜像…"
        errorMessage = nil

        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                // An image file is ours to modify; the console never has it open.
                let source: BlockSource
                if let writable = try? FileBlockSource(path: url.path, writable: true) {
                    source = writable
                } else {
                    source = try FileBlockSource(path: url.path)
                }
                let discovered = try PartitionScanner.scan(source: source) { progress, message in
                    DispatchQueue.main.async {
                        self.scanProgress = progress
                        self.scanMessage = message
                    }
                }
                DispatchQueue.main.async {
                    self.attach(volumes: discovered, source: source,
                                originName: url.lastPathComponent)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isScanning = false
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    /// Builds a sample volume in memory-ish (temp file) so the UI is explorable
    /// without hardware.
    func openSampleVolume() {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0.2
        scanMessage = "生成示例 FATX 卷…"
        errorMessage = nil

        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let built = try FatXImageBuilder.build(root: FatXImageBuilder.sampleTree(),
                                                       totalSize: 48 << 20,
                                                       sectorsPerCluster: 8)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("BoxingBuffaloSample.bin")
                try built.image.write(to: url)
                let source = try FileBlockSource(path: url.path)
                let discovered = try PartitionScanner.scan(source: source, progress: nil)
                DispatchQueue.main.async {
                    self.attach(volumes: discovered, source: source, originName: "示例镜像")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isScanning = false
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    private func attach(volumes discovered: [DiscoveredVolume],
                        source: BlockSource,
                        originName: String,
                        deviceID: String? = nil) {
        isScanning = false
        scanProgress = 1
        entryCache.removeAll()

        guard !discovered.isEmpty else {
            errorMessage = "没有找到可用的 FATX 卷。"
            pendingWriteUnlock = false
            return
        }
        // Merge into existing list, replacing any volume from the same origin.
        let fresh = discovered.map {
            MountedVolume(source: source, discovered: $0, originName: originName, deviceID: deviceID)
        }
        volumes.removeAll { $0.originName == originName }
        volumes.append(contentsOf: fresh)
        selectedVolumeID = fresh.first?.id
        path = []
        forwardStack = []
        reloadEntries()

        if pendingWriteUnlock {
            pendingWriteUnlock = false
            if fresh.first?.isWritable == true {
                statusMessage = "已解锁写入 · 上传、新建、删除都会再确认一次"
            } else {
                let deviceID = deviceID ?? ""
                var hint = ""
                if pendingUnlockDetail.contains("errno 1 ") || pendingUnlockDetail.contains("EPERM") {
                    hint = """

                    系统以 EPERM 拒绝了对裸设备的写访问，这通常需要给 BoxingBuffalo.app 授予
                    「系统设置 → 隐私与安全性 → 完全磁盘访问权限」，然后重启 BoxingBuffalo。
                    也可以先在「终端」里手工执行一次：
                    sudo chmod 666 /dev/rdisk\(deviceID.replacingOccurrences(of: "disk", with: "")) /dev/\(deviceID)
                    再回到 BoxingBuffalo 点一次锁（此时不会再要密码）。
                    """
                }
                errorMessage = """
                已通过管理员授权，但磁盘仍以只读方式打开，写入不可用。

                \(writeHandleIssue ?? "写句柄未能建立。")
                \(pendingUnlockDetail.isEmpty ? "" : "授权结果：\(pendingUnlockDetail)")
                \(hint)
                日志：~/Library/Logs/BoxingBuffalo.log
                """
            }
            return
        }
        statusMessage = "挂载 \(fresh.count) 个 FATX 卷"
        if fresh.contains(where: { !$0.isWritable }) {
            statusMessage += " · 只读（工具栏点锁申请写权限）"
        }
    }

    func unmount(_ volume: MountedVolume) {
        // All FATX volumes of one disk share a single file descriptor, so the
        // handle may only be closed when the last of them goes away.
        let shared = volumes.contains { $0.id != volume.id && $0.source === volume.source }
        if !shared { volume.source.close() }
        volumes.removeAll { $0.id == volume.id }
        if selectedVolumeID == volume.id {
            selectedVolumeID = volumes.first?.id
            path = []
            forwardStack = []
            reloadEntries()
        }
    }

    func selectVolume(_ id: UUID?) {
        guard id != selectedVolumeID else { return }
        selectedVolumeID = id
        path = []
        forwardStack = []
        selection = []
        reloadEntries()
    }

    // MARK: - Navigation

    func reloadEntries() {
        guard let volume = selectedVolume else {
            entries = []
            return
        }
        let cluster = currentCluster
        let key = "\(volume.id)-\(cluster)-\(showDeletedEntries)"
        if let cached = entryCache[key] {
            entries = cached
            return
        }
        isLoadingEntries = true
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let list = try volume.volume.listDirectory(cluster: cluster)
                DispatchQueue.main.async {
                    self.entryCache[key] = list
                    self.entries = list
                    self.isLoadingEntries = false
                    self.statusMessage = "\(list.count) 个项目"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoadingEntries = false
                    self.entries = []
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    func enter(_ entry: FatXEntry) {
        guard entry.isDirectory else { return }
        forwardStack = []
        path.append(PathStep(name: entry.name, cluster: entry.startingCluster))
        selection = []
        reloadEntries()
    }

    func goUp() {
        guard !path.isEmpty else { return }
        let leaving = path.removeLast()
        forwardStack.append(leaving)
        selection = []
        reloadEntries()
    }

    func goBack() {
        // Kept for symmetry with toolbar buttons: "back" in a tree is "up".
        guard !path.isEmpty else { return }
        path.removeLast()
        selection = []
        reloadEntries()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        path.append(next)
        selection = []
        reloadEntries()
    }

    func jump(to step: PathStep) {
        guard let index = path.firstIndex(where: { $0.cluster == step.cluster }) else {
            if step.cluster == selectedVolume?.volume.rootDirectoryCluster {
                path = []
                forwardStack = []
                reloadEntries()
            }
            return
        }
        path.removeSubrange((index + 1)...)
        forwardStack = []
        reloadEntries()
    }

    func goToRoot() {
        path = []
        forwardStack = []
        selection = []
        reloadEntries()
    }

    // MARK: - Extraction

    func extract(entries targetEntries: [FatXEntry], to destination: URL) {
        guard let volume = selectedVolume, !targetEntries.isEmpty, !isExtracting else { return }
        isExtracting = true
        extractionProgress = 0
        extractionLabel = "准备提取…"
        errorMessage = nil

        let relativeRoot = path.map(\.name)
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                var totalFiles = 0
                var doneFiles = 0
                var totalBytes: Int64 = 0
                var doneBytes: Int64 = 0

                // Pre-count so the bar means something.
                func count(_ entry: FatXEntry) {
                    if entry.isDirectory {
                        totalFiles += 1
                        if let children = try? volume.volume.listDirectory(cluster: entry.startingCluster) {
                            for child in children where !child.isDeleted { count(child) }
                        }
                    } else {
                        totalFiles += 1
                        totalBytes += Int64(entry.size)
                    }
                }
                for entry in targetEntries { count(entry) }

                func report(_ label: String) {
                    let fraction: Double = totalBytes > 0
                        ? Double(doneBytes) / Double(totalBytes)
                        : (totalFiles > 0 ? Double(doneFiles) / Double(totalFiles) : 0)
                    DispatchQueue.main.async {
                        self.extractionProgress = min(1, fraction)
                        self.extractionLabel = label
                    }
                }

                func extractRecursive(_ entry: FatXEntry, into base: URL) throws {
                    let target = base.appendingPathComponent(sanitizedName(entry.name))
                    if entry.isDirectory {
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                        let children = try volume.volume.listDirectory(cluster: entry.startingCluster)
                        for child in children where !child.isDeleted {
                            try extractRecursive(child, into: target)
                        }
                        doneFiles += 1
                        report(entry.name)
                    } else {
                        try volume.volume.extract(entry, to: target) { written, _ in
                            DispatchQueue.main.async {
                                let fraction: Double = totalBytes > 0
                                    ? Double(doneBytes + written) / Double(totalBytes)
                                    : 0
                                self.extractionProgress = min(1, fraction)
                                self.extractionLabel = entry.name
                            }
                            return true
                        }
                        doneBytes += Int64(entry.size)
                        doneFiles += 1
                        report(entry.name)
                    }
                }

                for entry in targetEntries {
                    try extractRecursive(entry, into: destination)
                }

                DispatchQueue.main.async {
                    self.isExtracting = false
                    self.extractionProgress = 1
                    self.extractionLabel = "完成"
                    self.statusMessage = "已提取 \(targetEntries.count) 项到 \(destination.lastPathComponent)"
                    _ = relativeRoot
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                DispatchQueue.main.async {
                    self.isExtracting = false
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    nonisolated private func sanitizedName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\0")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "unnamed" : cleaned
    }

    // MARK: - Writing

    /// Uploads land in the directory currently being browsed, which is the
    /// only sane default: the drop target is where the user is looking.
    @Published private(set) var isWriting = false
    @Published private(set) var writeProgress: Double = 0
    @Published private(set) var writeLabel: String = ""
    /// Bytes committed so far and the planned total, for a real progress bar
    /// (a bare percentage alone never tells you how much is left).
    @Published private(set) var writeBytes: (written: Int64, total: Int64) = (0, 0)
    /// Only uploads can be cancelled; short metadata writes must not offer a
    /// button that does nothing.
    @Published private(set) var writeIsCancellable = false
    private let writeCancel = WriteCancelFlag()

    var canWrite: Bool {
        selectedVolume?.isWritable ?? false
    }

    /// The name a local file will end up with. FATX is single-byte, so Chinese
    /// names have to be transliterated away — surfacing that up front beats
    /// letting the write fail halfway.
    func plannedName(for url: URL) -> String {
        FatXWriter.sanitizedName(url.lastPathComponent)
    }

    func plannedNameChanged(for url: URL) -> Bool {
        plannedName(for: url) != url.lastPathComponent
    }

    /// Asks macOS for write permission on the device node, then remounts.
    /// Only permission bits change here; nothing is written to the disk.
    func requestWritePermission() {
        guard let mounted = selectedVolume else {
            errorMessage = "先选一个分区，再申请写权限。"
            return
        }
        guard mounted.isRawDevice else {
            statusMessage = "镜像是本地文件，本来就是可写的。"
            return
        }
        // Identify the disk by identifier, not by display name: two drives can
        // share a model string, and a renamed volume would break the match.
        let device = devices.first { $0.id == mounted.deviceID }
            ?? devices.first {
                let name = $0.displayName.isEmpty ? $0.id : $0.displayName
                return name == mounted.originName
            }
        guard let device else {
            errorMessage = "找不到 \(mounted.originName) 对应的设备。点工具栏的刷新，再点一次设备重新挂载。"
            return
        }
        guard !mounted.isWritable else {
            statusMessage = "\(device.id) 已经是读写模式。"
            return
        }

        // Drop every volume from this disk before touching permissions: they all
        // share one file descriptor, and the open mode is fixed at construction
        // time, so write access needs a brand-new handle.
        let originName = mounted.originName
        mounted.source.close()
        volumes.removeAll { $0.originName == originName }
        if selectedVolumeID == nil || !volumes.contains(where: { $0.id == selectedVolumeID }) {
            selectedVolumeID = volumes.first?.id
        }
        entries = []
        path = []
        forwardStack = []

        statusMessage = "等待管理员授权…"
        var granted = DeviceEnumerator.canWriteRawDevice(device)
        var detail = ""
        if granted {
            detail = "设备节点已有写权限，跳过授权"
            BoxingBuffaloLog.log("write-access \(device.id): 权限位已允许，跳过授权")
        } else {
            let outcome = DeviceEnumerator.requestWriteAccessDetailed(for: device)
            granted = outcome.granted
            detail = outcome.detail
        }

        pendingWriteUnlock = true
        pendingUnlockDetail = detail
        mount(device: device)
    }

    /// Re-checks the device node and reports the answer without touching the
    /// volume, for the "为什么还是只读" case.
    func diagnoseWriteAccess() {
        guard let mounted = selectedVolume, let id = mounted.deviceID,
              let device = devices.first(where: { $0.id == id }) else { return }
        let writable = DeviceEnumerator.canWriteRawDevice(device)
        let rawPerms = (try? FileManager.default.attributesOfItem(atPath: device.rawPath)[.posixPermissions]
                        as? NSNumber)?.intValue
        let permText = rawPerms.map { String($0, radix: 8) } ?? "未知"
        BoxingBuffaloLog.log("diagnose \(id): canOpenRDWR=\(writable) perms=\(permText)")
        statusMessage = "\(id) 节点权限 \(permText) · 读写句柄\(writable ? "可用" : "不可用")"
    }
    /// Cancels an in-flight upload. The write queue notices the flag at the
    /// next progress callback, frees the clusters it claimed, and the journal
    /// restores every metadata sector touched by this upload.
    func cancelWrite() {
        guard isWriting, writeIsCancellable else { return }
        writeCancel.set()
        writeLabel = "正在取消…"
        statusMessage = "正在取消上传（当前写入窗口结束后回滚）…"
    }

    func upload(urls: [URL], overwrite: Bool = true) {
        guard let mounted = selectedVolume else {
            errorMessage = "没有挂载的卷。"
            return
        }
        guard mounted.isWritable else {
            errorMessage = "当前卷以只读方式打开，无法写入。点工具栏的「解锁写入」获取设备写权限。"
            return
        }
        guard !isWriting, !urls.isEmpty else { return }
        let target = currentCluster
        let volume = mounted.volume
        let destinationPath = breadcrumb.map(\.name).joined(separator: " / ")

        isWriting = true
        writeBytes = (0, 0)
        writeIsCancellable = true
        writeCancel.reset()
        // Capture the flag as a local so the background queue never has to
        // reach back into the main-actor-isolated model.
        let cancelFlag = writeCancel
        writeProgress = 0
        writeLabel = "整理上传清单…"
        errorMessage = nil

        workQueue.async { [weak self] in
            guard let self else { return }
            let journal = WriteJournal()
            do {
                // A mixed selection of files and folders becomes a tree. Doing
                // this before the first write means a bad name or an oversized
                // file cannot leave a half-created directory behind.
                let plan = try FolderUploadPlanner.plan(urls: urls)
                DispatchQueue.main.async {
                    self.writeBytes = (0, plan.totalBytes)
                    self.writeLabel = "准备写入 \(plan.fileCount) 个文件…"
                }
                let writer = try FatXWriter(volume: volume)
                writer.journal = journal

                try FolderUploadWriter.write(plan: plan, to: target,
                                             writer: writer, overwrite: overwrite) { update in
                    // Checked once per coalesced window (8 MiB), so the current
                    // window always finishes cleanly before we unwind.
                    if cancelFlag.isSet { return false }
                    DispatchQueue.main.async {
                        self.writeProgress = update.total > 0
                            ? min(1, Double(update.written) / Double(update.total)) : 0
                        self.writeBytes = (update.written, update.total)
                        self.writeLabel = "写入 \(update.name)…"
                    }
                    return true
                }

                DispatchQueue.main.async {
                    self.isWriting = false
                    self.writeIsCancellable = false
                    self.writeProgress = 1
                    self.writeBytes = (plan.totalBytes, plan.totalBytes)
                    self.writeLabel = "完成"
                    self.entryCache.removeAll()
                    self.reloadEntries()
                    var message = "已写入 \(plan.fileCount) 个文件"
                    if plan.folderCount > 0 { message += "、\(plan.folderCount) 个文件夹" }
                    message += " 到 \(destinationPath)"
                    if !plan.warnings.isEmpty {
                        let shown = plan.warnings.prefix(4).joined(separator: "；")
                        message += "（提示：\(shown)\(plan.warnings.count > 4 ? " …共 \(plan.warnings.count) 条" : "")）"
                    }
                    self.statusMessage = message
                }
            } catch {
                let cancelled = cancelFlag.isSet
                journal.rollback(source: volume.source)
                DispatchQueue.main.async {
                    self.isWriting = false
                    self.writeIsCancellable = false
                    self.writeLabel = cancelled ? "已取消" : "失败"
                    // A failure can still leave a committed entry behind (for
                    // instance when the second of three files fails), so always
                    // re-read the directory instead of trusting the cache.
                    self.entryCache.removeAll()
                    self.reloadEntries()
                    if cancelled {
                        // The journal restores every FAT sector and directory
                        // slot touched by this upload, so even files that were
                        // already committed are undone. Payload bytes stay on
                        // the media but their clusters are free again.
                        self.statusMessage = "已取消上传 · 本次写入的目录项与 FAT 已回滚，数据簇恢复空闲；原有文件不受影响"
                    } else {
                        self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    }
                }
            }
        }
    }

    func createFolder(named rawName: String) {
        guard let mounted = selectedVolume, mounted.isWritable else {
            errorMessage = "当前卷以只读方式打开，无法新建文件夹。"
            return
        }
        guard !isWriting else { return }
        let target = currentCluster
        let volume = mounted.volume

        isWriting = true
        writeBytes = (0, 0)
        writeIsCancellable = false
        writeLabel = "新建文件夹…"
        workQueue.async { [weak self] in
            guard let self else { return }
            let journal = WriteJournal()
            do {
                let writer = try FatXWriter(volume: volume)
                writer.journal = journal
                let folder = try writer.addDirectory(named: rawName, to: target)
                DispatchQueue.main.async {
                    self.isWriting = false
                    self.writeLabel = "完成"
                    self.entryCache.removeAll()
                    self.reloadEntries()
                    self.statusMessage = "已新建文件夹 \(folder.name)"
                }
            } catch {
                journal.rollback(source: volume.source)
                DispatchQueue.main.async {
                    self.isWriting = false
                    self.writeLabel = "失败"
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    func delete(entries targetEntries: [FatXEntry]) {
        guard let mounted = selectedVolume, mounted.isWritable else {
            errorMessage = "当前卷以只读方式打开，无法删除。"
            return
        }
        guard !isWriting, !targetEntries.isEmpty else { return }
        let target = currentCluster
        let volume = mounted.volume

        isWriting = true
        writeBytes = (0, 0)
        writeIsCancellable = false
        writeLabel = "删除…"
        workQueue.async { [weak self] in
            guard let self else { return }
            let journal = WriteJournal()
            do {
                let writer = try FatXWriter(volume: volume)
                writer.journal = journal
                for entry in targetEntries {
                    try writer.delete(entry, from: target)
                }
                DispatchQueue.main.async {
                    self.isWriting = false
                    self.writeLabel = "完成"
                    self.selection = []
                    self.entryCache.removeAll()
                    self.reloadEntries()
                    self.statusMessage = "已删除 \(targetEntries.count) 项"
                }
            } catch {
                journal.rollback(source: volume.source)
                DispatchQueue.main.async {
                    self.isWriting = false
                    self.writeLabel = "失败"
                    self.entryCache.removeAll()
                    self.reloadEntries()
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    func rename(_ entry: FatXEntry, to newName: String) {
        guard let mounted = selectedVolume, mounted.isWritable else {
            errorMessage = "当前卷以只读方式打开，无法重命名。"
            return
        }
        guard !isWriting else { return }
        let target = currentCluster
        let volume = mounted.volume

        isWriting = true
        writeBytes = (0, 0)
        writeIsCancellable = false
        writeLabel = "重命名…"
        workQueue.async { [weak self] in
            guard let self else { return }
            let journal = WriteJournal()
            do {
                let writer = try FatXWriter(volume: volume)
                writer.journal = journal
                try writer.rename(entry, to: newName, in: target)
                DispatchQueue.main.async {
                    self.isWriting = false
                    self.writeLabel = "完成"
                    self.entryCache.removeAll()
                    self.reloadEntries()
                    self.statusMessage = "已重命名为 \(newName)"
                }
            } catch {
                journal.rollback(source: volume.source)
                DispatchQueue.main.async {
                    self.isWriting = false
                    self.writeLabel = "失败"
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    // MARK: - Quick Look

    func writeTempFileForPreview(_ entry: FatXEntry) -> URL? {
        guard let volume = selectedVolume, !entry.isDirectory else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxingBuffaloPreview", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(sanitizedName(entry.name))
            try volume.volume.extract(entry, to: target)
            return target
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return nil
        }
    }
}
