import Foundation
import os

private struct FileManagerDirectorySnapshotStoredResult: @unchecked Sendable {
    let result: Result<FileManagerDirectorySnapshot, Error>
}

/// Hands a directory snapshot from the background queue back to the main actor. `state` owns
/// synchronization; `ready` lets a budgeted navigation wait briefly for an inline result.
private final class FileManagerDirectorySnapshotBox: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: nil as FileManagerDirectorySnapshotStoredResult?)
    let ready = DispatchSemaphore(value: 0)

    func store(_ result: Result<FileManagerDirectorySnapshot, Error>) {
        let stored = FileManagerDirectorySnapshotStoredResult(result: result)
        state.withLock { $0 = stored }
        ready.signal()
    }

    /// Returns the stored result once, then clears it so the inline and asynchronous deliveries
    /// never both apply the same snapshot.
    func take() -> Result<FileManagerDirectorySnapshot, Error>? {
        state.withLock { value in
            defer { value = nil }
            return value?.result
        }
    }
}

private extension Duration {
    var timeoutSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

enum FileManagerFileSystemSelectionScrollPlacement {
    case visible
    case centered
}

struct FileManagerFileSystemSelectionState {
    let selectedPaths: Set<String>
    let focusedPath: String?
    let scrollPlacement: FileManagerFileSystemSelectionScrollPlacement

    static let empty = FileManagerFileSystemSelectionState(selectedPaths: [],
                                                           focusedPath: nil,
                                                           scrollPlacement: .visible)
}

struct FileManagerDirectorySelectionRestoration {
    let rows: IndexSet
    let focusedRow: Int?
    let scrollPlacement: FileManagerFileSystemSelectionScrollPlacement
}

enum FileManagerDirectoryContentsChange {
    case snapshot
    case visibility
}

@MainActor
protocol FileManagerPaneDirectoryCoordinatorHost: AnyObject {
    var isViewLoaded: Bool { get }
    var isInsideArchive: Bool { get }
    var showsParentRow: Bool { get }

    func directorySelectionState() -> FileManagerFileSystemSelectionState
    /// Update the path and columns, then sort before reloading the table and status for a new snapshot.
    /// A visibility change keeps the current path and columns.
    func directoryContentsDidChange(_ change: FileManagerDirectoryContentsChange)
    /// Clear suspended presentation, restore selection when supplied, then optionally focus the list.
    func directoryNavigationDidFinish(selection: FileManagerDirectorySelectionRestoration?,
                                      focusFileList: Bool)
    func restoreDirectorySelection(_ selection: FileManagerDirectorySelectionRestoration)
    func directoryInitialLoadDidFail()
    func directoryPresentationDidSuspend()
    func showErrorAlert(_ error: Error)
    func setDirectoryLoadingVisible(_ visible: Bool)
    func autoRefreshIfPossible()
}

@MainActor
final class FileManagerPaneDirectoryCoordinator {
    private enum SnapshotPurpose {
        case refresh(selectionState: FileManagerFileSystemSelectionState)
        case autoRefresh(selectionState: FileManagerFileSystemSelectionState)
        case navigate(selectionState: FileManagerFileSystemSelectionState?,
                      focusAfterLoad: Bool,
                      showError: Bool)
    }

    /// How long a user-initiated navigation blocks for an inline snapshot before falling back to an
    /// asynchronous load with a loading indicator. Below the ~100ms perceptible threshold, so fast
    /// directories still apply atomically with no visible loading state.
    static let navigationBudget: Duration = .milliseconds(100)

    private static var snapshotQueueLabel: String {
        "\(Bundle.main.bundleIdentifier ?? "ShichiZip").file-manager.directory-snapshot"
    }

    private let snapshotQueue: DispatchQueue
    private weak var host: (any FileManagerPaneDirectoryCoordinatorHost)?
    private let makeSnapshot: @Sendable (URL) throws -> FileManagerDirectorySnapshot
    private let showsHiddenFiles: () -> Bool

    private var snapshotGeneration = 0
    private var directoryWatcher: DirectoryWatcher?
    private var recentDirectories: [URL] = []

    private(set) var currentDirectory: URL
    private var allItems: [FileSystemItem] = []
    private(set) var items: [FileSystemItem] = []

    init(host: any FileManagerPaneDirectoryCoordinatorHost,
         initialDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         snapshotQueue: DispatchQueue = DispatchQueue(label: FileManagerPaneDirectoryCoordinator.snapshotQueueLabel,
                                                      qos: .userInitiated),
         makeSnapshot: @escaping @Sendable (URL) throws -> FileManagerDirectorySnapshot = { try FileManagerDirectorySnapshot.make(for: $0) },
         showsHiddenFiles: @escaping () -> Bool = { SZSettings.bool(.showHiddenFiles) })
    {
        self.host = host
        currentDirectory = initialDirectory
        self.snapshotQueue = snapshotQueue
        self.makeSnapshot = makeSnapshot
        self.showsHiddenFiles = showsHiddenFiles
    }

    var hasRecentDirectoryHistory: Bool {
        !recentDirectories.isEmpty
    }

    func recentDirectoryHistory() -> [URL] {
        recentDirectories
    }

    func setRecentDirectoryHistory(_ entries: [URL]) {
        recentDirectories = FileManagerRecentDirectoryHistory.normalized(entries)
    }

    func sortItems(by descriptors: [NSSortDescriptor]) {
        FileManagerItemSorting.sort(&items,
                                    by: descriptors)
    }

    @discardableResult
    func loadDirectory(_ url: URL,
                       showError: Bool = true,
                       budget: Duration? = nil) -> Bool
    {
        navigateToDirectory(url,
                            showError: showError,
                            budget: budget)
    }

    @discardableResult
    func navigateToDirectory(_ url: URL,
                             showError: Bool,
                             selectionState: FileManagerFileSystemSelectionState? = nil,
                             focusAfterLoad: Bool = false,
                             budget: Duration? = nil) -> Bool
    {
        cancelPendingSnapshot()
        host?.setDirectoryLoadingVisible(false)

        let standardizedURL = url.standardizedFileURL

        guard let budget else {
            return navigateSynchronously(to: standardizedURL,
                                         showError: showError,
                                         selectionState: selectionState,
                                         focusAfterLoad: focusAfterLoad)
        }

        return navigateWithinBudget(to: standardizedURL,
                                    showError: showError,
                                    selectionState: selectionState,
                                    focusAfterLoad: focusAfterLoad,
                                    budget: budget)
    }

    private func navigateSynchronously(to url: URL,
                                       showError: Bool,
                                       selectionState: FileManagerFileSystemSelectionState?,
                                       focusAfterLoad: Bool) -> Bool
    {
        do {
            let snapshot = try makeSnapshot(url)
            return applyNavigationSnapshot(snapshot,
                                           selectionState: selectionState,
                                           focusAfterLoad: focusAfterLoad)
        } catch {
            if showError {
                host?.showErrorAlert(error)
            }
            return false
        }
    }

    private func navigateWithinBudget(to url: URL,
                                      showError: Bool,
                                      selectionState: FileManagerFileSystemSelectionState?,
                                      focusAfterLoad: Bool,
                                      budget: Duration) -> Bool
    {
        snapshotGeneration += 1
        let generation = snapshotGeneration
        let make = makeSnapshot
        let box = FileManagerDirectorySnapshotBox()
        let purpose = SnapshotPurpose.navigate(selectionState: selectionState,
                                               focusAfterLoad: focusAfterLoad,
                                               showError: showError)

        snapshotQueue.async {
            box.store(Result { try make(url) })
            DispatchQueue.main.async { [weak self = self] in
                MainActor.assumeIsolated {
                    self?.finishDirectorySnapshot(box.take(),
                                                  generation: generation,
                                                  purpose: purpose)
                }
            }
        }

        if box.ready.wait(timeout: .now() + budget.timeoutSeconds) == .success,
           let result = box.take()
        {
            snapshotGeneration += 1
            switch result {
            case let .success(snapshot):
                return applyNavigationSnapshot(snapshot,
                                               selectionState: selectionState,
                                               focusAfterLoad: focusAfterLoad)
            case let .failure(error):
                if showError {
                    host?.showErrorAlert(error)
                }
                return false
            }
        }

        host?.setDirectoryLoadingVisible(true)
        return true
    }

    @discardableResult
    private func applyNavigationSnapshot(_ snapshot: FileManagerDirectorySnapshot,
                                         selectionState: FileManagerFileSystemSelectionState?,
                                         focusAfterLoad: Bool) -> Bool
    {
        guard let host, !host.isInsideArchive else { return false }

        applyDirectorySnapshot(snapshot)
        host.directoryNavigationDidFinish(selection: selectionState.flatMap { selectionRestoration(for: $0) },
                                          focusFileList: focusAfterLoad)
        return true
    }

    func reloadCurrentDirectoryPreservingSelection() {
        scheduleDirectorySnapshot(for: currentDirectory,
                                  purpose: .refresh(selectionState: captureSelectionState()))
    }

    func autoRefreshCurrentDirectoryIfNeeded() {
        scheduleDirectorySnapshot(for: currentDirectory,
                                  purpose: .autoRefresh(selectionState: captureSelectionState()))
    }

    func reapplyHiddenFileVisibility() {
        guard host?.isInsideArchive == false else { return }
        let selectionState = captureSelectionState()
        items = visibleItems(from: allItems)
        host?.directoryContentsDidChange(.visibility)
        restoreSelectionState(selectionState)
    }

    func loadInitialDirectory(_ url: URL) {
        do {
            let snapshot = try makeSnapshot(url.standardizedFileURL)
            applyDirectorySnapshot(snapshot)
        } catch {
            currentDirectory = url.standardizedFileURL
            host?.directoryInitialLoadDidFail()
        }
    }

    func consumeDirectoryChange() -> Bool {
        directoryWatcher?.wasChanged() == true
    }

    func prepareForArchivePresentation(hostDirectory: URL) {
        currentDirectory = hostDirectory
        recordDirectoryVisit(hostDirectory)
        cancelPendingSnapshot()
        tearDownDirectoryWatcher()
        allItems.removeAll()
        items.removeAll()
    }

    func prepareForSuspension() {
        tearDownDirectoryWatcher()
        cancelPendingSnapshot()
        allItems.removeAll()
        items.removeAll()
        host?.directoryPresentationDidSuspend()
    }

    func tearDown() {
        tearDownDirectoryWatcher()
        cancelPendingSnapshot()
    }

    private func visibleItems(from source: [FileSystemItem]) -> [FileSystemItem] {
        showsHiddenFiles() ? source : source.filter { !$0.isHidden }
    }

    private func stableSnapshotItems(_ items: [FileSystemItem]) -> [FileSystemItem] {
        items.sorted { $0.url.standardizedFileURL.path < $1.url.standardizedFileURL.path }
    }

    private func captureSelectionState() -> FileManagerFileSystemSelectionState {
        guard let host, host.isViewLoaded, !host.isInsideArchive else {
            return .empty
        }
        return host.directorySelectionState()
    }

    private func restoreSelectionState(_ selectionState: FileManagerFileSystemSelectionState) {
        guard let selection = selectionRestoration(for: selectionState) else { return }
        host?.restoreDirectorySelection(selection)
    }

    private func selectionRestoration(for selectionState: FileManagerFileSystemSelectionState) -> FileManagerDirectorySelectionRestoration? {
        guard let host, !host.isInsideArchive else { return nil }

        let baseRow = host.showsParentRow ? 1 : 0
        let selectedRows = IndexSet(items.enumerated().compactMap { index, item in
            selectionState.selectedPaths.contains(item.url.standardizedFileURL.path) ? baseRow + index : nil
        })
        let focusedRow: Int? = if selectedRows.isEmpty {
            nil
        } else if let focusedPath = selectionState.focusedPath,
                  let index = items.firstIndex(where: { $0.url.standardizedFileURL.path == focusedPath })
        {
            baseRow + index
        } else {
            selectedRows.first
        }
        return FileManagerDirectorySelectionRestoration(rows: selectedRows,
                                                        focusedRow: focusedRow,
                                                        scrollPlacement: selectionState.scrollPlacement)
    }

    private func scheduleDirectorySnapshot(for url: URL,
                                           purpose: SnapshotPurpose)
    {
        snapshotGeneration += 1
        let generation = snapshotGeneration
        let make = makeSnapshot

        snapshotQueue.async {
            let result = Result {
                try make(url)
            }

            DispatchQueue.main.async { [weak self = self] in
                MainActor.assumeIsolated {
                    self?.finishDirectorySnapshot(result,
                                                  generation: generation,
                                                  purpose: purpose)
                }
            }
        }
    }

    private func cancelPendingSnapshot() {
        snapshotGeneration += 1
    }

    private func finishDirectorySnapshot(_ result: Result<FileManagerDirectorySnapshot, Error>?,
                                         generation: Int,
                                         purpose: SnapshotPurpose)
    {
        guard generation == snapshotGeneration, let result else { return }

        switch purpose {
        case let .navigate(selectionState, focusAfterLoad, showError):
            host?.setDirectoryLoadingVisible(false)
            switch result {
            case let .success(snapshot):
                applyNavigationSnapshot(snapshot,
                                        selectionState: selectionState,
                                        focusAfterLoad: focusAfterLoad)
            case let .failure(error):
                if showError {
                    host?.showErrorAlert(error)
                }
            }

        case let .autoRefresh(selectionState):
            guard case let .success(snapshot) = result, host?.isInsideArchive == false else { return }
            guard snapshot.url.standardizedFileURL == currentDirectory.standardizedFileURL else { return }
            guard stableSnapshotItems(snapshot.items) != stableSnapshotItems(allItems) else { return }
            applyDirectorySnapshot(snapshot, recordVisit: false)
            restoreSelectionState(selectionState)

        case let .refresh(selectionState):
            guard case let .success(snapshot) = result, host?.isInsideArchive == false else { return }
            guard snapshot.url.standardizedFileURL == currentDirectory.standardizedFileURL else { return }
            applyDirectorySnapshot(snapshot, recordVisit: false)
            restoreSelectionState(selectionState)
        }
    }

    private func applyDirectorySnapshot(_ snapshot: FileManagerDirectorySnapshot,
                                        recordVisit: Bool = true)
    {
        currentDirectory = snapshot.url
        if recordVisit {
            recordDirectoryVisit(snapshot.url)
        }
        allItems = snapshot.items
        items = visibleItems(from: allItems)
        host?.directoryContentsDidChange(.snapshot)
        installDirectoryWatcher(for: snapshot.url)
    }

    private func recordDirectoryVisit(_ url: URL) {
        recentDirectories = FileManagerRecentDirectoryHistory.recordingVisit(url,
                                                                             in: recentDirectories)
    }

    private func installDirectoryWatcher(for url: URL) {
        directoryWatcher?.stop()
        let watcher = DirectoryWatcher(directory: url)
        watcher.onChange = { [weak self] in
            self?.host?.autoRefreshIfPossible()
        }
        directoryWatcher = watcher
    }

    private func tearDownDirectoryWatcher() {
        directoryWatcher?.stop()
        directoryWatcher = nil
    }
}
