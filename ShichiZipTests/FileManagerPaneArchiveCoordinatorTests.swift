import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileManagerPaneArchiveCoordinatorTests: XCTestCase {
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

    func testCloseAllArchivesClearsSessionAndRunsRefreshCallbacks() throws {
        let session = FileManagerArchiveSession()
        try session.appendPreparedArchive(makePreparedArchive(named: "close-all"))
        var didUpdateTableColumns = false
        let coordinator = makeCoordinator(session: session,
                                          updateTableColumns: { didUpdateTableColumns = true })

        XCTAssertTrue(coordinator.closeAll(showError: true))

        XCTAssertFalse(session.isInsideArchive)
        XCTAssertTrue(session.displayItems.isEmpty)
        XCTAssertTrue(didUpdateTableColumns)
    }

    func testFinishArchiveOpenCommitsPreparedArchiveAndPresentsSubdir() throws {
        let session = FileManagerArchiveSession()
        let prepared = try makePreparedArchive(named: "finish-open-commit",
                                               entries: [
                                                   makeArchiveItem(path: "folder/", isDirectory: true),
                                                   makeArchiveItem(path: "folder/payload.txt"),
                                               ])
        var currentDirectory = FileManager.default.homeDirectoryForCurrentUser
        var preparedDirectory: URL?
        var didUpdateTableColumns = false
        var didReloadTableData = false
        let coordinator = makeCoordinator(session: session,
                                          currentDirectory: { currentDirectory },
                                          prepareDirectoryForArchivePresentation: { hostDirectory in
                                              preparedDirectory = hostDirectory
                                              currentDirectory = hostDirectory
                                          },
                                          updateTableColumns: { didUpdateTableColumns = true },
                                          reloadTableData: { didReloadTableData = true })
        defer { _ = coordinator.closeAll(showError: false) }

        let result = coordinator.finishArchiveOpen(.opened(prepared),
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
        XCTAssertEqual(currentDirectory, prepared.hostDirectory)
        XCTAssertEqual(preparedDirectory, prepared.hostDirectory)
        XCTAssertTrue(didUpdateTableColumns)
        XCTAssertTrue(didReloadTableData)
    }

    func testOpenArchiveInlineCommitsPreparedArchiveAsynchronously() async throws {
        let archiveURL = try makeArchive(named: "async-open",
                                         prefix: "ShichiZipArchiveCoordinatorTests")
        let session = FileManagerArchiveSession()
        let coordinator = makeCoordinator(session: session)
        defer { _ = coordinator.closeAll(showError: false) }

        let result = await coordinator.openArchiveInline(archiveURL,
                                                         hostDirectory: archiveURL.deletingLastPathComponent())

        guard case .opened = result else {
            XCTFail("Expected asynchronous archive open to commit")
            return
        }
        XCTAssertEqual(session.currentLevel?.archivePath, archiveURL.path)
        XCTAssertEqual(session.displayItems.map(\.name), ["payload.txt"])
    }

    func testAsyncArchiveOpenReplacesExistingArchive() async throws {
        let session = FileManagerArchiveSession()
        session.appendPreparedArchive(try makePreparedArchive(named: "async-open-original"))
        let replacementURL = try makeArchive(named: "async-open-replacement",
                                             prefix: "ShichiZipArchiveCoordinatorTests",
                                             payloadFileName: "replacement.txt")
        let coordinator = makeCoordinator(session: session)
        defer { _ = coordinator.closeAll(showError: false) }

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
    }

    func testCloseNestedArchiveRestoresParentSubdirWhenViewIsLoaded() throws {
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
        var didPresentParentSubdir = false
        let coordinator = makeCoordinator(session: session,
                                          isViewLoaded: { true },
                                          reloadTableData: { didPresentParentSubdir = true })
        defer { _ = coordinator.closeAll(showError: false) }

        XCTAssertTrue(coordinator.closeLevel(nestedLevel,
                                             showError: true))

        XCTAssertEqual(session.currentLevel?.archivePath, parent.archivePath)
        XCTAssertEqual(session.currentLevel?.currentSubdir, "folder")
        XCTAssertEqual(session.displayItems.map(\.path), ["folder/payload.txt"])
        XCTAssertTrue(didPresentParentSubdir)
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

        var reloadCount = 0
        var restoredSelection: [String]?
        let coordinator = makeCoordinator(session: session,
                                          reloadTableData: { reloadCount += 1 },
                                          selectArchivePaths: { restoredSelection = $0 },
                                          selectedArchivePaths: { ["visible.txt"] })

        showHidden = false
        coordinator.reapplyHiddenVisibility()

        XCTAssertEqual(session.displayItems.map(\.path), ["visible.txt"],
                       "Toggling hidden files off must re-filter the cached display items")
        XCTAssertEqual(reloadCount, 1, "Reapplying visibility must reload the table once")
        XCTAssertEqual(restoredSelection, ["visible.txt"],
                       "The captured selection must be restored after re-filtering")
    }

    private func makeCoordinator(session: FileManagerArchiveSession,
                                 observerIdentifier: ObjectIdentifier = ObjectIdentifier(NSObject()),
                                 isViewLoaded: @escaping () -> Bool = { false },
                                 currentDirectory: @escaping () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
                                 prepareDirectoryForArchivePresentation: @escaping (URL) -> Void = { _ in },
                                 updateTableColumns: @escaping () -> Void = {},
                                 reloadTableData: @escaping () -> Void = {},
                                 selectArchivePaths: @escaping ([String]) -> Void = { _ in },
                                 selectedArchivePaths: @escaping () -> [String] = { [] },
                                 hasConflictingNestedArchiveInstance: @escaping (FileManagerNestedArchiveIdentity) -> Bool = { _ in false }) -> FileManagerPaneArchiveCoordinator
    {
        FileManagerPaneArchiveCoordinator(archiveSession: session,
                                          observerIdentifier: observerIdentifier,
                                          parentWindow: { nil },
                                          isViewLoaded: isViewLoaded,
                                          updateTableColumns: updateTableColumns,
                                          currentDirectory: currentDirectory,
                                          prepareDirectoryForArchivePresentation: prepareDirectoryForArchivePresentation,
                                          reloadTableData: reloadTableData,
                                          selectArchivePaths: selectArchivePaths,
                                          selectedArchivePaths: selectedArchivePaths,
                                          hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance,
                                          showError: { error in
                                              XCTFail("Unexpected archive coordinator error: \(error)")
                                          })
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
