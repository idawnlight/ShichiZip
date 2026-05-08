import AppKit
import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerArchiveItemWorkflowServiceTests: XCTestCase {
    func testWorkflowContextBuildsArchiveItemDisplayPath() {
        let item = makeArchiveItem(index: 0,
                                   path: "folder/payload.txt")
        let context = FileManagerArchiveItemWorkflowContext(archive: SZArchive(),
                                                            hostDirectory: URL(fileURLWithPath: "/tmp"),
                                                            displayPathPrefix: "/tmp/source.7z",
                                                            quarantineSourceArchivePath: nil,
                                                            mutationTarget: nil)

        XCTAssertEqual(context.displayPath(for: item), "/tmp/source.7z/folder/payload.txt")
    }

    func testPrepareExternalArchiveItemOpenStagesSelectedFile() throws {
        let tempRoot = try makeTemporaryDirectory(named: "external-open")
        let payloadURL = tempRoot.appendingPathComponent("payload.txt")
        let archiveURL = tempRoot.appendingPathComponent("payload.7z")
        try "payload".write(to: payloadURL, atomically: true, encoding: .utf8)
        try createArchive(at: archiveURL, from: [payloadURL])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        defer { archive.close() }

        let item = try XCTUnwrap(archive.entries().map(ArchiveItem.init(from:)).first { !$0.isDirectory })
        let service = FileManagerArchiveItemWorkflowService(quarantineInheritanceEnabled: { false })
        let context = FileManagerArchiveItemWorkflowContext(archive: archive,
                                                            hostDirectory: tempRoot,
                                                            displayPathPrefix: archiveURL.path,
                                                            quarantineSourceArchivePath: nil,
                                                            mutationTarget: nil)

        let preparedOpen = try service.prepareExternalArchiveItemOpen(for: item,
                                                                      context: context,
                                                                      strategy: .forceExternal,
                                                                      session: SZOperationSession())
        defer { service.cleanup(preparedOpen.temporaryDirectory) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedOpen.stagedFileURL.path))
        XCTAssertEqual(try String(contentsOf: preparedOpen.stagedFileURL, encoding: .utf8), "payload")
    }

    func testPrepareExternalArchiveItemOpenRejectsInternalStrategy() throws {
        let tempRoot = try makeTemporaryDirectory(named: "external-open-internal-strategy")
        let payloadURL = tempRoot.appendingPathComponent("payload.txt")
        let archiveURL = tempRoot.appendingPathComponent("payload.7z")
        try "payload".write(to: payloadURL, atomically: true, encoding: .utf8)
        try createArchive(at: archiveURL, from: [payloadURL])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        defer { archive.close() }

        let item = try XCTUnwrap(archive.entries().map(ArchiveItem.init(from:)).first { !$0.isDirectory })
        let service = FileManagerArchiveItemWorkflowService(quarantineInheritanceEnabled: { false })
        let context = FileManagerArchiveItemWorkflowContext(archive: archive,
                                                            hostDirectory: tempRoot,
                                                            displayPathPrefix: archiveURL.path,
                                                            quarantineSourceArchivePath: nil,
                                                            mutationTarget: nil)

        XCTAssertThrowsError(try service.prepareExternalArchiveItemOpen(for: item,
                                                                        context: context,
                                                                        strategy: .forceInternal(.defaultBehavior),
                                                                        session: SZOperationSession()))
    }

    private func makeArchiveItem(index: Int,
                                 path: String,
                                 isDirectory: Bool = false) -> ArchiveItem
    {
        ArchiveItem(index: index,
                    path: path,
                    name: path.split(separator: "/").last.map(String.init) ?? path,
                    size: 0,
                    packedSize: 0,
                    modifiedDate: nil,
                    createdDate: nil,
                    accessedDate: nil,
                    crc: 0,
                    isDirectory: isDirectory,
                    isEncrypted: false,
                    isAnti: false,
                    method: "",
                    attributes: 0,
                    position: 0,
                    block: 0,
                    comment: "")
    }

    func testScheduledExternalCleanupSurvivesPaneCleanupUntilApplicationTerminates() throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "external-open-scheduled-cleanup")
        let stagedFileURL = temporaryDirectory.appendingPathComponent("payload.txt")
        try "payload".write(to: stagedFileURL, atomically: true, encoding: .utf8)

        let notificationCenter = NotificationCenter()
        let externalCleanup = FileManagerExternalTemporaryDirectoryCleanup(notificationCenter: notificationCenter)
        let service = FileManagerArchiveItemWorkflowService(externalTemporaryDirectoryCleanup: externalCleanup,
                                                            quarantineInheritanceEnabled: { false })
        service.register(temporaryDirectory)

        // Successful external open transfers ownership away from pane cleanup.
        service.scheduleCleanup(temporaryDirectory, when: NSRunningApplication.current)

        // Simulates pane teardown while the external app still has the staged file open.
        service.cleanupAll()

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFileURL.path))

        notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification,
                                object: nil,
                                userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])

        // The long-lived external cleanup owner should remove it after app exit.
        let deadline = Date().addingTimeInterval(1)
        while FileManager.default.fileExists(atPath: temporaryDirectory.path), Date() < deadline {
            RunLoop.current.run(mode: .default,
                                before: Date().addingTimeInterval(0.01))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }
}
