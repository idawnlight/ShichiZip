import Foundation

enum FileManagerArchiveOpenMode {
    case defaultBehavior
    case wildcard
    case parser

    var openType: String? {
        switch self {
        case .defaultBehavior:
            return nil
        case .wildcard:
            return "*"
        case .parser:
            return "#"
        }
    }
}

enum FileManagerArchiveOpenResult {
    case opened
    case unsupportedArchive(Error)
    case cancelled
    case failed(Error)
}

struct FileManagerPreparedArchiveOpen {
    let hostDirectory: URL
    let archivePath: String
    let displayPathPrefix: String
    let archive: SZArchive
    let entries: [ArchiveItem]
    let temporaryDirectory: URL?
}

enum FileManagerPreparedArchiveOpenResult {
    case opened(FileManagerPreparedArchiveOpen)
    case unsupportedArchive(Error)
    case cancelled
    case failed(Error)
}

enum FileManagerArchiveOpenService {
    @MainActor
    static func openSynchronously(url: URL,
                                  hostDirectory: URL,
                                  temporaryDirectory: URL?,
                                  displayPathPrefix: String,
                                  openMode: FileManagerArchiveOpenMode = .defaultBehavior) -> FileManagerPreparedArchiveOpenResult {
        do {
            return try ArchiveOperationRunner.runSynchronously(operationTitle: "Opening archive...",
                                                              initialFileName: displayPathPrefix,
                                                              deferredDisplay: true) { session in
                prepareArchiveOpen(url: url,
                                   hostDirectory: hostDirectory,
                                   temporaryDirectory: temporaryDirectory,
                                   displayPathPrefix: displayPathPrefix,
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
                                   openMode: FileManagerArchiveOpenMode,
                                   session: SZOperationSession) -> FileManagerPreparedArchiveOpenResult {
        let archive = SZArchive()
        do {
            try archive.open(atPath: url.path,
                             openType: openMode.openType,
                             session: session)
        } catch {
            if szIsUnsupportedArchive(error) {
                return .unsupportedArchive(error)
            }
            if szIsUserCancellation(error) {
                return .cancelled
            }
            return .failed(error)
        }

        let entries = archive.entries().map { ArchiveItem(from: $0) }
        return .opened(FileManagerPreparedArchiveOpen(hostDirectory: hostDirectory,
                                                      archivePath: url.path,
                                                      displayPathPrefix: displayPathPrefix,
                                                      archive: archive,
                                                      entries: entries,
                                                      temporaryDirectory: temporaryDirectory))
    }
}