import Foundation

/// Swift-friendly wrapper around SZArchiveEntry
struct ArchiveItem {
    let index: Int
    let path: String
    let pathParts: [String]
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

    private static func derivePathParts(from path: String) -> [String] {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: "/").map(String.init)
    }

    private static func deriveName(from path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let lastSlash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: lastSlash)...])
    }

    /// Parent path (directory containing this item)
    var parentPath: String {
        guard pathParts.count > 1 else { return "" }
        return pathParts.dropLast().joined(separator: "/")
    }

    /// File extension
    var fileExtension: String {
        guard let dotIndex = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dotIndex)...])
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
        self.path = entry.path.isEmpty ? entry.pathParts.joined(separator: "/") : entry.path
        self.pathParts = entry.pathParts.isEmpty ? Self.derivePathParts(from: self.path) : entry.pathParts
        self.name = self.pathParts.last ?? Self.deriveName(from: self.path)
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

    init(index: Int, path: String, pathParts: [String] = [], name: String, size: UInt64, packedSize: UInt64,
         modifiedDate: Date?, createdDate: Date?, crc: UInt32, isDirectory: Bool,
         isEncrypted: Bool, method: String, attributes: UInt32, comment: String) {
        self.index = index; self.path = path
        self.pathParts = pathParts.isEmpty ? Self.derivePathParts(from: path) : pathParts
        self.name = name
        self.size = size; self.packedSize = packedSize
        self.modifiedDate = modifiedDate; self.createdDate = createdDate
        self.crc = crc; self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted; self.method = method
        self.attributes = attributes; self.comment = comment
    }
}
