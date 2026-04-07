import Foundation

/// Represents a file system item for the file manager view
class FileSystemItem {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modifiedDate: Date?
    let createdDate: Date?

    private(set) var children: [FileSystemItem]?
    weak var parent: FileSystemItem?

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        let resourceValues = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey
        ])

        let resolvedDirectoryValue: Bool?
        if resourceValues?.isSymbolicLink == true {
            let resolvedURL = url.resolvingSymlinksInPath()
            resolvedDirectoryValue = try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
        } else {
            resolvedDirectoryValue = nil
        }

        self.isDirectory = resolvedDirectoryValue ?? resourceValues?.isDirectory ?? false
        self.size = UInt64(resourceValues?.fileSize ?? 0)
        self.modifiedDate = resourceValues?.contentModificationDate
        self.createdDate = resourceValues?.creationDate
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
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey],
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
