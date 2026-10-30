import Foundation
import os
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileManagerPaneDirectoryCoordinatorTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipIfAffectedByIsolatedDeinitTaskLocalRuntimeBug()
    }

    func testLoadDirectoryAppliesSnapshotBeforeNotifyingHost() throws {
        let directoryURL = try makeDirectory(named: "load-directory")
        try "alpha".write(to: directoryURL.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "beta".write(to: directoryURL.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
        let host = HostSpy()
        let coordinator = makeCoordinator(host: host)
        defer { coordinator.tearDown() }

        XCTAssertTrue(coordinator.loadDirectory(directoryURL))

        XCTAssertEqual(coordinator.currentDirectory.standardizedFileURL, directoryURL.standardizedFileURL)
        XCTAssertEqual(coordinator.items.map(\.name), ["alpha.txt", "beta.txt"])
        XCTAssertEqual(coordinator.recentDirectoryHistory().first, directoryURL.standardizedFileURL)
        XCTAssertEqual(host.presentedDirectories, [directoryURL.standardizedFileURL])
        XCTAssertEqual(host.events, [.loading(false), .snapshot, .navigation])
        XCTAssertNil(host.navigationCompletions.first?.selection)
        XCTAssertEqual(host.navigationCompletions.first?.focusFileList, false)
    }

    func testPrepareForSuspensionClearsPresentedItemsAndNotifiesHost() throws {
        let directoryURL = try makeDirectory(named: "suspend-directory")
        let host = HostSpy()
        let coordinator = makeCoordinator(host: host, makeSnapshot: { Self.snapshot(for: $0, names: ["payload.txt"]) })
        defer { coordinator.tearDown() }
        XCTAssertTrue(coordinator.loadDirectory(directoryURL))
        XCTAssertFalse(coordinator.items.isEmpty)

        coordinator.prepareForSuspension()

        XCTAssertTrue(coordinator.items.isEmpty)
        XCTAssertEqual(host.events.last, .suspension)
    }

    func testPrepareForArchivePresentationUpdatesCurrentDirectoryAndHistory() throws {
        let hostDirectory = try makeDirectory(named: "archive-host")
        let host = HostSpy()
        let coordinator = makeCoordinator(host: host)
        defer { coordinator.tearDown() }

        coordinator.prepareForArchivePresentation(hostDirectory: hostDirectory)

        XCTAssertEqual(coordinator.currentDirectory.standardizedFileURL, hostDirectory.standardizedFileURL)
        XCTAssertEqual(coordinator.recentDirectoryHistory().first, hostDirectory.standardizedFileURL)
        XCTAssertTrue(host.events.isEmpty)
    }

    func testRevealSelectionUsesSortedRowsAndParentOffsetBeforeFocusing() throws {
        let directoryURL = try makeDirectory(named: "reveal-centered-selection")
        let selectedPath = directoryURL.appendingPathComponent("beta.txt").standardizedFileURL.path
        let host = HostSpy()
        host.showsParentRow = true
        let coordinator = makeCoordinator(host: host, makeSnapshot: { Self.snapshot(for: $0, names: ["beta.txt", "alpha.txt"]) })
        defer { coordinator.tearDown() }

        XCTAssertTrue(coordinator.navigateToDirectory(directoryURL,
                                                      showError: true,
                                                      selectionState: FileManagerFileSystemSelectionState(selectedPaths: [selectedPath],
                                                                                                          focusedPath: selectedPath,
                                                                                                          scrollPlacement: .centered),
                                                      focusAfterLoad: true))

        let completion = try XCTUnwrap(host.navigationCompletions.first)
        let selection = try XCTUnwrap(completion.selection)
        XCTAssertEqual(selection.rows, IndexSet(integer: 2))
        XCTAssertEqual(selection.focusedRow, 2)
        XCTAssertEqual(selection.scrollPlacement, .centered)
        XCTAssertTrue(completion.focusFileList)
        XCTAssertEqual(host.events, [.loading(false), .snapshot, .navigation])
    }

    func testSelectionFallsBackToFirstSelectedRowWhenFocusedPathDisappears() throws {
        let directoryURL = try makeDirectory(named: "selection-focus-fallback")
        let host = HostSpy()
        let coordinator = makeCoordinator(host: host, makeSnapshot: { Self.snapshot(for: $0, names: ["alpha.txt", "beta.txt"]) })
        defer { coordinator.tearDown() }
        let selectedPath = directoryURL.appendingPathComponent("beta.txt").standardizedFileURL.path

        XCTAssertTrue(coordinator.navigateToDirectory(directoryURL,
                                                      showError: true,
                                                      selectionState: FileManagerFileSystemSelectionState(selectedPaths: [selectedPath],
                                                                                                          focusedPath: "/missing.txt",
                                                                                                          scrollPlacement: .visible)))

        let selection = try XCTUnwrap(host.navigationCompletions.first?.selection)
        XCTAssertEqual(selection.rows, IndexSet(integer: 1))
        XCTAssertEqual(selection.focusedRow, 1)
    }

    func testBudgetedNavigationAppliesSnapshotInlineWithoutLoadingWhenFast() throws {
        let directoryURL = try makeDirectory(named: "budget-fast")
        let host = HostSpy()
        let coordinator = makeCoordinator(host: host, makeSnapshot: { Self.snapshot(for: $0, names: ["alpha.txt"]) })
        defer { coordinator.tearDown() }

        XCTAssertTrue(coordinator.navigateToDirectory(directoryURL, showError: true, budget: .milliseconds(500)))

        XCTAssertFalse(host.events.contains(.loading(true)))
        XCTAssertEqual(coordinator.items.map(\.name), ["alpha.txt"])
        XCTAssertEqual(coordinator.currentDirectory.standardizedFileURL, directoryURL.standardizedFileURL)
        XCTAssertEqual(host.navigationCompletions.count, 1)
    }

    func testBudgetedNavigationShowsLoadingThenAppliesWhenSlow() throws {
        let directoryURL = try makeDirectory(named: "budget-slow")
        let gate = DispatchSemaphore(value: 0)
        let applied = expectation(description: "async snapshot applied")
        let host = HostSpy()
        host.snapshotAppliedExpectation = applied
        let coordinator = makeCoordinator(host: host, makeSnapshot: { url in
            gate.wait()
            return Self.snapshot(for: url, names: ["beta.txt"])
        })
        defer { coordinator.tearDown() }

        XCTAssertTrue(coordinator.navigateToDirectory(directoryURL, showError: true, budget: .milliseconds(20)))
        XCTAssertTrue(host.events.contains(.loading(true)))
        XCTAssertTrue(coordinator.items.isEmpty)

        gate.signal()
        wait(for: [applied], timeout: 2)

        XCTAssertEqual(host.events, [.loading(false), .loading(true), .loading(false), .snapshot, .navigation])
        XCTAssertEqual(coordinator.items.map(\.name), ["beta.txt"])
        XCTAssertEqual(coordinator.currentDirectory.standardizedFileURL, directoryURL.standardizedFileURL)
    }

    func testNewNavigationDiscardsPendingSnapshot() throws {
        let firstURL = try makeDirectory(named: "stale-navigation")
        let secondURL = try makeDirectory(named: "new-navigation")
        let queue = DispatchQueue(label: "DirectoryCoordinatorTests.stale-navigation")
        let gate = DispatchSemaphore(value: 0)
        let host = HostSpy()
        let coordinator = makeCoordinator(host: host, snapshotQueue: queue, makeSnapshot: { url in
            if url.standardizedFileURL == firstURL.standardizedFileURL {
                gate.wait()
            }
            return Self.snapshot(for: url, names: [url.lastPathComponent + ".txt"])
        })
        defer { coordinator.tearDown() }
        XCTAssertTrue(coordinator.navigateToDirectory(firstURL, showError: true, budget: .milliseconds(20)))
        XCTAssertTrue(coordinator.navigateToDirectory(secondURL, showError: true))

        gate.signal()
        waitForPendingSnapshots(on: queue)

        XCTAssertEqual(coordinator.currentDirectory.standardizedFileURL, secondURL.standardizedFileURL)
        XCTAssertEqual(host.presentedDirectories, [secondURL.standardizedFileURL])
        XCTAssertEqual(host.navigationCompletions.count, 1)
    }

    func testRefreshRestoresCapturedSelectionAfterSnapshotPresentation() throws {
        let directoryURL = try makeDirectory(named: "refresh-selection")
        let refreshed = expectation(description: "refresh applied")
        let host = HostSpy()
        let coordinator = makeCoordinator(host: host, makeSnapshot: { Self.snapshot(for: $0, names: ["beta.txt", "alpha.txt"]) })
        defer { coordinator.tearDown() }
        XCTAssertTrue(coordinator.loadDirectory(directoryURL))
        let selectedPath = directoryURL.appendingPathComponent("beta.txt").standardizedFileURL.path
        host.selectionState = FileManagerFileSystemSelectionState(selectedPaths: [selectedPath], focusedPath: selectedPath, scrollPlacement: .visible)
        host.snapshotAppliedExpectation = refreshed

        coordinator.reloadCurrentDirectoryPreservingSelection()
        wait(for: [refreshed], timeout: 2)

        let selection = try XCTUnwrap(host.restoredSelections.last)
        XCTAssertEqual(selection.rows, IndexSet(integer: 1))
        XCTAssertEqual(selection.focusedRow, 1)
        XCTAssertEqual(selection.scrollPlacement, .visible)
        XCTAssertEqual(host.events.suffix(2), [.snapshot, .selection])
        XCTAssertEqual(host.navigationCompletions.count, 1)
    }

    func testAutoRefreshIgnoresUnchangedItems() throws {
        let directoryURL = try makeDirectory(named: "auto-refresh-unchanged")
        let queue = DispatchQueue(label: "DirectoryCoordinatorTests.auto-refresh")
        let host = HostSpy()
        let coordinator = makeCoordinator(host: host, snapshotQueue: queue, makeSnapshot: { Self.snapshot(for: $0, names: ["alpha.txt"]) })
        defer { coordinator.tearDown() }
        XCTAssertTrue(coordinator.loadDirectory(directoryURL))
        let originalEvents = host.events

        coordinator.autoRefreshCurrentDirectoryIfNeeded()
        waitForPendingSnapshots(on: queue)

        XCTAssertEqual(host.events, originalEvents)
    }

    func testReapplyHiddenFileVisibilityPreservesSelectionWithoutReenumerating() throws {
        let directoryURL = try makeDirectory(named: "render-filter")
        let enumerationCount = OSAllocatedUnfairLock(initialState: 0)
        var showHidden = false
        let host = HostSpy()
        let coordinator = makeCoordinator(host: host, makeSnapshot: { url in
            enumerationCount.withLock { $0 += 1 }
            return Self.snapshot(for: url, names: ["alpha.txt", ".secret"])
        }, showsHiddenFiles: { showHidden })
        defer { coordinator.tearDown() }
        XCTAssertTrue(coordinator.loadDirectory(directoryURL))
        XCTAssertEqual(coordinator.items.map(\.name), ["alpha.txt"])
        let selectedPath = directoryURL.appendingPathComponent(".secret").standardizedFileURL.path
        host.selectionState = FileManagerFileSystemSelectionState(selectedPaths: [selectedPath], focusedPath: selectedPath, scrollPlacement: .visible)

        showHidden = true
        coordinator.reapplyHiddenFileVisibility()
        XCTAssertEqual(Set(coordinator.items.map(\.name)), ["alpha.txt", ".secret"])
        XCTAssertEqual(host.restoredSelections.last?.rows, IndexSet(integer: 0))

        showHidden = false
        coordinator.reapplyHiddenFileVisibility()
        XCTAssertEqual(coordinator.items.map(\.name), ["alpha.txt"])
        XCTAssertEqual(host.restoredSelections.last?.rows, IndexSet())
        XCTAssertNil(host.restoredSelections.last?.focusedRow)
        XCTAssertEqual(host.events.suffix(4), [.visibility, .selection, .visibility, .selection])
        XCTAssertEqual(enumerationCount.withLock { $0 }, 1)
    }

    func testInitialLoadFailureUpdatesLocationWithoutPresentingAnError() throws {
        let directoryURL = try makeDirectory(named: "initial-failure")
        let host = HostSpy()
        let coordinator = makeCoordinator(host: host, makeSnapshot: { _ in throw CocoaError(.fileReadNoPermission) })
        defer { coordinator.tearDown() }

        coordinator.loadInitialDirectory(directoryURL)

        XCTAssertEqual(coordinator.currentDirectory.standardizedFileURL, directoryURL.standardizedFileURL)
        XCTAssertEqual(host.events, [.initialFailure])
        XCTAssertTrue(host.errors.isEmpty)
        XCTAssertTrue(coordinator.recentDirectoryHistory().isEmpty)
    }

    func testNavigationFailureHonorsErrorPresentationFlag() throws {
        let directoryURL = try makeDirectory(named: "navigation-failure")
        let host = HostSpy()
        let coordinator = makeCoordinator(host: host, makeSnapshot: { _ in throw CocoaError(.fileReadNoPermission) })
        defer { coordinator.tearDown() }
        let originalDirectory = coordinator.currentDirectory

        XCTAssertFalse(coordinator.navigateToDirectory(directoryURL, showError: false))
        XCTAssertTrue(host.errors.isEmpty)
        XCTAssertFalse(coordinator.navigateToDirectory(directoryURL, showError: true))

        XCTAssertEqual(host.errors.count, 1)
        XCTAssertEqual(coordinator.currentDirectory, originalDirectory)
        XCTAssertTrue(host.navigationCompletions.isEmpty)
    }

    func testArchivePresentationRejectsPendingDirectoryNavigation() throws {
        let directoryURL = try makeDirectory(named: "archive-during-navigation")
        let queue = DispatchQueue(label: "DirectoryCoordinatorTests.archive-navigation")
        let gate = DispatchSemaphore(value: 0)
        let host = HostSpy()
        let coordinator = makeCoordinator(host: host, snapshotQueue: queue, makeSnapshot: { url in
            gate.wait()
            return Self.snapshot(for: url, names: ["alpha.txt"])
        })
        defer { coordinator.tearDown() }
        XCTAssertTrue(coordinator.navigateToDirectory(directoryURL, showError: true, budget: .milliseconds(20)))
        host.isInsideArchive = true

        gate.signal()
        waitForPendingSnapshots(on: queue)

        XCTAssertTrue(coordinator.items.isEmpty)
        XCTAssertTrue(host.navigationCompletions.isEmpty)
        XCTAssertEqual(host.events.last, .loading(false))
    }

    func testCoordinatorDoesNotRetainHostDuringPendingNavigation() throws {
        let directoryURL = try makeDirectory(named: "weak-host")
        let queue = DispatchQueue(label: "DirectoryCoordinatorTests.weak-host")
        let gate = DispatchSemaphore(value: 0)
        var host: HostSpy? = HostSpy()
        weak let weakHost = host
        let coordinator = try makeCoordinator(host: XCTUnwrap(host), snapshotQueue: queue, makeSnapshot: { url in
            gate.wait()
            return Self.snapshot(for: url, names: ["alpha.txt"])
        })
        defer { coordinator.tearDown() }
        XCTAssertTrue(coordinator.navigateToDirectory(directoryURL, showError: true, budget: .milliseconds(20)))

        host = nil
        XCTAssertNil(weakHost)
        gate.signal()
        waitForPendingSnapshots(on: queue)

        XCTAssertTrue(coordinator.items.isEmpty)
    }

    func testPaneDeinitWithoutLoadedViewDoesNotInitializeCoordinators() {
        weak var weakPane: FileManagerPaneController?
        autoreleasepool {
            let pane = FileManagerPaneController()
            weakPane = pane
        }
        XCTAssertNil(weakPane)
    }

    func testPaneDeinitAfterLoadingFileSystemViewDoesNotInitializeArchiveCoordinator() {
        weak var weakPane: FileManagerPaneController?
        autoreleasepool {
            let pane = FileManagerPaneController()
            _ = pane.view
            weakPane = pane
        }
        XCTAssertNil(weakPane)
    }

    private func makeDirectory(named name: String) throws -> URL {
        try makeTemporaryDirectory(named: name, prefix: "ShichiZipDirectoryCoordinatorTests")
    }

    private nonisolated static func snapshot(for url: URL, names: [String]) -> FileManagerDirectorySnapshot {
        FileManagerDirectorySnapshot(url: url, items: names.map { FileSystemItem(url: url.appendingPathComponent($0), resourceValues: nil) })
    }

    private func makeCoordinator(host: HostSpy,
                                 snapshotQueue: DispatchQueue = DispatchQueue(label: "DirectoryCoordinatorTests.snapshot"),
                                 makeSnapshot: @escaping @Sendable (URL) throws -> FileManagerDirectorySnapshot = { try FileManagerDirectorySnapshot.make(for: $0) },
                                 showsHiddenFiles: @escaping () -> Bool = { false }) -> FileManagerPaneDirectoryCoordinator
    {
        let coordinator = FileManagerPaneDirectoryCoordinator(host: host,
                                                              snapshotQueue: snapshotQueue,
                                                              makeSnapshot: makeSnapshot,
                                                              showsHiddenFiles: showsHiddenFiles)
        host.coordinator = coordinator
        return coordinator
    }

    private func waitForPendingSnapshots(on queue: DispatchQueue) {
        let drained = expectation(description: "pending snapshots delivered")
        queue.async {
            DispatchQueue.main.async { drained.fulfill() }
        }
        wait(for: [drained], timeout: 2)
    }

    @MainActor
    private final class HostSpy: FileManagerPaneDirectoryCoordinatorHost {
        enum Event: Equatable {
            case loading(Bool)
            case snapshot
            case visibility
            case navigation
            case selection
            case initialFailure
            case suspension
            case error
            case changedOnDisk
        }

        struct NavigationCompletion {
            let selection: FileManagerDirectorySelectionRestoration?
            let focusFileList: Bool
        }

        weak var coordinator: FileManagerPaneDirectoryCoordinator?
        var isViewLoaded = true
        var isInsideArchive = false
        var showsParentRow = false
        var selectionState = FileManagerFileSystemSelectionState.empty
        var events: [Event] = []
        var navigationCompletions: [NavigationCompletion] = []
        var restoredSelections: [FileManagerDirectorySelectionRestoration] = []
        var presentedDirectories: [URL] = []
        var errors: [Error] = []
        var snapshotAppliedExpectation: XCTestExpectation?

        func directorySelectionState() -> FileManagerFileSystemSelectionState {
            selectionState
        }

        func directoryContentsDidChange(_ change: FileManagerDirectoryContentsChange) {
            switch change {
            case .snapshot:
                events.append(.snapshot)
                if let coordinator {
                    presentedDirectories.append(coordinator.currentDirectory.standardizedFileURL)
                }
                snapshotAppliedExpectation?.fulfill()
                snapshotAppliedExpectation = nil
            case .visibility:
                events.append(.visibility)
            }
            coordinator?.sortItems(by: [])
        }

        func directoryNavigationDidFinish(selection: FileManagerDirectorySelectionRestoration?, focusFileList: Bool) {
            events.append(.navigation)
            navigationCompletions.append(NavigationCompletion(selection: selection, focusFileList: focusFileList))
        }

        func restoreDirectorySelection(_ selection: FileManagerDirectorySelectionRestoration) {
            events.append(.selection)
            restoredSelections.append(selection)
        }

        func directoryInitialLoadDidFail() {
            events.append(.initialFailure)
        }

        func directoryPresentationDidSuspend() {
            events.append(.suspension)
        }

        func showErrorAlert(_ error: Error) {
            events.append(.error)
            errors.append(error)
        }

        func setDirectoryLoadingVisible(_ visible: Bool) {
            events.append(.loading(visible))
        }

        func autoRefreshIfPossible() {
            events.append(.changedOnDisk)
        }
    }
}
