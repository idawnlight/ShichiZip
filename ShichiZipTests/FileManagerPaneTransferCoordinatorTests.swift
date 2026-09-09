import AppKit
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileManagerPaneTransferCoordinatorTests: XCTestCase {
    func testBeginArchiveTransferRemovesCleanupDirectoryForEmptyURLs() throws {
        let coordinator = FileManagerPaneTransferCoordinator()
        let host = TransferHostProbe()
        let cleanupDirectory = try makeTemporaryDirectory(named: "empty-archive-transfer-cleanup")

        let didBegin = coordinator.beginArchiveTransfer([],
                                                        to: (archive: SZArchive(), subdir: ""),
                                                        operation: .copy,
                                                        sourceHost: nil,
                                                        host: host,
                                                        cleanupDirectory: cleanupDirectory,
                                                        onSuccess: { XCTFail("An empty transfer must not report success.") })

        XCTAssertFalse(didBegin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanupDirectory.path))
        XCTAssertNil(host.requestedSubdir)
        XCTAssertTrue(host.readOnlyActions.isEmpty)
    }

    func testBeginArchiveTransferRemovesCleanupAndShowsAlertWhenTargetIsUnavailable() throws {
        let coordinator = FileManagerPaneTransferCoordinator()
        let host = TransferHostProbe()
        let tempRoot = try makeTemporaryDirectory(named: "unavailable-archive-transfer")
        let sourceURL = tempRoot.appendingPathComponent("payload.txt")
        let cleanupDirectory = try makeTemporaryDirectory(named: "unavailable-archive-transfer-cleanup")
        try Data("payload".utf8).write(to: sourceURL)

        let didBegin = coordinator.beginArchiveTransfer([sourceURL],
                                                        to: (archive: SZArchive(), subdir: "nested"),
                                                        operation: .copy,
                                                        sourceHost: nil,
                                                        host: host,
                                                        cleanupDirectory: cleanupDirectory,
                                                        onSuccess: { XCTFail("An unavailable target must not report success.") })

        XCTAssertFalse(didBegin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanupDirectory.path))
        XCTAssertEqual(host.requestedSubdir, "nested")
        XCTAssertEqual(host.readOnlyActions, [SZL10n.string("app.fileManager.action.addingFilesToArchive")])
    }

    func testArchiveTransferReportsSuccessAfterCopyAndMove() async throws {
        for operation: NSDragOperation in [.copy, .move] {
            let tempRoot = try makeTemporaryDirectory(named: "archive-transfer-success")
            let initialDirectory = tempRoot.appendingPathComponent("nested", isDirectory: true)
            let initialURL = initialDirectory.appendingPathComponent("initial.txt")
            let sourceURL = tempRoot.appendingPathComponent("payload.txt")
            let archiveURL = tempRoot.appendingPathComponent("destination.7z")
            try FileManager.default.createDirectory(at: initialDirectory, withIntermediateDirectories: false)
            try Data("initial".utf8).write(to: initialURL)
            try Data("payload".utf8).write(to: sourceURL)
            try createArchive(at: archiveURL, from: [initialDirectory])

            let archive = SZArchive()
            try archive.open(atPath: archiveURL.path, session: nil)
            defer { archive.close() }

            let host = TransferHostProbe()
            host.archiveTarget = FileManagerPaneArchiveTransferTarget(archive: archive,
                                                                      subdir: "nested",
                                                                      archiveURL: archiveURL)
            let completed = expectation(description: "Transfer completed")
            host.onError = { error in
                XCTFail("Transfer failed: \(error)")
                completed.fulfill()
            }
            let coordinator = FileManagerPaneTransferCoordinator()
            let didBegin = coordinator.beginArchiveTransfer([sourceURL],
                                                            to: (archive: archive, subdir: "nested"),
                                                            operation: operation,
                                                            sourceHost: nil,
                                                            host: host,
                                                            onSuccess: {
                                                                XCTAssertEqual(host.mutatedSelectionPaths, ["nested/payload.txt"])
                                                                completed.fulfill()
                                                            })

            XCTAssertTrue(didBegin)
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertTrue(host.errors.isEmpty)
            XCTAssertTrue(archive.entries().contains { $0.path == "nested/payload.txt" })
            XCTAssertEqual(FileManager.default.fileExists(atPath: sourceURL.path), operation != .move)
        }
    }

    func testArchiveTransferDoesNotReportSuccessWhenUpdateFails() async throws {
        let tempRoot = try makeTemporaryDirectory(named: "archive-transfer-failure")
        let sourceURL = tempRoot.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: sourceURL)
        let archive = SZArchive()
        let host = TransferHostProbe()
        host.archiveTarget = FileManagerPaneArchiveTransferTarget(archive: archive,
                                                                  subdir: "",
                                                                  archiveURL: tempRoot.appendingPathComponent("closed.7z"))
        let failed = expectation(description: "Transfer failed")
        host.onError = { _ in failed.fulfill() }
        let coordinator = FileManagerPaneTransferCoordinator()

        XCTAssertTrue(coordinator.beginArchiveTransfer([sourceURL],
                                                       to: (archive: archive, subdir: ""),
                                                       operation: .copy,
                                                       sourceHost: nil,
                                                       host: host,
                                                       onSuccess: { XCTFail("A failed transfer must not report success.") }))

        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(host.errors.count, 1)
        XCTAssertTrue(host.mutatedSelectionPaths.isEmpty)
    }
}

@MainActor
private final class TransferHostProbe: FileManagerPaneTransferHost {
    let transferLocation = FileManagerPaneTransferLocation(isVirtualLocation: true,
                                                           currentDirectoryURL: URL(fileURLWithPath: "/"),
                                                           presentationWindow: nil)

    var requestedSubdir: String?
    var readOnlyActions: [String] = []
    var archiveTarget: FileManagerPaneArchiveTransferTarget?
    var mutatedSelectionPaths: [String] = []
    var errors: [Error] = []
    var onError: ((Error) -> Void)?
    private let operationGate = FileManagerArchiveOperationGate()

    func transferRefresh() {}

    func transferItem(at _: Int) -> FileManagerPaneItem? {
        nil
    }

    func transferArchiveDragContext(acquireLease _: Bool) -> FileManagerPaneArchiveDragContext? {
        nil
    }

    func transferCurrentArchiveMutationTarget() -> FileManagerPaneArchiveTransferTarget? {
        nil
    }

    func transferArchiveMutationTarget(for archive: SZArchive, subdir: String) -> FileManagerPaneArchiveTransferTarget? {
        requestedSubdir = subdir
        guard let archiveTarget, archiveTarget.archive === archive else { return nil }
        return archiveTarget
    }

    func transferLeasedArchiveMutationTarget(for archive: SZArchive, subdir: String) -> FileManagerLeasedArchiveMutationTarget? {
        requestedSubdir = subdir
        guard archiveTarget?.archive === archive,
              let lease = operationGate.acquireLease()
        else { return nil }
        return FileManagerLeasedArchiveMutationTarget(archive: archive, subdir: subdir, lease: lease)
    }

    func transferDidMutateArchive(targetSubdir _: String?,
                                  selectingPaths paths: [String],
                                  reopenBeforeListing _: Bool)
    {
        mutatedSelectionPaths = paths
    }

    func transferShowReadOnlyArchiveMutationAlert(action: String) {
        readOnlyActions.append(action)
    }

    func transferShowError(_ error: Error) {
        errors.append(error)
        onError?(error)
    }
}
