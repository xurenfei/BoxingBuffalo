import Foundation

/// One local item normalised into something FATX can actually store. Folder
/// uploads walk this tree instead of flattening everything into the current
/// directory (which is what a naive "upload all URLs" would do).
public struct UploadNode {
    public enum Kind {
        case file(URL, Int64)
        indirect case directory([UploadNode])
    }

    public let localName: String
    public let remoteName: String
    public let modified: Date
    public let kind: Kind

    public init(localName: String, remoteName: String, modified: Date, kind: Kind) {
        self.localName = localName
        self.remoteName = remoteName
        self.modified = modified
        self.kind = kind
    }

    public var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }

    public var fileCount: Int {
        switch kind {
        case .file: return 1
        case let .directory(children): return children.reduce(0) { $0 + $1.fileCount }
        }
    }

    public var folderCount: Int {
        switch kind {
        case .file: return 0
        case let .directory(children): return 1 + children.reduce(0) { $0 + $1.folderCount }
        }
    }

    public var totalBytes: Int64 {
        switch kind {
        case let .file(_, size): return size
        case let .directory(children): return children.reduce(0) { $0 + $1.totalBytes }
        }
    }
}

public struct UploadPlan {
    public let roots: [UploadNode]
    public let warnings: [String]

    public init(roots: [UploadNode], warnings: [String]) {
        self.roots = roots
        self.warnings = warnings
    }

    public var fileCount: Int { roots.reduce(0) { $0 + $1.fileCount } }
    public var folderCount: Int { roots.reduce(0) { $0 + $1.folderCount } }
    public var totalBytes: Int64 { roots.reduce(0) { $0 + $1.totalBytes } }
}

/// Executes an `UploadPlan` against a FATX volume. Kept next to the planner so
/// the app and the self-check walk exactly the same tree.
public enum FolderUploadWriter {

    public struct Progress {
        public let name: String
        public let written: Int64
        public let total: Int64
    }

    /// Returns the number of payload bytes copied. `progress` can return false
    /// to abort before the current file's directory entry is published.
    @discardableResult
    public static func write(plan: UploadPlan,
                             to parentCluster: UInt32,
                             writer: FatXWriter,
                             overwrite: Bool = true,
                             progress: ((Progress) -> Bool)? = nil) throws -> Int64 {
        var transferred: Int64 = 0

        func writeNode(_ node: UploadNode, into parent: UInt32) throws {
            switch node.kind {
            case let .directory(children):
                // overwrite:true returns an existing folder, so uploading an
                // updated copy of a tree merges into it instead of failing.
                let folder = try writer.addDirectory(named: node.remoteName,
                                                     to: parent,
                                                     overwrite: true,
                                                     date: node.modified)
                for child in children {
                    try writeNode(child, into: folder.startingCluster)
                }
            case let .file(url, size):
                let base = transferred
                _ = try writer.addFile(from: url,
                                       named: node.remoteName,
                                       to: parent,
                                       overwrite: overwrite,
                                       date: node.modified) { written, _ in
                    if let progress {
                        return progress(Progress(name: node.remoteName,
                                                 written: base + written,
                                                 total: plan.totalBytes))
                    }
                    return true
                }
                transferred += size
            }
        }

        for root in plan.roots { try writeNode(root, into: parentCluster) }
        return transferred
    }
}

/// Expands a mixed selection of files and folders into a FATX-shaped tree.
///
/// Two things are deliberately filtered out before a single byte reaches the
/// disk: macOS metadata (`.DS_Store`, hidden files) and anything FATX cannot
/// represent (symlinks, >4 GB files, duplicate names after ASCII folding).
/// Every skipped item is reported to the user instead of being silently lost.
public enum FolderUploadPlanner {

    /// FATX stores file size in a UInt32.
    public static let maxFileSize: Int64 = Int64(UInt32.max)

    public static func plan(urls: [URL]) throws -> UploadPlan {
        var warnings: [String] = []
        var roots: [UploadNode] = []
        try collect(urls, into: &roots, warnings: &warnings)
        return UploadPlan(roots: roots, warnings: warnings)
    }

    private static func collect(_ urls: [URL],
                                into nodes: inout [UploadNode],
                                warnings: inout [String]) throws {
        // Names are matched case-insensitively by FATX, and ASCII folding can
        // turn "中文.txt" and "英文.txt" into the same "_.txt".
        var seen = Set<String>()
        for url in urls {
            guard let node = try makeNode(for: url, warnings: &warnings) else { continue }
            let key = node.remoteName.lowercased()
            if !seen.insert(key).inserted {
                warnings.append("同名冲突，跳过「\(node.localName)」（净化后都是 \(node.remoteName)）")
                continue
            }
            nodes.append(node)
        }
    }

    private static func makeNode(for url: URL,
                                 warnings: inout [String]) throws -> UploadNode? {
        let localName = url.lastPathComponent
        guard !localName.hasPrefix(".") else { return nil }   // .DS_Store etc.

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                       .isRegularFileKey, .fileSizeKey,
                                                       .contentModificationDateKey])
        if values?.isSymbolicLink == true {
            warnings.append("跳过符号链接「\(localName)」")
            return nil
        }

        let remoteName = FatXWriter.sanitizedName(localName)
        _ = try FatXWriter.validateName(remoteName)
        if remoteName != localName {
            warnings.append("\(localName) → \(remoteName)（FATX 只支持 ASCII）")
        }
        let modified = values?.contentModificationDate ?? Date()

        if values?.isDirectory == true {
            let childrenURLs: [URL]
            do {
                childrenURLs = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                 .isRegularFileKey, .fileSizeKey,
                                                 .contentModificationDateKey],
                    options: []
                )
            } catch {
                warnings.append("「\(localName)」无法读取，按空目录处理")
                childrenURLs = []
            }
            let sorted = childrenURLs.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            var children: [UploadNode] = []
            do {
                try collect(sorted, into: &children, warnings: &warnings)
            } catch {
                // A single unreadable child should not abort the whole folder.
                warnings.append("跳过 \(localName) 中的一项：\(error.localizedDescription)")
            }
            return UploadNode(localName: localName, remoteName: remoteName,
                              modified: modified, kind: .directory(children))
        }

        guard values?.isRegularFile != false else {
            warnings.append("跳过特殊文件「\(localName)」")
            return nil
        }
        let size = Int64(values?.fileSize ?? 0)
        guard size <= maxFileSize else {
            warnings.append("跳过「\(localName)」（\(FatXVolume.friendlySize(size)) 超过 FATX 单文件 4 GB 上限）")
            return nil
        }
        return UploadNode(localName: localName, remoteName: remoteName,
                          modified: modified, kind: .file(url, size))
    }
}
