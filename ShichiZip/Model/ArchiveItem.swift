import Foundation

/// Swift-friendly wrapper around SZArchiveEntry
struct ArchiveItem {
    let index: Int
    let path: String
    let name: String
    let size: UInt64
    let packedSize: UInt64
    let modifiedDate: Date?
    let createdDate: Date?
    let crc: UInt32
    let isDirectory: Bool
    let isEncrypted: Bool
    let method: String
    let attributes: UInt32
    let comment: String

    /// Parent path (directory containing this item)
    var parentPath: String {
        guard path.contains("/") else { return "" }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        if parent == "." || parent == "/" { return "" }
        return parent
    }

    /// File extension
    var fileExtension: String {
        URL(fileURLWithPath: path).pathExtension
    }

    /// Compression ratio as a percentage
    var compressionRatio: Double {
        guard size > 0 else { return 0 }
        return Double(packedSize) / Double(size) * 100.0
    }

    /// Human-readable size string
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var formattedPackedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(packedSize), countStyle: .file)
    }

    init(from entry: SZArchiveEntry) {
        self.index = Int(entry.index)
        self.path = entry.path
        self.name = URL(fileURLWithPath: entry.path).lastPathComponent
        self.size = entry.size
        self.packedSize = entry.packedSize
        self.modifiedDate = entry.modifiedDate
        self.createdDate = entry.createdDate
        self.crc = entry.crc
        self.isDirectory = entry.isDirectory
        self.isEncrypted = entry.isEncrypted
        self.method = entry.method ?? ""
        self.attributes = entry.attributes
        self.comment = entry.comment ?? ""
    }
}

/// Tree node for displaying archive contents hierarchically
class ArchiveTreeNode {
    let name: String
    let fullPath: String
    let isDirectory: Bool
    var item: ArchiveItem?
    var children: [ArchiveTreeNode] = []
    weak var parent: ArchiveTreeNode?

    /// Aggregate size (for directories: sum of children)
    var totalSize: UInt64 {
        if isDirectory {
            return children.reduce(0) { $0 + $1.totalSize }
        }
        return item?.size ?? 0
    }

    var totalPackedSize: UInt64 {
        if isDirectory {
            return children.reduce(0) { $0 + $1.totalPackedSize }
        }
        return item?.packedSize ?? 0
    }

    init(name: String, fullPath: String, isDirectory: Bool, item: ArchiveItem? = nil) {
        self.name = name
        self.fullPath = fullPath
        self.isDirectory = isDirectory
        self.item = item
    }

    /// Build a tree from a flat list of archive items
    static func buildTree(from items: [ArchiveItem]) -> [ArchiveTreeNode] {
        var directoryNodes: [String: ArchiveTreeNode] = [:]
        var rootChildren: [ArchiveTreeNode] = []

        // Ensure parent directories exist
        func getOrCreateDirectory(_ path: String) -> ArchiveTreeNode {
            if let existing = directoryNodes[path] {
                return existing
            }

            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            let name = String(components.last ?? "")
            let node = ArchiveTreeNode(name: name, fullPath: path, isDirectory: true)
            directoryNodes[path] = node

            if components.count <= 1 {
                rootChildren.append(node)
            } else {
                let parentPath = components.dropLast().joined(separator: "/")
                let parentNode = getOrCreateDirectory(parentPath)
                node.parent = parentNode
                parentNode.children.append(node)
            }

            return node
        }

        for item in items {
            if item.isDirectory {
                let node = getOrCreateDirectory(item.path)
                node.item = item
            } else {
                let node = ArchiveTreeNode(name: item.name, fullPath: item.path, isDirectory: false, item: item)

                let parentPath = item.parentPath
                if parentPath.isEmpty {
                    rootChildren.append(node)
                } else {
                    let parentNode = getOrCreateDirectory(parentPath)
                    node.parent = parentNode
                    parentNode.children.append(node)
                }
            }
        }

        // Sort: directories first, then alphabetically
        func sortChildren(_ nodes: inout [ArchiveTreeNode]) {
            nodes.sort { a, b in
                if a.isDirectory != b.isDirectory {
                    return a.isDirectory
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            for node in nodes {
                sortChildren(&node.children)
            }
        }

        sortChildren(&rootChildren)
        return rootChildren
    }
}
