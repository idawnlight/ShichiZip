import Darwin
import Foundation

/// Represents a file system item for the file manager view
class FileSystemItem {
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .contentAccessDateKey,
        .attributeModificationDateKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
    ]

    let url: URL
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let packedSize: UInt64
    let modifiedDate: Date?
    let createdDate: Date?
    let accessedDate: Date?
    let changedDate: Date?
    let attributes: UInt32
    let inode: UInt64?
    let links: UInt64?

    convenience init(url: URL) {
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        self.init(url: url, resourceValues: values)
    }

    /// Reuses pre-fetched resource values when available.
    init(url: URL, resourceValues: URLResourceValues?) {
        self.url = url
        let status = Self.fileStatus(for: url)
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
        packedSize = Self.allocatedSize(resourceValues: resourceValues, status: status)
        modifiedDate = resourceValues?.contentModificationDate
        createdDate = resourceValues?.creationDate
        accessedDate = resourceValues?.contentAccessDate
        changedDate = resourceValues?.attributeModificationDate ?? status.map { Self.date(from: $0.st_ctimespec) }
        attributes = status.map { 0x8000 | (UInt32($0.st_mode) << 16) } ?? 0
        inode = status.map { UInt64($0.st_ino) }
        links = status.map { UInt64($0.st_nlink) }
    }

    var formattedSize: String {
        if isDirectory { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var formattedPackedSize: String {
        guard packedSize > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(packedSize), countStyle: .file)
    }

    private static func fileStatus(for url: URL) -> stat? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &status)
        }
        return result == 0 ? status : nil
    }

    private static func allocatedSize(resourceValues: URLResourceValues?, status: stat?) -> UInt64 {
        let resourceAllocatedSize = resourceValues?.totalFileAllocatedSize
            ?? resourceValues?.fileAllocatedSize
        if let resourceAllocatedSize, resourceAllocatedSize > 0 {
            return UInt64(resourceAllocatedSize)
        }

        guard let status, status.st_blocks > 0 else { return 0 }
        return UInt64(status.st_blocks) * 512
    }

    private static func date(from timeSpec: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timeSpec.tv_sec) + TimeInterval(timeSpec.tv_nsec) / 1_000_000_000)
    }
}

extension FileSystemItem: @unchecked Sendable {}
