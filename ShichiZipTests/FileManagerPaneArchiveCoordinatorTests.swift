import AppKit
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileManagerPaneArchiveCoordinatorTests: XCTestCase {
    private var retainedHosts: [ArchiveHostSpy] = []

    func testArchiveFingerprintDetectsFileReplacementWithPreservedMetadata() throws {
        let directory = try makeTemporaryDirectory(named: "archive-fingerprint",
                                                   prefix: "ShichiZipArchiveCoordinatorTests")
        let archiveURL = directory.appendingPathComponent("archive.7z")
        let replacementURL = directory.appendingPathComponent("replacement.7z")
        let contents = Data("same-size".utf8)
        try contents.write(to: archiveURL)
        let fingerprint = try XCTUnwrap(
            FileManagerArchiveFileFingerprint.captureIfPossible(for: archiveURL),
        )
        try contents.write(to: replacementURL)
        try FileManager.default.setAttributes(
            [.modificationDate: fingerprint.modificationDate],
            ofItemAtPath: replacementURL.path,
        )

        try FileManager.default.removeItem(at: archiveURL)
        try FileManager.default.moveItem(at: replacementURL,
                                         to: archiveURL)

        XCTAssertFalse(fingerprint.matchesCurrentFile(at: archiveURL))
    }

    func testPublishMutationUsesCurrentTopLevelArchiveAndNormalizesPaths() throws {
        let archiveURL = try makeArchiveURL(named: "publish-normalized-mutation")
        let session = makeArchiveSession(archiveURL: archiveURL)
        let observer = NSObject()
        let coordinator = makeCoordinator(session: session,
                                          observerIdentifier: ObjectIdentifier(observer))
        let publishedChange = UncheckedSendableBox<FileManagerArchiveChange>()
        let published = expectation(description: "archive mutation published")

        let token = NotificationCenter.default.addObserver(forName: .fileManagerArchiveDidChange,
                                                           object: nil,
                                                           queue: nil)
        { notification in
            publishedChange.value = FileManagerArchiveChange(notification: notification)
            published.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        coordinator.publishMutationIfNeeded(targetSubdir: "/folder/",
                                            selectingPaths: ["/folder/file.txt/"])

        wait(for: [published], timeout: 1)
        XCTAssertEqual(publishedChange.value,
                       FileManagerArchiveChange(archiveURL: archiveURL,
                                                targetSubdir: "folder",
                                                selectingPaths: ["folder/file.txt"],
                                                sourceIdentifier: ObjectIdentifier(observer)))
    }

    func testPublishMutationSkipsTemporaryArchiveCopies() throws {
        let archiveURL = try makeArchiveURL(named: "skip-temporary-copy-mutation")
        let session = try makeArchiveSession(archiveURL: archiveURL,
                                             temporaryDirectory: makeTemporaryDirectory(named: "temporary-copy"))
        let coordinator = makeCoordinator(session: session)
        let unexpectedPublish = expectation(description: "temporary archive mutation should not publish")
        unexpectedPublish.isInverted = true

        let token = NotificationCenter.default.addObserver(forName: .fileManagerArchiveDidChange,
                                                           object: nil,
                                                           queue: nil)
        { notification in
            guard FileManagerArchiveChange(notification: notification)?.archiveURL == archiveURL.standardizedFileURL else { return }
            unexpectedPublish.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        coordinator.publishMutationIfNeeded(targetSubdir: "folder",
                                            selectingPaths: ["folder/file.txt"])

        wait(for: [unexpectedPublish], timeout: 0.1)
    }

    func testCloseAllArchivesClearsSessionAndNotifiesHost() async throws {
        let session = FileManagerArchiveSession()
        try session.appendPreparedArchive(makePreparedArchive(named: "close-all"))
        let host = ArchiveHostSpy()
        let coordinator = makeCoordinator(session: session,
                                          host: host)

        let didClose = await coordinator.closeAll(showError: true)
        XCTAssertTrue(didClose)

        XCTAssertFalse(session.isInsideArchive)
        XCTAssertTrue(session.displayItems.isEmpty)
        XCTAssertEqual(host.events, [.closedLevel, .closedLevel])
    }

    func testConcurrentCloseAllRequestsShareOneCloseOperation() async throws {
        let session = FileManagerArchiveSession()
        try session.appendPreparedArchive(makePreparedArchive(named: "coalesced-close-all"))
        let level = try XCTUnwrap(session.currentLevel)
        var lease: FileManagerArchiveOperationGate.Lease? = try XCTUnwrap(level.operationGate.acquireLease())
        XCTAssertNotNil(lease)
        let coordinator = makeCoordinator(session: session)

        let firstClose = Task { @MainActor in
            await coordinator.closeAll(showError: true)
        }
        let secondClose = Task { @MainActor in
            await coordinator.closeAll(showError: true)
        }

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(session.isInsideArchive)

        lease = nil
        let firstResult = await firstClose.value
        let secondResult = await secondClose.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertFalse(session.isInsideArchive)
    }

    func testFinishArchiveOpenCommitsPreparedArchiveAndPresentsSubdir() async throws {
        let session = FileManagerArchiveSession()
        let prepared = try makePreparedArchive(named: "finish-open-commit",
                                               entries: [
                                                   makeArchiveItem(path: "folder/", isDirectory: true),
                                                   makeArchiveItem(path: "folder/payload.txt"),
                                               ])
        let host = ArchiveHostSpy()
        let coordinator = makeCoordinator(session: session,
                                          host: host)
        let result = await coordinator.finishArchiveOpen(.opened(prepared),
                                                         temporaryDirectory: nil,
                                                         preserveTemporaryDirectoryOnUnsupported: false,
                                                         replaceCurrentState: false,
                                                         showError: true)

        guard case .opened = result else {
            XCTFail("Expected archive open to commit")
            return
        }

        XCTAssertEqual(session.currentLevel?.archivePath, prepared.archivePath)
        XCTAssertEqual(session.displayItems.map(\.path), ["folder/"])
        XCTAssertEqual(host.currentDirectory, prepared.hostDirectory)
        XCTAssertEqual(host.events, [.prepared(prepared.hostDirectory), .location([])])
        let didClose = await coordinator.closeAll(showError: false)
        XCTAssertTrue(didClose)
    }

    func testOpenArchiveInlineCommitsPreparedArchiveAsynchronously() async throws {
        let archiveURL = try makeArchive(named: "async-open",
                                         prefix: "ShichiZipArchiveCoordinatorTests")
        let session = FileManagerArchiveSession()
        let host = ArchiveHostSpy()
        let coordinator = makeCoordinator(session: session,
                                          host: host)

        let result = await coordinator.openArchiveInline(archiveURL,
                                                         hostDirectory: archiveURL.deletingLastPathComponent())

        guard case .opened = result else {
            XCTFail("Expected asynchronous archive open to commit")
            return
        }
        XCTAssertEqual(session.currentLevel?.archivePath, archiveURL.path)
        XCTAssertEqual(session.displayItems.map(\.name), ["payload.txt"])
        XCTAssertEqual(host.openedTopLevelArchives, [archiveURL.standardizedFileURL])
        let didClose = await coordinator.closeAll(showError: false)
        XCTAssertTrue(didClose)
    }

    func testOpenArchiveInlineDoesNotRecordTemporaryArchive() async throws {
        let archiveURL = try makeArchive(named: "temporary-open",
                                         prefix: "ShichiZipArchiveCoordinatorTests")
        let session = FileManagerArchiveSession()
        let host = ArchiveHostSpy()
        let coordinator = makeCoordinator(session: session,
                                          host: host)

        let result = await coordinator.openArchiveInline(
            archiveURL,
            hostDirectory: archiveURL.deletingLastPathComponent(),
            temporaryDirectory: archiveURL.deletingLastPathComponent(),
        )

        guard case .opened = result else {
            XCTFail("Expected temporary archive to open")
            return
        }
        XCTAssertTrue(host.openedTopLevelArchives.isEmpty)
        let didClose = await coordinator.closeAll(showError: false)
        XCTAssertTrue(didClose)
    }

    func testAsyncArchiveOpenReplacesExistingArchive() async throws {
        let session = FileManagerArchiveSession()
        try session.appendPreparedArchive(makePreparedArchive(named: "async-open-original"))
        let replacementURL = try makeArchive(named: "async-open-replacement",
                                             prefix: "ShichiZipArchiveCoordinatorTests",
                                             payloadFileName: "replacement.txt")
        let coordinator = makeCoordinator(session: session)

        let result = await coordinator.openArchiveInline(replacementURL,
                                                         hostDirectory: replacementURL.deletingLastPathComponent(),
                                                         replaceCurrentState: true)

        guard case .opened = result else {
            XCTFail("Expected asynchronous replacement archive open to commit")
            return
        }
        XCTAssertEqual(session.count, 1)
        XCTAssertEqual(session.currentLevel?.archivePath, replacementURL.path)
        XCTAssertEqual(session.displayItems.map(\.name), ["replacement.txt"])
        let didClose = await coordinator.closeAll(showError: false)
        XCTAssertTrue(didClose)
    }

    func testAsyncArchiveReplacementDoesNotCommitAfterOpenInvalidation() async throws {
        let session = FileManagerArchiveSession()
        try session.appendPreparedArchive(makePreparedArchive(named: "invalidated-open-original"))
        let originalLevel = try XCTUnwrap(session.currentLevel)
        var lease: FileManagerArchiveOperationGate.Lease? = try XCTUnwrap(originalLevel.operationGate.acquireLease())
        XCTAssertNotNil(lease)
        let replacementURL = try makeArchive(named: "invalidated-open-replacement",
                                             prefix: "ShichiZipArchiveCoordinatorTests")
        let host = ArchiveHostSpy()
        let coordinator = makeCoordinator(
            session: session,
            host: host,
        )

        let openTask = Task { @MainActor in
            await coordinator.openArchiveInline(replacementURL,
                                                hostDirectory: replacementURL.deletingLastPathComponent(),
                                                replaceCurrentState: true)
        }

        var closeStarted = false
        for _ in 0 ..< 200 {
            if let probeLease = originalLevel.operationGate.acquireLease() {
                withExtendedLifetime(probeLease) {}
                try await Task.sleep(for: .milliseconds(10))
            } else {
                closeStarted = true
                break
            }
        }
        guard closeStarted else {
            lease = nil
            _ = await openTask.value
            XCTFail("Archive replacement did not begin closing the existing stack")
            return
        }
        XCTAssertNotNil(host.activeReplacementToken)

        coordinator.invalidatePendingArchiveOpen()
        lease = nil

        let result = await openTask.value
        guard case .cancelled = result else {
            XCTFail("Invalidated archive replacement must not commit")
            _ = await coordinator.closeAll(showError: false)
            return
        }
        XCTAssertFalse(session.isInsideArchive)
        XCTAssertNil(host.activeReplacementToken)
        XCTAssertEqual(host.endedReplacementTokens, host.begunReplacementTokens)
    }

    func testPendingNestedOpenIsDiscardedWhenParentCloseBegins() async throws {
        let session = FileManagerArchiveSession()
        try session.appendPreparedArchive(makePreparedArchive(named: "pending-nested-parent"))
        let parentLevel = try XCTUnwrap(session.currentLevel)
        var parentLease: FileManagerArchiveOperationGate.Lease? = try XCTUnwrap(
            parentLevel.operationGate.acquireLease(),
        )
        XCTAssertNotNil(parentLease)
        let coordinator = makeCoordinator(session: session)
        let openGeneration = coordinator.beginArchiveOpen()
        let nestedPrepared = try makePreparedArchive(named: "pending-nested-child")

        let closeTask = Task { @MainActor in
            await coordinator.closeAll(showError: true)
        }

        var closeStarted = false
        for _ in 0 ..< 200 {
            if let probeLease = parentLevel.operationGate.acquireLease() {
                withExtendedLifetime(probeLease) {}
                try await Task.sleep(for: .milliseconds(10))
            } else {
                closeStarted = true
                break
            }
        }
        guard closeStarted else {
            parentLease = nil
            _ = await closeTask.value
            nestedPrepared.archive.close()
            XCTFail("Parent close did not begin waiting for the nested-open lease")
            return
        }

        let nestedResult = await coordinator.finishArchiveOpen(
            .opened(nestedPrepared),
            temporaryDirectory: nil,
            preserveTemporaryDirectoryOnUnsupported: false,
            replaceCurrentState: false,
            showError: true,
            invalidatePendingOpen: false,
            expectedOpenGeneration: openGeneration,
        )
        guard case .cancelled = nestedResult else {
            parentLease = nil
            _ = await closeTask.value
            XCTFail("Nested open must be discarded after parent close invalidates its token")
            return
        }

        parentLease = nil
        let didClose = await closeTask.value
        XCTAssertTrue(didClose)
        XCTAssertFalse(session.isInsideArchive)
    }

    func testCloseNestedArchiveRestoresParentSubdirWhenViewIsLoaded() async throws {
        let session = FileManagerArchiveSession()
        let parent = try makePreparedArchive(named: "parent",
                                             entries: [
                                                 makeArchiveItem(path: "folder/", isDirectory: true),
                                                 makeArchiveItem(path: "folder/payload.txt"),
                                             ])
        session.appendPreparedArchive(parent)
        XCTAssertTrue(session.navigateSubdir("folder"))
        try session.appendPreparedArchive(makePreparedArchive(named: "nested"))
        let nestedLevel = try XCTUnwrap(session.currentLevel)
        let host = ArchiveHostSpy()
        host.isViewLoaded = true
        let coordinator = makeCoordinator(session: session,
                                          host: host)

        let didCloseNested = await coordinator.closeLevel(nestedLevel,
                                                          showError: true)
        XCTAssertTrue(didCloseNested)

        XCTAssertEqual(session.currentLevel?.archivePath, parent.archivePath)
        XCTAssertEqual(session.currentLevel?.currentSubdir, "folder")
        XCTAssertEqual(session.displayItems.map(\.path), ["folder/payload.txt"])
        XCTAssertEqual(host.events, [.closedLevel])
        let didCloseParent = await coordinator.closeAll(showError: false)
        XCTAssertTrue(didCloseParent)
    }

    func testCloseNestedArchiveWritesModifiedTemporaryArchiveBackToParent() async throws {
        let nestedSourceURL = try makeArchive(named: "nested-write-back-source",
                                              prefix: "ShichiZipArchiveCoordinatorTests")
        let parentDirectory = try makeTemporaryDirectory(named: "nested-write-back-parent",
                                                         prefix: "ShichiZipArchiveCoordinatorTests")
        let parentURL = parentDirectory.appendingPathComponent("parent.7z")
        try createArchive(at: parentURL,
                          from: [nestedSourceURL])

        let parentArchive = SZArchive()
        try parentArchive.open(atPath: parentURL.path,
                               session: SZOperationSession())
        let parentEntries = try FileManagerArchiveListing.items(from: parentArchive,
                                                                session: SZOperationSession())
        let session = FileManagerArchiveSession()
        session.appendPreparedArchive(FileManagerPreparedArchiveOpen(
            hostDirectory: parentDirectory,
            archivePath: parentURL.path,
            displayPathPrefix: parentURL.path,
            archive: parentArchive,
            entries: parentEntries,
            temporaryDirectory: nil,
            nestedWriteBackInfo: nil,
        ))

        let stagedDirectory = try makeTemporaryDirectory(named: "nested-write-back-staged",
                                                         prefix: "ShichiZipArchiveCoordinatorTests")
        let stagedArchiveURL = stagedDirectory.appendingPathComponent(nestedSourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: nestedSourceURL,
                                         to: stagedArchiveURL)
        let initialFingerprint = try XCTUnwrap(
            FileManagerArchiveFileFingerprint.captureIfPossible(for: stagedArchiveURL),
        )
        let nestedArchive = SZArchive()
        try nestedArchive.open(atPath: stagedArchiveURL.path,
                               session: SZOperationSession())
        let nestedEntries = try FileManagerArchiveListing.items(from: nestedArchive,
                                                                session: SZOperationSession())
        let parentItem = try XCTUnwrap(parentEntries.first(where: { !$0.isDirectory }))
        let parentItemPath = parentItem.path
        let parentItemReference = try XCTUnwrap(parentItem.reference)
        let parentArchiveFingerprint = try XCTUnwrap(
            FileManagerArchiveFileFingerprint.captureIfPossible(for: parentURL),
        )
        let writeBackInfo = FileManagerNestedArchiveWriteBackInfo(
            identity: FileManagerNestedArchiveIdentity(
                topLevelArchiveURL: parentURL,
                entryLineage: [
                    FileManagerNestedArchiveIdentity.Entry(
                        archiveIndex: parentItem.index,
                        path: parentItem.path,
                        isDirectory: parentItem.isDirectory,
                    ),
                ],
                displayPath: "\(parentURL.path)/\(parentItemPath)",
            ),
            parentTarget: FileManagerArchiveMutationTarget(archive: parentArchive,
                                                           subdir: "",
                                                           topLevelArchiveURL: parentURL),
            parentItemReference: parentItemReference,
            parentArchiveURL: parentURL,
            parentArchiveFingerprint: parentArchiveFingerprint,
            initialFingerprint: initialFingerprint,
        )
        session.appendPreparedArchive(FileManagerPreparedArchiveOpen(
            hostDirectory: parentDirectory,
            archivePath: stagedArchiveURL.path,
            displayPathPrefix: writeBackInfo.identity.displayPath,
            archive: nestedArchive,
            entries: nestedEntries,
            temporaryDirectory: stagedDirectory,
            nestedWriteBackInfo: writeBackInfo,
        ))

        try nestedArchive.createFolderNamed("changed",
                                            inArchiveSubdir: "",
                                            session: nil)
        let nestedLevel = try XCTUnwrap(session.currentLevel)
        let coordinator = makeCoordinator(session: session)

        let didCloseNested = await coordinator.closeLevel(nestedLevel,
                                                          showError: true)
        XCTAssertTrue(didCloseNested)

        let extractedDirectory = try makeTemporaryDirectory(named: "nested-write-back-extracted",
                                                            prefix: "ShichiZipArchiveCoordinatorTests")
        let extractionSettings = SZExtractionSettings()
        extractionSettings.pathMode = .fullPaths
        try parentArchive.extract(toPath: extractedDirectory.path,
                                  settings: extractionSettings,
                                  session: nil)

        let roundTrippedNestedURL = extractedDirectory.appendingPathComponent(parentItemPath)
        let roundTrippedNestedArchive = SZArchive()
        try roundTrippedNestedArchive.open(atPath: roundTrippedNestedURL.path,
                                           session: SZOperationSession())
        let roundTrippedPaths = try Set(FileManagerArchiveListing.items(from: roundTrippedNestedArchive,
                                                                        session: SZOperationSession()).map(\.path))
        roundTrippedNestedArchive.close()
        XCTAssertTrue(roundTrippedPaths.contains("changed"))

        let didCloseParent = await coordinator.closeAll(showError: false)
        XCTAssertTrue(didCloseParent)
    }

    func testMutationTargetsResolveCurrentArchiveAndRevalidateByArchiveURL() throws {
        let session = FileManagerArchiveSession()
        let prepared = try makePreparedArchive(named: "mutation-target",
                                               entries: [makeArchiveItem(index: 7,
                                                                         path: "folder/payload.txt")])
        session.appendPreparedArchive(prepared)
        let coordinator = makeCoordinator(session: session)

        let currentTarget = try XCTUnwrap(coordinator.currentMutationTarget())
        XCTAssertTrue(currentTarget.archive === prepared.archive)
        XCTAssertEqual(currentTarget.subdir, "")

        let archiveURL = URL(fileURLWithPath: prepared.archivePath).standardizedFileURL
        let nestedTarget = try XCTUnwrap(coordinator.mutationTarget(for: archiveURL,
                                                                    subdir: "folder"))
        XCTAssertTrue(nestedTarget.archive === prepared.archive)
        XCTAssertEqual(nestedTarget.subdir, "folder")

        let transferTarget = try XCTUnwrap(coordinator.transferTarget(for: prepared.archive,
                                                                      subdir: "folder"))
        XCTAssertTrue(transferTarget.archive === prepared.archive)
        XCTAssertEqual(transferTarget.subdir, "folder")
        XCTAssertEqual(transferTarget.archiveURL, archiveURL)

        let otherArchiveURL = archiveURL.deletingLastPathComponent().appendingPathComponent("other.7z")
        XCTAssertNil(coordinator.mutationTarget(for: otherArchiveURL,
                                                subdir: "folder"))

        // Revalidating a write target leases the operation gate so close() waits for the in-flight
        // mutation. While the lease is held, no concurrent in-place target may resolve.
        let revalidatedTarget = try XCTUnwrap(coordinator.revalidatedMutationTarget(for: (archive: prepared.archive,
                                                                                          subdir: "folder")))
        XCTAssertTrue(revalidatedTarget.archive === prepared.archive)
        XCTAssertEqual(revalidatedTarget.subdir, "folder")
        XCTAssertNil(coordinator.currentMutationTarget(),
                     "An active mutation lease must block concurrent in-place mutation targets")
        XCTAssertNil(coordinator.revalidatedMutationTarget(for: (archive: prepared.archive,
                                                                 subdir: "folder")),
                     "A second concurrent leased mutation target must not be granted")
    }

    func testCurrentItemWorkflowContextUsesCurrentArchiveDisplayAndQuarantineSource() throws {
        let session = FileManagerArchiveSession()
        let prepared = try makePreparedArchive(named: "workflow-context")
        session.appendPreparedArchive(prepared)
        let coordinator = makeCoordinator(session: session)

        let context = try XCTUnwrap(coordinator.currentItemWorkflowContext(acquireLease: false,
                                                                           quarantineSourceArchivePath: "/tmp/source.7z"))

        XCTAssertTrue(context.archive === prepared.archive)
        XCTAssertEqual(context.hostDirectory, prepared.hostDirectory)
        XCTAssertEqual(context.displayPathPrefix, prepared.displayPathPrefix)
        XCTAssertEqual(context.quarantineSourceArchivePath, "/tmp/source.7z")
        XCTAssertNil(context.archiveOperationLease)
    }

    func testPrepareExtractionUsesSessionContextAndSelectionMessage() throws {
        let session = FileManagerArchiveSession()
        let item = makeArchiveItem(index: 7,
                                   path: "root/Payload/file.txt")
        let prepared = try makePreparedArchive(named: "prepare-extraction",
                                               entries: [item])
        session.appendPreparedArchive(prepared)
        XCTAssertTrue(session.navigateSubdir("root"))
        let coordinator = makeCoordinator(session: session)
        let destinationURL = URL(fileURLWithPath: "/tmp/Payload", isDirectory: true)

        let extraction = try coordinator.prepareExtraction(of: [item],
                                                           emptySelectionMessage: "Select something",
                                                           to: destinationURL,
                                                           overwriteMode: .ask,
                                                           pathMode: .currentPaths,
                                                           password: "secret",
                                                           preserveNtSecurityInfo: true,
                                                           eliminateDuplicates: true,
                                                           inheritDownloadedFileQuarantine: true,
                                                           quarantineSourceArchivePath: "/tmp/source.7z")

        XCTAssertEqual(extraction.entryIndices.map(\.intValue), [7])
        XCTAssertEqual(extraction.destinationURL.path, destinationURL.path)
        XCTAssertEqual(extraction.settings.pathPrefixToStrip, "root/Payload")
        XCTAssertEqual(extraction.settings.sourceArchivePathForQuarantine, "/tmp/source.7z")
        XCTAssertEqual(extraction.settings.password, "secret")
        XCTAssertTrue(extraction.settings.preserveNtSecurityInfo)

        XCTAssertThrowsError(try coordinator.prepareExtraction(of: [],
                                                               emptySelectionMessage: "Select something",
                                                               to: destinationURL,
                                                               overwriteMode: .ask,
                                                               pathMode: .currentPaths,
                                                               password: nil,
                                                               preserveNtSecurityInfo: false,
                                                               eliminateDuplicates: false,
                                                               inheritDownloadedFileQuarantine: false,
                                                               quarantineSourceArchivePath: nil))
        { error in
            XCTAssertEqual((error as NSError).localizedDescription, "Select something")
        }
    }

    func testPrepareExtractionLeasesOperationGateSoCloseWaits() throws {
        let session = FileManagerArchiveSession()
        let item = makeArchiveItem(index: 3,
                                   path: "folder/file.txt")
        let prepared = try makePreparedArchive(named: "extract-lease",
                                               entries: [item])
        session.appendPreparedArchive(prepared)
        let coordinator = makeCoordinator(session: session)

        let extraction = try coordinator.prepareExtraction(of: [item],
                                                           emptySelectionMessage: "Select something",
                                                           to: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
                                                           overwriteMode: .ask,
                                                           pathMode: .currentPaths,
                                                           password: nil,
                                                           preserveNtSecurityInfo: false,
                                                           eliminateDuplicates: false,
                                                           inheritDownloadedFileQuarantine: false,
                                                           quarantineSourceArchivePath: nil)

        // The lease lives as long as `extraction`; keep it alive across the blocking check so the
        // assertion can't be defeated by early release of the carrier.
        withExtendedLifetime(extraction) {
            XCTAssertNotNil(extraction.archiveOperationLease,
                            "A prepared extraction must hold an operation-gate lease so close() waits for it")
            XCTAssertNil(coordinator.currentMutationTarget(),
                         "A held extraction lease must block concurrent in-place mutation targets")
        }
    }

    func testCurrentArchiveForTestLeasesOperationGateSoCloseWaits() throws {
        let session = FileManagerArchiveSession()
        let prepared = try makePreparedArchive(named: "test-lease")
        session.appendPreparedArchive(prepared)
        let coordinator = makeCoordinator(session: session)

        let leasedArchive = try coordinator.currentArchiveForTest()

        XCTAssertTrue(leasedArchive.archive === prepared.archive)
        withExtendedLifetime(leasedArchive) {
            XCTAssertNotNil(leasedArchive.lease,
                            "Testing the current archive must hold an operation-gate lease so close() waits for it")
            XCTAssertNil(coordinator.currentMutationTarget(),
                         "A held test lease must block concurrent in-place mutation targets")
        }
    }

    func testArchiveReadOperationsAreRejectedAfterGateBeginsClosing() async throws {
        let session = FileManagerArchiveSession()
        let item = makeArchiveItem(index: 3,
                                   path: "folder/file.txt")
        let prepared = try makePreparedArchive(named: "closing-read-gate",
                                               entries: [item])
        session.appendPreparedArchive(prepared)
        let level = try XCTUnwrap(session.currentLevel)
        let coordinator = makeCoordinator(session: session)

        await level.operationGate.beginClosingAndWaitForLeases()
        defer { level.operationGate.cancelClosing() }

        XCTAssertThrowsError(try coordinator.currentArchiveForTest())
        XCTAssertThrowsError(
            try coordinator.prepareExtraction(
                of: [item],
                emptySelectionMessage: "Select something",
                to: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
                overwriteMode: .ask,
                pathMode: .currentPaths,
                password: nil,
                preserveNtSecurityInfo: false,
                eliminateDuplicates: false,
                inheritDownloadedFileQuarantine: false,
                quarantineSourceArchivePath: nil,
            ),
        )
    }

    func testReapplyHiddenVisibilityFiltersAndRestoresSelectionWithoutReloadingEntries() {
        var showHidden = true
        let session = FileManagerArchiveSession(showsHiddenFiles: { showHidden })
        session.appendPreparedArchive(FileManagerPreparedArchiveOpen(hostDirectory: URL(fileURLWithPath: "/tmp"),
                                                                     archivePath: "/tmp/source.7z",
                                                                     displayPathPrefix: "/tmp/source.7z",
                                                                     archive: SZArchive(),
                                                                     entries: [
                                                                         makeArchiveItem(index: 0, path: "visible.txt"),
                                                                         makeArchiveItem(index: 1, path: ".secret.txt"),
                                                                     ],
                                                                     temporaryDirectory: nil,
                                                                     nestedWriteBackInfo: nil))
        XCTAssertEqual(Set(session.displayItems.map(\.path)), ["visible.txt", ".secret.txt"])

        let host = ArchiveHostSpy()
        host.archiveSelectedPaths = ["visible.txt"]
        let coordinator = makeCoordinator(session: session,
                                          host: host)

        showHidden = false
        coordinator.reapplyHiddenVisibility()

        XCTAssertEqual(session.displayItems.map(\.path), ["visible.txt"],
                       "Toggling hidden files off must re-filter the cached display items")
        XCTAssertEqual(host.events, [.visibility(["visible.txt"])],
                       "The host must receive one visibility update with the captured selection")
    }

    func testCoordinatorDoesNotRetainHost() throws {
        var host: ArchiveHostSpy? = ArchiveHostSpy()
        weak let weakHost = host
        let coordinator = FileManagerPaneArchiveCoordinator(
            archiveSession: FileManagerArchiveSession(),
            observerIdentifier: ObjectIdentifier(self),
            host: try XCTUnwrap(host),
        )

        host = nil

        XCTAssertNil(weakHost)
        XCTAssertEqual(coordinator.archiveHostDirectory(), FileManager.default.homeDirectoryForCurrentUser)
    }

    func testSubdirectoryNavigationUpdatesSessionAndNotifiesHost() throws {
        let session = FileManagerArchiveSession()
        let prepared = try makePreparedArchive(named: "host-navigation",
                                               entries: [
                                                   makeArchiveItem(path: "folder/", isDirectory: true),
                                                   makeArchiveItem(path: "folder/payload.txt"),
                                               ])
        session.appendPreparedArchive(prepared)
        let host = ArchiveHostSpy()
        let coordinator = makeCoordinator(session: session, host: host)

        coordinator.navigateSubdir("folder")

        XCTAssertEqual(session.currentLevel?.currentSubdir, "folder")
        XCTAssertEqual(session.displayItems.map(\.path), ["folder/payload.txt"])
        XCTAssertEqual(host.events, [.location([])])
    }

    func testEntriesReloadRestoresSelectionThroughHost() async throws {
        let session = FileManagerArchiveSession()
        let prepared = try makePreparedArchive(named: "host-reload-selection")
        session.appendPreparedArchive(prepared)
        let host = ArchiveHostSpy()
        let reloaded = expectation(description: "archive entries refreshed")
        host.locationUpdateExpectation = reloaded
        let coordinator = makeCoordinator(session: session, host: host)

        coordinator.reloadCurrentArchiveEntries(selectingPaths: ["/payload.txt/"])
        await fulfillment(of: [reloaded], timeout: 5)

        XCTAssertEqual(session.displayItems.map(\.path), ["payload.txt"])
        XCTAssertEqual(host.events, [.location(["payload.txt"])])
        host.locationUpdateExpectation = nil
        let didClose = await coordinator.closeAll(showError: false)
        XCTAssertTrue(didClose)
    }

    func testReplacementRejectedByHostPreservesExistingArchive() async throws {
        let session = FileManagerArchiveSession()
        let original = try makePreparedArchive(named: "host-replacement-original")
        session.appendPreparedArchive(original)
        let replacement = try makePreparedArchive(named: "host-replacement-rejected")
        let host = ArchiveHostSpy()
        host.allowsStateReplacement = false
        let coordinator = makeCoordinator(session: session, host: host)

        let result = await coordinator.finishArchiveOpen(.opened(replacement),
                                                         temporaryDirectory: nil,
                                                         preserveTemporaryDirectoryOnUnsupported: false,
                                                         replaceCurrentState: true,
                                                         showError: true)

        guard case .cancelled = result else {
            XCTFail("The host must be able to reject an archive state replacement")
            return
        }
        XCTAssertTrue(session.currentLevel?.archive === original.archive)
        XCTAssertEqual(session.count, 1)
        XCTAssertTrue(host.events.isEmpty)
        XCTAssertTrue(host.begunReplacementTokens.isEmpty)
        let didClose = await coordinator.closeAll(showError: false)
        XCTAssertTrue(didClose)
    }

    func testConflictingHostArchiveBlocksInPlaceMutation() throws {
        let session = FileManagerArchiveSession()
        let prepared = try makePreparedArchive(named: "host-conflicting-mutation")
        session.appendPreparedArchive(prepared)
        let host = ArchiveHostSpy()
        host.conflictingNestedIdentity = .root(topLevelArchiveURL: URL(fileURLWithPath: prepared.archivePath))
        let coordinator = makeCoordinator(session: session, host: host)

        XCTAssertFalse(coordinator.supportsInPlaceMutation())
        XCTAssertNil(coordinator.currentMutationTarget())
        host.conflictingNestedIdentity = nil
        XCTAssertTrue(coordinator.supportsInPlaceMutation())
    }

    private func makeCoordinator(session: FileManagerArchiveSession,
                                 observerIdentifier: ObjectIdentifier = ObjectIdentifier(NSObject()),
                                 host: ArchiveHostSpy? = nil) -> FileManagerPaneArchiveCoordinator
    {
        let host = host ?? ArchiveHostSpy()
        retainedHosts.append(host)
        return FileManagerPaneArchiveCoordinator(archiveSession: session,
                                                 observerIdentifier: observerIdentifier,
                                                 host: host)
    }

    private func makeArchiveURL(named name: String) throws -> URL {
        try makeTemporaryDirectory(named: name,
                                   prefix: "ShichiZipArchiveCoordinatorTests")
            .appendingPathComponent("source.7z")
    }

    private func makeArchiveSession(archiveURL: URL,
                                    temporaryDirectory: URL? = nil) -> FileManagerArchiveSession
    {
        let session = FileManagerArchiveSession()
        session.appendPreparedArchive(FileManagerPreparedArchiveOpen(hostDirectory: archiveURL.deletingLastPathComponent(),
                                                                     archivePath: archiveURL.path,
                                                                     displayPathPrefix: archiveURL.path,
                                                                     archive: SZArchive(),
                                                                     entries: [],
                                                                     temporaryDirectory: temporaryDirectory,
                                                                     nestedWriteBackInfo: nil))
        return session
    }

    private func makePreparedArchive(named name: String,
                                     entries: [ArchiveItem]? = nil) throws -> FileManagerPreparedArchiveOpen
    {
        let archiveURL = try makeArchive(named: name,
                                         prefix: "ShichiZipArchiveCoordinatorTests")
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path,
                         session: SZOperationSession())
        let archiveEntries = try entries ?? FileManagerArchiveListing.items(from: archive,
                                                                            session: SZOperationSession())
        return FileManagerPreparedArchiveOpen(hostDirectory: archiveURL.deletingLastPathComponent(),
                                              archivePath: archiveURL.path,
                                              displayPathPrefix: archiveURL.path,
                                              archive: archive,
                                              entries: archiveEntries,
                                              temporaryDirectory: nil,
                                              nestedWriteBackInfo: nil)
    }

    private func makeArchiveItem(index: Int = 0,
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
}

@MainActor
private final class ArchiveHostSpy: FileManagerPaneArchiveCoordinatorHost {
    enum Event: Equatable {
        case prepared(URL)
        case location([String])
        case visibility([String])
        case closedLevel
    }

    var archiveParentWindow: NSWindow?
    var isViewLoaded = false
    var currentDirectory = FileManager.default.homeDirectoryForCurrentUser
    var archiveSelectedPaths: [String] = []
    var events: [Event] = []
    var locationUpdateExpectation: XCTestExpectation?
    var openedTopLevelArchives: [URL] = []
    var conflictingNestedIdentity: FileManagerNestedArchiveIdentity?
    var dirtyNestedIdentity: FileManagerNestedArchiveIdentity?
    var allowsStateReplacement = true
    var activeReplacementToken: UUID?
    var begunReplacementTokens: [UUID] = []
    var endedReplacementTokens: [UUID] = []
    var expectedError = false
    var errors: [Error] = []

    func archivePrepareForPresentation(hostDirectory: URL) {
        currentDirectory = hostDirectory
        events.append(.prepared(hostDirectory))
    }

    func archiveLocationDidChange(selectingPaths: [String]) {
        events.append(.location(selectingPaths))
        locationUpdateExpectation?.fulfill()
    }

    func archiveVisibilityDidChange(restoringSelection: [String]) {
        events.append(.visibility(restoringSelection))
    }

    func archiveStackDidCloseLevel() {
        events.append(.closedLevel)
    }

    func archiveDidOpenTopLevel(_ url: URL) {
        openedTopLevelArchives.append(url)
    }

    func hasConflictingNestedArchiveInstance(for identity: FileManagerNestedArchiveIdentity) -> Bool {
        identity == conflictingNestedIdentity
    }

    func hasDirtyNestedArchiveInstance(for identity: FileManagerNestedArchiveIdentity) -> Bool {
        identity == dirtyNestedIdentity
    }

    func archiveBeginStateReplacement() -> UUID? {
        guard allowsStateReplacement else { return nil }
        let token = UUID()
        activeReplacementToken = token
        begunReplacementTokens.append(token)
        return token
    }

    func archiveEndStateReplacement(_ token: UUID) {
        endedReplacementTokens.append(token)
        activeReplacementToken = nil
    }

    func showErrorAlert(_ error: Error) {
        errors.append(error)
        if !expectedError {
            XCTFail("Unexpected archive coordinator error: \(error)")
        }
    }
}
