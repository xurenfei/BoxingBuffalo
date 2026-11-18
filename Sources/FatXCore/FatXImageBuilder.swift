import Foundation

/// Builds a valid FATX volume from scratch.
///
/// Two purposes: a self-check fixture so the parser can be proven correct
/// without a real console drive, and the "生成示例镜像" menu item so people can
/// poke at the app before plugging hardware in.
public enum FatXImageBuilder {

    public indirect enum Node {
        case file(name: String, data: Data)
        case directory(name: String, children: [Node])

        public var name: String {
            switch self {
            case let .file(name, _): return name
            case let .directory(name, _): return name
            }
        }

        public var isDirectory: Bool {
            if case .directory = self { return true }
            return false
        }
    }

    public struct Result {
        public let image: Data
        public let clusterSize: Int64
        public let totalClusters: UInt32
        public let fatEntrySize: Int
    }

    /// Writes a complete single-partition FATX image. The volume starts at
    /// offset 0, matching a `.bin` dump of one partition rather than a whole
    /// console drive.
    public static func build(root: [Node],
                             totalSize: Int64 = 32 << 20,
                             sectorsPerCluster: UInt32 = 8,
                             volumeID: UInt32 = 0xB0FF_A105) throws -> Result {
        guard sectorsPerCluster >= 1, (sectorsPerCluster & (sectorsPerCluster - 1)) == 0 else {
            throw FatXError.unsupported("每簇扇区数必须是 2 的幂")
        }
        let clusterSize = Int64(sectorsPerCluster) * FatXConstants.sectorSize

        // Geometry — mirrors FatXVolume exactly, so the self-check exercises the
        // same arithmetic the real parser uses.
        let totalClusters = totalSize / clusterSize
        guard totalClusters > 0 else { throw FatXError.unsupported("镜像太小") }
        let entrySize = totalClusters < 0xFFF0 ? 2 : 4
        let raw = totalClusters * Int64(entrySize)
        let clusterFATBytes = clusterSize / Int64(entrySize)
        let fatSize = (((raw + FatXConstants.superblockSize) + clusterFATBytes - 1)
                       / clusterFATBytes) * clusterFATBytes - FatXConstants.superblockSize
        let dataOffset = FatXConstants.superblockSize + fatSize
        guard totalClusters > 0 else { throw FatXError.unsupported("算不出簇") }

        var image = [UInt8](repeating: 0, count: Int(totalSize))
        var fat = [UInt32](repeating: 0, count: Int(totalClusters) + 1)
        var nextCluster: UInt32 = 1

        // FAT[0] is reserved; FATX leaves it as a media descriptor-ish value.
        fat[0] = 0xFFFF_FFF8

        func allocate(_ clusters: Int) -> UInt32 {
            precondition(clusters >= 1)
            let start = nextCluster
            for i in 0..<clusters {
                let c = start + UInt32(i)
                fat[Int(c)] = (i == clusters - 1) ? 0xFFFF_FFFF : c + 1
            }
            nextCluster += UInt32(clusters)
            return start
        }

        func writeClusters(startCluster: UInt32, bytes: [UInt8], clusters: Int) {
            for i in 0..<clusters {
                let c = startCluster + UInt32(i)
                let base = Int(dataOffset) + Int(c - 1) * Int(clusterSize)
                let srcStart = i * Int(clusterSize)
                let srcEnd = min(srcStart + Int(clusterSize), bytes.count)
                guard srcStart < bytes.count else { break }
                for j in srcStart..<srcEnd {
                    image[base + (j - srcStart)] = bytes[j]
                }
            }
        }

        // Directory serialisation: each entry is 64 bytes, terminated by
        // 0xFFFFFFFF. Entries per cluster = clusterSize / 64.
        let entriesPerCluster = Int(clusterSize) / FatXConstants.dirEntrySize
        precondition(entriesPerCluster > 0)

        func entryBytes(name: String,
                        flags: UInt8,
                        startCluster: UInt32,
                        size: UInt32,
                        date: UInt16,
                        time: UInt16) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: FatXConstants.dirEntrySize)
            let nameBytes = Array(name.utf8.prefix(FatXConstants.maxNameLength))
            out[0] = UInt8(nameBytes.count)
            out[1] = flags
            for (i, b) in nameBytes.enumerated() { out[0x2 + i] = b }
            func put32(_ value: UInt32, at offset: Int) {
                out[offset] = UInt8((value >> 24) & 0xFF)
                out[offset + 1] = UInt8((value >> 16) & 0xFF)
                out[offset + 2] = UInt8((value >> 8) & 0xFF)
                out[offset + 3] = UInt8(value & 0xFF)
            }
            func put16(_ value: UInt16, at offset: Int) {
                out[offset] = UInt8((value >> 8) & 0xFF)
                out[offset + 1] = UInt8(value & 0xFF)
            }
            put32(startCluster, at: 0x2C)
            put32(size, at: 0x30)
            put16(date, at: 0x34); put16(time, at: 0x36)   // created
            put16(date, at: 0x38); put16(time, at: 0x3A)   // accessed
            put16(date, at: 0x3C); put16(time, at: 0x3E)   // modified
            return out
        }

        // FAT 16-bit date: year-1980 in bits 9..15, month bits 5..8, day bits 0..4.
        let sampleDate: UInt16 = UInt16(((2024 - 1980) << 9) | (6 << 5) | 15)
        let sampleTime: UInt16 = UInt16((19 << 11) | (42 << 5) | (30 / 2))

        // Recursive writer. Returns the entry record describing this node so
        // the caller can point its parent at it.
        func writeNode(_ node: Node) -> [UInt8] {
            switch node {
            case let .file(name, data):
                let clusterCount = max(1, (data.count + Int(clusterSize) - 1) / Int(clusterSize))
                let start = allocate(clusterCount)
                writeClusters(startCluster: start, bytes: [UInt8](data), clusters: clusterCount)
                return entryBytes(name: name, flags: 0x20, startCluster: start,
                                  size: UInt32(data.count), date: sampleDate, time: sampleTime)

            case let .directory(name, children):
                let childCount = children.count
                let clustersNeeded = max(1, (childCount + 1 + entriesPerCluster - 1) / entriesPerCluster)
                let start = allocate(clustersNeeded)

                var dirBytes: [UInt8] = []
                dirBytes.reserveCapacity(clustersNeeded * Int(clusterSize))
                for child in children {
                    dirBytes.append(contentsOf: writeNode(child))
                }
                // Terminator
                dirBytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
                writeClusters(startCluster: start, bytes: dirBytes, clusters: clustersNeeded)

                let flags: UInt8 = name.isEmpty ? 0x10 : 0x10   // directory bit
                return entryBytes(name: name, flags: flags, startCluster: start,
                                  size: 0, date: sampleDate, time: sampleTime)
            }
        }

        // Root directory occupies cluster 1.
        let rootCluster: UInt32 = 1
        let rootClusters = max(1, (root.count + 1 + entriesPerCluster - 1) / entriesPerCluster)
        _ = allocate(rootClusters)   // claims clusters 1..n for the root

        var rootBytes: [UInt8] = []
        for child in root {
            rootBytes.append(contentsOf: writeNode(child))
        }
        rootBytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        writeClusters(startCluster: rootCluster, bytes: rootBytes, clusters: rootClusters)

        // --- Superblock ---
        func poke32(_ value: UInt32, at offset: Int) {
            image[offset] = UInt8((value >> 24) & 0xFF)
            image[offset + 1] = UInt8((value >> 16) & 0xFF)
            image[offset + 2] = UInt8((value >> 8) & 0xFF)
            image[offset + 3] = UInt8(value & 0xFF)
        }
        poke32(FatXConstants.magic, at: 0x00)
        poke32(volumeID, at: 0x04)
        poke32(sectorsPerCluster, at: 0x08)
        poke32(rootCluster, at: 0x0C)

        // --- FAT ---
        // Hard stop at the end of the FAT region: writing one entry past it
        // silently stomps the first bytes of the data area.
        let fatRegionEnd = Int(FatXConstants.superblockSize) + Int(fatSize)
        for index in 0..<fat.count {
            let value = fat[index]
            let base = Int(FatXConstants.superblockSize) + index * entrySize
            guard base + entrySize <= fatRegionEnd else { break }
            if entrySize == 2 {
                image[base] = UInt8((value >> 8) & 0xFF)
                image[base + 1] = UInt8(value & 0xFF)
            } else {
                poke32(value, at: base)
            }
        }

        return Result(image: Data(image),
                      clusterSize: clusterSize,
                      totalClusters: UInt32(totalClusters),
                      fatEntrySize: entrySize)
    }

    /// Convenience fixture used by the self-check tool and the sample menu item.
    public static func sampleTree() -> [Node] {
        [
            .directory(name: "Content", children: [
                .directory(name: "0000000000000000", children: [
                    .directory(name: "000B0000", children: [
                        .file(name: "TitleUpdate.bin", data: Data(repeating: 0xAB, count: 73_000)),
                    ]),
                    .directory(name: "00000002", children: [
                        .file(name: "SaveGame.sav", data: Data("Xbox 360 save data placeholder\n".utf8)),
                    ]),
                ]),
                .directory(name: "E0000A1B2C3D4E5F", children: [
                    .file(name: "Header.bin", data: Data(repeating: 0x11, count: 4096)),
                ]),
            ]),
            .directory(name: "Cache", children: [
                .file(name: "TU0A1B2C3D", data: Data(repeating: 0xCD, count: 200_000)),
                .file(name: "GA00000000", data: Data(repeating: 0xEF, count: 1_500_000)),
            ]),
            .directory(name: "EmptyDir", children: []),
            .file(name: "readme.txt", data: Data("BoxingBuffalo sample FATX volume\n".utf8)),
        ]
    }
}
