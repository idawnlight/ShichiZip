import AppKit
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileManagerPaneSuspensionCoordinatorTests: XCTestCase {
    func testPrepareForCloseKeepsPaneActiveWhenArchiveCloseFails() async {
        var closeShowError: Bool?
        let harness = makeCoordinator(isInsideArchive: { true },
                                      closeAllArchives: { showError in
                                          closeShowError = showError
                                          return false
                                      },
                                      prepareDirectoryForSuspension: {
                                          XCTFail("Failed archive close must not suspend the pane")
                                      })

        let didPrepare = await harness.coordinator.prepareForClose(showError: true)
        XCTAssertFalse(didPrepare)

        XCTAssertEqual(closeShowError, true)
        XCTAssertFalse(harness.coordinator.isSuspended)
        XCTAssertNil(suspendedOverlay(in: harness))
    }

    func testPrepareForCloseSuspendsAfterArchiveCloseSucceeds() async {
        var isInsideArchive = true
        var closeShowError: Bool?
        var prepareCount = 0
        var cancelRefreshCount = 0
        var clearArchiveDisplayCount = 0
        let harness = makeCoordinator(isInsideArchive: { isInsideArchive },
                                      closeAllArchives: { showError in
                                          closeShowError = showError
                                          isInsideArchive = false
                                          return true
                                      },
                                      prepareDirectoryForSuspension: { prepareCount += 1 },
                                      cancelPendingArchiveRefresh: { cancelRefreshCount += 1 },
                                      clearArchiveDisplayItems: { clearArchiveDisplayCount += 1 })

        let didPrepare = await harness.coordinator.prepareForClose(showError: false)
        XCTAssertTrue(didPrepare)

        XCTAssertEqual(closeShowError, false)
        XCTAssertTrue(harness.coordinator.isSuspended)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(cancelRefreshCount, 1)
        XCTAssertEqual(clearArchiveDisplayCount, 1)
        XCTAssertEqual(harness.statusLabel.stringValue, "")
        XCTAssertNotNil(suspendedOverlay(in: harness))
    }

    func testPrepareForDeactivationSuspendsLoadedFilesystemPaneWithoutClosingArchive() async {
        var closeCount = 0
        var prepareCount = 0
        let harness = makeCoordinator(isInsideArchive: { false },
                                      closeAllArchives: { _ in
                                          closeCount += 1
                                          return true
                                      },
                                      prepareDirectoryForSuspension: { prepareCount += 1 })

        let didPrepare = await harness.coordinator.prepareForDeactivation(showError: true)
        XCTAssertTrue(didPrepare)

        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertTrue(harness.coordinator.isSuspended)
        XCTAssertNotNil(suspendedOverlay(in: harness))
    }

    func testPrepareEmptyPaneForDeactivationSuspendsWithoutClosingArchive() {
        var closeCount = 0
        let harness = makeCoordinator(isInsideArchive: { false },
                                      closeAllArchives: { _ in
                                          closeCount += 1
                                          return true
                                      })

        harness.coordinator.prepareEmptyPaneForDeactivation()

        XCTAssertEqual(closeCount, 0)
        XCTAssertTrue(harness.coordinator.isSuspended)
        XCTAssertNotNil(suspendedOverlay(in: harness))
    }

    func testCloseDirectoryDoesNotRepeatSuspensionWhenAlreadySuspended() async {
        var prepareCount = 0
        let harness = makeCoordinator(isInsideArchive: { false },
                                      prepareDirectoryForSuspension: { prepareCount += 1 })

        await harness.coordinator.closeDirectory()
        await harness.coordinator.closeDirectory()

        XCTAssertTrue(harness.coordinator.isSuspended)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertNotNil(suspendedOverlay(in: harness))
    }

    func testCloseDirectorySuspendsOnlyAfterArchiveActuallyCloses() async {
        var isInsideArchive = true
        var prepareCount = 0
        let harness = makeCoordinator(isInsideArchive: { isInsideArchive },
                                      closeAllArchives: { _ in
                                          isInsideArchive = false
                                          return true
                                      },
                                      prepareDirectoryForSuspension: { prepareCount += 1 })

        await harness.coordinator.closeDirectory()

        XCTAssertFalse(isInsideArchive)
        XCTAssertTrue(harness.coordinator.isSuspended)
        XCTAssertEqual(prepareCount, 1)
    }

    func testReactivateIfSuspendedLoadsCurrentDirectoryAndClearsStateOnSuccess() async {
        let directoryURL = URL(fileURLWithPath: "/tmp/reactivate-success", isDirectory: true)
        var loadRequest: (url: URL, showError: Bool)?
        let harness = makeCoordinator(currentDirectory: { directoryURL },
                                      loadDirectory: { url, showError in
                                          loadRequest = (url, showError)
                                          return true
                                      })
        await harness.coordinator.closeDirectory()

        harness.coordinator.reactivateIfSuspended()

        XCTAssertEqual(loadRequest?.url, directoryURL)
        XCTAssertEqual(loadRequest?.showError, true)
        XCTAssertFalse(harness.coordinator.isSuspended)
        XCTAssertNil(suspendedOverlay(in: harness))
    }

    func testReactivateKeepsPaneSuspendedWhenDirectoryLoadFails() async {
        let harness = makeCoordinator(loadDirectory: { _, _ in false })
        await harness.coordinator.closeDirectory()

        harness.coordinator.reactivateIfSuspended()

        XCTAssertTrue(harness.coordinator.isSuspended)
        XCTAssertNotNil(suspendedOverlay(in: harness))
    }

    func testReactivateIsRejectedDuringClosePreparation() async {
        var loadCount = 0
        let harness = makeCoordinator(canReactivate: { false },
                                      loadDirectory: { _, _ in
                                          loadCount += 1
                                          return true
                                      })
        await harness.coordinator.closeDirectory()

        harness.coordinator.reactivateIfSuspended()

        XCTAssertEqual(loadCount, 0)
        XCTAssertTrue(harness.coordinator.isSuspended)
    }

    func testActivityStateInvalidatesNavigationWhenClosePreparationBegins() throws {
        let state = FileManagerPaneActivityState()
        let navigationGeneration = state.beginNavigation()

        _ = state.beginClosePreparation()

        XCTAssertNotNil(navigationGeneration)
        XCTAssertFalse(state.isCurrentNavigation(try XCTUnwrap(navigationGeneration)))
        XCTAssertNil(state.beginNavigation())
    }

    func testActivityStateAllowsFreshNavigationAfterClosePreparationIsCancelled() throws {
        let state = FileManagerPaneActivityState()
        let oldNavigationGeneration = try XCTUnwrap(state.beginNavigation())
        let closePreparationToken = state.beginClosePreparation()

        state.endClosePreparation(closePreparationToken)
        let newNavigationGeneration = try XCTUnwrap(state.beginNavigation())

        XCTAssertFalse(state.isCurrentNavigation(oldNavigationGeneration))
        XCTAssertTrue(state.isCurrentNavigation(newNavigationGeneration))
    }

    func testActivityStateKeepsOverlappingClosePreparationActiveUntilEveryOwnerEnds() {
        let state = FileManagerPaneActivityState()
        let windowToken = state.beginClosePreparation()
        let localToken = state.beginClosePreparation()

        state.endClosePreparation(localToken)

        XCTAssertTrue(state.isClosePreparationActive)
        XCTAssertNil(state.beginNavigation())

        state.endClosePreparation(windowToken)
        XCTAssertFalse(state.isClosePreparationActive)
        XCTAssertNotNil(state.beginNavigation())
    }

    func testActivityStateNavigationTransitionRejectsCompetingNavigation() throws {
        let state = FileManagerPaneActivityState()
        let generation = try XCTUnwrap(state.beginNavigation())
        let transitionToken = try XCTUnwrap(state.beginNavigationTransition(for: generation))

        XCTAssertNil(state.beginNavigation())
        XCTAssertTrue(state.isCurrentNavigation(generation))

        state.endNavigationTransition(transitionToken)
        XCTAssertNotNil(state.beginNavigation())
    }

    private func makeCoordinator(isViewLoaded: @escaping () -> Bool = { true },
                                 isInsideArchive: @escaping () -> Bool = { false },
                                 closeAllArchives: @escaping (Bool) async -> Bool = { _ in true },
                                 prepareDirectoryForSuspension: @escaping () -> Void = {},
                                 cancelPendingArchiveRefresh: @escaping () -> Void = {},
                                 clearArchiveDisplayItems: @escaping () -> Void = {},
                                 currentDirectory: @escaping () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
                                 canReactivate: @escaping () -> Bool = { true },
                                 loadDirectory: @escaping (URL, Bool) -> Bool = { _, _ in true }) -> SuspensionHarness
    {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        let statusLabel = NSTextField(labelWithString: "ready")
        let coordinator = FileManagerPaneSuspensionCoordinator(isViewLoaded: isViewLoaded,
                                                               isInsideArchive: isInsideArchive,
                                                               closeAllArchives: closeAllArchives,
                                                               prepareDirectoryForSuspension: prepareDirectoryForSuspension,
                                                               cancelPendingArchiveRefresh: cancelPendingArchiveRefresh,
                                                               clearArchiveDisplayItems: clearArchiveDisplayItems,
                                                               clearStatusText: { statusLabel.stringValue = "" },
                                                               containerView: { containerView },
                                                               scrollView: { scrollView },
                                                               currentDirectory: currentDirectory,
                                                               canReactivate: canReactivate,
                                                               loadDirectory: loadDirectory)

        return SuspensionHarness(coordinator: coordinator,
                                 containerView: containerView,
                                 scrollView: scrollView,
                                 statusLabel: statusLabel)
    }

    private func suspendedOverlay(in harness: SuspensionHarness) -> NSView? {
        harness.containerView.subviews.first { $0 !== harness.scrollView }
    }
}

@MainActor
private struct SuspensionHarness {
    let coordinator: FileManagerPaneSuspensionCoordinator
    let containerView: NSView
    let scrollView: NSScrollView
    let statusLabel: NSTextField
}
