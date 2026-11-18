import Foundation

/// Everything needed to mutate a FATX volume.
///
/// Ordering matters more than speed here. A write is staged so that the worst
/// possible outcome of an interruption is a *leaked* cluster chain (space that
/// no directory entry points at) rather than a file that is visible but whose
/// contents are half-written, or a directory entry pointing at clusters that
/// still hold someone else's data. Concretely:
///
///   1. claim clusters in the FAT (marked end-of-chain, so nothing else can
///      claim them)
///   2. write the file payload into those clusters
///   3. publish the directory entry — this is the commit point
///   4. only then release the clusters of an overwritten file
///
/// If the process dies before step 3 nothing references the new chain, and a
/// `WriteJournal` rollback puts the FAT back exactly as it was.
public final class FatXWriter {
    public let volume: FatXVolume
    private let lock = NSLock()
    /// Where the next free-cluster scan starts. Kept between calls so a
    /// sequence of uploads does not re-read the whole FAT every time.
    private var scanHint: UInt32 = 2

    /// Optional pre-image log. Only metadata sectors are recorded (FAT entries
    /// and 64-byte directory records) — not the payload clusters, which are
    /// freshly allocated and therefore cannot damage existing files. That keeps
    /// a 4 GB upload from needing a 4 GB rollback buffer.
    public var journal: WriteJournal?

    public init(volume: FatXVolume) throws {
        guard volume.source.isWritable else {
            throw FatXError.notWritable(path: volume.source.displayName)
        }
        self.volume = volume
        self.scanHint = 2
    }

    // MARK: - Constants

    private var endOfChain: UInt32 { volume.fatEntrySize == 2 ? 0xFFFF : 0xFFFF_FFFF }
    private var freeCluster: UInt32 { 0 }

    private var usableLimit: UInt32 { volume.maxWritableCluster }

    // MARK: - Journalled writes

    /// Every metadata write goes through here so a failed transaction can be
    /// undone. Payload clusters deliberately bypass it.
    private func writeMetadata(_ data: Data, at offset: Int64) throws {
        try journal?.record(source: volume.source, offset: offset, length: data.count)
        try volume.source.write(offset: offset, data: data)
    }

    // MARK: - Name validation

    /// FATX names are single-byte and the console rejects anything outside
    /// printable ASCII. Chinese file names cannot be stored verbatim, so this
    /// fails loudly instead of writing a name the console would render as
    /// mojibake.
    public static func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FatXError.invalidName(name: name, reason: "不能为空")
        }
        guard trimmed != "." && trimmed != ".." else {
            throw FatXError.invalidName(name: name, reason: "保留名称")
        }
        let forbidden: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
        if let bad = trimmed.first(where: { forbidden.contains($0) }) {
            throw FatXError.invalidName(name: name, reason: "不能包含 \(bad)")
        }
        // FATX stores the name as bytes, no encoding tag. Anything above 0x7E
        // has no faithful single-byte representation the dashboard accepts.
        let ascii = trimmed.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }
        guard ascii.count == trimmed.unicodeScalars.count else {
            throw FatXError.invalidName(name: name, reason: "FATX 文件名只支持 ASCII 字符，请先改名")
        }
        let byteCount = trimmed.utf8.count
        guard byteCount <= FatXConstants.maxNameLength else {
            throw FatXError.nameTooLong(name: trimmed, max: FatXConstants.maxNameLength)
        }
        return trimmed
    }

    /// Turns an arbitrary local file name into something the console accepts,
    /// keeping the extension so the dashboard can still identify the type.
    public static func sanitizedName(_ raw: String) -> String {
        let invalid: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
        var out = ""
        var lastWasPlaceholder = false
        for character in raw {
            let scalars = character.unicodeScalars
            let printableASCII = scalars.count == 1
                && scalars.first!.value >= 0x20
                && scalars.first!.value < 0x7F
            if printableASCII && !invalid.contains(character) {
                out.append(character)
                lastWasPlaceholder = false
            } else if !lastWasPlaceholder {
                // Collapse a run of unusable characters into a single "_"
                // instead of a row of them for a Chinese file name.
                out.append("_")
                lastWasPlaceholder = true
            }
        }
        if out.isEmpty { out = "file" }
        // Trim to the byte limit without splitting a character.
        while out.utf8.count > FatXConstants.maxNameLength {
            out.removeLast()
        }
        return out
    }

    // MARK: - Free space

    /// Finds `needed` unused clusters, scanning forward from the last position
    /// used. FATX has no allocation bitmap; the only way to know a cluster is
    /// free is a zero FAT entry, so this walks the table in 1 MiB windows.
    public func allocateClusters(_ needed: Int,
                                 progress: ((Int, Int) -> Bool)? = nil) throws -> [UInt32] {
        guard needed > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }

        let limit = usableLimit
        guard limit > 2 else { throw FatXError.noFreeSpace(needed: needed) }

        var found: [UInt32] = []
        var cluster = max(2, min(scanHint, limit))
        var wrapped = false

        while found.count < needed {
            if cluster > limit {
                if wrapped { break }
                wrapped = true
                cluster = 2
                continue
            }
            let remaining = Int(limit - cluster) + 1
            let window = min(remaining, 262_144)
            let byteOffset = Int64(cluster) * Int64(volume.fatEntrySize)
            let byteCount = window * volume.fatEntrySize
            let data = try volume.source.readPadded(offset: volume.fatOffset + byteOffset,
                                                    count: byteCount)
            guard data.count >= volume.fatEntrySize else { break }

            let stride = volume.fatEntrySize
            var index = 0
            while index + stride <= data.count && found.count < needed {
                let base = data.startIndex + index
                let value: UInt32
                if stride == 2 {
                    value = (UInt32(data[base]) << 8) | UInt32(data[base + 1])
                } else {
                    value = (UInt32(data[base]) << 24)
                        | (UInt32(data[base + 1]) << 16)
                        | (UInt32(data[base + 2]) << 8)
                        | UInt32(data[base + 3])
                }
                if value == freeCluster {
                    found.append(cluster + UInt32(index / stride))
                }
                index += stride
            }
            cluster += UInt32(window)
            if let progress, progress(found.count, needed) == false {
                throw FatXError.unsupported("已取消")
            }
        }

        guard found.count >= needed else {
            throw FatXError.noFreeSpace(needed: needed)
        }
        scanHint = found.last! + 1
        // Claim them immediately so a concurrent write cannot hand out the
        // same clusters. They become proper chain links in `linkChain`.
        try applyFAT(found.map { ($0, endOfChain) })
        return found
    }

    /// Counts free clusters without claiming any. Scans the whole table, so
    /// call it only when the UI actually needs the number.
    public func freeClusterCount(progress: ((Int) -> Void)? = nil) throws -> Int {
        let limit = usableLimit
        var count = 0
        var cluster: UInt32 = 2
        while cluster <= limit {
            let remaining = Int(limit - cluster) + 1
            let window = min(remaining, 262_144)
            let byteOffset = Int64(cluster) * Int64(volume.fatEntrySize)
            let data = try volume.source.readPadded(offset: volume.fatOffset + byteOffset,
                                                    count: window * volume.fatEntrySize)
            let stride = volume.fatEntrySize
            var index = 0
            while index + stride <= data.count {
                let base = data.startIndex + index
                if stride == 2 {
                    if data[base] == 0 && data[base + 1] == 0 { count += 1 }
                } else if data[base] == 0 && data[base + 1] == 0 && data[base + 2] == 0 && data[base + 3] == 0 {
                    count += 1
                }
                index += stride
            }
            cluster += UInt32(window)
            progress?(count)
        }
        return count
    }

    // MARK: - FAT chain

    /// Writes `clusters[0] -> clusters[1] -> ... -> end` in one batch per
    /// contiguous run, which is the normal case because the allocator scans
    /// forward.
    private func linkChain(_ clusters: [UInt32]) throws {
        guard !clusters.isEmpty else { return }
        var pairs: [(UInt32, UInt32)] = []
        pairs.reserveCapacity(clusters.count)
        for (offset, cluster) in clusters.enumerated() {
            let next = offset + 1 < clusters.count ? clusters[offset + 1] : endOfChain
            pairs.append((cluster, next))
        }
        try applyFAT(pairs)
    }

    /// Writes FAT entries in contiguous batches instead of one 4-byte pwrite
    /// per cluster — a 2 GB upload is 130k entries.
    private func applyFAT(_ pairs: [(UInt32, UInt32)]) throws {
        guard !pairs.isEmpty else { return }
        let sorted = pairs.sorted { $0.0 < $1.0 }
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count && sorted[end + 1].0 == sorted[end].0 + 1 {
                end += 1
            }
            let first = sorted[index].0
            let count = Int(sorted[end].0 - first) + 1
            let stride = volume.fatEntrySize
            let byteOffset = Int64(first) * Int64(stride)
            var buffer = try volume.source.readPadded(offset: volume.fatOffset + byteOffset,
                                                      count: count * stride)
            guard buffer.count >= count * stride else {
                throw FatXError.corruptVolume("FAT 区间 0x\(String(byteOffset, radix: 16)) 读不完整")
            }
            for k in index...end {
                let slot = Int(sorted[k].0 - first) * stride
                let value = sorted[k].1
                if stride == 2 {
                    let trimmed = UInt16(truncatingIfNeeded: value)
                    buffer[slot] = UInt8(trimmed >> 8)
                    buffer[slot + 1] = UInt8(trimmed & 0xFF)
                } else {
                    buffer[slot] = UInt8(value >> 24)
                    buffer[slot + 1] = UInt8((value >> 16) & 0xFF)
                    buffer[slot + 2] = UInt8((value >> 8) & 0xFF)
                    buffer[slot + 3] = UInt8(value & 0xFF)
                }
            }
            try writeMetadata(buffer, at: volume.fatOffset + byteOffset)
            index = end + 1
        }
        volume.invalidateFATCache()
    }

    /// Marks every cluster of a chain as free. Does not touch directory entries.
    public func freeChain(startingAt start: UInt32) throws {
        guard start >= 2 else { return }
        let chain = try volume.clusterChain(startingAt: start)
        guard !chain.isEmpty else { return }
        try applyFAT(chain.map { ($0, freeCluster) })
    }

    // MARK: - Directory slots

    /// Location of a reusable 64-byte slot inside a directory.
    private struct DirectorySlot {
        let cluster: UInt32
        let offsetInCluster: Int
        let absoluteOffset: Int64
        /// True when this slot is currently the end-of-directory marker, which
        /// means a new terminator has to follow it.
        let wasEndMarker: Bool
    }

    private func findSlot(in parentCluster: UInt32) throws -> DirectorySlot {
        let chain = try volume.clusterChain(startingAt: parentCluster)
        guard !chain.isEmpty else {
            throw FatXError.corruptVolume("目录簇 \(parentCluster) 没有可用的 FAT 链")
        }
        let clusterSize = Int(volume.clusterSize)

        for cluster in chain {
            let data = try volume.readCluster(cluster)
            let base = try volume.offset(forCluster: cluster)
            var index = 0
            while index + FatXConstants.dirEntrySize <= data.count {
                let at = data.startIndex + index
                let first4 = (UInt32(data[at]) << 24)
                    | (UInt32(data[at + 1]) << 16)
                    | (UInt32(data[at + 2]) << 8)
                    | UInt32(data[at + 3])
                // The console terminates a directory with 0xFF bytes; 0x00 is
                // accepted as well by the parser. A 0xE5 name length is a
                // deleted entry whose slot can be recycled.
                if first4 == 0xFFFF_FFFF || first4 == 0 {
                    return DirectorySlot(cluster: cluster,
                                         offsetInCluster: index,
                                         absoluteOffset: base + Int64(index),
                                         wasEndMarker: true)
                }
                if data[at] == FatXConstants.deletedEntryMarker {
                    return DirectorySlot(cluster: cluster,
                                         offsetInCluster: index,
                                         absoluteOffset: base + Int64(index),
                                         wasEndMarker: false)
                }
                index += FatXConstants.dirEntrySize
            }
            _ = clusterSize
        }

        // No slot left anywhere in the chain: extend the directory by one
        // cluster and use its first slot.
        let extra = try allocateClusters(1)
        guard let newCluster = extra.first else {
            throw FatXError.noFreeSpace(needed: 1)
        }
        let tail = chain.last!
        try applyFAT([(tail, newCluster), (newCluster, endOfChain)])
        try volume.writeCluster(newCluster, data: Data())
        let base = try volume.offset(forCluster: newCluster)
        return DirectorySlot(cluster: newCluster,
                             offsetInCluster: 0,
                             absoluteOffset: base,
                             wasEndMarker: true)
    }

    /// Builds the 64-byte record. Padding between the name and 0x2C is 0xFF,
    /// matching what the console writes.
    private func makeEntry(name: String,
                           flags: UInt8,
                           startCluster: UInt32,
                           size: UInt32,
                           date: Date) -> Data {
        var record = [UInt8](repeating: 0xFF, count: FatXConstants.dirEntrySize)
        let nameBytes = Array(name.utf8)
        record[0] = UInt8(nameBytes.count)
        record[1] = flags
        for (index, byte) in nameBytes.enumerated() where 2 + index < 0x2C {
            record[2 + index] = byte
        }
        func put32(_ value: UInt32, at offset: Int) {
            record[offset] = UInt8(value >> 24)
            record[offset + 1] = UInt8((value >> 16) & 0xFF)
            record[offset + 2] = UInt8((value >> 8) & 0xFF)
            record[offset + 3] = UInt8(value & 0xFF)
        }
        func put16(_ value: UInt16, at offset: Int) {
            record[offset] = UInt8(value >> 8)
            record[offset + 1] = UInt8(value & 0xFF)
        }
        put32(startCluster, at: 0x2C)
        put32(size, at: 0x30)

        let stamp = FatXDate.encode(date)
        put16(stamp.date, at: 0x34)   // creation
        put16(stamp.time, at: 0x36)
        put16(stamp.date, at: 0x38)   // last write
        put16(stamp.time, at: 0x3A)
        put16(stamp.date, at: 0x3C)   // last access
        put16(stamp.time, at: 0x3E)
        return Data(record)
    }

    private func writeEntry(_ record: Data, at slot: DirectorySlot) throws {
        try writeMetadata(record, at: slot.absoluteOffset)

        // If the slot we consumed was the terminator, the slot after it must
        // become the new terminator, otherwise the parser walks into stale
        // bytes and invents entries.
        guard slot.wasEndMarker else { return }
        let next = slot.offsetInCluster + FatXConstants.dirEntrySize
        let clusterSize = Int(volume.clusterSize)
        if next + FatXConstants.dirEntrySize <= clusterSize {
            let base = try volume.offset(forCluster: slot.cluster)
            try writeMetadata(Data(repeating: 0xFF, count: FatXConstants.dirEntrySize),
                              at: base + Int64(next))
        } else {
            // Terminator was the last slot of its cluster. Extend so the next
            // entry has somewhere to land and the directory stays terminated.
            let extra = try allocateClusters(1)
            guard let newCluster = extra.first else {
                throw FatXError.noFreeSpace(needed: 1)
            }
            try applyFAT([(slot.cluster, newCluster), (newCluster, endOfChain)])
            try volume.writeCluster(newCluster, data: Data())
        }
    }

    // MARK: - Public operations

    public func entry(named name: String, in parentCluster: UInt32) throws -> FatXEntry? {
        let entries = try volume.listDirectory(cluster: parentCluster)
        return entries.first { !$0.isDeleted && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    @discardableResult
    public func addDirectory(named rawName: String,
                             to parentCluster: UInt32,
                             overwrite: Bool = false,
                             date: Date = Date()) throws -> FatXEntry {
        let name = try Self.validateName(rawName)
        if let existing = try entry(named: name, in: parentCluster) {
            if existing.isDirectory && overwrite { return existing }
            throw FatXError.nameAlreadyExists(name: name)
        }

        let claimed = try allocateClusters(1)
        guard let cluster = claimed.first else { throw FatXError.noFreeSpace(needed: 1) }
        try volume.writeCluster(cluster, data: Data())   // empty directory, all 0xFF

        let slot = try findSlot(in: parentCluster)
        let record = makeEntry(name: name,
                               flags: FatXEntryFlags.directory.rawValue,
                               startCluster: cluster,
                               size: 0,
                               date: date)
        try writeEntry(record, at: slot)
        volume.source.synchronize()

        return FatXEntry(name: name,
                         flags: .directory,
                         startingCluster: cluster,
                         size: 0,
                         created: date,
                         modified: date,
                         accessed: date,
                         entryOffset: slot.absoluteOffset,
                         isDeleted: false)
    }

    /// Writes a whole in-memory blob. Fine for icons and config files; use the
    /// URL variant for anything large.
    @discardableResult
    public func addFile(named rawName: String,
                        data: Data,
                        to parentCluster: UInt32,
                        overwrite: Bool = true,
                        date: Date = Date()) throws -> FatXEntry {
        let name = try Self.validateName(rawName)
        let existing = try entry(named: name, in: parentCluster)
        if let existing {
            guard !existing.isDirectory else {
                throw FatXError.invalidName(name: name, reason: "同名目录已存在")
            }
            guard overwrite else { throw FatXError.nameAlreadyExists(name: name) }
        }

        let needed = max(1, Int((Int64(data.count) + volume.clusterSize - 1) / volume.clusterSize))
        let claimed = try allocateClusters(needed)
        guard claimed.count == needed else { throw FatXError.noFreeSpace(needed: needed) }

        // Payload first: a cluster claimed but never written is invisible junk,
        // a directory entry pointing at unwritten clusters is data loss.
        var cursor = 0
        for cluster in claimed {
            let take = min(Int(volume.clusterSize), data.count - cursor)
            let slice = take > 0 ? data.subdata(in: cursor..<(cursor + take)) : Data()
            try volume.writeCluster(cluster, data: slice)
            cursor += take
        }
        try linkChain(claimed)

        let slot: DirectorySlot
        if let existing {
            slot = DirectorySlot(cluster: 0,
                                 offsetInCluster: 0,
                                 absoluteOffset: existing.entryOffset,
                                 wasEndMarker: false)
        } else {
            slot = try findSlot(in: parentCluster)
        }
        let record = makeEntry(name: name,
                               flags: 0,
                               startCluster: claimed[0],
                               size: UInt32(truncatingIfNeeded: data.count),
                               date: date)
        try writeEntry(record, at: slot)
        volume.source.synchronize()

        // Committed. The previous chain is now unreachable.
        if let existing, existing.startingCluster >= 2 {
            try freeChain(startingAt: existing.startingCluster)
        }

        return FatXEntry(name: name,
                         flags: [],
                         startingCluster: claimed[0],
                         size: UInt32(truncatingIfNeeded: data.count),
                         created: existing?.created ?? date,
                         modified: date,
                         accessed: date,
                         entryOffset: slot.absoluteOffset,
                         isDeleted: false)
    }

    /// Streams a local file in without loading it into memory. The payload is
    /// copied through a bounded buffer, so a 4 GB package costs ~4 MB of RSS.
    @discardableResult
    public func addFile(from url: URL,
                        named rawName: String? = nil,
                        to parentCluster: UInt32,
                        overwrite: Bool = true,
                        date: Date = Date(),
                        progress: ((Int64, Int64) -> Bool)? = nil) throws -> FatXEntry {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let total = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let name = try Self.validateName(rawName ?? url.lastPathComponent)

        let existing = try entry(named: name, in: parentCluster)
        if let existing {
            guard !existing.isDirectory else {
                throw FatXError.invalidName(name: name, reason: "同名目录已存在")
            }
            guard overwrite else { throw FatXError.nameAlreadyExists(name: name) }
        }

        let clusterSize = Int(volume.clusterSize)
        // USB bridges charge a fixed round trip for every 16 KiB transaction
        // (~6 ms measured on the HM500JI). Coalescing adjacent clusters into
        // one large aligned write replaces 512 of those with a single one.
        let maxRunClusters = max(1, (8 << 20) / clusterSize)
        let chunkSize = max(maxRunClusters * clusterSize, 1 << 20)
        let needed = max(1, Int((total + volume.clusterSize - 1) / volume.clusterSize))
        let claimed = try allocateClusters(needed)
        guard claimed.count == needed else { throw FatXError.noFreeSpace(needed: needed) }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw FatXError.cannotOpen(path: url.path, errno: EIO)
        }
        defer { try? handle.close() }

        var clusterIndex = 0
        var pending = Data()
        var written: Int64 = 0
        pending.reserveCapacity(chunkSize + clusterSize)

        /// Emits `count` full clusters, merging consecutive cluster numbers
        /// into one device write. Non-contiguous runs fall back to one aligned
        /// cluster write, which still skips the old read-modify-write.
        func flush(fullClusters count: Int) throws {
            guard count > 0 else { return }
            var emitted = 0
            while emitted < count {
                let idx = clusterIndex + emitted
                guard idx < claimed.count else {
                    throw FatXError.noFreeSpace(needed: count - emitted)
                }
                var run = 1
                while emitted + run < count,
                      idx + run < claimed.count,
                      claimed[idx + run] == claimed[idx + run - 1] + 1,
                      run < maxRunClusters {
                    run += 1
                }
                let firstOffset = try volume.offset(forCluster: claimed[idx])
                let byteCount = run * clusterSize
                let start = emitted * clusterSize
                let base = pending.startIndex
                let payload = Data(pending[(base + start)..<(base + start + byteCount)])
                try volume.source.write(offset: firstOffset, data: payload)
                emitted += run
            }
            pending.removeFirst(count * clusterSize)
            clusterIndex += count
        }

        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)
            written += Int64(chunk.count)
            try flush(fullClusters: pending.count / clusterSize)
            if let progress, progress(written, total) == false {
                // Abort before the directory entry exists: free what we claimed
                // so the user does not lose space to a cancelled upload.
                try applyFAT(claimed.map { ($0, freeCluster) })
                throw FatXError.unsupported("已取消")
            }
        }
        // The final partial cluster keeps its trailing 0xFF padding.
        if !pending.isEmpty {
            pending.append(Data(repeating: 0xFF, count: clusterSize - pending.count))
            try flush(fullClusters: 1)
        }
        while clusterIndex < claimed.count {
            try volume.writeCluster(claimed[clusterIndex], data: Data())
            clusterIndex += 1
        }

        try linkChain(claimed)

        let slot: DirectorySlot
        if let existing {
            slot = DirectorySlot(cluster: 0,
                                 offsetInCluster: 0,
                                 absoluteOffset: existing.entryOffset,
                                 wasEndMarker: false)
        } else {
            slot = try findSlot(in: parentCluster)
        }
        let record = makeEntry(name: name,
                               flags: 0,
                               startCluster: claimed[0],
                               size: UInt32(truncatingIfNeeded: total),
                               date: date)
        try writeEntry(record, at: slot)
        volume.source.synchronize()

        if let existing, existing.startingCluster >= 2 {
            try freeChain(startingAt: existing.startingCluster)
        }

        return FatXEntry(name: name,
                         flags: [],
                         startingCluster: claimed[0],
                         size: UInt32(truncatingIfNeeded: total),
                         created: existing?.created ?? date,
                         modified: date,
                         accessed: date,
                         entryOffset: slot.absoluteOffset,
                         isDeleted: false)
    }

    /// Marks the entry deleted (0xE5) and releases its clusters. Directories are
    /// emptied recursively first, so no orphaned subtree is left behind.
    public func delete(_ entry: FatXEntry, from parentCluster: UInt32) throws {
        if entry.isDirectory, entry.startingCluster >= 2 {
            let children = try volume.listDirectory(cluster: entry.startingCluster)
            for child in children where !child.isDeleted {
                try delete(child, from: entry.startingCluster)
            }
        }

        // One byte flips the entry to deleted; `flags` and the old name stay so
        // the console (and this app) can still show it as recoverable.
        try writeMetadata(Data([FatXConstants.deletedEntryMarker]), at: entry.entryOffset)

        if entry.startingCluster >= 2 {
            try freeChain(startingAt: entry.startingCluster)
        }
        volume.source.synchronize()
    }

    /// Renames in place: only the name bytes and length change, the chain and
    /// timestamps are untouched.
    public func rename(_ entry: FatXEntry, to rawName: String, in parentCluster: UInt32) throws {
        let name = try Self.validateName(rawName)
        if let clash = try self.entry(named: name, in: parentCluster),
           clash.entryOffset != entry.entryOffset {
            throw FatXError.nameAlreadyExists(name: name)
        }
        var record = try volume.source.readPadded(offset: entry.entryOffset,
                                                  count: FatXConstants.dirEntrySize)
        let nameBytes = Array(name.utf8)
        record[0] = UInt8(nameBytes.count)
        for index in 0..<FatXConstants.maxNameLength {
            let at = 2 + index
            record[at] = index < nameBytes.count ? nameBytes[index] : 0xFF
        }
        try writeMetadata(record, at: entry.entryOffset)
        volume.source.synchronize()
    }
}

extension FatXDate {
    /// Encodes a `Date` into the FAT-style (date, time) pair the console uses.
    /// Two-second resolution and a 1980 epoch are inherent to the format.
    static func encode(_ date: Date) -> (date: UInt16, time: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, parts.year ?? 1980)) - 1980
        let month = max(1, min(12, parts.month ?? 1))
        let day = max(1, min(31, parts.day ?? 1))
        let hour = max(0, min(23, parts.hour ?? 0))
        let minute = max(0, min(59, parts.minute ?? 0))
        let second = max(0, min(59, parts.second ?? 0))
        let packedDate = UInt16((year << 9) | (month << 5) | day)
        let packedTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        return (packedDate, packedTime)
    }
}
