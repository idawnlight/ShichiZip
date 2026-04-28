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
    let accessedDate: Date?
    let crc: UInt32
    let isDirectory: Bool
    let isEncrypted: Bool
    let isAnti: Bool
    let method: String
    let attributes: UInt32
    let position: UInt64
    let block: UInt64
    let comment: String
    let propertyValues: [String: String]

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

    /// Human-readable size string
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    static func duplicateRootPrefixToStrip(for items: [ArchiveItem],
                                           destinationLeafName: String,
                                           removingPrefix prefix: String? = nil) -> String?
    {
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

            if relativeComponents.count == 1, !item.isDirectory {
                return nil
            }
        }

        guard sawRelativeItem else { return nil }
        return (prefixComponents + [trimmedLeafName]).joined(separator: "/")
    }

    static func extractedOutputURLs(for items: [ArchiveItem],
                                    destinationURL: URL,
                                    pathMode: SZPathMode,
                                    pathPrefixToStrip: String?) -> [URL]
    {
        let prefixComponents = pathPrefixToStrip.map(Self.derivePathParts(from:)) ?? []
        let standardizedDestination = destinationURL.standardizedFileURL
        var seenPaths = Set<String>()
        var outputURLs: [URL] = []

        for item in items {
            let itemOutputURLs = extractedOutputURLs(for: item,
                                                     destinationURL: standardizedDestination,
                                                     pathMode: pathMode,
                                                     prefixComponents: prefixComponents)
            for outputURL in itemOutputURLs {
                let standardizedURL = outputURL.standardizedFileURL
                // Never return paths that escape the destination directory.
                guard isURL(standardizedURL, containedIn: standardizedDestination) else { continue }
                guard seenPaths.insert(standardizedURL.path).inserted else { continue }
                outputURLs.append(standardizedURL)
            }
        }

        return outputURLs
    }

    private static func isURL(_ candidate: URL, containedIn parent: URL) -> Bool {
        let parentComponents = parent.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= parentComponents.count else { return false }
        return Array(candidateComponents.prefix(parentComponents.count)) == parentComponents
    }

    private static func extractedOutputURLs(for item: ArchiveItem,
                                            destinationURL: URL,
                                            pathMode: SZPathMode,
                                            prefixComponents: [String]) -> [URL]
    {
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
                // Re-anchor absolute archive paths under the destination.
                let trimmedPath = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !trimmedPath.isEmpty else { return [] }
                let anchored = destinationURL.appendingPathComponent(trimmedPath,
                                                                     isDirectory: item.isDirectory)
                return [anchored]
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
                                           leafIsDirectory: Bool) -> [URL]
    {
        guard !relativeComponents.isEmpty else { return [] }

        var urls: [URL] = []
        if relativeComponents.count > 1 {
            for depth in 1 ..< relativeComponents.count {
                let directoryPath = NSString.path(withComponents: Array(relativeComponents.prefix(depth)))
                urls.append(destinationURL.appendingPathComponent(directoryPath, isDirectory: true))
            }
        }

        let leafPath = NSString.path(withComponents: relativeComponents)
        urls.append(destinationURL.appendingPathComponent(leafPath, isDirectory: leafIsDirectory))
        return urls
    }

    private static func removingPrefixComponents(_ prefixComponents: [String],
                                                 from components: [String]) -> [String]
    {
        guard !prefixComponents.isEmpty,
              components.count >= prefixComponents.count
        else {
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
        index = Int(entry.index)
        path = entry.path.isEmpty
            ? (preservesAbsoluteRoot ? "/" : "") + normalizedEntryPathParts.joined(separator: "/")
            : entry.path
        pathParts = normalizedEntryPathParts.isEmpty ? Self.derivePathParts(from: path) : normalizedEntryPathParts
        name = pathParts.last ?? Self.deriveName(from: path)
        size = entry.size
        packedSize = entry.packedSize
        modifiedDate = entry.modifiedDate
        createdDate = entry.createdDate
        accessedDate = entry.accessedDate
        crc = entry.crc
        isDirectory = entry.isDirectory
        isEncrypted = entry.isEncrypted
        isAnti = entry.isAnti
        method = entry.method ?? ""
        attributes = entry.attributes
        position = entry.position
        block = entry.block
        comment = entry.comment ?? ""
        propertyValues = entry.propertyValues
    }

    init(index: Int, path: String, pathParts: [String] = [], name: String, size: UInt64, packedSize: UInt64,
         modifiedDate: Date?, createdDate: Date?, accessedDate: Date?, crc: UInt32, isDirectory: Bool,
         isEncrypted: Bool, isAnti: Bool, method: String, attributes: UInt32, position: UInt64, block: UInt64,
         comment: String, propertyValues: [String: String] = [:])
    {
        self.index = index; self.path = path
        self.pathParts = pathParts.isEmpty ? Self.derivePathParts(from: path) : pathParts
        self.name = name
        self.size = size; self.packedSize = packedSize
        self.modifiedDate = modifiedDate; self.createdDate = createdDate
        self.accessedDate = accessedDate
        self.crc = crc; self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted; self.isAnti = isAnti
        self.method = method; self.attributes = attributes
        self.position = position; self.block = block
        self.comment = comment
        self.propertyValues = propertyValues
    }
}
