import AppKit
import Darwin
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileSystemTransferTests: XCTestCase {
    func testCopyRecursivelyPreservesHierarchySymlinksAndDirectoryMode() throws {
        let tempRoot = try makeTemporaryDirectory(named: "filesystem-transfer-recursive-copy")
        let sourceURL = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let nestedDirectoryURL = sourceURL.appendingPathComponent("Nested", isDirectory: true)
        let sourceFileURL = nestedDirectoryURL.appendingPathComponent("payload.txt")
        let sourceLinkURL = sourceURL.appendingPathComponent("payload-link")
        let destinationDirectoryURL = tempRoot.appendingPathComponent("Destination", isDirectory: true)

        try FileManager.default.createDirectory(at: nestedDirectoryURL,
                                                withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: sourceFileURL)
        try FileManager.default.createSymbolicLink(atPath: sourceLinkURL.path,
                                                   withDestinationPath: "Nested/payload.txt")
        XCTAssertEqual(chmod(sourceURL.path, mode_t(0o750)), 0)
        try FileManager.default.createDirectory(at: destinationDirectoryURL,
                                                withIntermediateDirectories: true)

        try FileOperationFileSystemTransfer.perform([sourceURL],
                                                    to: destinationDirectoryURL,
                                                    operation: .copy,
                                                    session: SZOperationSession())

        let copiedRootURL = destinationDirectoryURL.appendingPathComponent("Source", isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: copiedRootURL.appendingPathComponent("Nested/payload.txt")),
                       Data("payload".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: copiedRootURL.appendingPathComponent("payload-link").path,
        ), "Nested/payload.txt")
        XCTAssertEqual(try permissions(at: copiedRootURL), mode_t(0o750))
    }

    func testCopyMergesDirectoriesAndPromptsOnlyForConflictingLeaves() throws {
        let tempRoot = try makeTemporaryDirectory(named: "filesystem-transfer-directory-merge")
        let sourceURL = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let destinationDirectoryURL = tempRoot.appendingPathComponent("Destination", isDirectory: true)
        let destinationURL = destinationDirectoryURL.appendingPathComponent("Source", isDirectory: true)

        try FileManager.default.createDirectory(at: sourceURL,
                                                withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: sourceURL.appendingPathComponent("conflict.txt"))
        try Data("new".utf8).write(to: sourceURL.appendingPathComponent("new.txt"))
        try FileManager.default.createDirectory(at: destinationURL,
                                                withIntermediateDirectories: true)
        try Data("original".utf8).write(to: destinationURL.appendingPathComponent("conflict.txt"))
        try Data("keep".utf8).write(to: destinationURL.appendingPathComponent("keep.txt"))

        let session = SZOperationSession()
        var promptCount = 0
        session.choiceRequestHandler = { _, _, _, _ in
            promptCount += 1
            return 0
        }

        try FileOperationFileSystemTransfer.perform([sourceURL],
                                                    to: destinationDirectoryURL,
                                                    operation: .copy,
                                                    session: session)

        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(try Data(contentsOf: destinationURL.appendingPathComponent("conflict.txt")),
                       Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: destinationURL.appendingPathComponent("new.txt")),
                       Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: destinationURL.appendingPathComponent("keep.txt")),
                       Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testMoveMergesDirectoriesAndLeavesSkippedChildrenAtSource() throws {
        let tempRoot = try makeTemporaryDirectory(named: "filesystem-transfer-directory-move-merge")
        let sourceURL = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let destinationDirectoryURL = tempRoot.appendingPathComponent("Destination", isDirectory: true)
        let destinationURL = destinationDirectoryURL.appendingPathComponent("Source", isDirectory: true)

        try FileManager.default.createDirectory(at: sourceURL,
                                                withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: sourceURL.appendingPathComponent("conflict.txt"))
        try Data("moved".utf8).write(to: sourceURL.appendingPathComponent("moved.txt"))
        try FileManager.default.createDirectory(at: destinationURL,
                                                withIntermediateDirectories: true)
        try Data("original".utf8).write(to: destinationURL.appendingPathComponent("conflict.txt"))
        try Data("keep".utf8).write(to: destinationURL.appendingPathComponent("keep.txt"))

        let session = SZOperationSession()
        session.choiceRequestHandler = { _, _, _, _ in 2 }

        try FileOperationFileSystemTransfer.perform([sourceURL],
                                                    to: destinationDirectoryURL,
                                                    operation: .move,
                                                    session: session)

        XCTAssertEqual(try Data(contentsOf: destinationURL.appendingPathComponent("conflict.txt")),
                       Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: destinationURL.appendingPathComponent("moved.txt")),
                       Data("moved".utf8))
        XCTAssertEqual(try Data(contentsOf: destinationURL.appendingPathComponent("keep.txt")),
                       Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: sourceURL.appendingPathComponent("conflict.txt")),
                       Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.appendingPathComponent("moved.txt").path))
    }

    func testOverwriteMoveUsesDirectRename() throws {
        let tempRoot = try makeTemporaryDirectory(named: "filesystem-transfer-overwrite-move")
        let sourceURL = tempRoot.appendingPathComponent("payload.txt")
        let destinationDirectoryURL = tempRoot.appendingPathComponent("Destination", isDirectory: true)
        let destinationURL = destinationDirectoryURL.appendingPathComponent("payload.txt")

        try Data("replacement".utf8).write(to: sourceURL)
        try FileManager.default.createDirectory(at: destinationDirectoryURL,
                                                withIntermediateDirectories: true)
        try Data("original".utf8).write(to: destinationURL)
        let sourceInode = try inode(at: sourceURL)
        let originalDestinationInode = try inode(at: destinationURL)

        let session = SZOperationSession()
        session.choiceRequestHandler = { _, _, _, _ in 0 }
        try FileOperationFileSystemTransfer.perform([sourceURL],
                                                    to: destinationDirectoryURL,
                                                    operation: .move,
                                                    session: session)

        XCTAssertEqual(try inode(at: destinationURL), sourceInode)
        XCTAssertNotEqual(try inode(at: destinationURL), originalDestinationInode)
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testMoveStillUsesRenameWhenExclusiveRenameIsUnsupported() throws {
        let tempRoot = try makeTemporaryDirectory(named: "filesystem-transfer-plain-rename")
        let sourceURL = tempRoot.appendingPathComponent("payload.txt")
        let destinationURL = tempRoot.appendingPathComponent("moved.txt")
        try Data("payload".utf8).write(to: sourceURL)
        let sourceInode = try inode(at: sourceURL)

        let engine = FileSystemTransferEngine(renameItem: { _, _ in ENOTSUP })
        let outcome = try engine.transfer(from: sourceURL,
                                          to: destinationURL,
                                          operation: .move,
                                          session: SZOperationSession())
        { _, _ in
            XCTFail("An absent destination must not request a conflict decision")
            return .cancel
        }

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(try inode(at: destinationURL), sourceInode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testOverwriteCopyDoesNotRestoreDeletedDestinationWhenSourceDisappears() throws {
        let tempRoot = try makeTemporaryDirectory(named: "filesystem-transfer-destructive-overwrite")
        let sourceURL = tempRoot.appendingPathComponent("payload.txt")
        let destinationDirectoryURL = tempRoot.appendingPathComponent("Destination", isDirectory: true)
        let destinationURL = destinationDirectoryURL.appendingPathComponent("payload.txt")

        try Data("replacement".utf8).write(to: sourceURL)
        try FileManager.default.createDirectory(at: destinationDirectoryURL,
                                                withIntermediateDirectories: true)
        try Data("original".utf8).write(to: destinationURL)

        let session = SZOperationSession()
        session.choiceRequestHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: sourceURL)
            return 0
        }

        XCTAssertThrowsError(
            try FileOperationFileSystemTransfer.perform([sourceURL],
                                                        to: destinationDirectoryURL,
                                                        operation: .copy,
                                                        session: session),
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testCopyFailureKeepsCompletedChildrenAndPartialDirectory() throws {
        let tempRoot = try makeTemporaryDirectory(named: "filesystem-transfer-partial-copy")
        let sourceURL = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let destinationDirectoryURL = tempRoot.appendingPathComponent("Destination", isDirectory: true)
        let destinationURL = destinationDirectoryURL.appendingPathComponent("Source", isDirectory: true)

        try FileManager.default.createDirectory(at: sourceURL,
                                                withIntermediateDirectories: true)
        try Data("stable".utf8).write(to: sourceURL.appendingPathComponent("a-stable.txt"))
        XCTAssertEqual(mkfifo(sourceURL.appendingPathComponent("z-unsupported-fifo").path,
                              mode_t(0o600)), 0)
        try FileManager.default.createDirectory(at: destinationDirectoryURL,
                                                withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try FileOperationFileSystemTransfer.perform([sourceURL],
                                                        to: destinationDirectoryURL,
                                                        operation: .copy,
                                                        session: SZOperationSession()),
        )
        XCTAssertEqual(try Data(contentsOf: destinationURL.appendingPathComponent("a-stable.txt")),
                       Data("stable".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.appendingPathComponent("a-stable.txt").path))
    }

    func testFallbackMoveDeletesOnlySuccessfullyCopiedChildren() throws {
        let tempRoot = try makeTemporaryDirectory(named: "filesystem-transfer-partial-move")
        let sourceURL = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let destinationURL = tempRoot.appendingPathComponent("Destination", isDirectory: true)

        try FileManager.default.createDirectory(at: sourceURL,
                                                withIntermediateDirectories: true)
        try Data("stable".utf8).write(to: sourceURL.appendingPathComponent("a-stable.txt"))
        let unsupportedURL = sourceURL.appendingPathComponent("z-unsupported-fifo")
        XCTAssertEqual(mkfifo(unsupportedURL.path, mode_t(0o600)), 0)

        let engine = FileSystemTransferEngine(renameItem: { _, _ in EXDEV })
        XCTAssertThrowsError(
            try engine.transfer(from: sourceURL,
                                to: destinationURL,
                                operation: .move,
                                session: SZOperationSession())
            { _, _ in
                XCTFail("An absent destination must not request a conflict decision")
                return .cancel
            },
        )

        XCTAssertEqual(try Data(contentsOf: destinationURL.appendingPathComponent("a-stable.txt")),
                       Data("stable".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.appendingPathComponent("a-stable.txt").path))
        XCTAssertNotNil(try itemStatus(at: unsupportedURL))
        XCTAssertNotNil(try itemStatus(at: sourceURL))
    }

    func testCancellationAfterFallbackCopyKeepsSourceAndDestination() throws {
        let tempRoot = try makeTemporaryDirectory(named: "filesystem-transfer-cancelled-move")
        let sourceURL = tempRoot.appendingPathComponent("payload.txt")
        let destinationURL = tempRoot.appendingPathComponent("moved.txt")
        try Data("payload".utf8).write(to: sourceURL)

        let session = CancelWhenItemExistsSession(itemURL: destinationURL)
        let engine = FileSystemTransferEngine(renameItem: { _, _ in EXDEV })
        let outcome = try engine.transfer(from: sourceURL,
                                          to: destinationURL,
                                          operation: .move,
                                          session: session)
        { _, _ in
            XCTFail("An absent destination must not request a conflict decision")
            return .cancel
        }

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data("payload".utf8))
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("payload".utf8))
    }

    func testDirectoryAndNonDirectoryConflictDoesNotDeleteEitherItem() throws {
        let tempRoot = try makeTemporaryDirectory(named: "filesystem-transfer-kind-conflict")
        let sourceURL = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let destinationDirectoryURL = tempRoot.appendingPathComponent("Destination", isDirectory: true)
        let destinationURL = destinationDirectoryURL.appendingPathComponent("Source")

        try FileManager.default.createDirectory(at: sourceURL,
                                                withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL.appendingPathComponent("payload.txt"))
        try FileManager.default.createDirectory(at: destinationDirectoryURL,
                                                withIntermediateDirectories: true)
        try Data("destination".utf8).write(to: destinationURL)

        let session = SZOperationSession()
        session.choiceRequestHandler = { _, _, _, _ in
            XCTFail("Incompatible item kinds must not request overwrite")
            return 0
        }

        XCTAssertThrowsError(
            try FileOperationFileSystemTransfer.perform([sourceURL],
                                                        to: destinationDirectoryURL,
                                                        operation: .copy,
                                                        session: session),
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL.appendingPathComponent("payload.txt")),
                       Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("destination".utf8))
    }

    func testMoveTreatsAliasedPathToDestinationAsSameItem() throws {
        let tempRoot = try makeTemporaryDirectory(named: "filesystem-transfer-same-item-alias")
        let actualDirectoryURL = tempRoot.appendingPathComponent("Actual", isDirectory: true)
        let aliasDirectoryURL = tempRoot.appendingPathComponent("Alias", isDirectory: true)
        let destinationURL = actualDirectoryURL.appendingPathComponent("payload.txt")
        let aliasedSourceURL = aliasDirectoryURL.appendingPathComponent("payload.txt")

        try FileManager.default.createDirectory(at: actualDirectoryURL,
                                                withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: destinationURL)
        try FileManager.default.createSymbolicLink(atPath: aliasDirectoryURL.path,
                                                   withDestinationPath: actualDirectoryURL.path)

        try FileOperationFileSystemTransfer.perform([aliasedSourceURL],
                                                    to: actualDirectoryURL,
                                                    operation: .move,
                                                    session: SZOperationSession())

        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("payload".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aliasedSourceURL.path))
    }

    private func permissions(at url: URL) throws -> mode_t {
        try XCTUnwrap(itemStatus(at: url)).st_mode & mode_t(0o777)
    }

    private func inode(at url: URL) throws -> ino_t {
        try XCTUnwrap(itemStatus(at: url)).st_ino
    }

    private func itemStatus(at url: URL) throws -> stat? {
        var status = stat()
        errno = 0
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return lstat(path, &status)
        }
        if result == 0 {
            return status
        }
        if errno == ENOENT {
            return nil
        }
        throw NSError(domain: NSPOSIXErrorDomain,
                      code: Int(errno),
                      userInfo: [NSFilePathErrorKey: url.path])
    }
}

private final class CancelWhenItemExistsSession: SZOperationSession, @unchecked Sendable {
    private let itemURL: URL

    init(itemURL: URL) {
        self.itemURL = itemURL
        super.init()
    }

    override func shouldCancel() -> Bool {
        FileManager.default.fileExists(atPath: itemURL.path)
    }
}
