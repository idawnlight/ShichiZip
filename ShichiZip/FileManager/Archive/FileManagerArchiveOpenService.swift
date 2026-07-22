import Cocoa

enum FileManagerArchiveOpenMode {
    case defaultBehavior
    case wildcard
    case parser

    var openType: String? {
        switch self {
        case .defaultBehavior:
            nil
        case .wildcard:
            "*"
        case .parser:
            "#"
        }
    }
}

enum FileManagerArchiveOpenResult {
    case opened
    case unsupportedArchive(Error)
    case cancelled
    case failed(Error)
}

struct FileManagerArchiveMutationTarget {
    let archive: SZArchive
    let subdir: String
    let topLevelArchiveURL: URL?
}

enum FileManagerArchiveMutationOutcome {
    case completed(SZArchiveUpdateOutcome)
    case archiveCommittedAfterCancellation
    case archiveCommittedAfterError(Error, requiresReopen: Bool)

    var requiresReopenBeforeRefresh: Bool {
        if case let .archiveCommittedAfterError(_, requiresReopen) = self {
            return requiresReopen
        }
        return false
    }

    var committedError: Error? {
        if case let .archiveCommittedAfterError(error, _) = self {
            return error
        }
        return nil
    }

    @discardableResult
    static func perform(_ operation: () throws -> SZArchiveUpdateOutcome) throws -> Self {
        do {
            return .completed(try operation())
        } catch {
            guard szArchiveMutationWasCommitted(error) else {
                throw error
            }
            if szIsUserCancellation(error) {
                return .archiveCommittedAfterCancellation
            }
            return .archiveCommittedAfterError(
                error,
                requiresReopen: szArchiveMutationRequiresReopen(error),
            )
        }
    }
}

extension FileManagerArchiveMutationOutcome: ArchiveOperationPresentationResult {
    var archiveUpdateOutcomeForPresentation: SZArchiveUpdateOutcome? {
        if case let .completed(outcome) = self {
            return outcome
        }
        return nil
    }
}

/// A mutation target paired with an operation-gate lease held for the lifetime of an in-place
/// archive write, so a concurrent `closeLevel` drains before `archive.close()` tears down the
/// shared `SZArchive`. Mirrors the lease carried by `FileManagerArchiveItemWorkflowContext` for
/// extraction.
struct FileManagerLeasedArchiveMutationTarget {
    let archive: SZArchive
    let subdir: String
    let lease: FileManagerArchiveOperationGate.Lease
}

/// Pairs the current archive with an operation-gate lease so a background read keeps the gate busy,
/// letting `closeLevel`'s drain wait for it instead of hard-blocking on `close()`. The lease is
/// optional so the read still proceeds when the archive is already closing.
struct FileManagerLeasedArchive {
    let archive: SZArchive
    let lease: FileManagerArchiveOperationGate.Lease?
}

struct FileManagerArchiveFileFingerprint: Equatable {
    let fileSize: UInt64
    let modificationDate: Date
    let fileNumber: UInt64?

    static func captureIfPossible(for url: URL,
                                  fileManager: FileManager = .default) -> FileManagerArchiveFileFingerprint?
    {
        let standardizedURL = url.standardizedFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: standardizedURL.path),
              let modificationDate = attributes[.modificationDate] as? Date
        else {
            return nil
        }

        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return FileManagerArchiveFileFingerprint(fileSize: fileSize,
                                                 modificationDate: modificationDate,
                                                 fileNumber: fileNumber)
    }

    func matchesCurrentFile(at url: URL,
                            fileManager: FileManager = .default) -> Bool
    {
        Self.captureIfPossible(for: url,
                               fileManager: fileManager) == self
    }
}

struct FileManagerNestedArchiveWriteBackInfo {
    let identity: FileManagerNestedArchiveIdentity
    let parentTarget: FileManagerArchiveMutationTarget
    let parentItemReference: SZArchiveItemReference
    let parentArchiveURL: URL
    let parentArchiveFingerprint: FileManagerArchiveFileFingerprint
    let initialFingerprint: FileManagerArchiveFileFingerprint

    var parentItemPath: String {
        parentItemReference.path
    }
}

struct FileManagerPreparedArchiveOpen {
    let hostDirectory: URL
    let archivePath: String
    let displayPathPrefix: String
    let archive: SZArchive
    let entries: [ArchiveItem]
    let temporaryDirectory: URL?
    let nestedIdentity: FileManagerNestedArchiveIdentity?
    let nestedWriteBackInfo: FileManagerNestedArchiveWriteBackInfo?

    init(hostDirectory: URL,
         archivePath: String,
         displayPathPrefix: String,
         archive: SZArchive,
         entries: [ArchiveItem],
         temporaryDirectory: URL?,
         nestedIdentity: FileManagerNestedArchiveIdentity? = nil,
         nestedWriteBackInfo: FileManagerNestedArchiveWriteBackInfo?)
    {
        self.hostDirectory = hostDirectory
        self.archivePath = archivePath
        self.displayPathPrefix = displayPathPrefix
        self.archive = archive
        self.entries = entries
        self.temporaryDirectory = temporaryDirectory
        self.nestedIdentity = nestedIdentity ?? nestedWriteBackInfo?.identity
        self.nestedWriteBackInfo = nestedWriteBackInfo
    }
}

enum FileManagerPreparedArchiveOpenResult {
    case opened(FileManagerPreparedArchiveOpen)
    case unsupportedArchive(Error)
    case cancelled
    case failed(Error)
}

enum FileManagerArchiveOpenService {
    @MainActor
    static func open(url: URL,
                     hostDirectory: URL,
                     temporaryDirectory: URL?,
                     displayPathPrefix: String,
                     parentWindow: NSWindow? = nil,
                     nestedIdentity: FileManagerNestedArchiveIdentity? = nil,
                     nestedWriteBackInfo: FileManagerNestedArchiveWriteBackInfo? = nil,
                     openMode: FileManagerArchiveOpenMode = .defaultBehavior) async -> FileManagerPreparedArchiveOpenResult
    {
        do {
            return try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.opening"),
                                                        initialFileName: displayPathPrefix,
                                                        parentWindow: parentWindow,
                                                        deferredDisplay: true)
            { session in
                prepareArchiveOpen(url: url,
                                   hostDirectory: hostDirectory,
                                   temporaryDirectory: temporaryDirectory,
                                   displayPathPrefix: displayPathPrefix,
                                   nestedIdentity: nestedIdentity,
                                   nestedWriteBackInfo: nestedWriteBackInfo,
                                   openMode: openMode,
                                   session: session)
            }
        } catch {
            return .failed(error)
        }
    }

    static func prepareArchiveOpen(url: URL,
                                   hostDirectory: URL,
                                   temporaryDirectory: URL?,
                                   displayPathPrefix: String,
                                   nestedIdentity: FileManagerNestedArchiveIdentity? = nil,
                                   nestedWriteBackInfo: FileManagerNestedArchiveWriteBackInfo?,
                                   openMode: FileManagerArchiveOpenMode,
                                   session: SZOperationSession) -> FileManagerPreparedArchiveOpenResult
    {
        let archive = SZArchive()
        do {
            try coordinatedRead(at: url) { coordinatedURL in
                try archive.open(atPath: coordinatedURL.path,
                                 openType: openMode.openType,
                                 session: session)
            }
            let entries = try FileManagerArchiveListing.items(from: archive,
                                                              session: session)
            return .opened(FileManagerPreparedArchiveOpen(hostDirectory: hostDirectory,
                                                          archivePath: url.path,
                                                          displayPathPrefix: displayPathPrefix,
                                                          archive: archive,
                                                          entries: entries,
                                                          temporaryDirectory: temporaryDirectory,
                                                          nestedIdentity: nestedIdentity,
                                                          nestedWriteBackInfo: nestedWriteBackInfo))
        } catch {
            archive.close()
            if szIsUnsupportedArchive(error) {
                return .unsupportedArchive(error)
            }
            if szIsUserCancellation(error) {
                return .cancelled
            }
            return .failed(error)
        }
    }

    /// Read the file through an `NSFileCoordinator` so cloud / file-provider
    /// placeholders are materialized before 7-Zip's POSIX `open(2)` runs, and
    /// hold a security-scoped access grant for the duration of the read so
    /// sandboxed entry points (Launch Services hand-off, bookmarks) work.
    private static func coordinatedRead(at url: URL,
                                        accessor: (URL) throws -> Void) throws
    {
        let needsScopeRelease = url.startAccessingSecurityScopedResource()
        defer { if needsScopeRelease { url.stopAccessingSecurityScopedResource() } }

        var coordinatorError: NSError?
        var accessorError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            do {
                try accessor(coordinatedURL)
            } catch {
                accessorError = error
            }
        }
        if let accessorError { throw accessorError }
        if let coordinatorError { throw coordinatorError }
    }
}
