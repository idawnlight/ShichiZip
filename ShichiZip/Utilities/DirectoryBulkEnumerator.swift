import Darwin
import Foundation

/// One directory entry materialized from a single `getattrlistbulk(2)` batch.
///
/// It carries the same facts `FileSystemItem` would otherwise gather from
/// `URLResourceValues` plus a per-item `lstat`, letting a whole directory be
/// described with a handful of syscalls instead of `1 + 2N`.
struct BulkDirectoryEntry {
    let name: String
    let objectType: UInt32
    let mode: UInt32
    let flags: UInt32
    let inode: UInt64
    /// The object's own hard-link count, read straight from the filesystem
    /// (`ATTR_FILE_LINKCOUNT` for files and symlinks, `ATTR_DIR_LINKCOUNT` for
    /// directories) rather than re-synthesizing `lstat`'s `2 + entries` count.
    let linkCount: UInt32
    let dataLength: Int64
    let allocatedSize: Int64
    let createdTime: timespec
    let modifiedTime: timespec
    let changedTime: timespec
    let accessedTime: timespec

    var isDirectory: Bool {
        objectType == DirectoryBulkEnumerator.vdir
    }

    var isSymbolicLink: Bool {
        objectType == DirectoryBulkEnumerator.vlnk
    }
}

/// Reads a directory's entries in bulk via `getattrlistbulk(2)`.
///
/// The parser gates every field read on the kernel's returned-attributes
/// bitmap, advancing the cursor only for attributes the filesystem actually
/// supplied, so it tolerates directories and files reporting different subsets.
enum DirectoryBulkEnumerator {
    static let vreg: UInt32 = 1
    static let vdir: UInt32 = 2
    static let vlnk: UInt32 = 5

    private static let bufferCapacity = 64 * 1024

    static func entries(atDirectory url: URL) throws -> [BulkDirectoryEntry] {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY)
        }
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }

        var attributes = requestedAttributes()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferCapacity, alignment: 8)
        defer { buffer.deallocate() }
        guard let base = buffer.baseAddress else { return [] }

        var entries: [BulkDirectoryEntry] = []
        while true {
            let count = getattrlistbulk(descriptor, &attributes, base, bufferCapacity, 0)
            if count == 0 {
                break
            }
            guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

            var offset = 0
            for _ in 0 ..< count {
                let (entry, length) = parseEntry(base.advanced(by: offset))
                if let entry, entry.name != ".", entry.name != ".." {
                    entries.append(entry)
                }
                offset += length
            }
        }
        return entries
    }

    private static func requestedAttributes() -> attrlist {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_CRTIME)
            | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_CHGTIME)
            | attrgroup_t(ATTR_CMN_ACCTIME)
            | attrgroup_t(ATTR_CMN_ACCESSMASK)
            | attrgroup_t(ATTR_CMN_FLAGS)
            | attrgroup_t(ATTR_CMN_FILEID)
            | attrgroup_t(ATTR_CMN_ERROR)
        attributes.dirattr = attrgroup_t(ATTR_DIR_LINKCOUNT)
        attributes.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT)
            | attrgroup_t(ATTR_FILE_ALLOCSIZE)
            | attrgroup_t(ATTR_FILE_DATALENGTH)
        return attributes
    }

    /// Returns the parsed entry (or `nil` when the kernel flagged a per-entry
    /// error) and the byte length to advance to the next record.
    private static func parseEntry(_ entryBase: UnsafeRawPointer) -> (BulkDirectoryEntry?, Int) {
        let length = Int(entryBase.loadUnaligned(as: UInt32.self))
        var cursor = entryBase.advanced(by: MemoryLayout<UInt32>.size)
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor = cursor.advanced(by: MemoryLayout<attribute_set_t>.size)

        func hasCommon(_ attribute: Int32) -> Bool {
            returned.commonattr & attrgroup_t(attribute) != 0
        }
        func hasDirectory(_ attribute: Int32) -> Bool {
            returned.dirattr & attrgroup_t(attribute) != 0
        }
        func hasFile(_ attribute: Int32) -> Bool {
            returned.fileattr & attrgroup_t(attribute) != 0
        }

        func take<T>(_ type: T.Type) -> T {
            let value = cursor.loadUnaligned(as: type)
            cursor = cursor.advanced(by: MemoryLayout<T>.size)
            return value
        }

        var name = ""
        if hasCommon(ATTR_CMN_NAME) {
            let reference = cursor.loadUnaligned(as: attrreference_t.self)
            name = String(cString: cursor.advanced(by: Int(reference.attr_dataoffset))
                .assumingMemoryBound(to: CChar.self))
            cursor = cursor.advanced(by: MemoryLayout<attrreference_t>.size)
        }

        var objectType: UInt32 = 0
        if hasCommon(ATTR_CMN_OBJTYPE) {
            objectType = take(UInt32.self)
        }
        var createdTime = timespec()
        if hasCommon(ATTR_CMN_CRTIME) {
            createdTime = take(timespec.self)
        }
        var modifiedTime = timespec()
        if hasCommon(ATTR_CMN_MODTIME) {
            modifiedTime = take(timespec.self)
        }
        var changedTime = timespec()
        if hasCommon(ATTR_CMN_CHGTIME) {
            changedTime = take(timespec.self)
        }
        var accessedTime = timespec()
        if hasCommon(ATTR_CMN_ACCTIME) {
            accessedTime = take(timespec.self)
        }
        var mode: UInt32 = 0
        if hasCommon(ATTR_CMN_ACCESSMASK) {
            mode = take(UInt32.self)
        }
        var flags: UInt32 = 0
        if hasCommon(ATTR_CMN_FLAGS) {
            flags = take(UInt32.self)
        }
        var inode: UInt64 = 0
        if hasCommon(ATTR_CMN_FILEID) {
            inode = take(UInt64.self)
        }
        var entryError: Int32 = 0
        if hasCommon(ATTR_CMN_ERROR) {
            entryError = take(Int32.self)
        }

        var linkCount: UInt32 = 1
        if hasDirectory(ATTR_DIR_LINKCOUNT) {
            linkCount = take(UInt32.self)
        }
        if hasFile(ATTR_FILE_LINKCOUNT) {
            linkCount = take(UInt32.self)
        }
        var allocatedSize: Int64 = 0
        if hasFile(ATTR_FILE_ALLOCSIZE) {
            allocatedSize = take(Int64.self)
        }
        var dataLength: Int64 = 0
        if hasFile(ATTR_FILE_DATALENGTH) {
            dataLength = take(Int64.self)
        }

        guard entryError == 0 else { return (nil, length) }

        return (BulkDirectoryEntry(name: name,
                                   objectType: objectType,
                                   mode: mode,
                                   flags: flags,
                                   inode: inode,
                                   linkCount: linkCount,
                                   dataLength: dataLength,
                                   allocatedSize: allocatedSize,
                                   createdTime: createdTime,
                                   modifiedTime: modifiedTime,
                                   changedTime: changedTime,
                                   accessedTime: accessedTime),
                length)
    }
}
