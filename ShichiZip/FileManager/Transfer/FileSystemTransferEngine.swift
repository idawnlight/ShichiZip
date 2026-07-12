import Darwin
import Foundation

struct FileSystemTransferEngine {
    enum Operation {
        case copy
        case move
    }

    enum Outcome: Equatable {
        case completed
        case incomplete
        case cancelled
    }

    enum ConflictResolution {
        case overwrite
        case skip
        case cancel
    }

    enum TransferError: LocalizedError {
        case unsupportedItem(URL)
        case incompatibleItemKinds(source: URL, destination: URL)
        case copiedItemKindChanged(URL)
        case directoryFinalizationFailed(destination: URL, operationError: Error, metadataError: Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedItem:
                "The item type is not supported by this file operation."
            case .incompatibleItemKinds:
                "A directory cannot replace a non-directory item, or vice versa."
            case .copiedItemKindChanged:
                "The copied item does not have the expected type."
            case .directoryFinalizationFailed:
                "The directory operation and metadata finalization both failed."
            }
        }

        var failureReason: String? {
            switch self {
            case let .unsupportedItem(url):
                url.path
            case let .incompatibleItemKinds(source, destination):
                "\(source.path) and \(destination.path) have incompatible types."
            case let .copiedItemKindChanged(url):
                url.path
            case let .directoryFinalizationFailed(destination, operationError, metadataError):
                "\(operationError.localizedDescription) Metadata for \(destination.path) also failed: \(metadataError.localizedDescription)"
            }
        }
    }

    private enum ItemKind: Equatable {
        case regularFile
        case directory
        case symbolicLink
    }

    private struct ItemIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Item {
        let kind: ItemKind
        let status: stat

        var identity: ItemIdentity {
            ItemIdentity(device: status.st_dev, inode: status.st_ino)
        }
    }

    private let fileManager: FileManager
    private let renameItem: (URL, URL) -> Int32?

    init(fileManager: FileManager = .default,
         renameItem: @escaping (URL, URL) -> Int32? = FileSystemTransferEngine.renameExclusively)
    {
        self.fileManager = fileManager
        self.renameItem = renameItem
    }

    func transfer(from sourceURL: URL,
                  to destinationURL: URL,
                  operation: Operation,
                  session: SZOperationSession,
                  resolveConflict: (URL, URL) -> ConflictResolution) throws -> Outcome
    {
        try transferItem(from: sourceURL,
                         to: destinationURL,
                         operation: operation,
                         session: session,
                         resolveConflict: resolveConflict)
    }

    private func transferItem(from sourceURL: URL,
                              to destinationURL: URL,
                              operation: Operation,
                              session: SZOperationSession,
                              resolveConflict: (URL, URL) -> ConflictResolution) throws -> Outcome
    {
        if session.shouldCancel() {
            return .cancelled
        }

        let sourceItem = try requiredItem(at: sourceURL)
        guard let destinationItem = try item(at: destinationURL) else {
            return try transferToAbsentDestination(from: sourceURL,
                                                   sourceItem: sourceItem,
                                                   to: destinationURL,
                                                   operation: operation,
                                                   session: session,
                                                   resolveConflict: resolveConflict)
        }

        if sourceItem.identity == destinationItem.identity {
            return .completed
        }

        let sourceIsDirectory = sourceItem.kind == .directory
        let destinationIsDirectory = destinationItem.kind == .directory
        guard sourceIsDirectory == destinationIsDirectory else {
            throw TransferError.incompatibleItemKinds(source: sourceURL,
                                                      destination: destinationURL)
        }

        if sourceIsDirectory {
            return try mergeDirectory(from: sourceURL,
                                      to: destinationURL,
                                      operation: operation,
                                      session: session,
                                      resolveConflict: resolveConflict)
        }

        switch resolveConflict(sourceURL, destinationURL) {
        case .skip:
            return .incomplete
        case .cancel:
            return .cancelled
        case .overwrite:
            if session.shouldCancel() {
                return .cancelled
            }
            try unlinkItem(at: destinationURL)
            if session.shouldCancel() {
                return .cancelled
            }
            return try transferToAbsentDestination(from: sourceURL,
                                                   sourceItem: sourceItem,
                                                   to: destinationURL,
                                                   operation: operation,
                                                   session: session,
                                                   resolveConflict: resolveConflict)
        }
    }

    private func transferToAbsentDestination(from sourceURL: URL,
                                             sourceItem: Item,
                                             to destinationURL: URL,
                                             operation: Operation,
                                             session: SZOperationSession,
                                             resolveConflict: (URL, URL) -> ConflictResolution) throws -> Outcome
    {
        if session.shouldCancel() {
            return .cancelled
        }

        if operation == .move {
            var renameError = renameItem(sourceURL, destinationURL)
            if renameError == ENOTSUP {
                guard try item(at: destinationURL) == nil else {
                    throw posixError(EEXIST, path: destinationURL)
                }
                renameError = Self.renameNormally(sourceURL, destinationURL)
            }

            switch renameError {
            case nil:
                return .completed
            case EXDEV:
                break
            case let errorCode?:
                throw posixError(errorCode, path: destinationURL)
            }
        }

        return try copyItem(from: sourceURL,
                            sourceItem: sourceItem,
                            to: destinationURL,
                            removeSource: operation == .move,
                            session: session,
                            resolveConflict: resolveConflict)
    }

    private func copyItem(from sourceURL: URL,
                          sourceItem: Item,
                          to destinationURL: URL,
                          removeSource: Bool,
                          session: SZOperationSession,
                          resolveConflict: (URL, URL) -> ConflictResolution) throws -> Outcome
    {
        switch sourceItem.kind {
        case .regularFile, .symbolicLink:
            try copyLeaf(from: sourceURL,
                         expectedKind: sourceItem.kind,
                         to: destinationURL)
            if session.shouldCancel() {
                return .cancelled
            }
            if removeSource {
                try unlinkItem(at: sourceURL)
            }
            return .completed
        case .directory:
            return try copyDirectory(from: sourceURL,
                                     sourceItem: sourceItem,
                                     to: destinationURL,
                                     removeSource: removeSource,
                                     session: session,
                                     resolveConflict: resolveConflict)
        }
    }

    private func copyDirectory(from sourceURL: URL,
                               sourceItem: Item,
                               to destinationURL: URL,
                               removeSource: Bool,
                               session: SZOperationSession,
                               resolveConflict: (URL, URL) -> ConflictResolution) throws -> Outcome
    {
        try createDirectory(at: destinationURL)

        var operationError: Error?
        var outcome = Outcome.completed
        do {
            outcome = try transferDirectoryContents(from: sourceURL,
                                                    to: destinationURL,
                                                    operation: removeSource ? .move : .copy,
                                                    session: session,
                                                    resolveConflict: resolveConflict)
        } catch {
            operationError = error
        }

        do {
            try finalizeDirectoryMetadata(from: sourceURL,
                                          sourceStatus: sourceItem.status,
                                          to: destinationURL)
        } catch {
            if let operationError {
                throw TransferError.directoryFinalizationFailed(destination: destinationURL,
                                                                operationError: operationError,
                                                                metadataError: error)
            }
            throw error
        }

        if let operationError {
            throw operationError
        }

        if removeSource, outcome == .completed {
            if session.shouldCancel() {
                return .cancelled
            }
            try removeDirectory(at: sourceURL)
        }

        return outcome
    }

    private func mergeDirectory(from sourceURL: URL,
                                to destinationURL: URL,
                                operation: Operation,
                                session: SZOperationSession,
                                resolveConflict: (URL, URL) -> ConflictResolution) throws -> Outcome
    {
        let outcome = try transferDirectoryContents(from: sourceURL,
                                                    to: destinationURL,
                                                    operation: operation,
                                                    session: session,
                                                    resolveConflict: resolveConflict)
        if operation == .move, outcome == .completed {
            if session.shouldCancel() {
                return .cancelled
            }
            try removeDirectory(at: sourceURL)
        }
        return outcome
    }

    private func transferDirectoryContents(from sourceURL: URL,
                                           to destinationURL: URL,
                                           operation: Operation,
                                           session: SZOperationSession,
                                           resolveConflict: (URL, URL) -> ConflictResolution) throws -> Outcome
    {
        let childURLs = try fileManager.contentsOfDirectory(at: sourceURL,
                                                            includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var outcome = Outcome.completed

        for childURL in childURLs {
            if session.shouldCancel() {
                return .cancelled
            }

            session.reportCurrentFileName(childURL.lastPathComponent)
            let childDestinationURL = destinationURL.appendingPathComponent(childURL.lastPathComponent)
            let childOutcome = try transferItem(from: childURL,
                                                to: childDestinationURL,
                                                operation: operation,
                                                session: session,
                                                resolveConflict: resolveConflict)
            switch childOutcome {
            case .completed:
                break
            case .incomplete:
                outcome = .incomplete
            case .cancelled:
                return .cancelled
            }
        }

        return outcome
    }

    private func copyLeaf(from sourceURL: URL,
                          expectedKind: ItemKind,
                          to destinationURL: URL) throws
    {
        let flags = copyfile_flags_t(
            COPYFILE_ALL
                | COPYFILE_CLONE
                | COPYFILE_EXCL
                | COPYFILE_NOFOLLOW,
        )
        errno = 0
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return copyfile(sourcePath, destinationPath, nil, flags)
            }
        }
        let errorCode = errno
        guard result == 0 else {
            throw posixError(errorCode == 0 ? EIO : errorCode,
                             path: destinationURL)
        }
        guard try item(at: destinationURL)?.kind == expectedKind else {
            throw TransferError.copiedItemKindChanged(destinationURL)
        }
    }

    private func createDirectory(at url: URL) throws {
        errno = 0
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return mkdir(path, mode_t(S_IRWXU))
        }
        guard result == 0 else {
            throw posixError(errno == 0 ? EIO : errno, path: url)
        }
    }

    private func finalizeDirectoryMetadata(from sourceURL: URL,
                                           sourceStatus: stat,
                                           to destinationURL: URL) throws
    {
        let sourceDescriptor = try openDirectory(at: sourceURL)
        defer { close(sourceDescriptor) }
        let destinationDescriptor = try openDirectory(at: destinationURL)
        defer { close(destinationDescriptor) }

        errno = 0
        guard fcopyfile(sourceDescriptor,
                        destinationDescriptor,
                        nil,
                        copyfile_flags_t(COPYFILE_METADATA)) == 0
        else {
            throw posixError(errno == 0 ? EIO : errno,
                             path: destinationURL)
        }

        let timestamps = [sourceStatus.st_atimespec, sourceStatus.st_mtimespec]
        errno = 0
        let result = timestamps.withUnsafeBufferPointer { buffer in
            futimens(destinationDescriptor, buffer.baseAddress)
        }
        guard result == 0 else {
            throw posixError(errno == 0 ? EIO : errno,
                             path: destinationURL)
        }
    }

    private func openDirectory(at url: URL) throws -> Int32 {
        errno = 0
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw posixError(errno == 0 ? EIO : errno, path: url)
        }
        return descriptor
    }

    private func requiredItem(at url: URL) throws -> Item {
        guard let item = try item(at: url) else {
            throw posixError(ENOENT, path: url)
        }
        return item
    }

    private func item(at url: URL) throws -> Item? {
        var status = stat()
        errno = 0
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return lstat(path, &status)
        }
        guard result == 0 else {
            let errorCode = errno == 0 ? EIO : errno
            if errorCode == ENOENT || errorCode == ENOTDIR {
                return nil
            }
            throw posixError(errorCode, path: url)
        }

        let kind: ItemKind
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG):
            kind = .regularFile
        case mode_t(S_IFDIR):
            kind = .directory
        case mode_t(S_IFLNK):
            kind = .symbolicLink
        default:
            throw TransferError.unsupportedItem(url)
        }
        return Item(kind: kind, status: status)
    }

    private func unlinkItem(at url: URL) throws {
        errno = 0
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return unlink(path)
        }
        guard result == 0 else {
            throw posixError(errno == 0 ? EIO : errno, path: url)
        }
    }

    private func removeDirectory(at url: URL) throws {
        errno = 0
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return rmdir(path)
        }
        guard result == 0 else {
            throw posixError(errno == 0 ? EIO : errno, path: url)
        }
    }

    private static func renameExclusively(_ sourceURL: URL,
                                          _ destinationURL: URL) -> Int32?
    {
        errno = 0
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return renamex_np(sourcePath,
                                  destinationPath,
                                  UInt32(RENAME_EXCL))
            }
        }
        return result == 0 ? nil : (errno == 0 ? EIO : errno)
    }

    private static func renameNormally(_ sourceURL: URL,
                                       _ destinationURL: URL) -> Int32?
    {
        errno = 0
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return rename(sourcePath, destinationPath)
            }
        }
        return result == 0 ? nil : (errno == 0 ? EIO : errno)
    }

    private func posixError(_ code: Int32,
                            path: URL) -> NSError
    {
        NSError(domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSFilePathErrorKey: path.path])
    }
}
