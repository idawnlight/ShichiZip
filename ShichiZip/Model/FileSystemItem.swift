import Darwin
import Foundation

/// Represents a file system item for the file manager view
final class FileSystemItem: Sendable {
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .contentAccessDateKey,
        .attributeModificationDateKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
        .isHiddenKey,
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
    let isHidden: Bool

    convenience init(url: URL) {
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        self.init(url: url, resourceValues: values)
    }

    /// Reuses pre-fetched resource values when available.
    init(url: URL, resourceValues: URLResourceValues?) {
        self.url = url
        let status = Self.fileStatus(for: url)
        name = url.lastPathComponent
        isHidden = resourceValues?.isHidden == true || HiddenItemVisibility.isHiddenName(name)

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

    /// Builds the same fields as `init(url:resourceValues:)` from a
    /// `getattrlistbulk(2)` record, so both initializers produce equivalent items.
    init(url: URL, bulkEntry: BulkDirectoryEntry) {
        self.url = url
        name = url.lastPathComponent
        isHidden = bulkEntry.flags & UInt32(UF_HIDDEN) != 0 || HiddenItemVisibility.isHiddenName(name)

        if bulkEntry.isSymbolicLink {
            isDirectory = (try? url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        } else {
            isDirectory = bulkEntry.isDirectory
        }

        size = UInt64(max(0, bulkEntry.dataLength))
        packedSize = UInt64(max(0, bulkEntry.allocatedSize))
        modifiedDate = Self.date(from: bulkEntry.modifiedTime)
        createdDate = Self.date(from: bulkEntry.createdTime)
        accessedDate = Self.date(from: bulkEntry.accessedTime)
        changedDate = Self.date(from: bulkEntry.changedTime)
        attributes = 0x8000 | ((bulkEntry.mode & 0xFFFF) << 16)
        inode = bulkEntry.inode
        links = UInt64(bulkEntry.linkCount)
    }

    var formattedSize: String {
        if isDirectory {
            return "--"
        }
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
        // Match CoreFoundation's own timespec→Date conversion (subtract the 1970
        // epoch before adding the sub-second term, and multiply rather than
        // divide) so these dates equal the ones Foundation derives for the same
        // timestamps.
        let secondsSinceReference = TimeInterval(timeSpec.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate
        return Date(timeIntervalSinceReferenceDate: secondsSinceReference + 1e-9 * TimeInterval(timeSpec.tv_nsec))
    }
}

extension FileSystemItem: Equatable {
    static func == (lhs: FileSystemItem, rhs: FileSystemItem) -> Bool {
        lhs.url.standardizedFileURL.path == rhs.url.standardizedFileURL.path
            && lhs.name == rhs.name
            && lhs.isDirectory == rhs.isDirectory
            && lhs.size == rhs.size
            && lhs.packedSize == rhs.packedSize
            && lhs.modifiedDate == rhs.modifiedDate
            && lhs.createdDate == rhs.createdDate
            && lhs.accessedDate == rhs.accessedDate
            && lhs.changedDate == rhs.changedDate
            && lhs.attributes == rhs.attributes
            && lhs.inode == rhs.inode
            && lhs.links == rhs.links
            && lhs.isHidden == rhs.isHidden
    }
}
