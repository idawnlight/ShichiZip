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
        let host = TestSuspensionHost()
        host.isInsideArchive = true
        host.closeResult = false

        let didPrepare = await host.coordinator.prepareForClose(showError: true)

        XCTAssertFalse(didPrepare)
        XCTAssertEqual(host.closeRequests, [true])
        XCTAssertFalse(host.coordinator.isSuspended)
        XCTAssertEqual(host.suspensionCount, 0)
        XCTAssertNil(host.suspendedOverlay)
    }

    func testPrepareForCloseSuspendsAfterArchiveCloseSucceeds() async {
        let host = TestSuspensionHost()
        host.isInsideArchive = true

        let didPrepare = await host.coordinator.prepareForClose(showError: false)

        XCTAssertTrue(didPrepare)
        XCTAssertEqual(host.closeRequests, [false])
        XCTAssertTrue(host.coordinator.isSuspended)
        XCTAssertEqual(host.suspensionCount, 1)
        XCTAssertNotNil(host.suspendedOverlay)
    }

    func testPrepareForDeactivationSuspendsLoadedFilesystemPaneWithoutClosingArchive() async {
        let host = TestSuspensionHost()

        let didPrepare = await host.coordinator.prepareForDeactivation(showError: true)

        XCTAssertTrue(didPrepare)
        XCTAssertTrue(host.closeRequests.isEmpty)
        XCTAssertEqual(host.suspensionCount, 1)
        XCTAssertTrue(host.coordinator.isSuspended)
        XCTAssertNotNil(host.suspendedOverlay)
    }

    func testPrepareEmptyPaneForDeactivationSuspendsWithoutClosingArchive() {
        let host = TestSuspensionHost()

        host.coordinator.prepareEmptyPaneForDeactivation()

        XCTAssertTrue(host.closeRequests.isEmpty)
        XCTAssertTrue(host.coordinator.isSuspended)
        XCTAssertEqual(host.suspensionCount, 1)
        XCTAssertNotNil(host.suspendedOverlay)
    }

    func testDeactivationDoesNotLoadAnUnloadedPane() async {
        let host = TestSuspensionHost()
        host.isViewLoaded = false

        let didPrepare = await host.coordinator.prepareForDeactivation()

        XCTAssertTrue(didPrepare)
        XCTAssertFalse(host.coordinator.isSuspended)
        XCTAssertEqual(host.suspensionCount, 0)
        XCTAssertNil(host.suspendedOverlay)
    }

    func testCloseDirectoryDoesNotRepeatSuspensionWhenAlreadySuspended() async {
        let host = TestSuspensionHost()

        await host.coordinator.closeDirectory()
        await host.coordinator.closeDirectory()

        XCTAssertTrue(host.coordinator.isSuspended)
        XCTAssertEqual(host.suspensionCount, 1)
        XCTAssertNotNil(host.suspendedOverlay)
    }

    func testCloseDirectorySuspendsOnlyAfterArchiveActuallyCloses() async {
        let host = TestSuspensionHost()
        host.isInsideArchive = true

        await host.coordinator.closeDirectory()

        XCTAssertFalse(host.isInsideArchive)
        XCTAssertTrue(host.coordinator.isSuspended)
        XCTAssertEqual(host.closeRequests, [true])
        XCTAssertEqual(host.suspensionCount, 1)
    }

    func testCloseDirectoryKeepsPaneActiveIfArchiveRemainsOpen() async {
        let host = TestSuspensionHost()
        host.isInsideArchive = true
        host.closeResult = false

        await host.coordinator.closeDirectory()

        XCTAssertTrue(host.isInsideArchive)
        XCTAssertFalse(host.coordinator.isSuspended)
        XCTAssertEqual(host.suspensionCount, 0)
    }

    func testReactivateIfSuspendedRequestsDirectoryReloadAndClearsStateOnSuccess() async {
        let host = TestSuspensionHost()
        await host.coordinator.closeDirectory()

        let didReactivate = host.coordinator.reactivateIfSuspended()

        XCTAssertTrue(didReactivate)
        XCTAssertEqual(host.reloadCount, 1)
        XCTAssertFalse(host.coordinator.isSuspended)
        XCTAssertNil(host.suspendedOverlay)
    }

    func testReactivateKeepsPaneSuspendedWhenDirectoryLoadFails() async {
        let host = TestSuspensionHost()
        host.reloadResult = false
        await host.coordinator.closeDirectory()

        let didReactivate = host.coordinator.reactivateIfSuspended()

        XCTAssertFalse(didReactivate)
        XCTAssertEqual(host.reloadCount, 1)
        XCTAssertTrue(host.coordinator.isSuspended)
        XCTAssertNotNil(host.suspendedOverlay)
    }

    func testReactivateIsRejectedDuringClosePreparation() async {
        let host = TestSuspensionHost()
        host.canReactivate = false
        await host.coordinator.closeDirectory()

        let didReactivate = host.coordinator.reactivateIfSuspended()

        XCTAssertFalse(didReactivate)
        XCTAssertEqual(host.reloadCount, 0)
        XCTAssertTrue(host.coordinator.isSuspended)
    }

    func testCoordinatorDoesNotRetainItsHost() async throws {
        var host: TestSuspensionHost? = TestSuspensionHost()
        weak let weakHost = host
        let coordinator = try XCTUnwrap(host).coordinator

        host = nil

        XCTAssertNil(weakHost)
        let didPrepare = await coordinator.prepareForClose()
        XCTAssertFalse(didPrepare)
    }

    func testActivityStateInvalidatesNavigationWhenClosePreparationBegins() throws {
        let state = FileManagerPaneActivityState()
        let navigationGeneration = state.beginNavigation()

        _ = state.beginClosePreparation()

        XCTAssertNotNil(navigationGeneration)
        XCTAssertFalse(try state.isCurrentNavigation(XCTUnwrap(navigationGeneration)))
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

}

@MainActor
private final class TestSuspensionHost: FileManagerPaneSuspensionHost {
    var isViewLoaded = true
    var isInsideArchive = false
    var closeResult = true
    var canReactivate = true
    var reloadResult = true
    private(set) var closeRequests: [Bool] = []
    private(set) var suspensionCount = 0
    private(set) var reloadCount = 0

    let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
    let scrollView = NSScrollView()
    lazy var coordinator = FileManagerPaneSuspensionCoordinator(host: self)

    init() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    var suspensionOverlayViews: (container: NSView, content: NSView)? {
        isViewLoaded ? (containerView, scrollView) : nil
    }

    var suspendedOverlay: NSView? {
        containerView.subviews.first { $0 !== scrollView }
    }

    func closeAllArchives(showError: Bool) async -> Bool {
        closeRequests.append(showError)
        if closeResult {
            isInsideArchive = false
        }
        return closeResult
    }

    func preparePaneForSuspension() {
        suspensionCount += 1
    }

    func reloadSuspendedDirectory() -> Bool {
        guard canReactivate else { return false }
        reloadCount += 1
        return reloadResult
    }
}
