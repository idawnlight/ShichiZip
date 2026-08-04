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
    private let isViewLoaded: () -> Bool
    private let isInsideArchive: () -> Bool
    private let showsParentRow: () -> Bool
    private let selectedFileSystemItems: () -> [FileSystemItem]
    private let focusedFileSystemItemPath: () -> String?
    private let clearSuspendedState: () -> Void
    private let updatePathField: () -> Void
    private let updateStatusBar: () -> Void
    private let updateTableColumns: () -> Void
    private let sortCurrentItems: () -> Void
    private let reloadTableData: () -> Void
    private let focusFileList: () -> Void
    private let selectRows: (IndexSet) -> Void
    private let deselectRows: () -> Void
    private let scrollRow: (Int, FileManagerFileSystemSelectionScrollPlacement) -> Void
    private let showError: (Error) -> Void
    private let directoryDidChange: () -> Void
    private let setDirectoryLoadingVisible: (Bool) -> Void
    private let makeSnapshot: @Sendable (URL) throws -> FileManagerDirectorySnapshot
    private let showsHiddenFiles: () -> Bool

    private var snapshotGeneration = 0
    private var directoryWatcher: DirectoryWatcher?
    private var recentDirectories: [URL] = []

    private(set) var currentDirectory: URL
    private var allItems: [FileSystemItem] = []
    private(set) var items: [FileSystemItem] = []

    init(initialDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         snapshotQueue: DispatchQueue = DispatchQueue(label: FileManagerPaneDirectoryCoordinator.snapshotQueueLabel,
                                                      qos: .userInitiated),
         isViewLoaded: @escaping () -> Bool,
         isInsideArchive: @escaping () -> Bool,
         showsParentRow: @escaping () -> Bool,
         selectedFileSystemItems: @escaping () -> [FileSystemItem],
         focusedFileSystemItemPath: @escaping () -> String?,
         clearSuspendedState: @escaping () -> Void,
         updatePathField: @escaping () -> Void,
         updateStatusBar: @escaping () -> Void,
         updateTableColumns: @escaping () -> Void,
         sortCurrentItems: @escaping () -> Void,
         reloadTableData: @escaping () -> Void,
         focusFileList: @escaping () -> Void,
         selectRows: @escaping (IndexSet) -> Void,
         deselectRows: @escaping () -> Void,
         scrollRow: @escaping (Int, FileManagerFileSystemSelectionScrollPlacement) -> Void,
         showError: @escaping (Error) -> Void,
         directoryDidChange: @escaping () -> Void,
         setDirectoryLoadingVisible: @escaping (Bool) -> Void = { _ in },
         makeSnapshot: @escaping @Sendable (URL) throws -> FileManagerDirectorySnapshot = { try FileManagerDirectorySnapshot.make(for: $0) },
         showsHiddenFiles: @escaping () -> Bool = { SZSettings.bool(.showHiddenFiles) })
    {
        currentDirectory = initialDirectory
        self.snapshotQueue = snapshotQueue
        self.isViewLoaded = isViewLoaded
        self.isInsideArchive = isInsideArchive
        self.showsParentRow = showsParentRow
        self.selectedFileSystemItems = selectedFileSystemItems
        self.focusedFileSystemItemPath = focusedFileSystemItemPath
        self.clearSuspendedState = clearSuspendedState
        self.updatePathField = updatePathField
        self.updateStatusBar = updateStatusBar
        self.updateTableColumns = updateTableColumns
        self.sortCurrentItems = sortCurrentItems
        self.reloadTableData = reloadTableData
        self.focusFileList = focusFileList
        self.selectRows = selectRows
        self.deselectRows = deselectRows
        self.scrollRow = scrollRow
        self.showError = showError
        self.directoryDidChange = directoryDidChange
        self.setDirectoryLoadingVisible = setDirectoryLoadingVisible
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
        setDirectoryLoadingVisible(false)

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
                self.showError(error)
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
                    self.showError(error)
                }
                return false
            }
        }

        setDirectoryLoadingVisible(true)
        return true
    }

    @discardableResult
    private func applyNavigationSnapshot(_ snapshot: FileManagerDirectorySnapshot,
                                         selectionState: FileManagerFileSystemSelectionState?,
                                         focusAfterLoad: Bool) -> Bool
    {
        guard !isInsideArchive() else { return false }

        applyDirectorySnapshot(snapshot)
        clearSuspendedState()
        if let selectionState {
            restoreSelectionState(selectionState)
        }
        if focusAfterLoad {
            focusFileList()
        }
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
        guard !isInsideArchive() else { return }
        let selectionState = captureSelectionState()
        items = visibleItems(from: allItems)
        sortCurrentItems()
        reloadTableData()
        updateStatusBar()
        restoreSelectionState(selectionState)
    }

    func loadInitialDirectory(_ url: URL) {
        do {
            let snapshot = try makeSnapshot(url.standardizedFileURL)
            applyDirectorySnapshot(snapshot)
        } catch {
            currentDirectory = url.standardizedFileURL
            updatePathField()
            updateStatusBar()
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
        reloadTableData()
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
        guard isViewLoaded(), !isInsideArchive() else {
            return .empty
        }

        let selectedItems = selectedFileSystemItems()
        let selectedPaths = Set(selectedItems.map(\.url.standardizedFileURL.path))
        let focusedPath = focusedFileSystemItemPath() ?? selectedItems.first?.url.standardizedFileURL.path
        return FileManagerFileSystemSelectionState(selectedPaths: selectedPaths,
                                                   focusedPath: focusedPath,
                                                   scrollPlacement: .visible)
    }

    private func restoreSelectionState(_ selectionState: FileManagerFileSystemSelectionState) {
        guard !isInsideArchive() else { return }

        let baseRow = showsParentRow() ? 1 : 0
        let selectedRows = IndexSet(items.enumerated().compactMap { index, item in
            selectionState.selectedPaths.contains(item.url.standardizedFileURL.path) ? baseRow + index : nil
        })

        if selectedRows.isEmpty {
            deselectRows()
            return
        }

        selectRows(selectedRows)

        if let focusedPath = selectionState.focusedPath,
           let row = items.firstIndex(where: { $0.url.standardizedFileURL.path == focusedPath }).map({ baseRow + $0 })
        {
            scrollRow(row, selectionState.scrollPlacement)
        } else if let firstRow = selectedRows.first {
            scrollRow(firstRow, selectionState.scrollPlacement)
        }
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
            setDirectoryLoadingVisible(false)
            switch result {
            case let .success(snapshot):
                applyNavigationSnapshot(snapshot,
                                        selectionState: selectionState,
                                        focusAfterLoad: focusAfterLoad)
            case let .failure(error):
                if showError {
                    self.showError(error)
                }
            }

        case let .autoRefresh(selectionState):
            guard case let .success(snapshot) = result, !isInsideArchive() else { return }
            guard snapshot.url.standardizedFileURL == currentDirectory.standardizedFileURL else { return }
            guard stableSnapshotItems(snapshot.items) != stableSnapshotItems(allItems) else { return }
            applyDirectorySnapshot(snapshot, recordVisit: false)
            restoreSelectionState(selectionState)

        case let .refresh(selectionState):
            guard case let .success(snapshot) = result, !isInsideArchive() else { return }
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
        updatePathField()
        allItems = snapshot.items
        items = visibleItems(from: allItems)
        updateTableColumns()
        sortCurrentItems()
        reloadTableData()
        updateStatusBar()
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
            self?.directoryDidChange()
        }
        directoryWatcher = watcher
    }

    private func tearDownDirectoryWatcher() {
        directoryWatcher?.stop()
        directoryWatcher = nil
    }
}
