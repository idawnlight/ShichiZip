import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerArchiveItemWorkflowServiceTests: XCTestCase {
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
}
