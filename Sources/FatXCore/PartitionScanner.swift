import Foundation

/// A FATX volume found on a device, together with how it was identified.
public struct DiscoveredVolume {
    public let volume: FatXVolume
    public let layout: FatXLayout
    public let label: String
    public let source: BlockSource
}

/// Finds FATX volumes on a device without trusting the partition table.
///
/// Xbox 360 drives use MBR, but the partition type bytes are not a reliable
/// signal (official drives often carry 0x00). So identification is done by
/// probing known layout offsets first, then falling back to a magic scan.
public enum PartitionScanner {

    /// Known FATX partition offsets for each layout, with human labels and the
    /// partition length the console writes (nil = runs to the end of the device).
    private struct KnownOffset {
        let offset: Int64
        let label: String
        let size: Int64?
    }

    private static let hddOffsets: [KnownOffset] = [
        .init(offset: FatXConstants.HDDOffsets.data, label: "数据分区", size: nil),
        .init(offset: FatXConstants.HDDOffsets.compatibility, label: "兼容分区（Xbox 1 游戏）", size: 0x1000_0000),
        .init(offset: FatXConstants.HDDOffsets.systemExtended, label: "系统扩展区", size: 0x0800_0000),
        .init(offset: FatXConstants.HDDOffsets.systemCacheAlt, label: "系统缓存区（扩展）", size: 0x0CE3_0000),
        .init(offset: FatXConstants.HDDOffsets.gameCache, label: "游戏缓存区", size: 0xA0E3_0000),
        .init(offset: FatXConstants.HDDOffsets.systemCache, label: "系统缓存区", size: 0x8000_0000),
    ]

    private static let usbOffsets: [KnownOffset] = [
        .init(offset: FatXConstants.USBOffsets.data, label: "数据分区", size: nil),
        .init(offset: FatXConstants.USBOffsets.systemAux, label: "系统辅助区", size: 0x0400_0000),
        .init(offset: FatXConstants.USBOffsets.systemExtended, label: "系统扩展区", size: 0x0DFF_FC00),
        .init(offset: FatXConstants.USBOffsets.cache, label: "缓存区", size: 0x047F_F000),
    ]

    private static let nandOffsets: [KnownOffset] = [
        .init(offset: FatXConstants.NANDOffsets.data, label: "数据分区", size: nil),
        .init(offset: FatXConstants.NANDOffsets.system, label: "系统分区", size: 0x0B60_0000),
        .init(offset: FatXConstants.NANDOffsets.cache, label: "缓存区", size: 0x0C00_0000),
    ]

    /// Probes the device and returns every mountable FATX volume found.
    public static func scan(source: BlockSource,
                            progress: ((Double, String) -> Void)? = nil) throws -> [DiscoveredVolume] {
        var candidates: [(offset: Int64, label: String, layout: FatXLayout, size: Int64?)] = []
        var seenOffsets = Set<Int64>()

        func addCandidate(_ offset: Int64, _ label: String, _ layout: FatXLayout, size: Int64? = nil) {
            guard offset >= 0, offset < source.length else { return }
            guard seenOffsets.insert(offset).inserted else { return }
            candidates.append((offset, label, layout, size))
        }

        progress?(0.05, "读取分区表…")

        // 0. A single-partition dump starts at byte 0 with the superblock.
        addCandidate(0, "单分区镜像", .standalone)

        // 1. MBR / GPT declared partitions.
        let declared = declaredPartitions(source: source)
        for part in declared {
            addCandidate(part.offset, "分区 \(part.index)（表内声明）", .standalone, size: part.length)
        }

        // 2. Known fixed layouts. Ordered by how common they are.
        let probableLayouts: [FatXLayout] = source.length > 40_000_000_000
            ? [.hardDisk, .usbStorage, .nand, .devkit]
            : [.usbStorage, .hardDisk, .nand, .devkit]

        for layout in probableLayouts {
            let offsets: [KnownOffset]
            switch layout {
            case .hardDisk, .devkit: offsets = hddOffsets
            case .usbStorage: offsets = usbOffsets
            case .nand: offsets = nandOffsets
            case .standalone: offsets = []
            }
            for known in offsets {
                addCandidate(known.offset, known.label, layout, size: known.size)
            }
        }

        progress?(0.2, "校验候选位置…")

        var volumes: [DiscoveredVolume] = []
        var rejectedProbes: [String] = []

        for (index, candidate) in candidates.enumerated() {
            progress?(0.2 + 0.5 * Double(index) / Double(max(1, candidates.count)),
                      "校验 0x\(String(candidate.offset, radix: 16).uppercased())…")
            if let volume = tryProbe(source: source,
                                     offset: candidate.offset,
                                     label: candidate.label,
                                     layout: candidate.layout,
                                     size: candidate.size) {
                // Avoid reporting the same volume twice (MBR entry + known offset).
                if !volumes.contains(where: { $0.volume.partitionOffset == volume.volume.partitionOffset }) {
                    volumes.append(volume)
                }
            } else {
                rejectedProbes.append("0x" + String(candidate.offset, radix: 16).uppercased())
            }
        }

        // 3. Brute-force scan if nothing matched. Homebrew FATX drives are
        //    occasionally formatted at offsets nobody documented.
        if volumes.isEmpty {
            progress?(0.7, "扫描整块设备寻找 FATX 卷…")
            let found = try magicScan(source: source, progress: progress)
            volumes.append(contentsOf: found)
        }

        progress?(1.0, "完成")
        guard !volumes.isEmpty else {
            throw FatXError.noFATXPartition(found: rejectedProbes)
        }

        // Largest volume first — the Data partition is what people want.
        return volumes.sorted { $0.volume.partitionSize > $1.volume.partitionSize }
    }

    // MARK: - Probing

    private static func tryProbe(source: BlockSource,
                                 offset: Int64,
                                 label: String,
                                 layout: FatXLayout,
                                 size: Int64? = nil) -> DiscoveredVolume? {
        guard let header = try? source.readPadded(offset: offset, count: 0x1000) else { return nil }
        var cursor = ByteCursor(header)
        guard let magic = cursor.u32be(), magic == FatXConstants.magic else { return nil }
        let _ = cursor.u32be()                     // volume id
        guard let spc = cursor.u32be(), spc >= 1, spc <= 0x4000, (spc & (spc - 1)) == 0 else { return nil }
        guard let rootCluster = cursor.u32be(), rootCluster >= 1, rootCluster < 0x1000_0000 else { return nil }

        let partitionSize = size ?? (source.length - offset)
        guard let volume = try? FatXVolume(source: source,
                                           partitionOffset: offset,
                                           partitionSize: partitionSize,
                                           name: label) else { return nil }

        // Final gate: the root directory must contain at least one plausible
        // entry, or an immediate terminator (a freshly formatted volume).
        guard let rootEntries = try? volume.listDirectory(cluster: volume.rootDirectoryCluster) else {
            return nil
        }
        let plausible = rootEntries.contains { entry in
            let n = entry.name
            return !n.isEmpty && n.count <= FatXConstants.maxNameLength
        }
        if !plausible && !rootEntries.isEmpty { return nil }

        return DiscoveredVolume(volume: volume, layout: layout, label: label, source: source)
    }

    // MARK: - MBR parsing

    private struct DeclaredPartition {
        let index: Int
        let offset: Int64
        let length: Int64
        let type: UInt8
    }

    private static func declaredPartitions(source: BlockSource) -> [DeclaredPartition] {
        var out: [DeclaredPartition] = []
        guard let mbr = try? source.readPadded(offset: 0, count: 0x200) else { return out }
        // MBR signature
        let sigBase = mbr.startIndex + 0x1FE
        guard mbr.count >= 0x200, mbr[sigBase] == 0x55, mbr[sigBase + 1] == 0xAA else { return out }

        for i in 0..<4 {
            var cursor = ByteCursor(mbr, offset: 0x1BE + i * 16)
            cursor.skip(4)                                   // boot + CHS start
            guard let type = cursor.u8() else { continue }
            cursor.skip(3)                                   // CHS end
            guard let lbaStart = cursor.u32(), let sectors = cursor.u32() else { continue }
            guard lbaStart > 0, sectors > 0 else { continue }
            let offset = Int64(lbaStart) * FatXConstants.sectorSize
            let length = Int64(sectors) * FatXConstants.sectorSize
            guard offset < source.length else { continue }
            // 0xEE = GPT protective MBR, skip it: GPT FATX volumes are not a thing.
            if type == 0xEE { continue }
            out.append(DeclaredPartition(index: i + 1, offset: offset, length: length, type: type))
        }
        return out
    }

    // MARK: - Brute force

    private static func magicScan(source: BlockSource,
                                  progress: ((Double, String) -> Void)?) throws -> [DiscoveredVolume] {
        // Scan on a 256 KB stride. FATX partitions are always far larger than
        // that, so no superblock can hide between two probes.
        let stride: Int64 = 0x40000
        // Must be a whole sector: a 0x100-byte read is rejected with EINVAL on
        // raw disks (Party Buffalo always rounds to 0x200). The old 0x100
        // probe silently failed at every offset because `try?` swallowed it.
        let probeLength = 0x200
        var offset: Int64 = 0
        var hits: [Int64] = []
        var scanned: Int64 = 0

        while offset < source.length {
            if let head = try? source.readPadded(offset: offset, count: probeLength),
               head.count >= 4 {
                let magic = (UInt32(head[head.startIndex]) << 24)
                    | (UInt32(head[head.startIndex + 1]) << 16)
                    | (UInt32(head[head.startIndex + 2]) << 8)
                    | UInt32(head[head.startIndex + 3])
                if magic == FatXConstants.magic {
                    hits.append(offset)
                }
            }
            offset += stride
            scanned += stride
            if scanned % (stride * 256) == 0 {
                progress?(0.7 + 0.29 * Double(offset) / Double(max(1, source.length)), "扫描中…")
            }
        }

        var volumes: [DiscoveredVolume] = []
        for (i, hit) in hits.enumerated() {
            if let volume = tryProbe(source: source,
                                     offset: hit,
                                     label: "扫描发现 \(i + 1)",
                                     layout: .standalone) {
                volumes.append(volume)
            }
        }
        return volumes
    }
}
