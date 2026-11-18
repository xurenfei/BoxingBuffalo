import Foundation

/// Cursor over a `Data` slice.
///
/// FATX stores every multi-byte numeric field big-endian: superblock fields,
/// directory entry cluster/size, timestamps and FAT entries. This was verified
/// against a real 500 GB console drive — reading the same bytes little-endian
/// yields nonsense like "268435456 sectors per cluster". `u16()` / `u32()` keep
/// the little-endian behaviour for the handful of places that need it.
public struct ByteCursor {
    public let data: Data
    public private(set) var offset: Int

    public init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public var remaining: Int { max(0, data.count - offset) }

    public mutating func seek(_ newOffset: Int) {
        offset = newOffset
    }

    public mutating func skip(_ count: Int) {
        offset += count
    }

    public mutating func u8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    public mutating func u16() -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        defer { offset += 2 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    public mutating func u32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        defer { offset += 4 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    /// Big-endian 16-bit read — the on-disk order for every FATX field.
    public mutating func u16be() -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        defer { offset += 2 }
        let base = data.startIndex + offset
        return (UInt16(data[base]) << 8) | UInt16(data[base + 1])
    }

    /// Big-endian 32-bit read — the on-disk order for every FATX field.
    public mutating func u32be() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        defer { offset += 4 }
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24)
            | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8)
            | UInt32(data[base + 3])
    }

    public mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        let base = data.startIndex + offset
        return data[base..<(base + count)]
    }

    /// FATX file names are ASCII, but the console tolerates high-bit bytes in
    /// some cache filenames; decode leniently rather than dropping the entry.
    public mutating func fatxName(_ count: Int) -> String? {
        guard let raw = bytes(count) else { return nil }
        var scalars = String.UnicodeScalarView()
        for byte in raw {
            if byte == 0 { break }
            scalars.append(UnicodeScalar(byte))
        }
        return String(scalars)
    }
}

public enum FatXConstants {
    /// "XTAF" as it appears on disk, read big-endian: 0x58 0x54 0x41 0x46.
    public static let magic: UInt32 = 0x5854_4146
    public static let sectorSize: Int64 = 0x200
    /// The superblock occupies a full 0x1000 sector; the FAT starts after it.
    public static let superblockSize: Int64 = 0x1000
    public static let dirEntrySize = 0x40
    public static let maxNameLength = 0x2A
    public static let endOfDirectory: UInt32 = 0xFFFF_FFFF
    public static let deletedEntryMarker: UInt8 = 0xE5

    /// Two partitions on a retail drive use a hand-tuned FAT size instead of the
    /// computed one. These values come from CLKsFATXLib's `FATSize()` and were
    /// confirmed against a real 500 GB drive: the formula yields 1 MB for the
    /// system cache where the console actually wrote 0x7000.
    public static let fixedFATSize: [Int64: Int64] = [
        0x80000: 0x7000,        // SystemCache
        0x118E_B0000: 0x5000,   // System_Extended
    ]

    // Well-known partition offsets on official / homebrew layouts.
    public enum HDDOffsets {
        public static let josh: Int64 = 0x800
        public static let securitySector: Int64 = 0x2000
        public static let systemCache: Int64 = 0x80000
        public static let gameCache: Int64 = 0x8008_0000
        public static let systemCacheAlt: Int64 = 0x10C0_80000
        public static let systemExtended: Int64 = 0x118E_B0000
        public static let compatibility: Int64 = 0x120E_B0000
        public static let data: Int64 = 0x130E_B0000

        /// Display names in partition order.
        public static let known: [(offset: Int64, name: String)] = [
            (systemCache, "系统缓存区"),
            (gameCache, "游戏缓存区"),
            (systemCacheAlt, "系统缓存区（扩展）"),
            (systemExtended, "系统扩展区"),
            (compatibility, "兼容分区（Xbox 1 游戏）"),
            (data, "数据分区"),
        ]
    }

    public enum USBOffsets {
        public static let cache: Int64 = 0x0800_0400
        public static let systemAux: Int64 = 0x8115_200
        public static let systemExtended: Int64 = 0x1200_0400
        public static let data: Int64 = 0x2000_0000
    }

    public enum NANDOffsets {
        public static let system: Int64 = 0x319_0800
        public static let cache: Int64 = 0x3CE_8800
        public static let data: Int64 = 0x1E60_0300
    }

    public enum DevOffsets {
        public static let devkit: Int64 = 0xB660_0000
        public static let content: Int64 = 0xC660_0000
    }
}

/// Entry attribute bits, straight from the on-disk flags byte.
public struct FatXEntryFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let readOnly     = FatXEntryFlags(rawValue: 0x01)
    public static let hidden       = FatXEntryFlags(rawValue: 0x02)
    public static let system       = FatXEntryFlags(rawValue: 0x04)
    public static let volume       = FatXEntryFlags(rawValue: 0x08)
    public static let directory    = FatXEntryFlags(rawValue: 0x10)
    public static let archive      = FatXEntryFlags(rawValue: 0x20)
    public static let device       = FatXEntryFlags(rawValue: 0x40)

    public var humanReadable: [String] {
        var out: [String] = []
        if contains(.readOnly) { out.append("只读") }
        if contains(.hidden) { out.append("隐藏") }
        if contains(.system) { out.append("系统") }
        if contains(.volume) { out.append("卷标") }
        if contains(.directory) { out.append("目录") }
        if contains(.archive) { out.append("存档") }
        if contains(.device) { out.append("设备") }
        return out
    }
}

/// Which physical layout the volume came from. Determines the well-known
/// partition table and the FAT entry width fallbacks.
public enum FatXLayout: String, Sendable {
    case hardDisk = "Xbox 360 硬盘"
    case usbStorage = "Xbox 360 U 盘"
    case nand = "内置存储 (NAND)"
    case devkit = "开发机"
    case standalone = "独立 FATX 卷"
}
