import Foundation
import Darwin

/// Errors surfaced by the FATX layer. Every failure path carries enough
/// context that the UI can show something actionable instead of "unknown error".
public enum FatXError: LocalizedError {
    case cannotOpen(path: String, errno: Int32)
    case notPermitted(path: String)
    case readFailed(offset: Int64, count: Int, errno: Int32)
    case writeFailed(offset: Int64, count: Int, errno: Int32)
    case notWritable(path: String)
    case noFATXPartition(found: [String])
    case corruptVolume(String)
    case clusterOutOfRange(cluster: UInt32, max: UInt32)
    case fatCycleDetected(startCluster: UInt32)
    case unsupported(String)
    case noFreeSpace(needed: Int)
    case nameTooLong(name: String, max: Int)
    case nameAlreadyExists(name: String)
    case invalidName(name: String, reason: String)
    case directoryFull(cluster: UInt32)

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, err):
            return "无法打开 \(path)（errno \(err)：\(String(cString: strerror(err)))）"
        case let .notPermitted(path):
            return "没有访问 \(path) 的权限。裸设备需要管理员权限，请用「以管理员身份重新打开」或先 dump 成镜像文件。"
        case let .readFailed(offset, count, err):
            return "读取失败：偏移 0x\(String(offset, radix: 16))，长度 \(count)（errno \(err)：\(String(cString: strerror(err)))）"
        case let .writeFailed(offset, count, err):
            return "写入失败：偏移 0x\(String(offset, radix: 16))，长度 \(count)（errno \(err)：\(String(cString: strerror(err)))）"
        case let .notWritable(path):
            return "\(path) 以只读方式打开，无法写入。"
        case let .noFATXPartition(found):
            if found.isEmpty {
                return "这块设备上没找到 FATX 分区。"
            }
            return "这块设备上没找到 FATX 分区。已探测的位置：\(found.joined(separator: "、"))"
        case let .corruptVolume(reason):
            return "FATX 卷结构损坏：\(reason)"
        case let .clusterOutOfRange(cluster, max):
            return "簇号越界：\(cluster)（上限 \(max)），FAT 链可能已损坏。"
        case let .fatCycleDetected(start):
            return "从簇 \(start) 开始的 FAT 链出现死循环，已中止以避免卡死。"
        case let .unsupported(reason):
            return "暂不支持：\(reason)"
        case let .noFreeSpace(needed):
            return "空间不足：这次写入需要 \(needed) 个空闲簇。"
        case let .nameTooLong(name, max):
            return "文件名过长：\(name)（FATX 上限 \(max) 字节，中文按 3 字节算）"
        case let .nameAlreadyExists(name):
            return "同名文件已存在：\(name)"
        case let .invalidName(name, reason):
            return "文件名不合法：\(name)（\(reason)）"
        case let .directoryFull(cluster):
            return "目录簇 \(cluster) 已满且无法扩展。"
        }
    }
}

/// Random-access view over a byte source: a disk image file or a raw block
/// device. Reads use `pread` so they are stateless and safe to call from
/// multiple threads (file extraction runs off the main actor).
public protocol BlockSource: AnyObject {
    var displayName: String { get }
    var length: Int64 { get }
    var isRawDevice: Bool { get }
    var isWritable: Bool { get }
    func read(offset: Int64, count: Int) throws -> Data
    /// Writes `data` at `offset`. Implementations are responsible for any
    /// alignment requirement the underlying device imposes.
    func write(offset: Int64, data: Data) throws
    /// Pushes writes to stable storage. A no-op where unsupported.
    func synchronize()
    func close()
}

public extension BlockSource {
    /// Reads exactly `count` bytes or throws. Short reads at EOF are padded
    /// with zeros, which matters because directory clusters are routinely
    /// scanned past their meaningful content.
    func readPadded(offset: Int64, count: Int) throws -> Data {
        var out = Data(count: count)
        if offset >= length { return out }
        let available = Int(min(Int64(count), length - offset))
        let chunk = try read(offset: offset, count: available)
        out.replaceSubrange(0..<chunk.count, with: chunk)
        return out
    }

    public func write(offset: Int64, data: Data) throws {
        throw FatXError.notWritable(path: displayName)
    }

    public func synchronize() {}
}

/// `sys/disk.h` is not importable from Swift, so the two ioctl request codes
/// are spelled out here. Values match `_IOR('d', 24, uint32_t)` and
/// `_IOR('d', 25, uint64_t)`.
private let dkIOCGetBlockSize: UInt = 0x4004_6418
private let dkIOCGetBlockCount: UInt = 0x4008_6419

/// A raw disk only accepts transfers whose offset AND length are whole
/// sectors. Measured on the real HM500JI USB bridge: 256-byte and 16-byte
/// reads, or any read at an offset like 0x…1008, all fail with EINVAL even
/// though a 512-byte read at the same boundary succeeds. This is exactly the
/// reason Party Buffalo opens `\\.\PhysicalDriveN` with FILE_FLAG_NO_BUFFERING
/// and rounds everything with DownToNearest200/UpToNearest200.
public let deviceSectorSize = 512

/// Device writes still go through a read-modify-write of whole 4 KiB blocks,
/// which keeps partial FAT entries and 64-byte directory records safe.
public let deviceWriteBlockSize = 4096

/// The alignment trick CLKsFATXLib applies at every call site, factored out
/// once so no caller can forget it:
///   FATXFileStream.Read   -> RealSectorOffset + UpToNearest200 + Array.Copy
///   GetBlocksOccupied    -> DownToNearestCluster(0x1000) + OffsetInBuffer
/// We round the request out to whole sectors, issue sector-aligned reads,
/// then slice out exactly the bytes the caller asked for.
public enum SectorAlignedIO {
    public static func read(offset: Int64,
                            count: Int,
                            length: Int64,
                            sectorSize: Int = deviceSectorSize,
                            rawRead: (Int64, Int) throws -> Data) throws -> Data {
        guard count > 0 else { return Data() }
        let sector = Int64(max(1, sectorSize))
        let alignedStart = (offset / sector) * sector
        let skip = Int(offset - alignedStart)
        let wanted = Int64(skip) + Int64(count)
        let rounded = ((wanted + sector - 1) / sector) * sector
        // Never ask the kernel for a whole sector past the end of the device.
        let capped = Int(min(rounded, max(0, length - alignedStart)))
        guard capped > skip else { return Data(count: count) }
        // Keep each transfer sector-multiple; a short read simply ends the loop.
        let transferCount = ((capped + sectorSize - 1) / sectorSize) * sectorSize
        let maxTransfer = 16 << 20

        var out = Data()
        out.reserveCapacity(transferCount)
        var done = 0
        while done < transferCount {
            let n = min(maxTransfer, transferCount - done)
            let piece = try rawRead(alignedStart + Int64(done), n)
            out.append(piece)
            done += n
            if piece.count < n { break }
        }
        let upper = min(out.count, skip + count)
        guard upper > skip else { return Data(count: count) }
        return Data(out[(out.startIndex + skip)..<(out.startIndex + upper)])
    }
}

/// Disk image file (.bin / .img / .iso, or any file that happens to contain
/// a FATX volume). Plain `open`/`pread`/`pwrite`, no buffering surprises.
public final class FileBlockSource: BlockSource {
    public let displayName: String
    public let length: Int64
    public let isRawDevice = false
    public let isWritable: Bool
    private let fd: Int32
    private let path: String

    public init(path: String, writable: Bool = false) throws {
        self.path = path
        self.displayName = (path as NSString).lastPathComponent
        let flags = writable ? O_RDWR : O_RDONLY
        let fdv = open(path, flags)
        guard fdv >= 0 else {
            throw FatXError.cannotOpen(path: path, errno: errno)
        }
        self.fd = fdv
        self.isWritable = writable
        var st = stat()
        guard fstat(fdv, &st) == 0 else {
            Darwin.close(fdv)
            throw FatXError.cannotOpen(path: path, errno: errno)
        }
        self.length = Int64(st.st_size)
    }

    public func read(offset: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let n = pread(fd, &buffer[total], count - total, off_t(offset) + off_t(total))
            if n < 0 {
                if errno == EINTR { continue }
                throw FatXError.readFailed(offset: offset + Int64(total), count: count - total, errno: errno)
            }
            if n == 0 { break }
            total += n
        }
        return Data(buffer[0..<total])
    }

    public func write(offset: Int64, data: Data) throws {
        guard isWritable else { throw FatXError.notWritable(path: path) }
        guard !data.isEmpty else { return }
        try pwriteAll(offset: offset, data: data)
    }

    private func pwriteAll(offset: Int64, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var total = 0
            while total < data.count {
                let n = pwrite(fd, base + total, data.count - total, off_t(offset) + off_t(total))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FatXError.writeFailed(offset: offset + Int64(total), count: data.count - total, errno: errno)
                }
                if n == 0 { throw FatXError.writeFailed(offset: offset + Int64(total), count: data.count - total, errno: EIO) }
                total += n
            }
        }
    }

    public func synchronize() {
        fsync(fd)
    }

    public func close() {
        Darwin.close(fd)
    }
}

/// Raw block device (`/dev/rdisk2`, ...). Same interface as a file, but the
/// length must come from ioctl because `st_size` is meaningless for devices.
public final class RawBlockSource: BlockSource {
    public let displayName: String
    public let length: Int64
    public let isRawDevice = true
    public let isWritable: Bool
    private let fd: Int32
    private let path: String
    private let sectorSize: Int

    public init(path: String, writable: Bool = false) throws {
        self.path = path
        self.displayName = (path as NSString).lastPathComponent
        let flags = writable ? O_RDWR : O_RDONLY
        let fdv = open(path, flags)
        guard fdv >= 0 else {
            if errno == EACCES || errno == EPERM {
                throw FatXError.notPermitted(path: path)
            }
            throw FatXError.cannotOpen(path: path, errno: errno)
        }
        self.fd = fdv
        self.isWritable = writable

        // Device size: block count * block size. `DKIOCGETBLOCKCOUNT` returns
        // 512-byte-style counts for the *device logical* blocks.
        var blockSize: UInt32 = 0
        var blockCount: UInt64 = 0
        if ioctl(fdv, dkIOCGetBlockSize, &blockSize) != 0 || blockSize == 0 {
            blockSize = 512
        }
        // Trust the kernel's reported sector size, but stay in the 512…4096
        // range: some USB bridges report nonsense, and larger alignments only
        // cost a little extra read-ahead.
        self.sectorSize = min(4096, max(512, Int(blockSize)))
        if ioctl(fdv, dkIOCGetBlockCount, &blockCount) != 0 {
            // Fall back to seeking to the end; works on most device nodes.
            let end = lseek(fdv, 0, SEEK_END)
            blockCount = end > 0 ? UInt64(end) / UInt64(blockSize) : 0
        }
        self.length = Int64(blockCount) * Int64(blockSize)
        guard self.length > 0 else {
            Darwin.close(fdv)
            throw FatXError.cannotOpen(path: path, errno: EIO)
        }
    }

    /// Every caller — FAT entries, directory records, superblocks, magic
    /// probes — goes through the same sector-aligned read + in-memory slice
    /// that CLKsFATXLib does by hand at each call site.
    public func read(offset: Int64, count: Int) throws -> Data {
        try SectorAlignedIO.read(offset: offset,
                                 count: count,
                                 length: length,
                                 sectorSize: sectorSize) { alignedOffset, alignedCount in
            try self.rawPread(offset: alignedOffset, count: alignedCount)
        }
    }

    /// Only ever called with a sector-aligned offset and a sector-multiple
    /// length, so the kernel cannot answer EINVAL.
    private func rawPread(offset: Int64, count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let n = pread(fd, &buffer[total], count - total, off_t(offset) + off_t(total))
            if n < 0 {
                if errno == EINTR { continue }
                throw FatXError.readFailed(offset: offset + Int64(total),
                                           count: count - total, errno: errno)
            }
            if n == 0 { break }
            total += n
        }
        return Data(buffer[0..<total])
    }

    /// Read-modify-write within 4 KiB boundaries, never a bare partial write.
    ///
    /// A whole, 4 KiB-aligned payload is a *complete overwrite*: reading the
    /// old bytes first would double the I/O for large sequential writes (which
    /// is what an Xbox game upload is). Only partial blocks — a 4-byte FAT
    /// entry, a 64-byte directory record — need the read-modify-write path.
    public func write(offset: Int64, data: Data) throws {
        guard isWritable else { throw FatXError.notPermitted(path: path) }
        guard !data.isEmpty else { return }
        let block = Int64(deviceWriteBlockSize)
        guard offset >= 0, offset + Int64(data.count) <= length else {
            throw FatXError.writeFailed(offset: offset, count: data.count, errno: EINVAL)
        }
        if offset % block == 0, Int64(data.count) % block == 0 {
            try pwriteAll(offset: offset, data: data)
            return
        }
        let start = (offset / block) * block
        let end = ((offset + Int64(data.count) + block - 1) / block) * block
        let span = Int(end - start)
        var buffer = try read(offset: start, count: span)
        guard buffer.count == span else {
            throw FatXError.writeFailed(offset: start, count: span, errno: EIO)
        }
        let within = Int(offset - start)
        buffer.replaceSubrange(within..<(within + data.count), with: data)
        try pwriteAll(offset: start, data: buffer)
    }

    private func pwriteAll(offset: Int64, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var total = 0
            while total < data.count {
                let n = pwrite(fd, base + total, data.count - total, off_t(offset) + off_t(total))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FatXError.writeFailed(offset: offset + Int64(total), count: data.count - total, errno: errno)
                }
                if n == 0 { throw FatXError.writeFailed(offset: offset + Int64(total), count: data.count - total, errno: EIO) }
                total += n
            }
        }
    }

    public func synchronize() {
        fsync(fd)
    }

    public func close() {
        Darwin.close(fd)
    }
}

/// Records the pre-image of every 4 KiB block a write transaction touches, so
/// a failure halfway through can put the volume back exactly as it was. A
/// half-written FATX volume is worse than no change at all: a dangling chain
/// makes files vanish and a stomped directory entry can shift a whole folder.
public final class WriteJournal {
    private var originals: [(offset: Int64, data: Data)] = []
    private var seen = Set<Int64>()
    private let block: Int64

    public init(blockSize: Int = deviceWriteBlockSize) {
        self.block = Int64(blockSize)
    }

    public var blockCount: Int { originals.count }
    public var isEmpty: Bool { originals.isEmpty }

    /// Must be called *before* the corresponding write lands.
    public func record(source: BlockSource, offset: Int64, length: Int) throws {
        guard length > 0 else { return }
        let start = (offset / block) * block
        let end = ((offset + Int64(length) + block - 1) / block) * block
        var cursor = start
        while cursor < end {
            if seen.insert(cursor).inserted {
                let span = Int(min(block, source.length - cursor))
                if span > 0 {
                    let data = try source.readPadded(offset: cursor, count: span)
                    originals.append((cursor, data))
                }
            }
            cursor += block
        }
    }

    /// Restores every recorded block, newest first.
    public func rollback(source: BlockSource) {
        for record in originals.reversed() {
            try? source.write(offset: record.offset, data: record.data)
        }
        source.synchronize()
        originals.removeAll()
        seen.removeAll()
    }

    public func commit() {
        originals.removeAll()
        seen.removeAll()
    }
}
