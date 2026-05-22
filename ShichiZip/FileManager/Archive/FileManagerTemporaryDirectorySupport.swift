import Foundation

enum FileManagerTemporaryDirectorySupport {
    static let openArchivePrefix = "7zO"
    static let dragPrefix = "7zE"
    static let quickLookPrefix = "7zQ"
    static let stagingPrefix = "7zS"
    /// Destination-side extraction sidecars reuse the temp naming scheme but are not
    /// temp-root managed items.
    static let extractionSidecarPrefix = ".7zT"

    private static let randomSuffixLength = 8
    private static let directoryCreationAttempts = 16
    private static let managedRootPrefixes = ["7zE", "7zO", "7zQ", "7zS"]

    static func rootDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
    }

    static func makeTemporaryDirectory(prefix: String,
                                       fileManager: FileManager = .default) throws -> URL
    {
        let root = rootDirectory(fileManager: fileManager)
        return try makeUniqueDirectory(in: root,
                                       prefix: prefix,
                                       fileManager: fileManager,
                                       failureDescription: "Unable to create a unique temporary directory.")
    }

    static func makeUniqueDirectory(in parentURL: URL,
                                    prefix: String,
                                    fileManager: FileManager = .default,
                                    failureDescription: String) throws -> URL
    {
        try fileManager.createDirectory(at: parentURL,
                                        withIntermediateDirectories: true)

        for _ in 0 ..< directoryCreationAttempts {
            let candidate = parentURL.appendingPathComponent(prefix + randomSuffix(), isDirectory: true)
            do {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate.standardizedFileURL
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain,
                   error.code == CocoaError.fileWriteFileExists.rawValue
                {
                    continue
                }
                throw error
            }
        }

        throw NSError(domain: NSCocoaErrorDomain,
                      code: CocoaError.fileWriteUnknown.rawValue,
                      userInfo: [NSLocalizedDescriptionKey: failureDescription])
    }

    static func isManagedRootItem(_ url: URL) -> Bool {
        let name = url.lastPathComponent

        guard let prefix = managedRootPrefixes.first(where: { name.hasPrefix($0) }) else {
            return false
        }

        let suffix = name.dropFirst(prefix.count)
        return suffix.count == 8 && suffix.unicodeScalars.allSatisfy(\.isASCIIHexDigit)
    }

    static func isInsideRoot(_ url: URL,
                             fileManager: FileManager = .default) -> Bool
    {
        let root = rootDirectory(fileManager: fileManager)
        let standardized = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return standardized.path == rootPath || standardized.path.hasPrefix(rootPrefix)
    }

    private static func randomSuffix() -> String {
        String(UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(randomSuffixLength)).uppercased()
    }
}

private extension UnicodeScalar {
    var isASCIIHexDigit: Bool {
        switch value {
        case 48 ... 57, 65 ... 70, 97 ... 102:
            true
        default:
            false
        }
    }
}
