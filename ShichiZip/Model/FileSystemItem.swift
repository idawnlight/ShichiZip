import Foundation

/// Represents a file system item for the file manager view
class FileSystemItem {
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey,
    ]

    let url: URL
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modifiedDate: Date?
    let createdDate: Date?

    convenience init(url: URL) {
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        self.init(url: url, resourceValues: values)
    }

    /// Preferred initializer when the caller has already fetched
    /// `URLResourceValues` for `url` (for example as part of building a
    /// directory fingerprint). Avoids the second synchronous
    /// filesystem round-trip that `init(url:)` would otherwise perform.
    init(url: URL, resourceValues: URLResourceValues?) {
        self.url = url
        name = url.lastPathComponent

        let resolvedDirectoryValue: Bool?
        if resourceValues?.isSymbolicLink == true {
            let resolvedURL = url.resolvingSymlinksInPath()
            resolvedDirectoryValue = try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
        } else {
            resolvedDirectoryValue = nil
        }

        isDirectory = resolvedDirectoryValue ?? resourceValues?.isDirectory ?? false
        size = UInt64(resourceValues?.fileSize ?? 0)
        modifiedDate = resourceValues?.contentModificationDate
        createdDate = resourceValues?.creationDate
    }

    var formattedSize: String {
        if isDirectory { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
