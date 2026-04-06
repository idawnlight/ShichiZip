import Foundation

/// Represents a file system item for the file manager view
class FileSystemItem {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modifiedDate: Date?
    let createdDate: Date?
    let isArchive: Bool

    private(set) var children: [FileSystemItem]?
    weak var parent: FileSystemItem?

    static let archiveExtensions: Set<String> = [
        "7z", "zip", "tar", "gz", "bz2", "xz", "rar", "cab", "iso",
        "dmg", "wim", "lzh", "lzma", "cpio", "rpm", "deb", "arj", "z",
        "tgz", "tbz2", "txz", "tar.gz", "tar.bz2", "tar.xz", "zst"
    ]

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        let resourceValues = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey
        ])

        self.isDirectory = resourceValues?.isDirectory ?? false
        self.size = UInt64(resourceValues?.fileSize ?? 0)
        self.modifiedDate = resourceValues?.contentModificationDate
        self.createdDate = resourceValues?.creationDate
        self.isArchive = Self.archiveExtensions.contains(url.pathExtension.lowercased())
    }

    var formattedSize: String {
        if isDirectory { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// Load children (lazy)
    func loadChildren() {
        guard isDirectory else { return }
        guard children == nil else { return }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            children = []
            return
        }

        children = contents.map { childURL in
            let item = FileSystemItem(url: childURL)
            item.parent = self
            return item
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Reload children
    func reloadChildren() {
        children = nil
        loadChildren()
    }
}
