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

    private static func stringsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
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

    static func duplicateRootPrefixToStrip(for items: [ArchiveItem],
                                           destinationLeafName: String,
                                           removingPrefix prefix: String? = nil) -> String? {
        let trimmedLeafName = destinationLeafName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLeafName.isEmpty else { return nil }

        let prefixComponents = prefix.map(Self.derivePathParts(from:)) ?? []
        var sawRelativeItem = false

        for item in items {
            let components = item.pathParts.isEmpty ? Self.derivePathParts(from: item.path) : item.pathParts
            guard components.count >= prefixComponents.count else { return nil }

            for (prefixComponent, component) in zip(prefixComponents, components) {
                guard stringsMatch(prefixComponent, component) else {
                    return nil
                }
            }

            let relativeComponents = Array(components.dropFirst(prefixComponents.count))
            guard let firstComponent = relativeComponents.first else { continue }

            sawRelativeItem = true
            guard stringsMatch(firstComponent, trimmedLeafName) else {
                return nil
            }

            if relativeComponents.count == 1 && !item.isDirectory {
                return nil
            }
        }

        guard sawRelativeItem else { return nil }
        return (prefixComponents + [trimmedLeafName]).joined(separator: "/")
    }

    static func extractedOutputURLs(for items: [ArchiveItem],
                                    destinationURL: URL,
                                    pathMode: SZPathMode,
                                    pathPrefixToStrip: String?) -> [URL] {
        let prefixComponents = pathPrefixToStrip.map(Self.derivePathParts(from:)) ?? []
        var seenPaths = Set<String>()
        var outputURLs: [URL] = []

        for item in items {
            let itemOutputURLs = extractedOutputURLs(for: item,
                                                     destinationURL: destinationURL,
                                                     pathMode: pathMode,
                                                     prefixComponents: prefixComponents)
            for outputURL in itemOutputURLs {
                let standardizedURL = outputURL.standardizedFileURL
                guard seenPaths.insert(standardizedURL.path).inserted else { continue }
                outputURLs.append(standardizedURL)
            }
        }

        return outputURLs
    }

    private static func extractedOutputURLs(for item: ArchiveItem,
                                            destinationURL: URL,
                                            pathMode: SZPathMode,
                                            prefixComponents: [String]) -> [URL] {
        let components = item.pathParts.isEmpty ? derivePathParts(from: item.path) : item.pathParts
        let relativeComponents = removingPrefixComponents(prefixComponents, from: components)

        switch pathMode {
        case .noPaths:
            guard !item.isDirectory else { return [] }
            let leafName = relativeComponents.last ?? item.name
            guard !leafName.isEmpty else { return [] }
            return [destinationURL.appendingPathComponent(leafName, isDirectory: false)]

        case .absolutePaths:
            if NSString(string: item.path).isAbsolutePath {
                let trimmedPath = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !trimmedPath.isEmpty else { return [] }
                return [URL(fileURLWithPath: item.path)]
            }

            return relativeOutputURLs(from: relativeComponents,
                                      destinationURL: destinationURL,
                                      leafIsDirectory: item.isDirectory)

        default:
            return relativeOutputURLs(from: relativeComponents,
                                      destinationURL: destinationURL,
                                      leafIsDirectory: item.isDirectory)
        }
    }

    private static func relativeOutputURLs(from relativeComponents: [String],
                                           destinationURL: URL,
                                           leafIsDirectory: Bool) -> [URL] {
        guard !relativeComponents.isEmpty else { return [] }

        var urls: [URL] = []
        if relativeComponents.count > 1 {
            for depth in 1..<relativeComponents.count {
                let directoryPath = NSString.path(withComponents: Array(relativeComponents.prefix(depth)))
                urls.append(destinationURL.appendingPathComponent(directoryPath, isDirectory: true))
            }
        }

        let leafPath = NSString.path(withComponents: relativeComponents)
        urls.append(destinationURL.appendingPathComponent(leafPath, isDirectory: leafIsDirectory))
        return urls
    }

    private static func removingPrefixComponents(_ prefixComponents: [String],
                                                 from components: [String]) -> [String] {
        guard !prefixComponents.isEmpty,
              components.count >= prefixComponents.count else {
            return components
        }

        for (prefixComponent, component) in zip(prefixComponents, components) {
            guard stringsMatch(prefixComponent, component) else {
                return components
            }
        }

        return Array(components.dropFirst(prefixComponents.count))
    }

    private static func normalizedPathParts(_ parts: [String]) -> [String] {
        parts.filter { !$0.isEmpty }
    }

    init(from entry: SZArchiveEntry) {
        let normalizedEntryPathParts = Self.normalizedPathParts(entry.pathParts)
        let preservesAbsoluteRoot = entry.path.isEmpty && entry.pathParts.first == ""
        self.index = Int(entry.index)
        self.path = entry.path.isEmpty
            ? (preservesAbsoluteRoot ? "/" : "") + normalizedEntryPathParts.joined(separator: "/")
            : entry.path
        self.pathParts = normalizedEntryPathParts.isEmpty ? Self.derivePathParts(from: self.path) : normalizedEntryPathParts
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
