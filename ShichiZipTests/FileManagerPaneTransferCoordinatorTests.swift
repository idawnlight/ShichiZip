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
                                                        cleanupDirectory: cleanupDirectory)

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
                                                        cleanupDirectory: cleanupDirectory)

        XCTAssertFalse(didBegin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanupDirectory.path))
        XCTAssertEqual(host.requestedSubdir, "nested")
        XCTAssertEqual(host.readOnlyActions, [SZL10n.string("app.fileManager.action.addingFilesToArchive")])
    }
}

@MainActor
private final class TransferHostProbe: FileManagerPaneTransferHost {
    let transferLocation = FileManagerPaneTransferLocation(isVirtualLocation: true,
                                                           currentDirectoryURL: URL(fileURLWithPath: "/"),
                                                           presentationWindow: nil)

    var requestedSubdir: String?
    var readOnlyActions: [String] = []

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

    func transferArchiveMutationTarget(for _: SZArchive, subdir: String) -> FileManagerPaneArchiveTransferTarget? {
        requestedSubdir = subdir
        return nil
    }

    func transferLeasedArchiveMutationTarget(for _: SZArchive, subdir: String) -> FileManagerLeasedArchiveMutationTarget? {
        requestedSubdir = subdir
        return nil
    }

    func transferDidMutateArchive(targetSubdir _: String?,
                                  selectingPaths _: [String],
                                  reopenBeforeListing _: Bool)
    {}

    func transferShowReadOnlyArchiveMutationAlert(action: String) {
        readOnlyActions.append(action)
    }

    func transferShowError(_: Error) {}
}
