import Foundation

/// One directory entry as stored on disk. FATX entries are a fixed 64 bytes;
/// the only variable part is the name length (max 42).
public struct FatXEntry: Identifiable, Hashable, Sendable {
    public var id: String { "\(entryOffset)-\(name)" }

    public let name: String
    public let flags: FatXEntryFlags
    public let startingCluster: UInt32
    public let size: UInt32
    public let created: Date?
    public let modified: Date?
    public let accessed: Date?
    /// Absolute byte offset of this 64-byte record on the underlying device.
    public let entryOffset: Int64
    /// The 0xE5 name-length marker means the console deleted this entry but
    /// the cluster chain is often still readable — data recovery territory.
    public let isDeleted: Bool

    public var isDirectory: Bool { flags.contains(.directory) }

    public var displayName: String {
        name.isEmpty ? "（无名称）" : name
    }
}

/// A parsed FATX volume, mounted at a known offset inside a block source.
///
/// Layout on disk (all multi-byte fields big-endian, verified against a real
/// 500 GB RGH console drive):
/// ```
/// partitionOffset + 0x0000 : superblock (0x1000 bytes, only 0x10 used)
///                            0x00 magic "XTAF"
///                            0x04 volume id
///                            0x08 sectors per cluster
///                            0x0C root directory cluster
/// partitionOffset + 0x1000 : FAT  (fatSize bytes)
/// dataOffset               : cluster heap; byte address of cluster N is
///                            dataOffset + (N-1) * clusterSize
/// ```
/// The cluster count is `partitionSize / clusterSize` — the console does not
/// subtract the superblock and FAT from the partition size, so the last few
/// clusters past the end of the device simply do not exist. Reads there are
/// clamped instead of failing.
public final class FatXVolume {
    public let source: BlockSource
    public let name: String
    public let partitionOffset: Int64
    public let partitionSize: Int64

    public let volumeID: UInt32
    public let sectorsPerCluster: UInt32
    public let rootDirectoryCluster: UInt32
    public let clusterSize: Int64
    public let fatEntrySize: Int
    public let fatOffset: Int64
    public let fatSize: Int64
    public let dataOffset: Int64
    public let totalClusters: UInt32

    private let fatCache = FATChunkCache()
    private let lock = NSLock()

    public init(source: BlockSource, partitionOffset: Int64, partitionSize: Int64, name: String? = nil) throws {
        self.source = source
        self.partitionOffset = partitionOffset
        self.name = name ?? "FATX 分区 @ 0x\(String(partitionOffset, radix: 16).uppercased())"

        // --- Superblock ---
        let header = try source.readPadded(offset: partitionOffset, count: 0x1000)
        var cursor = ByteCursor(header)
        guard let magic = cursor.u32be(), magic == FatXConstants.magic else {
            let found = cursor.u32be().map { String(format: "0x%08X", $0) } ?? "读不到"
            throw FatXError.corruptVolume("偏移 0x\(String(partitionOffset, radix: 16)) 处的 magic 是 \(found)，不是 FATX")
        }
        self.volumeID = cursor.u32be() ?? 0
        let spc = cursor.u32be() ?? 0
        guard spc > 0, spc <= 0x4000, (spc & (spc - 1)) == 0 else {
            throw FatXError.corruptVolume("每簇扇区数非法：\(spc)")
        }
        self.sectorsPerCluster = spc
        self.rootDirectoryCluster = cursor.u32be() ?? 1
        self.clusterSize = Int64(spc) * FatXConstants.sectorSize

        if partitionSize > 0 {
            self.partitionSize = partitionSize
        } else {
            self.partitionSize = source.length - partitionOffset
        }

        // --- Geometry ---
        // Straight from the console's own arithmetic: cluster count is the whole
        // partition divided by the cluster size, and the FAT is sized to hold
        // one entry per cluster, rounded up so the data area starts on an even
        // cluster boundary.
        let clusters = max(0, partitionSize / clusterSize)
        guard clusters > 0 else {
            throw FatXError.corruptVolume("分区太小，一个簇都装不下（簇大小 \(clusterSize) 字节）")
        }
        // FATX uses 16-bit entries until the volume needs more than 0xFFF0.
        let entrySize = clusters < 0xFFF0 ? 2 : 4
        let rawFAT = clusters * Int64(entrySize)
        let clusterFATBytes = clusterSize / Int64(entrySize)   // entries per cluster

        var fatSize = FatXConstants.fixedFATSize[partitionOffset]
            ?? (((rawFAT + FatXConstants.superblockSize) + clusterFATBytes - 1)
                / clusterFATBytes) * clusterFATBytes - FatXConstants.superblockSize
        if fatSize < 0 { fatSize = 0 }

        self.fatEntrySize = entrySize
        self.fatSize = fatSize
        self.fatOffset = partitionOffset + FatXConstants.superblockSize
        self.dataOffset = fatOffset + fatSize
        self.totalClusters = UInt32(min(clusters, Int64(UInt32.max)))

        guard rootDirectoryCluster >= 1, rootDirectoryCluster <= max(1, totalClusters) else {
            throw FatXError.corruptVolume("根目录簇 \(rootDirectoryCluster) 超出范围（共 \(totalClusters) 簇）")
        }
    }

    // MARK: - Cluster addressing

    public func offset(forCluster cluster: UInt32) throws -> Int64 {
        guard cluster >= 1 else {
            throw FatXError.clusterOutOfRange(cluster: cluster, max: totalClusters)
        }
        guard cluster <= totalClusters else {
            throw FatXError.clusterOutOfRange(cluster: cluster, max: totalClusters)
        }
        return dataOffset + Int64(cluster - 1) * clusterSize
    }

    public func readCluster(_ cluster: UInt32) throws -> Data {
        let off = try offset(forCluster: cluster)
        return try source.readPadded(offset: off, count: Int(clusterSize))
    }

    // MARK: - FAT chain

    /// Walks the FAT chain. Guards against the two failure modes seen on real
    /// drives: chains that loop back on themselves, and chains longer than the
    /// volume could possibly hold.
    public func clusterChain(startingAt start: UInt32, limit: Int? = nil) throws -> [UInt32] {
        guard start >= 1, start <= totalClusters else { return [] }
        var chain: [UInt32] = []
        var seen = Set<UInt32>()
        var current = start
        let hardLimit = limit ?? Int(totalClusters) + 1

        while current >= 1 && current <= totalClusters && chain.count < hardLimit {
            if !seen.insert(current).inserted {
                throw FatXError.fatCycleDetected(startCluster: start)
            }
            chain.append(current)
            let next = try fatEntry(cluster: current)
            // Values >= 0xFFFFFFF8 are end-of-chain markers.
            if next >= 0xFFFF_FFF8 { break }
            if next == 0 { break }
            current = next
        }
        return chain
    }

    public func fatEntry(cluster: UInt32) throws -> UInt32 {
        let byteOffset = Int64(cluster) * Int64(fatEntrySize)
        let chunkIndex = byteOffset / FATChunkCache.chunkSize
        let within = Int(byteOffset % FATChunkCache.chunkSize)
        let chunk = try fatChunk(index: chunkIndex)

        // FAT entries are big-endian, same as every other numeric field.
        if fatEntrySize == 2 {
            guard within + 2 <= chunk.count else { return 0xFFFF_FFFF }
            let base = chunk.startIndex + within
            let value = (UInt16(chunk[base]) << 8) | UInt16(chunk[base + 1])
            return UInt32(value)
        } else {
            guard within + 4 <= chunk.count else { return 0xFFFF_FFFF }
            let base = chunk.startIndex + within
            return (UInt32(chunk[base]) << 24)
                | (UInt32(chunk[base + 1]) << 16)
                | (UInt32(chunk[base + 2]) << 8)
                | UInt32(chunk[base + 3])
        }
    }

    private func fatChunk(index: Int64) throws -> Data {
        let absolute = fatOffset + index * FATChunkCache.chunkSize
        if absolute >= fatOffset + fatSize { return Data(repeating: 0xFF, count: Int(FATChunkCache.chunkSize)) }
        lock.lock()
        if let cached = fatCache.value(for: index) {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let data = try source.readPadded(offset: absolute, count: Int(FATChunkCache.chunkSize))
        lock.lock()
        fatCache.store(data, for: index)
        lock.unlock()
        return data
    }

    // MARK: - Directory listing

    public func listDirectory(cluster: UInt32) throws -> [FatXEntry] {
        var entries: [FatXEntry] = []
        var visited = Set<UInt32>()
        var current: UInt32? = cluster
        var guardCounter = 0

        while let c = current, guardCounter < 100_000 {
            guardCounter += 1
            if !visited.insert(c).inserted { break }
            let clusterData = try readCluster(c)
            let (parsed, reachedEnd) = parseDirectoryCluster(clusterData, cluster: c)
            entries.append(contentsOf: parsed)
            if reachedEnd { break }
            let next = try fatEntry(cluster: c)
            current = (next >= 0xFFFF_FFF8 || next == 0 || next > totalClusters) ? nil : next
        }
        return entries
    }

    private func parseDirectoryCluster(_ data: Data, cluster: UInt32) -> ([FatXEntry], Bool) {
        var result: [FatXEntry] = []
        let clusterBase = (try? offset(forCluster: cluster)) ?? 0
        var index = 0

        while index + FatXConstants.dirEntrySize <= data.count {
            let base = data.startIndex + index
            let first4 = UInt32(data[base])
                | (UInt32(data[base + 1]) << 8)
                | (UInt32(data[base + 2]) << 16)
                | (UInt32(data[base + 3]) << 24)

            // 0x00000000 / 0xFFFFFFFF mark the end of this directory.
            if first4 == 0 || first4 == FatXConstants.endOfDirectory {
                return (result, true)
            }

            var cursor = ByteCursor(data, offset: index)
            guard let nameSize = cursor.u8(), let flagByte = cursor.u8() else { break }
            // A zero name length is not an end-of-directory marker (that is
            // 0x00000000 across the first four bytes, handled above); it is a
            // slot that never got written. Skip it rather than surfacing a
            // nameless phantom file.
            if nameSize == 0 {
                index += FatXConstants.dirEntrySize
                continue
            }
            let deleted = nameSize == FatXConstants.deletedEntryMarker
            let nameChars = deleted ? FatXConstants.maxNameLength : Int(nameSize)
            guard nameChars >= 0, nameChars <= FatXConstants.maxNameLength else {
                index += FatXConstants.dirEntrySize
                continue
            }
            guard let rawName = cursor.fatxName(nameChars) else {
                index += FatXConstants.dirEntrySize
                continue
            }

            cursor.seek(index + 0x2C)
            guard let startCluster = cursor.u32be(),
                  let size = cursor.u32be() else {
                index += FatXConstants.dirEntrySize
                continue
            }
            // 0x34 creation, 0x38 last write, 0x3C last access — the same order
            // the console writes, each as a FAT-style (date, time) pair.
            let createdDate = cursor.u16be() ?? 0
            let createdTime = cursor.u16be() ?? 0
            let modDate = cursor.u16be() ?? 0
            let modTime = cursor.u16be() ?? 0
            let accessDate = cursor.u16be() ?? 0
            let accessTime = cursor.u16be() ?? 0

            let flags = FatXEntryFlags(rawValue: flagByte)
            // A live entry always has a name; a deleted one may be garbage, so
            // keep it only when it decodes to something printable.
            let usableName = deleted ? cleansedDeletedName(rawName) : rawName
            if deleted && usableName.isEmpty {
                index += FatXConstants.dirEntrySize
                continue
            }

            let entry = FatXEntry(
                name: usableName,
                flags: flags,
                startingCluster: startCluster,
                size: size,
                created: FatXDate.decode(date: createdDate, time: createdTime),
                modified: FatXDate.decode(date: modDate, time: modTime),
                accessed: FatXDate.decode(date: accessDate, time: accessTime),
                entryOffset: clusterBase + Int64(index),
                isDeleted: deleted
            )
            result.append(entry)
            index += FatXConstants.dirEntrySize
        }
        // Ran off the end of the cluster without an end marker: keep going via
        // the FAT chain.
        return (result, false)
    }

    private func cleansedDeletedName(_ raw: String) -> String {
        let printable = raw.unicodeScalars.prefix { scalar in
            scalar.value >= 0x20 && scalar.value < 0x7F && scalar != "?"
        }
        return String(String.UnicodeScalarView(printable))
    }

    // MARK: - File content

    /// Streams a file out cluster by cluster. Callback-based so a 4 GB package
    /// never has to fit in memory.
    public func readFile(_ entry: FatXEntry,
                         chunkSize: Int = 1 << 20,
                         progress: ((Int64, Int64) -> Bool)? = nil,
                         onChunk: (Data) throws -> Void) throws {
        guard !entry.isDirectory else { return }
        let total = Int64(entry.size)
        if total == 0 { return }

        let neededClusters = Int((total + clusterSize - 1) / clusterSize)
        let chain = try clusterChain(startingAt: entry.startingCluster, limit: neededClusters + 16)
        guard !chain.isEmpty else {
            throw FatXError.corruptVolume("文件「\(entry.name)」的起始簇 \(entry.startingCluster) 没有可用的 FAT 链")
        }

        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(max(chunkSize, Int(clusterSize)))

        for cluster in chain {
            if written >= total { break }
            let clusterData = try readCluster(cluster)
            let take = Int(min(Int64(clusterData.count), total - written))
            buffer.append(clusterData.prefix(take))
            written += Int64(take)

            if buffer.count >= chunkSize {
                try onChunk(buffer)
                buffer.removeAll(keepingCapacity: true)
                if let progress, progress(written, total) == false { return }
            }
        }
        if !buffer.isEmpty {
            try onChunk(buffer)
            _ = progress?(written, total)
        }
    }

    /// Convenience for small files (icons, config blobs). Refuses to load
    /// anything above `maxBytes` into memory.
    public func readFileData(_ entry: FatXEntry, maxBytes: Int = 64 << 20) throws -> Data {
        guard Int(entry.size) <= maxBytes else {
            throw FatXError.unsupported("文件「\(entry.name)」有 \(entry.size) 字节，超过一次性读取上限")
        }
        var out = Data()
        out.reserveCapacity(Int(entry.size))
        try readFile(entry) { out.append($0) }
        return out
    }

    /// Extracts to a local URL, creating intermediate directories as needed.
    public func extract(_ entry: FatXEntry, to url: URL,
                        progress: ((Int64, Int64) -> Bool)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw FatXError.unsupported("无法在 \(url.path) 创建文件")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try readFile(entry, progress: progress) { chunk in
            try handle.write(contentsOf: chunk)
        }
    }

    // MARK: - Write primitives

    /// Clusters past this point run off the end of the device. The console
    /// sizes the cluster count from the whole partition without subtracting
    /// the FAT, so the tail of the numbering space simply has no backing
    /// bytes; allocating there would produce a write error halfway through.
    public var maxWritableCluster: UInt32 {
        let bytes = source.length - dataOffset
        guard bytes > 0 else { return 1 }
        let limit = bytes / clusterSize
        return UInt32(max(1, min(Int64(totalClusters), limit)))
    }

    public func writeCluster(_ cluster: UInt32, data: Data) throws {
        guard source.isWritable else { throw FatXError.notWritable(path: source.displayName) }
        let off = try offset(forCluster: cluster)
        guard off + clusterSize <= source.length else {
            throw FatXError.writeFailed(offset: off, count: Int(clusterSize), errno: ENOSPC)
        }
        var payload = data
        if payload.count < Int(clusterSize) {
            payload.append(Data(repeating: 0xFF, count: Int(clusterSize) - payload.count))
        } else if payload.count > Int(clusterSize) {
            payload = payload.prefix(Int(clusterSize))
        }
        try source.write(offset: off, data: payload)
    }

    public func writeFATEntry(cluster: UInt32, value: UInt32) throws {
        guard source.isWritable else { throw FatXError.notWritable(path: source.displayName) }
        let byteOffset = Int64(cluster) * Int64(fatEntrySize)
        guard byteOffset + Int64(fatEntrySize) <= fatSize else {
            throw FatXError.corruptVolume("FAT 项 \(cluster) 超出 FAT 表范围（FAT 大小 \(fatSize) 字节）")
        }
        var bytes = [UInt8]()
        if fatEntrySize == 2 {
            let trimmed = UInt16(truncatingIfNeeded: value)
            bytes = [UInt8(trimmed >> 8), UInt8(trimmed & 0xFF)]
        } else {
            bytes = [UInt8(value >> 24),
                     UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF),
                     UInt8(value & 0xFF)]
        }
        try source.write(offset: fatOffset + byteOffset, data: Data(bytes))
        // Drop the cached chunk rather than patching it in place: a partial
        // patch that misses one of the code paths above would leave the cache
        // disagreeing with the disk, which is exactly how chains get corrupted.
        lock.lock()
        fatCache.remove(index: byteOffset / FATChunkCache.chunkSize)
        lock.unlock()
    }

    public func invalidateFATCache() {
        lock.lock()
        fatCache.removeAll()
        lock.unlock()
    }

    // MARK: - Geometry summary for the inspector

    public var geometrySummary: [(String, String)] {
        [
            ("分区偏移", "0x" + String(partitionOffset, radix: 16).uppercased()),
            ("分区大小", FatXVolume.friendlySize(partitionSize)),
            ("卷 ID", "0x" + String(format: "%08X", volumeID)),
            ("每簇扇区", "\(sectorsPerCluster)"),
            ("簇大小", "\(clusterSize) 字节"),
            ("簇总数", "\(totalClusters)"),
            ("FAT 偏移", "0x" + String(fatOffset, radix: 16).uppercased()),
            ("FAT 大小", FatXVolume.friendlySize(fatSize)),
            ("FAT 项宽度", "\(fatEntrySize) 字节"),
            ("数据区偏移", "0x" + String(dataOffset, radix: 16).uppercased()),
            ("根目录簇", "\(rootDirectoryCluster)"),
        ]
    }

    /// `ByteCountFormatter` follows the process locale, which is English here
    /// even though the whole UI is Chinese ("6 bytes"). Format by hand so the
    /// units match the interface.
    public static func friendlySize(_ bytes: Int64) -> String {
        if abs(bytes) < 1024 { return "\(bytes) 字节" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1024
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: index == 0 ? "%.1f %@" : "%.2f %@", value, units[index])
    }
}

/// Small LRU cache over FAT chunks. A 320 GB volume has a ~80 MB FAT; reading
/// it whole on open would stall the UI, and reading 4 bytes at a time per
/// chain link would be miserable. 64 KB chunks is the sweet spot.
final class FATChunkCache {
    static let chunkSize: Int64 = 0x10000
    private static let maxChunks = 256          // 16 MB ceiling
    private var storage: [Int64: Data] = [:]
    private var order: [Int64] = []

    func value(for index: Int64) -> Data? {
        guard let data = storage[index] else { return nil }
        if let pos = order.firstIndex(of: index) {
            order.remove(at: pos)
            order.append(index)
        }
        return data
    }

    func store(_ data: Data, for index: Int64) {
        storage[index] = data
        order.append(index)
        if order.count > Self.maxChunks {
            let evict = order.removeFirst()
            storage.removeValue(forKey: evict)
        }
    }

    func remove(index: Int64) {
        storage.removeValue(forKey: index)
        if let pos = order.firstIndex(of: index) {
            order.remove(at: pos)
        }
    }

    func removeAll() {
        storage.removeAll()
        order.removeAll()
    }
}

/// FATX keeps FAT-style 16-bit date/time pairs. Dates come back as nil when
/// the console wrote zeroes or nonsense, which happens a lot in cache files.
enum FatXDate {
    static func decode(date: UInt16, time: UInt16) -> Date? {
        guard date != 0 else { return nil }
        let day = Int(date & 0x1F)
        let month = Int((date >> 5) & 0x0F)
        let year = Int((date >> 9) & 0x7F) + 1980
        guard day >= 1, day <= 31, month >= 1, month <= 12, year >= 1980, year <= 2200 else {
            return nil
        }
        let seconds = Int(time & 0x1F) * 2
        let minutes = Int((time >> 5) & 0x3F)
        let hours = Int((time >> 11) & 0x1F)
        guard hours < 24, minutes < 60 else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hours
        components.minute = minutes
        components.second = seconds
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: components)
    }
}
