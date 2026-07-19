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

    func testWorkflowContextDistinguishesDuplicateNestedArchiveEntries() throws {
        let snapshotIdentifier = UUID()
        let topLevelArchiveURL = URL(fileURLWithPath: "/tmp/source.7z")
        let context = FileManagerArchiveItemWorkflowContext(
            archive: SZArchive(),
            hostDirectory: URL(fileURLWithPath: "/tmp"),
            displayPathPrefix: topLevelArchiveURL.path,
            quarantineSourceArchivePath: nil,
            mutationTarget: nil,
            topLevelArchiveURL: topLevelArchiveURL,
        )
        let first = makeArchiveItem(
            index: 4,
            path: "nested.7z",
            reference: SZArchiveItemReference(
                archiveIndex: 4,
                path: "nested.7z",
                isDirectory: false,
                snapshotIdentifier: snapshotIdentifier,
            ),
        )
        let second = makeArchiveItem(
            index: 9,
            path: "nested.7z",
            reference: SZArchiveItemReference(
                archiveIndex: 9,
                path: "nested.7z",
                isDirectory: false,
                snapshotIdentifier: snapshotIdentifier,
            ),
        )

        let firstIdentity = try XCTUnwrap(context.nestedIdentity(for: first))
        let secondIdentity = try XCTUnwrap(context.nestedIdentity(for: second))

        XCTAssertNotEqual(firstIdentity, secondIdentity)
        XCTAssertEqual(firstIdentity.entryLineage.map(\.archiveIndex), [4])
        XCTAssertEqual(secondIdentity.entryLineage.map(\.archiveIndex), [9])
    }

    func testWorkflowContextAppendsNestedArchiveLineage() throws {
        let topLevelArchiveURL = URL(fileURLWithPath: "/tmp/source.7z")
        let parentIdentity = FileManagerNestedArchiveIdentity(
            topLevelArchiveURL: topLevelArchiveURL,
            entryLineage: [
                FileManagerNestedArchiveIdentity.Entry(archiveIndex: 4,
                                                       path: "outer.7z",
                                                       isDirectory: false),
            ],
            displayPath: "/tmp/source.7z/outer.7z",
        )
        let context = FileManagerArchiveItemWorkflowContext(
            archive: SZArchive(),
            hostDirectory: URL(fileURLWithPath: "/tmp"),
            displayPathPrefix: parentIdentity.displayPath,
            quarantineSourceArchivePath: nil,
            mutationTarget: nil,
            parentNestedIdentity: parentIdentity,
        )
        let child = makeArchiveItem(
            index: 2,
            path: "inner.7z",
            reference: SZArchiveItemReference(
                archiveIndex: 2,
                path: "inner.7z",
                isDirectory: false,
                snapshotIdentifier: UUID(),
            ),
        )

        let childIdentity = try XCTUnwrap(context.nestedIdentity(for: child))

        XCTAssertEqual(childIdentity.topLevelArchiveURL, topLevelArchiveURL)
        XCTAssertEqual(childIdentity.entryLineage.map(\.archiveIndex), [4, 2])
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

    func testStageQuickLookItemsSeparatesDuplicateArchivePaths() throws {
        let tempRoot = try makeTemporaryDirectory(named: "quick-look-duplicates")
        let archiveURL = tempRoot.appendingPathComponent("duplicates.tar")
        try createTarFixture(
            at: archiveURL,
            entries: [
                (path: "duplicate.txt", contents: "first"),
                (path: "duplicate.txt", contents: "second"),
            ],
        )

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let items = archive.entries()
            .map(ArchiveItem.init(from:))
            .filter { $0.path == "duplicate.txt" }
            .sorted { $0.index < $1.index }
        XCTAssertEqual(items.count, 2)

        let service = FileManagerArchiveItemWorkflowService(quarantineInheritanceEnabled: { false })
        let context = FileManagerArchiveItemWorkflowContext(
            archive: archive,
            hostDirectory: tempRoot,
            displayPathPrefix: archiveURL.path,
            quarantineSourceArchivePath: nil,
            mutationTarget: nil,
        )
        let preview = try service.stageQuickLookItems(items,
                                                      context: context,
                                                      session: nil)
        defer { service.cleanup(preview.temporaryDirectory) }

        XCTAssertEqual(Set(preview.fileURLs.map(\.standardizedFileURL.path)).count, 2)
        XCTAssertEqual(try preview.fileURLs.map {
            try String(contentsOf: $0, encoding: .utf8)
        }, ["first", "second"])
    }

    func testStageQuickLookItemsSeparatesCaseEquivalentArchivePaths() throws {
        let tempRoot = try makeTemporaryDirectory(named: "quick-look-case-collisions")
        let archiveURL = tempRoot.appendingPathComponent("case-collisions.tar")
        try createTarFixture(
            at: archiveURL,
            entries: [
                (path: "Case.txt", contents: "uppercase"),
                (path: "case.txt", contents: "lowercase"),
            ],
        )

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }
        let items = archive.entries()
            .map(ArchiveItem.init(from:))
            .filter { $0.path == "Case.txt" || $0.path == "case.txt" }
            .sorted { $0.index < $1.index }
        XCTAssertEqual(items.count, 2)

        let service = FileManagerArchiveItemWorkflowService(quarantineInheritanceEnabled: { false })
        let context = FileManagerArchiveItemWorkflowContext(
            archive: archive,
            hostDirectory: tempRoot,
            displayPathPrefix: archiveURL.path,
            quarantineSourceArchivePath: nil,
            mutationTarget: nil,
        )
        let preview = try service.stageQuickLookItems(items,
                                                      context: context,
                                                      session: nil)
        defer { service.cleanup(preview.temporaryDirectory) }

        XCTAssertEqual(try preview.fileURLs.map {
            try String(contentsOf: $0, encoding: .utf8)
        }, ["uppercase", "lowercase"])
    }

    func testStageQuickLookItemsKeepsInternalDirectoriesSeparateFromArchivePaths() throws {
        let tempRoot = try makeTemporaryDirectory(named: "quick-look-internal-paths")
        let archiveURL = tempRoot.appendingPathComponent("internal-paths.tar")
        try createTarFixture(
            at: archiveURL,
            entries: [
                (path: "duplicate.txt", contents: "first"),
                (path: "duplicate.txt", contents: "second"),
                (path: "occurrence-0", contents: "ordinary"),
            ],
        )

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }
        let items = archive.entries()
            .map(ArchiveItem.init(from:))
            .filter { $0.path == "duplicate.txt" || $0.path == "occurrence-0" }
            .sorted { $0.index < $1.index }
        XCTAssertEqual(items.count, 3)

        let service = FileManagerArchiveItemWorkflowService(quarantineInheritanceEnabled: { false })
        let context = FileManagerArchiveItemWorkflowContext(
            archive: archive,
            hostDirectory: tempRoot,
            displayPathPrefix: archiveURL.path,
            quarantineSourceArchivePath: nil,
            mutationTarget: nil,
        )
        let preview = try service.stageQuickLookItems(items,
                                                      context: context,
                                                      session: nil)
        defer { service.cleanup(preview.temporaryDirectory) }

        XCTAssertEqual(try preview.fileURLs.map {
            try String(contentsOf: $0, encoding: .utf8)
        }, ["first", "second", "ordinary"])
    }

    func testWritePromiseForDirectoryPublishesPromisedDestinationName() throws {
        let tempRoot = try makeTemporaryDirectory(named: "promise-directory-sidecar")
        let archiveURL = try makeBundleArchive(named: "Payload.app",
                                               in: tempRoot)
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        defer { archive.close() }

        let rootItem = try XCTUnwrap(archive.entries()
            .map(ArchiveItem.init(from:))
            .first { $0.isDirectory && $0.pathParts == ["Payload.app"] })
        let service = FileManagerArchiveItemWorkflowService(quarantineInheritanceEnabled: { false })
        let context = workflowContext(archive: archive,
                                      archiveURL: archiveURL,
                                      hostDirectory: tempRoot)
        let dropRoot = tempRoot.appendingPathComponent("drop", isDirectory: true)
        try FileManager.default.createDirectory(at: dropRoot,
                                                withIntermediateDirectories: true)
        let destinationURL = dropRoot.appendingPathComponent("Renamed.app", isDirectory: true)

        try service.writePromise(for: rootItem,
                                 context: context,
                                 to: destinationURL,
                                 session: SZOperationSession())

        XCTAssertEqual(try String(contentsOf: destinationURL.appendingPathComponent("Contents/payload.txt"),
                                  encoding: .utf8),
                       "payload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropRoot.appendingPathComponent("Payload.app").path))
        XCTAssertTrue(hiddenSidecarDirectories(in: dropRoot).isEmpty)
    }

    func testWritePromiseForDirectoryPublishesPartialResultWhenExtractionFails() throws {
        let tempRoot = try makeTemporaryDirectory(named: "promise-directory-sidecar-partial")
        let bundleName = "Payload.app"
        let bundleRoot = tempRoot.appendingPathComponent(bundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot,
                                                withIntermediateDirectories: true)
        try "payload".write(to: bundleRoot.appendingPathComponent("payload.txt"),
                            atomically: true,
                            encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: bundleRoot.appendingPathComponent("bad-link").path,
                                                   withDestinationPath: "../../shichizip-unsafe-target")
        let archiveURL = tempRoot.appendingPathComponent("payload.zip")
        try createZipFixture(at: archiveURL,
                             currentDirectory: tempRoot,
                             entryPaths: [bundleName,
                                          "\(bundleName)/payload.txt"])
        try createZipFixture(at: archiveURL,
                             currentDirectory: tempRoot,
                             entryPaths: ["\(bundleName)/bad-link"],
                             preserveSymlinks: true)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        defer { archive.close() }

        let rootItem = try XCTUnwrap(archive.entries()
            .map(ArchiveItem.init(from:))
            .first { $0.isDirectory && $0.pathParts == [bundleName] })
        let service = FileManagerArchiveItemWorkflowService(quarantineInheritanceEnabled: { false })
        let context = workflowContext(archive: archive,
                                      archiveURL: archiveURL,
                                      hostDirectory: tempRoot)
        let dropRoot = tempRoot.appendingPathComponent("drop", isDirectory: true)
        try FileManager.default.createDirectory(at: dropRoot,
                                                withIntermediateDirectories: true)
        let destinationURL = dropRoot.appendingPathComponent("Renamed.app", isDirectory: true)

        XCTAssertThrowsError(try service.writePromise(for: rootItem,
                                                      context: context,
                                                      to: destinationURL,
                                                      session: SZOperationSession()))
        XCTAssertEqual(try String(contentsOf: destinationURL.appendingPathComponent("payload.txt"),
                                  encoding: .utf8),
                       "payload")
        XCTAssertTrue(hiddenSidecarDirectories(in: dropRoot).isEmpty)
    }

    func testPreparedExtractionMaterializesNewDestinationRoot() throws {
        let tempRoot = try makeTemporaryDirectory(named: "prepared-extraction-sidecar")
        let archiveURL = try makeBundleArchive(named: "Payload.app",
                                               in: tempRoot)
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        defer { archive.close() }

        let entries = archive.entries().map(ArchiveItem.init(from:))
        let prepared = try XCTUnwrap(FileManagerArchiveExtraction.prepare(
            items: entries,
            context: FileManagerArchiveExtractionContext(archive: archive,
                                                         allEntries: entries,
                                                         currentSubdir: "",
                                                         quarantineSourceArchivePath: nil),
            destinationURL: tempRoot.appendingPathComponent("Extracted", isDirectory: true),
            overwriteMode: .overwrite,
            pathMode: .fullPaths,
            password: nil,
            preserveNtSecurityInfo: false,
            eliminateDuplicates: false,
            inheritDownloadedFileQuarantine: false,
        ))

        try prepared.perform(session: SZOperationSession())

        let outputRoot = tempRoot.appendingPathComponent("Extracted", isDirectory: true)
        XCTAssertEqual(try String(contentsOf: outputRoot.appendingPathComponent("Payload.app/Contents/payload.txt"),
                                  encoding: .utf8),
                       "payload")
        XCTAssertTrue(hiddenSidecarDirectories(in: tempRoot).isEmpty)
    }

    func testPreparedExtractionKeepsExistingDestinationMergeBehavior() throws {
        let tempRoot = try makeTemporaryDirectory(named: "prepared-extraction-existing-destination")
        let archiveURL = try makeBundleArchive(named: "Payload.app",
                                               in: tempRoot)
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        defer { archive.close() }

        let outputRoot = tempRoot.appendingPathComponent("Extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot,
                                                withIntermediateDirectories: true)
        try "marker".write(to: outputRoot.appendingPathComponent("marker.txt"),
                           atomically: true,
                           encoding: .utf8)

        let entries = archive.entries().map(ArchiveItem.init(from:))
        let prepared = try XCTUnwrap(FileManagerArchiveExtraction.prepare(
            items: entries,
            context: FileManagerArchiveExtractionContext(archive: archive,
                                                         allEntries: entries,
                                                         currentSubdir: "",
                                                         quarantineSourceArchivePath: nil),
            destinationURL: outputRoot,
            overwriteMode: .overwrite,
            pathMode: .fullPaths,
            password: nil,
            preserveNtSecurityInfo: false,
            eliminateDuplicates: false,
            inheritDownloadedFileQuarantine: false,
        ))

        try prepared.perform(session: SZOperationSession())

        XCTAssertEqual(try String(contentsOf: outputRoot.appendingPathComponent("marker.txt"),
                                  encoding: .utf8),
                       "marker")
        XCTAssertEqual(try String(contentsOf: outputRoot.appendingPathComponent("Payload.app/Contents/payload.txt"),
                                  encoding: .utf8),
                       "payload")
    }

    func testMaterializationPublishOverwritesRaceCreatedDirectory() throws {
        let tempRoot = try makeTemporaryDirectory(named: "materialization-race")
        let finalURL = tempRoot.appendingPathComponent("Output.app", isDirectory: true)
        let materialization = try XCTUnwrap(try FileManagerExtractionMaterialization.prepareNewDestination(
            finalURL: finalURL,
            publishRootIsDirectory: true,
        ))
        try materialization.createPublishRootDirectoryIfNeeded()
        try "new".write(to: materialization.publishRootURL.appendingPathComponent("new.txt"),
                        atomically: true,
                        encoding: .utf8)

        try FileManager.default.createDirectory(at: finalURL,
                                                withIntermediateDirectories: true)
        try "old".write(to: finalURL.appendingPathComponent("old.txt"),
                        atomically: true,
                        encoding: .utf8)

        try materialization.finish(operationError: nil)

        XCTAssertEqual(try String(contentsOf: finalURL.appendingPathComponent("new.txt"),
                                  encoding: .utf8),
                       "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.appendingPathComponent("old.txt").path))
        XCTAssertTrue(hiddenSidecarDirectories(in: tempRoot).isEmpty)
    }

    private func makeArchiveItem(index: Int,
                                 path: String,
                                 isDirectory: Bool = false,
                                 reference: SZArchiveItemReference? = nil) -> ArchiveItem
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
                    comment: "",
                    reference: reference)
    }

    private func makeBundleArchive(named bundleName: String,
                                   in tempRoot: URL) throws -> URL
    {
        let bundleRoot = tempRoot.appendingPathComponent(bundleName, isDirectory: true)
        let contentsRoot = bundleRoot.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsRoot,
                                                withIntermediateDirectories: true)
        try "payload".write(to: contentsRoot.appendingPathComponent("payload.txt"),
                            atomically: true,
                            encoding: .utf8)
        let archiveURL = tempRoot.appendingPathComponent("payload.zip")
        try createZipFixture(at: archiveURL,
                             currentDirectory: tempRoot,
                             entryPaths: [bundleName],
                             recursive: true)
        return archiveURL
    }

    private func workflowContext(archive: SZArchive,
                                 archiveURL: URL,
                                 hostDirectory: URL) -> FileManagerArchiveItemWorkflowContext
    {
        FileManagerArchiveItemWorkflowContext(archive: archive,
                                              hostDirectory: hostDirectory,
                                              displayPathPrefix: archiveURL.path,
                                              quarantineSourceArchivePath: nil,
                                              mutationTarget: nil)
    }

    private func hiddenSidecarDirectories(in directoryURL: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directoryURL,
                                                      includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix(".7zT") } ?? []
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
