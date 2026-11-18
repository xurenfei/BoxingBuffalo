import Foundation
import Darwin
import FatXCore

// Device mode: `fatxcheck /dev/rdisk8` inspects a real drive instead of running
// the synthetic self-check. Read-only, exactly like the app.
if CommandLine.arguments.count > 1 {
    let path = CommandLine.arguments[1]
    let source: BlockSource
    do {
        source = path.hasPrefix("/dev/r") ? try RawBlockSource(path: path)
                                          : try FileBlockSource(path: path)
        print("设备 \(path) · \(FatXVolume.friendlySize(source.length))")
    } catch {
        print("打开 \(path) 失败：\(error)")
        exit(1)
    }
    do {
        let volumes = try PartitionScanner.scan(source: source) { _, _ in }
        print("发现 \(volumes.count) 个 FATX 卷")
        for discovered in volumes {
            let volume = discovered.volume
            print("\n=== \(discovered.label) @ 0x\(String(volume.partitionOffset, radix: 16).uppercased()) ===")
            for (key, value) in volume.geometrySummary {
                print("  \(key): \(value)")
            }
            // Exact regression for the real-drive failure: the FAT allocator
            // reads fatOffset + 8 for 1 MiB. A raw disk rejects that unless the
            // read is rounded out to whole 512-byte sectors first.
            if source.isRawDevice {
                let probeOffset = volume.fatOffset + 8
                let slice = try? source.readPadded(offset: probeOffset, count: 1 << 20)
                print("  FAT 非对齐 1 MiB 读 @ 0x\(String(probeOffset, radix: 16))：\(slice?.count ?? 0) 字节 \(slice?.count == 1 << 20 ? "✔" : "✗ EINVAL")")
            }
            let root = (try? volume.listDirectory(cluster: volume.rootDirectoryCluster)) ?? []
            print("  根目录 \(root.count) 项：")
            for entry in root.prefix(25) {
                let kind = entry.isDirectory ? "DIR " : "FILE"
                print("    \(kind) \(entry.name)  簇=\(entry.startingCluster)  大小=\(entry.size)")
            }
            // Root-level small files: read them end to end and eyeball the bytes.
            for entry in root where !entry.isDirectory && entry.size > 0 && entry.size <= 8192 {
                if let data = try? volume.readFileData(entry) {
                    let ok = data.count == Int(entry.size)
                    let text = String(data: data.prefix(120), encoding: .utf8)?
                        .replacingOccurrences(of: "\n", with: " ") ?? "(二进制)"
                    print("    ⤷ \(entry.name) 读出 \(data.count) 字节 \(ok ? "✔" : "✗") 内容片段：\(text)")
                }
            }
            // Drill one level into the first few directories to prove the FAT
            // chain walk and recursion work on the real thing.
            for entry in root.filter({ $0.isDirectory }).prefix(3) {
                let children = (try? volume.listDirectory(cluster: entry.startingCluster)) ?? []
                print("    └─ \(entry.name)/ 下 \(children.count) 项")
                for child in children.prefix(8) {
                    let kind = child.isDirectory ? "DIR " : "FILE"
                    print("         \(kind) \(child.name)  簇=\(child.startingCluster)  大小=\(child.size)")
                }
                // Small files get read end-to-end and byte-counted.
                for child in children where !child.isDirectory && child.size > 0 && child.size <= 4096 {
                    if let data = try? volume.readFileData(child) {
                        print("         ⤷ 读出 \(child.name)：\(data.count) 字节 \(data.count == Int(child.size) ? "✔" : "✗ 大小不符")")
                    }
                }
            }
        }
    } catch {
        print("扫描失败：\(error)")
        exit(1)
    }
    exit(0)
}

// Self-check harness. Builds a synthetic FATX image, scans it, walks every
// directory, extracts every file and compares bytes. Exits non-zero on any
// mismatch so it can gate a build.

var failures: [String] = []
var checks = 0

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures.append(message)
        print("  ✗ \(message)")
    }
}

func section(_ title: String) {
    print("\n▸ \(title)")
}

// MARK: - 1. Build the image

section("构造合成 FATX 镜像")
let tree = FatXImageBuilder.sampleTree()
let built: FatXImageBuilder.Result
do {
    built = try FatXImageBuilder.build(root: tree, totalSize: 48 << 20, sectorsPerCluster: 8)
    print("  镜像大小 \(FatXVolume.friendlySize(Int64(built.image.count))) · 簇大小 \(built.clusterSize) · 共 \(built.totalClusters) 簇 · FAT 项 \(built.fatEntrySize) 字节")
} catch {
    print("  ✗ 构造失败：\(error)")
    exit(1)
}

let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("boxingbuffalo-selftest-\(UUID().uuidString).bin")
do {
    try built.image.write(to: tempURL)
    print("  写入 \(tempURL.path)")
} catch {
    print("  ✗ 写临时文件失败：\(error)")
    exit(1)
}
defer { try? FileManager.default.removeItem(at: tempURL) }

// MARK: - 2. Open through the real code path

section("通过 FileBlockSource + PartitionScanner 打开")
let source: BlockSource
do {
    source = try FileBlockSource(path: tempURL.path)
    check(source.length == Int64(built.image.count), "设备长度与镜像一致")
} catch {
    print("  ✗ 打开失败：\(error)")
    exit(1)
}

var found: [DiscoveredVolume] = []
do {
    // Empty the scanner's known-offset cache path by scanning normally.
    found = try PartitionScanner.scan(source: source) { progress, message in
        _ = progress; _ = message
    }
    print("  发现 \(found.count) 个 FATX 卷")
    for volume in found {
        print("    · \(volume.label) @ 0x\(String(volume.volume.partitionOffset, radix: 16).uppercased()) · \(FatXVolume.friendlySize(volume.volume.partitionSize))")
    }
    check(found.count >= 1, "至少发现一个卷")
} catch {
    print("  ✗ 扫描失败：\(error)")
    exit(1)
}

guard let primary = found.first else {
    print("  ✗ 没有可用卷")
    exit(1)
}
let volume = primary.volume

section("校验超级块几何")
print("  " + volume.geometrySummary.map { "\($0.0)=\($0.1)" }.joined(separator: "  "))
check(volume.clusterSize == built.clusterSize, "簇大小与构造时一致")
check(volume.totalClusters == built.totalClusters, "簇总数与构造时一致")
check(volume.fatEntrySize == built.fatEntrySize, "FAT 项宽度一致")
check(volume.rootDirectoryCluster == 1, "根目录簇为 1")

// MARK: - 3. Walk the tree and compare against the source tree

section("遍历目录树并与源树比对")

func expectedName(_ node: FatXImageBuilder.Node) -> String { node.name }

var extractedTotal = 0
var fileCount = 0
var dirCount = 0

func walk(nodes: [FatXImageBuilder.Node], cluster: UInt32, path: String, depth: Int) {
    let entries: [FatXEntry]
    do {
        entries = try volume.listDirectory(cluster: cluster)
    } catch {
        check(false, "读取目录 \(path) 失败：\(error)")
        return
    }

    let liveEntries = entries.filter { !$0.isDeleted }
    let expectedLive = nodes

    check(liveEntries.count == expectedLive.count,
          "目录 \(path) 应有 \(expectedLive.count) 项，实际读到 \(liveEntries.count) 项")

    let indent = String(repeating: "  ", count: depth)
    for node in nodes {
        guard let entry = liveEntries.first(where: { $0.name == expectedName(node) }) else {
            check(false, "目录 \(path) 缺少「\(expectedName(node))」")
            continue
        }

        switch node {
        case let .file(_, expectedData):
            fileCount += 1
            check(!entry.isDirectory, "「\(entry.name)」应被识别为文件")
            check(Int(entry.size) == expectedData.count,
                  "「\(entry.name)」大小应为 \(expectedData.count)，读到 \(entry.size)")
            do {
                let data = try volume.readFileData(entry, maxBytes: 64 << 20)
                check(data == expectedData, "「\(entry.name)」内容逐字节一致")
                extractedTotal += data.count
                print("\(indent)📄 \(entry.name)  \(FatXVolume.friendlySize(Int64(entry.size)))")
            } catch {
                check(false, "提取「\(entry.name)」失败：\(error)")
            }

        case let .directory(_, children):
            dirCount += 1
            check(entry.isDirectory, "「\(entry.name)」应被识别为目录")
            print("\(indent)📁 \(entry.name)/")
            walk(nodes: children, cluster: entry.startingCluster,
                 path: path + "/" + entry.name, depth: depth + 1)
        }
    }
}

// Debug: dump the first 256 bytes of the root directory cluster.
do {
    let raw = try volume.readCluster(volume.rootDirectoryCluster)
    let preview = raw.prefix(256)
    var hex = ""
    for (i, byte) in preview.enumerated() {
        if i % 64 == 0 { hex += String(format: "\n  0x%04X  ", i) }
        hex += String(format: "%02X ", byte)
        if i % 64 == 63 { hex += " |" }
    }
    print(hex)
    let names = try volume.listDirectory(cluster: volume.rootDirectoryCluster).map { "\($0.name)[\($0.isDirectory ? "D" : "F")]" }
    print("  解析出的名字：\(names.joined(separator: ", "))")
} catch { print("  dump 失败 \(error)") }

walk(nodes: tree, cluster: volume.rootDirectoryCluster, path: "/", depth: 0)
print("  遍历完成：\(dirCount) 个目录 · \(fileCount) 个文件 · 提取 \(FatXVolume.friendlySize(Int64(extractedTotal)))")

// MARK: - 4. Extraction to disk

section("提取到磁盘并复验")
let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("boxingbuffalo-extract-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: outDir) }

do {
    let rootEntries = try volume.listDirectory(cluster: volume.rootDirectoryCluster)
    if let readme = rootEntries.first(where: { $0.name == "readme.txt" }) {
        let target = outDir.appendingPathComponent("readme.txt")
        try volume.extract(readme, to: target)
        let data = try Data(contentsOf: target)
        check(data == Data("BoxingBuffalo sample FATX volume\n".utf8), "落盘文件内容一致")
        print("  已提取 readme.txt（\(data.count) 字节）")
    } else {
        check(false, "根目录找不到 readme.txt")
    }
} catch {
    check(false, "提取到磁盘失败：\(error)")
}

// MARK: - 5. Corruption handling

section("损坏数据容错")
do {
    // A cluster number past the end must throw, not crash.
    _ = try volume.readCluster(volume.totalClusters + 100)
    check(false, "越界簇应抛错")
} catch {
    check(true, "")
    print("  越界簇正确抛错")
}

// MARK: - 6. Write regression

section("写入回归")

let rwSource: BlockSource
do {
    rwSource = try FileBlockSource(path: tempURL.path, writable: true)
    check(rwSource.isWritable, "镜像以可写方式打开")
} catch {
    print("  ✗ 可写打开失败：\(error)")
    exit(1)
}

let rwVolume: FatXVolume
do {
    rwVolume = try FatXVolume(source: rwSource,
                              partitionOffset: volume.partitionOffset,
                              partitionSize: volume.partitionSize,
                              name: "写入测试")
} catch {
    print("  ✗ 挂载可写卷失败：\(error)")
    exit(1)
}

let writer: FatXWriter
do {
    writer = try FatXWriter(volume: rwVolume)
} catch {
    print("  ✗ 创建写入器失败：\(error)")
    exit(1)
}

let rootCluster = rwVolume.rootDirectoryCluster
let clusterBytes = Int(rwVolume.clusterSize)

// 6.1 A file that spans many clusters.
let payload = Data((0..<(clusterBytes * 25 + 137)).map { UInt8($0 % 251) })
var crossEntry: FatXEntry?
do {
    let entry = try writer.addFile(named: "crosscluster.bin", data: payload, to: rootCluster)
    crossEntry = entry
    check(Int(entry.size) == payload.count, "写入返回的大小与实际一致（\(entry.size) / \(payload.count)）")
    let chain = try rwVolume.clusterChain(startingAt: entry.startingCluster)
    let expected = (payload.count + clusterBytes - 1) / clusterBytes
    check(chain.count == expected, "跨簇文件应占 \(expected) 簇，实际 \(chain.count)")
    let readBack = try rwVolume.readFileData(entry)
    check(readBack == payload, "写入后立刻读回逐字节一致")
    print("  写入 crosscluster.bin：\(FatXVolume.friendlySize(Int64(entry.size))) · \(chain.count) 簇")
} catch {
    check(false, "跨簇写入失败：\(error)")
}

// 6.2 New directory plus a nested file.
var uploadsDir: FatXEntry?
do {
    let dir = try writer.addDirectory(named: "Uploads", to: rootCluster)
    uploadsDir = dir
    check(dir.isDirectory, "新建条目被识别为目录")
    let note = try writer.addFile(named: "note.txt",
                                  data: Data("hello from boxingbuffalo\n".utf8),
                                  to: dir.startingCluster)
    let children = try rwVolume.listDirectory(cluster: dir.startingCluster)
    check(children.contains { $0.name == "note.txt" }, "子目录里能枚举到刚写的文件")
    check(try rwVolume.readFileData(note) == Data("hello from boxingbuffalo\n".utf8), "嵌套文件内容一致")
    print("  新建目录 Uploads/ 并写入 note.txt")
} catch {
    check(false, "目录写入失败：\(error)")
}

// 6.3 Dismount and remount: everything must survive a fresh parse.
do {
    rwSource.synchronize()
    let fresh = try FileBlockSource(path: tempURL.path)
    defer { fresh.close() }
    let remounted = try FatXVolume(source: fresh,
                                   partitionOffset: volume.partitionOffset,
                                   partitionSize: volume.partitionSize)
    let entries = try remounted.listDirectory(cluster: remounted.rootDirectoryCluster)
    check(entries.contains { $0.name == "crosscluster.bin" }, "重新挂载后仍能枚举到新文件")
    if let entry = entries.first(where: { $0.name == "crosscluster.bin" }) {
        check(try remounted.readFileData(entry) == payload, "重新挂载后内容仍逐字节一致")
    }
    if let dir = entries.first(where: { $0.name == "Uploads" }) {
        let kids = try remounted.listDirectory(cluster: dir.startingCluster)
        check(kids.contains { $0.name == "note.txt" }, "重新挂载后子目录结构完整")
    }
    print("  重新挂载校验通过")
} catch {
    check(false, "重新挂载失败：\(error)")
}

// 6.4 Overwrite: the old chain must be released, the new payload must win.
do {
    guard let before = crossEntry else { throw FatXError.unsupported("没有基准文件") }
    let oldChain = try rwVolume.clusterChain(startingAt: before.startingCluster)
    let replacement = Data(repeating: 0x41, count: clusterBytes * 3 + 9)
    let updated = try writer.addFile(named: "crosscluster.bin", data: replacement, to: rootCluster)
    check(try rwVolume.readFileData(updated) == replacement, "覆盖后内容为新数据")
    let newChain = Set(try rwVolume.clusterChain(startingAt: updated.startingCluster))
    var leaked = 0
    for cluster in oldChain where !newChain.contains(cluster) {
        if try rwVolume.fatEntry(cluster: cluster) != 0 { leaked += 1 }
    }
    check(leaked == 0, "覆盖后旧链已全部释放（残留 \(leaked) 个簇）")
    let all = try rwVolume.listDirectory(cluster: rootCluster).filter { !$0.isDeleted }
    check(all.filter { $0.name == "crosscluster.bin" }.count == 1, "覆盖没有产生重复条目")
    crossEntry = updated
    print("  覆盖写入通过（旧链 \(oldChain.count) 簇已释放）")
} catch {
    check(false, "覆盖写入失败：\(error)")
}

// 6.5 Delete: entry flips to 0xE5 and the space comes back.
do {
    guard let target = crossEntry else { throw FatXError.unsupported("没有可删文件") }
    let freeBefore = try writer.freeClusterCount()
    let chain = try rwVolume.clusterChain(startingAt: target.startingCluster)
    try writer.delete(target, from: rootCluster)
    let freeAfter = try writer.freeClusterCount()
    check(freeAfter - freeBefore == chain.count,
          "删除后空闲簇应增加 \(chain.count)，实际增加 \(freeAfter - freeBefore)")
    let entries = try rwVolume.listDirectory(cluster: rootCluster)
    check(entries.contains { $0.name == "crosscluster.bin" && $0.isDeleted }, "删除后条目标记为 0xE5")
    check(!entries.contains { $0.name == "crosscluster.bin" && !$0.isDeleted }, "删除后不再出现在活跃项里")
    print("  删除通过（回收 \(chain.count) 簇）")
} catch {
    check(false, "删除失败：\(error)")
}

// 6.6 Directory growth: a 512-byte cluster holds only 8 slots, so the ninth
// entry has to force a new cluster onto the directory chain.
do {
    let smallImage: FatXImageBuilder.Result
    smallImage = try FatXImageBuilder.build(root: [], totalSize: 2 << 20, sectorsPerCluster: 1)
    let smallURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("boxingbuffalo-dirgrowth-\(UUID().uuidString).bin")
    try smallImage.image.write(to: smallURL)
    defer { try? FileManager.default.removeItem(at: smallURL) }

    let smallSource = try FileBlockSource(path: smallURL.path, writable: true)
    defer { smallSource.close() }
    let smallVolume = try FatXVolume(source: smallSource, partitionOffset: 0, partitionSize: smallSource.length)
    let smallWriter = try FatXWriter(volume: smallVolume)
    let dir = try smallWriter.addDirectory(named: "Many", to: smallVolume.rootDirectoryCluster)
    let slotsPerCluster = Int(smallVolume.clusterSize) / FatXConstants.dirEntrySize
    check(slotsPerCluster < 20, "测试簇容量足够小（每簇 \(slotsPerCluster) 槽）")

    var added = 0
    for index in 0..<20 {
        try smallWriter.addFile(named: "f\(index).txt",
                                data: Data("entry \(index)".utf8),
                                to: dir.startingCluster)
        added += 1
    }
    let children = try smallVolume.listDirectory(cluster: dir.startingCluster)
    check(children.count == added, "目录扩簇后应能枚举 \(added) 项，实际 \(children.count)")
    let dirChain = try smallVolume.clusterChain(startingAt: dir.startingCluster)
    check(dirChain.count > 1, "目录确实扩展到了多个簇（实际 \(dirChain.count) 簇）")
    let verify = try smallVolume.readFileData(children.first { $0.name == "f19.txt" }!)
    check(verify == Data("entry 19".utf8), "扩簇后写入的内容仍正确")
    print("  目录扩簇通过（\(slotsPerCluster) 槽/簇 → \(dirChain.count) 簇放下 20 项）")
} catch {
    check(false, "目录扩簇失败：\(error)")
}

// 6.7 Names: FATX is single-byte, so a Chinese name must be refused rather
// than silently written as mojibake the console cannot open.
do {
    _ = try writer.addFile(named: "中文名.txt", data: Data("x".utf8), to: rootCluster)
    check(false, "中文文件名应被拒绝")
} catch {
    check(true, "")
    print("  中文文件名正确被拒（FATX 只支持 ASCII）")
}
do {
    let safe = FatXWriter.sanitizedName("游戏 存档.dat")
    check(safe.utf8.count <= FatXConstants.maxNameLength, "净化后的名字长度合规")
    check(safe.contains("."), "净化后保留扩展名")
    print("  名字净化：'游戏 存档.dat' → '\(safe)'")
} catch {
    check(false, "名字净化抛出异常")
}

// 6.8 Recursive folder upload: structure, name folding, hidden files, symlinks.
do {
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("boxingbuffalo-folder-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let pack = scratch.appendingPathComponent("Pack", isDirectory: true)
    let sub = pack.appendingPathComponent("Sub", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try Data("top level".utf8).write(to: pack.appendingPathComponent("readme.txt"))
    try Data("nested".utf8).write(to: sub.appendingPathComponent("data.bin"))
    try Data("chinese".utf8).write(to: sub.appendingPathComponent("存档.txt"))
    try Data("metadata".utf8).write(to: pack.appendingPathComponent(".DS_Store"))
    try FileManager.default.createSymbolicLink(
        at: pack.appendingPathComponent("link.txt"),
        withDestinationURL: pack.appendingPathComponent("readme.txt"))

    let plan = try FolderUploadPlanner.plan(urls: [pack])
    let expectedBytes = Int64("top level".utf8.count + "nested".utf8.count + "chinese".utf8.count)
    check(plan.fileCount == 3, "文件夹计划应含 3 个文件，实际 \(plan.fileCount)")
    check(plan.folderCount == 2, "文件夹计划应含 2 层目录，实际 \(plan.folderCount)")
    check(plan.totalBytes == expectedBytes, "文件夹计划字节数正确（\(plan.totalBytes)）")
    check(plan.warnings.contains { $0.contains("存档") }, "中文名净化被记录为提示")
    print("  文件夹计划：\(plan.fileCount) 文件 / \(plan.folderCount) 目录 · \(plan.totalBytes) B")

    let written = try FolderUploadWriter.write(plan: plan, to: rootCluster, writer: writer)
    check(written == plan.totalBytes, "递归写入字节数与计划一致")

    func packEntry() throws -> FatXEntry? {
        try rwVolume.listDirectory(cluster: rootCluster)
            .first { $0.name == "Pack" && $0.isDirectory && !$0.isDeleted }
    }
    let firstPack = try packEntry()
    check(firstPack != nil, "根目录下创建了 Pack/")
    if let folder = firstPack {
        let kids = try rwVolume.listDirectory(cluster: folder.startingCluster)
        check(kids.contains { $0.name == "readme.txt" }, "Pack/ 里有顶层文件")
        check(!kids.contains { $0.name == ".DS_Store" }, "隐藏文件 .DS_Store 被跳过")
        check(!kids.contains { $0.name == "link.txt" }, "符号链接被跳过")
        if let subEntry = kids.first(where: { $0.name == "Sub" && $0.isDirectory }) {
            let subKids = try rwVolume.listDirectory(cluster: subEntry.startingCluster)
            check(subKids.contains { $0.name == "data.bin" }, "Sub/ 里有嵌套文件")
            check(subKids.contains { $0.name == "_.txt" }, "中文名净化为 _.txt 后写入")
            if let data = subKids.first(where: { $0.name == "data.bin" }) {
                check(try rwVolume.readFileData(data) == Data("nested".utf8), "嵌套文件内容一致")
            }
        } else {
            check(false, "Sub/ 子目录存在")
        }
    }

    // Re-uploading must merge, not duplicate the whole tree.
    let again = try FolderUploadPlanner.plan(urls: [pack])
    try FolderUploadWriter.write(plan: again, to: rootCluster, writer: writer)
    let packs = try rwVolume.listDirectory(cluster: rootCluster)
        .filter { $0.name == "Pack" && $0.isDirectory && !$0.isDeleted }
    check(packs.count == 1, "重复上传同名目录应合并，实际 \(packs.count) 个")
    print("  递归目录写入、中文名净化、隐藏项跳过、重复上传合并均通过")
} catch {
    check(false, "文件夹上传回归失败：\(error)")
}

// MARK: - 7. Sector alignment (the invariant CLKsFATXLib enforces)

section("扇区对齐读取回归（模拟裸设备 512 字节约束）")

/// Stands in for `/dev/rdisk*`: any transfer whose offset or length is not a
/// whole sector fails with EINVAL, exactly as measured on the HM500JI bridge.
final class StrictSectorSource: BlockSource {
    private let backing: FileBlockSource
    let displayName: String
    var length: Int64 { backing.length }
    var isRawDevice: Bool { true }
    var isWritable: Bool { false }

    init(path: String) throws {
        backing = try FileBlockSource(path: path)
        displayName = "strict-sector:" + (path as NSString).lastPathComponent
    }

    func read(offset: Int64, count: Int) throws -> Data {
        try SectorAlignedIO.read(offset: offset, count: count,
                                 length: length, sectorSize: deviceSectorSize) { off, n in
            guard off % Int64(deviceSectorSize) == 0,
                  n % deviceSectorSize == 0 else {
                throw FatXError.readFailed(offset: off, count: n, errno: EINVAL)
            }
            return try backing.read(offset: off, count: n)
        }
    }

    func close() { backing.close() }
}

do {
    let strict = try StrictSectorSource(path: tempURL.path)
    defer { strict.close() }
    // The write regression above has already modified this image on disk, so
    // compare against the current bytes, not the pristine in-memory build.
    let image = try Data(contentsOf: tempURL)
    func original(_ offset: Int64, _ count: Int) -> Data {
        let start = image.startIndex + Int(offset)
        return Data(image[start..<(start + count)])
    }

    // 7.1 The precise call that failed on the real disk: fatOffset + 8, 1 MiB.
    let fatProbe = volume.fatOffset + 8
    let oneMiB = 1 << 20
    let fatSlice = try strict.readPadded(offset: fatProbe, count: oneMiB)
    check(fatSlice.count == oneMiB, "fatOffset+8 的 1 MiB 读返回完整长度")
    check(fatSlice == original(fatProbe, oneMiB), "fatOffset+8 的 1 MiB 非对齐读逐字节一致")

    // 7.2 Tiny unaligned reads: FAT entries, directory records, magic probes.
    let probes: [(Int64, Int, String)] = [
        (volume.fatOffset + 13, 3, "FAT 项碎片"),
        (volume.dataOffset + 1, 63, "目录项碎片"),
        (Int64(0x40000), 0x100, "magic 探测 256 字节"),
        (Int64(0x20000) + 7, 4096, "跨扇区 4 KiB 读"),
    ]
    for (off, count, label) in probes {
        let got = try strict.readPadded(offset: off, count: count)
        check(got == original(off, count), "\(label)：非对齐读逐字节一致")
    }

    // 7.3 Reads past the end must be zero-padded, never EINVAL.
    let tail = try strict.readPadded(offset: strict.length - 100, count: 200)
    check(tail.count == 200, "设备末尾读补足长度")
    check(Data(tail.prefix(100)) == original(strict.length - 100, 100), "设备末尾有效字节一致")
    check(tail.suffix(100).allSatisfy { $0 == 0 }, "设备末尾补零")

    // 7.4 A whole-sector request still matches the plain file path.
    let aligned = try strict.read(offset: 0, count: 4096)
    check(aligned == original(0, 4096), "已对齐请求走快速路径且数据一致")
    print("  非对齐 FAT 扫描、碎片读、末尾补零、对齐快路径均通过")
} catch {
    check(false, "扇区对齐回归失败：\(error)")
}

// MARK: - 8. Bulk write coalescing

section("连续簇合并大块写")

/// Counts device writes and reproduces RawBlockSource's alignment rule so the
/// self-check can prove that large payloads are coalesced and never pay a
/// read-modify-write pre-read.
final class CoalescingProbe: BlockSource {
    private let backing: FileBlockSource
    let displayName = "coalescing-probe"
    var length: Int64 { backing.length }
    var isRawDevice: Bool { false }
    var isWritable: Bool { true }

    /// Set once the volume geometry is known. Writes at/after this offset that
    /// are a full cluster or larger are file payload, not metadata.
    var payloadOffset: Int64 = .max
    var payloadWrites = 0
    var payloadBytes: Int64 = 0
    var payloadReadModifyWrites = 0

    init(path: String) throws {
        backing = try FileBlockSource(path: path, writable: true)
    }
    func read(offset: Int64, count: Int) throws -> Data {
        try backing.read(offset: offset, count: count)
    }
    func write(offset: Int64, data: Data) throws {
        let block = Int64(deviceWriteBlockSize)
        let isPayload = offset >= payloadOffset && data.count >= 4096
        let aligned = offset % block == 0 && Int64(data.count) % block == 0
        if isPayload {
            payloadWrites += 1
            payloadBytes += Int64(data.count)
            if !aligned { payloadReadModifyWrites += 1 }
        }
        if !aligned {
            let start = (offset / block) * block
            let end = ((offset + Int64(data.count) + block - 1) / block) * block
            _ = try read(offset: start, count: Int(end - start))
        }
        try backing.write(offset: offset, data: data)
    }
    func synchronize() { backing.synchronize() }
    func close() { backing.close() }
}

do {
    let bulkURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("boxingbuffalo-bulk-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: bulkURL) }
    let fresh = try FatXImageBuilder.build(root: FatXImageBuilder.sampleTree(),
                                           totalSize: 96 << 20,
                                           sectorsPerCluster: 8)
    try fresh.image.write(to: bulkURL)

    let probe = try CoalescingProbe(path: bulkURL.path)
    defer { probe.close() }
    let bulkVolume = try FatXVolume(source: probe,
                                    partitionOffset: 0,
                                    partitionSize: Int64(fresh.image.count),
                                    name: "批量写")
    probe.payloadOffset = bulkVolume.dataOffset
    let bulkWriter = try FatXWriter(volume: bulkVolume)

    // 20 MiB deliberately spans three 8 MiB coalescing windows.
    let oneMiB = Data((0..<(1 << 20)).map { UInt8($0 % 251) })
    var pattern = Data()
    for i in 0..<20 {
        pattern.append(oneMiB)
        pattern[pattern.count - 1] = UInt8(i)
    }
    let payloadURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("boxingbuffalo-payload-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: payloadURL) }
    try pattern.write(to: payloadURL)

    let entry = try bulkWriter.addFile(from: payloadURL,
                                       named: "bulk.bin",
                                       to: bulkVolume.rootDirectoryCluster)
    let readBack = try bulkVolume.readFileData(entry)
    let clusters = pattern.count / Int(bulkVolume.clusterSize)
    check(Int(entry.size) == pattern.count, "批量写目录项大小正确")
    check(readBack == pattern, "20 MiB 跨 3 个合并窗口写入后逐字节一致")
    check(probe.payloadWrites <= 6,
          "20 MiB 只发起 \(probe.payloadWrites) 次设备写（逐簇写需要 \(clusters) 次）")
    check(probe.payloadReadModifyWrites == 0, "对齐的大块写跳过读-改-写预读")
    print("  20 MiB / \(clusters) 簇 → \(probe.payloadWrites) 次设备写 · "
          + "\(FatXVolume.friendlySize(probe.payloadBytes)) · RMW 预读 \(probe.payloadReadModifyWrites) 次")
} catch {
    check(false, "批量合并写回归失败：\(error)")
}

// MARK: - Cancel upload regression

do {
    let cancelImage = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("boxingbuffalo-cancel-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: cancelImage) }
    let built = try FatXImageBuilder.build(root: FatXImageBuilder.sampleTree(),
                                           totalSize: 96 << 20,
                                           sectorsPerCluster: 8)
    try built.image.write(to: cancelImage)
    let source = try FileBlockSource(path: cancelImage.path, writable: true)
    defer { source.close() }
    let volume = try FatXVolume(source: source,
                                partitionOffset: 0,
                                partitionSize: Int64(built.image.count),
                                name: "取消回归")
    let root = volume.rootDirectoryCluster
    let fatBefore = try source.read(offset: volume.fatOffset, count: Int(volume.fatSize))
    let dirBefore = try volume.readCluster(root)
    let entriesBefore = try volume.listDirectory(cluster: root)

    let payloadURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("boxingbuffalo-cancel-payload.bin")
    defer { try? FileManager.default.removeItem(at: payloadURL) }
    let slab = Data((0..<(1 << 20)).map { UInt8($0 % 251) })
    var payload = Data()
    for _ in 0..<20 { payload.append(slab) }   // 20 MiB → three 8 MiB windows
    try payload.write(to: payloadURL)

    let plan = try FolderUploadPlanner.plan(urls: [payloadURL])
    let writer = try FatXWriter(volume: volume)
    let journal = WriteJournal()
    writer.journal = journal
    var callbacks = 0
    var aborted = false
    do {
        try FolderUploadWriter.write(plan: plan, to: root, writer: writer) { _ in
            callbacks += 1
            return callbacks < 2            // cancel at the second window
        }
    } catch {
        aborted = true
    }
    journal.rollback(source: source)

    check(callbacks >= 2, "20 MiB 上传产生 \(callbacks) 次进度回调（取消有落点）")
    check(aborted, "进度回调返回 false 会中止整次上传")
    let entriesAfter = try volume.listDirectory(cluster: root)
    check(entriesAfter.count == entriesBefore.count,
          "取消后目录项数量不变（未提交半成品）")
    let fatAfter = try source.read(offset: volume.fatOffset, count: Int(volume.fatSize))
    check(fatBefore == fatAfter, "取消并回滚后 FAT 表逐字节还原（无孤儿簇）")
    let dirAfter = try volume.readCluster(root)
    check(dirBefore == dirAfter, "取消并回滚后根目录簇逐字节还原")
    print("  取消上传：第 \(callbacks) 个写入窗口后中止 · FAT 与目录项逐字节还原")
} catch {
    check(false, "取消上传回归失败：\(error)")
}

// MARK: - Report

print("\n" + String(repeating: "─", count: 52))
if failures.isEmpty {
    print("✅ 全部通过（\(checks) 项检查）")
    exit(0)
} else {
    print("❌ \(failures.count) 项失败 / 共 \(checks) 项")
    for failure in failures { print("   · \(failure)") }
    exit(1)
}
