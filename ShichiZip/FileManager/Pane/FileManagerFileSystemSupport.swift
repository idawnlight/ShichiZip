import Darwin
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
        .isHiddenKey,
    ]

    static func entriesPreservingPresentedPath(for url: URL,
                                               fileManager: FileManager = .default) throws -> [FileManagerDirectoryListingEntry]
    {
        let listingURL = try listingURL(for: url)

        let contents = try fileManager.contentsOfDirectory(
            at: listingURL,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [],
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

    /// The directory to actually enumerate: a symbolic link that points at a
    /// directory is followed to its target while children stay presented under
    /// the original `url`.
    static func listingURL(for url: URL) throws -> URL {
        let isSymbolicLink = try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false
        guard isSymbolicLink,
              let resolvedIsDirectory = try url.resolvingSymlinksInPath()
              .resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
              resolvedIsDirectory
        else {
            return url
        }
        return url.resolvingSymlinksInPath()
    }
}

struct FileManagerDirectorySnapshot {
    let url: URL
    let items: [FileSystemItem]

    static func make(for url: URL) throws -> FileManagerDirectorySnapshot {
        // A single getattrlistbulk(2) sweep describes the whole directory; the
        // per-item path is the fallback when bulk enumeration is unavailable or
        // fails, and surfaces a meaningful error if the directory is unreadable.
        if let items = try? bulkItems(for: url) {
            return FileManagerDirectorySnapshot(url: url, items: items)
        }
        return try FileManagerDirectorySnapshot(url: url, items: legacyItems(for: url))
    }

    static func bulkItems(for url: URL) throws -> [FileSystemItem] {
        let listingURL = try FileManagerDirectoryListing.listingURL(for: url)

        // `contentsOfDirectory` reports children under the directory's canonical
        // path, with firmlinks resolved (e.g. `/var` → `/private/var`). `realpath`
        // performs the same resolution, which `URL.resolvingSymlinksInPath` does
        // not. Match it when listing a directory directly; keep children under the
        // original path when following a symbolic link.
        let base = listingURL == url ? canonicalDirectoryURL(url) : url

        return try DirectoryBulkEnumerator.entries(atDirectory: listingURL).map { entry in
            let childURL = base.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
            return FileSystemItem(url: childURL, bulkEntry: entry)
        }
    }

    static func legacyItems(for url: URL) throws -> [FileSystemItem] {
        try FileManagerDirectoryListing.entriesPreservingPresentedPath(for: url)
            .map { FileSystemItem(url: $0.url, resourceValues: $0.resourceValues) }
    }

    private static func canonicalDirectoryURL(_ url: URL) -> URL {
        url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return url }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard let resolved = realpath(pointer, &buffer) else { return url }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
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
        guard let itemKind = fileManager.szExistingItemKind(at: standardizedURL) else {
            return nil
        }

        if itemKind == .directory {
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

        guard let itemKind = fileManager.szExistingItemKind(at: url) else {
            return nil
        }

        if itemKind == .directory {
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
                                 destinationURL: URL) -> Conflict?
    {
        let normalizedDestinationURL = normalizedFileSystemURL(destinationURL)
        var fileSourceURLs: [URL] = []

        for sourceURL in sourceURLs {
            guard isDirectory(at: sourceURL) else {
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

    private static func isDirectory(at url: URL) -> Bool {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &status)
        }
        return result == 0 && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
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
