import Foundation

struct FileManagerDirectoryListingEntry {
    let url: URL
    let resourceValues: URLResourceValues?
}

enum FileManagerDirectoryListing {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .contentAccessDateKey,
        .attributeModificationDateKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
    ]

    static func contentsPreservingPresentedPath(for url: URL,
                                                options: FileManager.DirectoryEnumerationOptions,
                                                fileManager: FileManager = .default) throws -> [URL]
    {
        try entriesPreservingPresentedPath(for: url,
                                           options: options,
                                           fileManager: fileManager)
            .map(\.url)
    }

    static func entriesPreservingPresentedPath(for url: URL,
                                               options: FileManager.DirectoryEnumerationOptions,
                                               fileManager: FileManager = .default) throws -> [FileManagerDirectoryListingEntry]
    {
        let resourceValues = try url.resourceValues(forKeys: Self.resourceKeys)
        let listingURL: URL = if resourceValues.isSymbolicLink == true,
                                 let resolvedIsDirectory = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                                 resolvedIsDirectory
        {
            url.resolvingSymlinksInPath()
        } else {
            url
        }

        let contents = try fileManager.contentsOfDirectory(
            at: listingURL,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: options,
        )

        let entries = contents.map { childURL in
            let childValues = try? childURL.resourceValues(forKeys: Self.resourceKeys)
            return (url: childURL, resourceValues: childValues)
        }

        guard listingURL != url else {
            return entries.map { FileManagerDirectoryListingEntry(url: $0.url,
                                                                  resourceValues: $0.resourceValues) }
        }

        return entries.map { entry in
            FileManagerDirectoryListingEntry(
                url: url.appendingPathComponent(entry.url.lastPathComponent,
                                                isDirectory: entry.resourceValues?.isDirectory ?? false),
                resourceValues: entry.resourceValues,
            )
        }
    }
}

struct FileManagerDirectorySnapshot {
    struct EntryFingerprint: Equatable {
        let path: String
        let isDirectory: Bool
        let size: Int
        let modifiedDate: Date?
        let createdDate: Date?
    }

    let url: URL
    let fingerprint: [EntryFingerprint]
    let items: [FileSystemItem]

    static func make(for url: URL,
                     options: FileManager.DirectoryEnumerationOptions) throws -> FileManagerDirectorySnapshot
    {
        let entries = try FileManagerDirectoryListing.entriesPreservingPresentedPath(for: url,
                                                                                     options: options)
        let pairs: [(EntryFingerprint, FileSystemItem)] = entries.map { entry in
            let values = entry.resourceValues
            let fingerprint = EntryFingerprint(
                path: entry.url.standardizedFileURL.path,
                isDirectory: values?.isDirectory ?? false,
                size: values?.fileSize ?? 0,
                modifiedDate: values?.contentModificationDate,
                createdDate: values?.creationDate,
            )
            let item = FileSystemItem(url: entry.url, resourceValues: values)
            return (fingerprint, item)
        }

        return FileManagerDirectorySnapshot(url: url,
                                            fingerprint: pairs.map(\.0).sorted { $0.path < $1.path },
                                            items: pairs.map(\.1))
    }
}

enum FileManagerRecentDirectoryHistory {
    private static let maxEntries = 20

    static func normalized(_ entries: [URL]) -> [URL] {
        var normalizedEntries: [URL] = []
        var seenPaths = Set<String>()

        for url in entries {
            let standardizedURL = url.standardizedFileURL
            guard seenPaths.insert(standardizedURL.path).inserted else { continue }
            normalizedEntries.append(standardizedURL)
            if normalizedEntries.count == maxEntries {
                break
            }
        }

        return normalizedEntries
    }

    static func recordingVisit(_ url: URL, in entries: [URL]) -> [URL] {
        let standardizedURL = url.standardizedFileURL
        var updatedEntries = entries
        updatedEntries.removeAll { $0.standardizedFileURL == standardizedURL }
        updatedEntries.insert(standardizedURL, at: 0)
        if updatedEntries.count > maxEntries {
            updatedEntries.removeSubrange(maxEntries ..< updatedEntries.count)
        }
        return updatedEntries
    }
}

struct FileManagerFileSystemRevealTarget {
    let parentDirectory: URL
    let selectedPaths: Set<String>
    let focusedPath: String?
}

enum FileManagerFileSystemOpenTarget {
    case directory(URL)
    case file(url: URL, hostDirectory: URL)
}

enum FileManagerFileSystemNavigation {
    static func rootURL(for directoryURL: URL) -> URL {
        let components = directoryURL.standardizedFileURL.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            return URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(3))))
        }
        return URL(fileURLWithPath: "/")
    }

    static func revealTarget(for urls: [URL]) -> FileManagerFileSystemRevealTarget? {
        let standardizedURLs = urls.map(\.standardizedFileURL)
        guard !standardizedURLs.isEmpty else { return nil }

        let parentDirectory = standardizedURLs[0].deletingLastPathComponent().standardizedFileURL
        guard standardizedURLs.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parentDirectory }) else {
            return nil
        }

        return FileManagerFileSystemRevealTarget(parentDirectory: parentDirectory,
                                                 selectedPaths: Set(standardizedURLs.map(\.path)),
                                                 focusedPath: standardizedURLs.first?.path)
    }

    static func openTarget(for url: URL,
                           fileManager: FileManager = .default) -> FileManagerFileSystemOpenTarget?
    {
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return .directory(standardizedURL)
        }

        return .file(url: standardizedURL,
                     hostDirectory: standardizedURL.deletingLastPathComponent().standardizedFileURL)
    }

    static func addressBarTarget(for enteredPath: String,
                                 fileManager: FileManager = .default) -> FileManagerFileSystemOpenTarget?
    {
        let expandedPath = NSString(string: enteredPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return .directory(url)
        }

        return .file(url: url,
                     hostDirectory: url.deletingLastPathComponent())
    }
}

enum FileManagerTransferPathValidation {
    enum ConflictKind: Equatable {
        case sameDestination
        case descendant
    }

    struct Conflict: Equatable {
        let sourceURL: URL
        let destinationURL: URL
        let sourceIsDirectory: Bool
        let kind: ConflictKind

        var isSameLocation: Bool {
            kind == .sameDestination
        }
    }

    static func ancestryConflict(sourceURLs: [URL],
                                 destinationURL: URL,
                                 fileManager: FileManager = .default) -> Conflict?
    {
        let normalizedDestinationURL = normalizedFileSystemURL(destinationURL)
        var fileSourceURLs: [URL] = []

        for sourceURL in sourceURLs {
            guard isDirectory(at: sourceURL, fileManager: fileManager) else {
                fileSourceURLs.append(sourceURL.standardizedFileURL)
                continue
            }

            let normalizedSourceURL = normalizedFileSystemURL(sourceURL)
            if normalizedDestinationURL == normalizedSourceURL {
                return Conflict(sourceURL: sourceURL.standardizedFileURL,
                                destinationURL: normalizedDestinationURL,
                                sourceIsDirectory: true,
                                kind: .sameDestination)
            }

            if isDescendant(normalizedDestinationURL, of: normalizedSourceURL) {
                return Conflict(sourceURL: sourceURL.standardizedFileURL,
                                destinationURL: normalizedDestinationURL,
                                sourceIsDirectory: true,
                                kind: .descendant)
            }
        }

        for sourceURL in fileSourceURLs {
            let normalizedParentURL = normalizedFileSystemURL(sourceURL.deletingLastPathComponent())
            guard normalizedDestinationURL == normalizedParentURL else {
                continue
            }

            return Conflict(sourceURL: sourceURL,
                            destinationURL: normalizedDestinationURL,
                            sourceIsDirectory: false,
                            kind: .sameDestination)
        }

        return nil
    }

    static func normalizedFileSystemURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isDirectory(at url: URL,
                                    fileManager: FileManager) -> Bool
    {
        let normalizedURL = normalizedFileSystemURL(url)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: normalizedURL.path,
                                     isDirectory: &isDirectory)
        else {
            return false
        }

        return isDirectory.boolValue
    }

    private static func isDescendant(_ url: URL,
                                     of ancestorURL: URL) -> Bool
    {
        let pathComponents = url.pathComponents
        let ancestorComponents = ancestorURL.pathComponents
        guard pathComponents.count > ancestorComponents.count else {
            return false
        }

        return Array(pathComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }
}

struct FileManagerTrashFailure {
    let url: URL
    let error: Error
}

enum FileManagerTrashOperation {
    static func trashItems(at paths: [String],
                           trashItem: (URL) throws -> Void = { url in
                               try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                           }) -> [FileManagerTrashFailure]
    {
        var failures: [FileManagerTrashFailure] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            do {
                try trashItem(url)
            } catch {
                failures.append(FileManagerTrashFailure(url: url, error: error))
            }
        }
        return failures
    }

    static func error(for failures: [FileManagerTrashFailure], attemptedCount: Int) -> NSError? {
        guard let firstFailure = failures.first else { return nil }

        let firstError = firstFailure.error as NSError
        return NSError(domain: NSCocoaErrorDomain,
                       code: CocoaError.fileWriteUnknown.rawValue,
                       userInfo: [
                           NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.error.trashFailedTitle", failures.count),
                           NSLocalizedFailureReasonErrorKey: SZL10n.string("app.fileManager.error.trashFailedReason", failures.count, attemptedCount),
                           NSLocalizedRecoverySuggestionErrorKey: SZL10n.string("app.fileManager.error.trashFailedFirstFailure",
                                                                                firstFailure.url.lastPathComponent,
                                                                                firstError.localizedDescription),
                           NSFilePathErrorKey: firstFailure.url.path,
                           NSUnderlyingErrorKey: firstError,
                       ])
    }
}
