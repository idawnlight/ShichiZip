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
