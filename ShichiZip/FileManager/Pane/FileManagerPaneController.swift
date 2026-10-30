import Cocoa
import os

@MainActor
final class FileManagerPaneActivityState {
    private var navigationGeneration = 0
    private var navigationTransitionToken: UUID?
    private var closePreparationTokens = Set<UUID>()

    var isClosePreparationActive: Bool {
        !closePreparationTokens.isEmpty
    }

    var isNavigationTransitionActive: Bool {
        navigationTransitionToken != nil
    }

    func beginNavigation() -> Int? {
        guard !isClosePreparationActive,
              navigationTransitionToken == nil
        else {
            return nil
        }
        navigationGeneration &+= 1
        return navigationGeneration
    }

    func isCurrentNavigation(_ generation: Int) -> Bool {
        !isClosePreparationActive && generation == navigationGeneration
    }

    func beginClosePreparation() -> UUID {
        let token = UUID()
        closePreparationTokens.insert(token)
        navigationGeneration &+= 1
        return token
    }

    func endClosePreparation(_ token: UUID) {
        closePreparationTokens.remove(token)
    }

    func containsClosePreparation(_ token: UUID) -> Bool {
        closePreparationTokens.contains(token)
    }

    func beginNavigationTransition(for generation: Int) -> UUID? {
        guard isCurrentNavigation(generation),
              navigationTransitionToken == nil
        else {
            return nil
        }
        let token = UUID()
        navigationTransitionToken = token
        return token
    }

    func beginCurrentNavigationTransition() -> UUID? {
        beginNavigationTransition(for: navigationGeneration)
    }

    func endNavigationTransition(_ token: UUID) {
        guard navigationTransitionToken == token else { return }
        navigationTransitionToken = nil
    }
}

/// Single pane of the file manager — displays file system contents
class FileManagerPaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate, FileManagerPaneTransferHost {
    // MARK: - Types

    private static let addressBarIconSize: CGFloat = 14

    // MARK: - Properties

    weak var delegate: FileManagerPaneDelegate?
    weak var archiveCoordinationProvider: (any FileManagerArchiveCoordinationProviding)?

    private var locationIconView: NSImageView!
    private var pathField: NSTextField!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var statusView: FileManagerPaneStatusView!
    private var directoryLoadingOverlay: NSView?
    private var listViewCoordinator: FileManagerPaneListViewCoordinator!
    private var menuHandler: FileManagerPaneMenuHandler!
    private var eventCoordinator: FileManagerPaneEventCoordinator?
    private let iconProvider = FileManagerPaneIconProvider(iconSize: NSSize(width: 16, height: 16))
    private let transferCoordinator = FileManagerPaneTransferCoordinator()
    private var iconSize: NSSize {
        iconProvider.iconSize
    }

    private let listRowHeight: CGFloat = 22
    private var suspensionCoordinatorStorage: FileManagerPaneSuspensionCoordinator?
    private let activityState = FileManagerPaneActivityState()
    private var deactivationPreparationToken: UUID?
    private var reactivatesAfterCloseCancellation = false

    var isSuspended: Bool {
        suspensionCoordinatorStorage?.isSuspended ?? false
    }

    var currentDirectory: URL {
        directoryCoordinator.currentDirectory
    }

    var currentDirectoryURL: URL {
        currentDirectory
    }

    private var directoryCoordinatorStorage: FileManagerPaneDirectoryCoordinator?
    private var directoryCoordinator: FileManagerPaneDirectoryCoordinator {
        if let directoryCoordinatorStorage {
            return directoryCoordinatorStorage
        }

        let coordinator = FileManagerPaneDirectoryCoordinator(host: self)
        directoryCoordinatorStorage = coordinator
        return coordinator
    }

    private let archiveSession = FileManagerArchiveSession()
    private var archiveCoordinatorStorage: FileManagerPaneArchiveCoordinator?
    var isInsideArchive: Bool {
        archiveSession.isInsideArchive
    }

    private var archiveCoordinator: FileManagerPaneArchiveCoordinator {
        if let archiveCoordinatorStorage {
            return archiveCoordinatorStorage
        }

        let coordinator = FileManagerPaneArchiveCoordinator(
            archiveSession: archiveSession,
            observerIdentifier: ObjectIdentifier(self),
            host: self,
        )
        archiveCoordinatorStorage = coordinator
        return coordinator
    }

    var supportsInPlaceArchiveMutation: Bool {
        archiveCoordinator.supportsInPlaceMutation()
    }

    private lazy var externalOpenService = FileManagerPaneExternalOpenService(
        scheduleCleanup: { [archiveSession] temporaryDirectory, application in
            archiveSession.itemWorkflowService.scheduleCleanup(temporaryDirectory,
                                                               when: application)
        },
        cleanupTemporaryDirectory: { [archiveSession] temporaryDirectory in
            archiveSession.cleanupTemporaryDirectory(temporaryDirectory)
        },
        showError: { [weak self] error in
            self?.showErrorAlert(error)
        },
    )

    private var suspensionCoordinator: FileManagerPaneSuspensionCoordinator {
        if let suspensionCoordinatorStorage {
            return suspensionCoordinatorStorage
        }

        let coordinator = FileManagerPaneSuspensionCoordinator(host: self)
        suspensionCoordinatorStorage = coordinator
        return coordinator
    }

    private var showsRealFileIcons: Bool {
        SZSettings.bool(.showRealFileIcons)
    }

    var showsParentRow: Bool {
        guard SZSettings.bool(.showDots) else {
            return false
        }
        if isInsideArchive {
            return true
        }
        return currentDirectory.path != currentDirectory.deletingLastPathComponent().path
    }

    private var tableModel: FileManagerPaneTableModel {
        if isInsideArchive {
            return FileManagerPaneTableModel(archiveItems: archiveSession.displayItems,
                                             showsParentRow: showsParentRow)
        }
        return FileManagerPaneTableModel(fileSystemItems: directoryCoordinator.items,
                                         showsParentRow: showsParentRow)
    }

    // MARK: - Lifecycle

    isolated deinit {
        eventCoordinator?.tearDown()

        directoryCoordinatorStorage?.tearDown()
        cancelPendingArchiveRefresh()

        if archiveSession.isInsideArchive {
            SZLog.error("FileManagerPane",
                        "Pane deinitialized before asynchronous archive close completed")
            assertionFailure("FileManager pane must close its archive stack before deinitialization")
        } else {
            archiveSession.cleanupAllTemporaryDirectories()
        }
    }

    // MARK: - View Setup

    override func loadView() {
        let paneView = FileManagerPaneView(currentDirectory: currentDirectory,
                                           addressBarIconSize: Self.addressBarIconSize,
                                           listRowHeight: listRowHeight)

        connectPaneView(paneView)
        installEventCoordinator()
        applyFileManagerSettings()

        view = paneView
        directoryCoordinator.loadInitialDirectory(currentDirectory)
    }

    private func connectPaneView(_ paneView: FileManagerPaneView) {
        paneView.upButton.target = self
        paneView.upButton.action = #selector(goUpClicked(_:))

        locationIconView = paneView.locationIconView
        configurePathField(paneView.pathField)
        configureTableView(paneView.tableView)
        scrollView = paneView.scrollView
        statusView = paneView.statusView
    }

    private func configurePathField(_ textField: NSTextField) {
        pathField = textField
        pathField.target = self
        pathField.action = #selector(pathFieldSubmitted(_:))
        pathField.delegate = self
    }

    private func configureTableView(_ fileTableView: FileManagerTableView) {
        tableView = fileTableView
        listViewCoordinator = FileManagerPaneListViewCoordinator(
            tableView: tableView,
            currentLocation: { [weak self] in
                self?.currentListViewLocation()
                    ?? FileManagerPaneListViewLocation(columns: FileManagerColumn.fileSystemColumns,
                                                       folderTypeID: FileManagerViewPreferences.fileSystemListViewFolderTypeID)
            },
            sortItems: { [weak self] descriptors in
                guard let self else { return }
                if isInsideArchive {
                    archiveSession.sortDisplayItems(by: descriptors)
                } else {
                    directoryCoordinator.sortItems(by: descriptors)
                }
            },
            reloadTableData: { [weak self] in
                self?.tableView.reloadData()
            },
        )
        menuHandler = FileManagerPaneMenuHandler(
            tableView: tableView,
            activatePane: { [weak self] in
                guard let self else { return }
                delegate?.paneDidBecomeActive(self)
            },
            populateColumnHeaderMenu: { [weak self] menu in
                self?.populateColumnHeaderMenu(menu)
            },
        )

        fileTableView.contextMenuPreparationHandler = { [weak self] clickedRow in
            guard let self else { return }
            menuHandler.prepareContextMenu(forClickedRow: clickedRow,
                                           presentationWindow: view.window)
        }
        fileTableView.quickLookPreviewHandler = { [weak self] in
            guard let self else { return }
            delegate?.paneDidRequestQuickLook(self)
        }
        fileTableView.shortcutEventHandler = { [weak self] event in
            self?.handleShortcutEvent(event) ?? false
        }
        listViewCoordinator.updateForCurrentLocation()
        tableView.headerView?.menu = menuHandler.makeColumnHeaderMenu(delegate: self)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        refreshContextMenu()
        SZLog.debug("ShichiZip", "File manager pane context menu set with \(tableView.menu?.items.count ?? 0) items")

        tableView.registerForDraggedTypes([.fileURL] + FileOperationDropResolver.promisedFilePasteboardTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
    }

    private func installEventCoordinator() {
        eventCoordinator = FileManagerPaneEventCoordinator(
            host: self,
            tableView: tableView,
            scrollView: scrollView,
        )
    }

    // MARK: - Navigation

    @discardableResult
    func loadDirectory(_ url: URL,
                       showError: Bool = true,
                       budget: Duration? = nil,
                       expectedNavigationGeneration: Int? = nil) -> Bool
    {
        guard prepareNavigation(expectedGeneration: expectedNavigationGeneration) else {
            return false
        }
        return directoryCoordinator.loadDirectory(url,
                                                  showError: showError,
                                                  budget: budget)
    }

    @discardableResult
    private func navigateToDirectory(_ url: URL,
                                     showError: Bool,
                                     selectionState: FileManagerFileSystemSelectionState? = nil,
                                     focusAfterLoad: Bool = false,
                                     budget: Duration? = nil,
                                     expectedNavigationGeneration: Int) -> Bool
    {
        guard isCurrentNavigation(expectedNavigationGeneration) else {
            return false
        }
        return directoryCoordinator.navigateToDirectory(url,
                                                        showError: showError,
                                                        selectionState: selectionState,
                                                        focusAfterLoad: focusAfterLoad,
                                                        budget: budget)
    }

    func beginNavigation() -> Int? {
        guard let generation = activityState.beginNavigation() else { return nil }
        archiveCoordinatorStorage?.invalidatePendingArchiveOpen()
        return generation
    }

    func isCurrentNavigation(_ generation: Int) -> Bool {
        activityState.isCurrentNavigation(generation)
    }

    func beginNavigationTransition(_ generation: Int) -> UUID? {
        activityState.beginNavigationTransition(for: generation)
    }

    func endNavigationTransition(_ token: UUID) {
        activityState.endNavigationTransition(token)
        reactivateAfterCloseCancellationIfPossible()
    }

    private func prepareNavigation(expectedGeneration: Int?) -> Bool {
        if let expectedGeneration {
            return isCurrentNavigation(expectedGeneration)
        }
        return beginNavigation() != nil
    }

    func setDirectoryLoadingVisible(_ visible: Bool) {
        if visible {
            showDirectoryLoadingOverlay()
        } else {
            directoryLoadingOverlay?.removeFromSuperview()
            directoryLoadingOverlay = nil
        }
    }

    private func showDirectoryLoadingOverlay() {
        guard isViewLoaded, directoryLoadingOverlay == nil else { return }

        let overlay = NSView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor
        overlay.setAccessibilityIdentifier("fileManager.directoryLoadingOverlay")

        let spinner = NSProgressIndicator()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        overlay.addSubview(spinner)

        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])

        directoryLoadingOverlay = overlay
    }

    private func reloadCurrentDirectoryPreservingSelection() {
        directoryCoordinator.reloadCurrentDirectoryPreservingSelection()
    }

    func autoRefreshCurrentDirectoryIfNeeded() {
        directoryCoordinator.autoRefreshCurrentDirectoryIfNeeded()
    }

    private func currentListViewLocation() -> FileManagerPaneListViewLocation {
        if let level = archiveSession.currentLevel {
            return FileManagerPaneListViewLocation(columns: FileManagerColumn.archiveColumns(entryProperties: level.entryProperties),
                                                   folderTypeID: FileManagerViewPreferences.archiveListViewFolderTypeID(formatName: level.archive.formatName))
        }
        return FileManagerPaneListViewLocation(columns: FileManagerColumn.fileSystemColumns,
                                               folderTypeID: FileManagerViewPreferences.fileSystemListViewFolderTypeID)
    }

    private func updateTableColumnsForCurrentLocation() {
        guard isViewLoaded else { return }
        listViewCoordinator.updateForCurrentLocation()
    }

    private func refreshColumnTitles() {
        listViewCoordinator.refreshColumnTitles()
    }

    func handleTableColumnLayoutDidChange() {
        listViewCoordinator.handleColumnLayoutDidChange()
    }

    private func clearSuspendedState() {
        suspensionCoordinatorStorage?.clearSuspendedState()
    }

    // MARK: - Pane Refresh And Focus

    func refresh() {
        if isInsideArchive {
            let selectedPaths = selectedArchiveItems().map { normalizeArchivePath($0.path) }
            reloadCurrentArchiveEntries(selectingPaths: selectedPaths)
        } else {
            reloadCurrentDirectoryPreservingSelection()
        }
    }

    func autoRefreshIfPossible() {
        guard isViewLoaded else { return }
        guard FileManagerViewPreferences.autoRefreshEnabled else { return }
        guard !isInsideArchive else { return }
        guard directoryCoordinator.consumeDirectoryChange() else { return }
        guard let eventCoordinator else {
            autoRefreshCurrentDirectoryIfNeeded()
            return
        }
        eventCoordinator.autoRefreshWhenPossible()
    }

    func reloadPresentedValues() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        updateStatusBar()
    }

    func focusFileList() {
        delegate?.paneDidBecomeActive(self)
        returnFocusToFileList()
    }

    var preferredInitialFirstResponder: NSView {
        tableView
    }

    var isVirtualLocation: Bool {
        isInsideArchive
    }

    // MARK: - Archive Mutation Targets

    func currentArchiveMutationTarget() -> (archive: SZArchive, subdir: String)? {
        archiveCoordinator.currentMutationTarget()
    }

    func revalidatedArchiveMutationTarget(for target: (archive: SZArchive, subdir: String)) -> FileManagerLeasedArchiveMutationTarget? {
        archiveCoordinator.revalidatedMutationTarget(for: target)
    }

    func currentArchiveDestinationDisplayPath() -> String? {
        archiveCoordinator.currentDestinationDisplayPath(locationDisplayPath: currentLocationDisplayPath)
    }

    func currentArchiveMutationTarget(for archiveURL: URL,
                                      subdir: String) -> (archive: SZArchive, subdir: String)?
    {
        archiveCoordinator.mutationTarget(for: archiveURL,
                                          subdir: subdir)
    }

    func containsOpenArchive(at archiveURL: URL) -> Bool {
        archiveSession.containsArchive(at: archiveURL)
    }

    private func transferArchiveTarget(for archive: SZArchive,
                                       subdir: String) -> FileManagerPaneArchiveTransferTarget?
    {
        archiveCoordinator.transferTarget(for: archive,
                                          subdir: subdir)
    }

    // MARK: - Command Capabilities

    var canQuickLookSelection: Bool {
        !paneSelectionState.realItems.isEmpty
    }

    var paneCommandState: FileManagerPaneCommandState {
        FileManagerPaneCommandState(isInsideArchive: isInsideArchive,
                                    supportsInPlaceArchiveMutation: supportsInPlaceArchiveMutation,
                                    hasCurrentArchive: archiveSession.currentLevel != nil,
                                    canGoUp: isInsideArchive || currentDirectory.path != currentDirectory.deletingLastPathComponent().path,
                                    canSelectVisibleItems: numberOfRows(in: tableView) > (showsParentRow ? 1 : 0),
                                    canDeselectSelection: !tableView.selectedRowIndexes.isEmpty,
                                    canShowFoldersHistory: directoryCoordinator.hasRecentDirectoryHistory)
    }

    func selectedArchiveCandidateURL() -> URL? {
        paneSelectionState.archiveCandidateURL
    }

    func sourceArchiveURLForPostProcessing() -> URL? {
        if let level = archiveSession.currentLevel, level.temporaryDirectory == nil {
            return URL(fileURLWithPath: level.archivePath).standardizedFileURL
        }

        return selectedArchiveCandidateURL()?.standardizedFileURL
    }

    func quarantineSourceArchiveURLForExtraction() -> URL? {
        if let level = archiveSession.currentLevel {
            return URL(fileURLWithPath: level.archivePath).standardizedFileURL
        }

        return selectedArchiveCandidateURL()?.standardizedFileURL
    }

    // MARK: - Command Entry Points

    func openSelection() {
        guard !activityState.isClosePreparationActive else { return }
        FileManagerPaneOpenCommandSupport.openSelection(in: self)
    }

    func openSelectionInside(_ openMode: FileManagerArchiveOpenMode) {
        guard !activityState.isClosePreparationActive else { return }
        FileManagerPaneOpenCommandSupport.openSelectionInside(openMode,
                                                              in: self)
    }

    func openSelectionOutside() {
        guard !activityState.isClosePreparationActive else { return }
        FileManagerPaneOpenCommandSupport.openSelectionOutside(in: self)
    }

    var activationRow: Int {
        tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
    }

    var currentArchiveLevel: FileManagerArchiveLevel? {
        archiveSession.currentLevel
    }

    var archiveItemWorkflowService: FileManagerArchiveItemWorkflowService {
        archiveSession.itemWorkflowService
    }

    func beginArchiveOpen() -> Int? {
        guard beginNavigation() != nil else { return nil }
        return archiveCoordinator.beginArchiveOpen()
    }

    @discardableResult
    func openArchiveInline(_ url: URL,
                           hostDirectory: URL? = nil,
                           openMode: FileManagerArchiveOpenMode = .defaultBehavior,
                           showError: Bool = true,
                           expectedNavigationGeneration: Int) async -> FileManagerArchiveOpenResult
    {
        guard isCurrentNavigation(expectedNavigationGeneration) else {
            return .cancelled
        }
        let result = await archiveCoordinator.openArchiveInline(url,
                                                                hostDirectory: hostDirectory,
                                                                openMode: openMode,
                                                                showError: showError)
        guard isCurrentNavigation(expectedNavigationGeneration) else {
            return .cancelled
        }
        return result
    }

    func finishArchiveOpen(_ preparedResult: FileManagerPreparedArchiveOpenResult,
                           temporaryDirectory: URL?,
                           preserveTemporaryDirectoryOnUnsupported: Bool,
                           replaceCurrentState: Bool,
                           showError: Bool,
                           expectedOpenGeneration: Int) async -> FileManagerArchiveOpenResult
    {
        await archiveCoordinator.finishArchiveOpen(preparedResult,
                                                   temporaryDirectory: temporaryDirectory,
                                                   preserveTemporaryDirectoryOnUnsupported: preserveTemporaryDirectoryOnUnsupported,
                                                   replaceCurrentState: replaceCurrentState,
                                                   showError: showError,
                                                   invalidatePendingOpen: false,
                                                   expectedOpenGeneration: expectedOpenGeneration)
    }

    @discardableResult
    func openExternallyIfPossible(_ url: URL,
                                  preservingTemporaryDirectory temporaryDirectory: URL? = nil) -> Bool
    {
        externalOpenService.openIfPossible(url,
                                           preservingTemporaryDirectory: temporaryDirectory)
    }

    @discardableResult
    func openExternally(_ url: URL,
                        withApplicationAt applicationURL: URL,
                        preservingTemporaryDirectory temporaryDirectory: URL? = nil) -> Bool
    {
        externalOpenService.open(url,
                                 withApplicationAt: applicationURL,
                                 preservingTemporaryDirectory: temporaryDirectory)
    }

    func cleanupTemporaryDirectory(_ temporaryDirectory: URL?) {
        archiveCoordinator.cleanupTemporaryDirectory(temporaryDirectory)
    }

    func unavailableExternalOpenError(for itemName: String) -> NSError {
        externalOpenService.unavailableExternalOpenError(for: itemName)
    }

    func navigateArchiveSubdir(_ subdir: String,
                               expectedNavigationGeneration: Int)
    {
        guard isCurrentNavigation(expectedNavigationGeneration) else { return }
        archiveCoordinator.navigateSubdir(subdir)
    }

    func returnFocusToFileList() {
        view.window?.makeFirstResponder(tableView)
    }

    func goUpOneLevel() {
        goUp()
    }

    func renameSelection() {
        FileManagerPaneMutationCommandSupport.renameSelection(in: self)
    }

    func deleteSelection() {
        FileManagerPaneMutationCommandSupport.deleteSelection(in: self)
    }

    func showSelectedItemProperties() {
        guard let item = selectedRealPaneItems().first else { return }

        switch item {
        case let .filesystem(fileSystemItem):
            let details = FileManagerItemPresentation.details(for: fileSystemItem)
            szShowDetailsDialog(title: details.title,
                                details: details.details,
                                for: view.window)

        case let .archive(archiveItem):
            let details = FileManagerItemPresentation.details(for: archiveItem,
                                                              entryProperties: archiveSession.currentLevel?.entryProperties ?? [])
            szShowDetailsDialog(title: details.title,
                                details: details.details,
                                for: view.window)

        case .parent:
            return
        }
    }

    func extractSelectionHere() {
        FileManagerPaneMutationCommandSupport.extractHere(in: self)
    }

    func openRootFolder() {
        FileManagerPaneNavigationCommands.openRootFolder(in: self)
    }

    // MARK: - Recent Directories

    func recentDirectoryHistory() -> [URL] {
        directoryCoordinator.recentDirectoryHistory()
    }

    func setRecentDirectoryHistory(_ entries: [URL]) {
        directoryCoordinator.setRecentDirectoryHistory(entries)
    }

    func openRecentDirectory(_ url: URL) {
        FileManagerPaneNavigationCommands.openRecentDirectory(url,
                                                              in: self)
    }

    // MARK: - Selection Commands

    func selectAllItems() {
        let rowCount = numberOfRows(in: tableView)
        let firstSelectableRow = showsParentRow ? 1 : 0
        guard rowCount > firstSelectableRow else {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(IndexSet(integersIn: firstSelectableRow ..< rowCount),
                                   byExtendingSelection: false)
    }

    func deselectAllItems() {
        tableView.deselectAll(nil)
    }

    func invertSelection() {
        let rowCount = numberOfRows(in: tableView)
        let firstSelectableRow = showsParentRow ? 1 : 0
        guard rowCount > firstSelectableRow else { return }

        let currentSelection = tableView.selectedRowIndexes
        var inverseSelection = IndexSet()
        for row in firstSelectableRow ..< rowCount where !currentSelection.contains(row) {
            inverseSelection.insert(row)
        }
        tableView.selectRowIndexes(inverseSelection, byExtendingSelection: false)
    }

    // MARK: - Sort Commands

    func sortByName() {
        listViewCoordinator.applySortDescriptor(columnIdentifier: "name",
                                                key: "name",
                                                ascending: true,
                                                selector: #selector(NSString.localizedStandardCompare(_:)))
    }

    func sortBySize() {
        listViewCoordinator.applySortDescriptor(columnIdentifier: "size",
                                                key: "size",
                                                ascending: false)
    }

    func sortByType() {
        listViewCoordinator.applySortDescriptor(columnIdentifier: "name",
                                                key: "type",
                                                ascending: true,
                                                selector: #selector(NSString.localizedStandardCompare(_:)))
    }

    func sortByModifiedDate() {
        listViewCoordinator.applySortDescriptor(columnIdentifier: "modified",
                                                key: "modified",
                                                ascending: false)
    }

    func sortByCreatedDate() {
        listViewCoordinator.applySortDescriptor(columnIdentifier: "created",
                                                key: "created",
                                                ascending: false)
    }

    var primarySortKey: String? {
        listViewCoordinator.primarySortKey
    }

    var currentLocationDisplayPath: String {
        isInsideArchive ? currentArchiveDisplayPathPrefix() : currentDirectory.path
    }

    var addressBarPath: String {
        pathField.stringValue
    }

    var selectedRealItemCount: Int {
        paneSelectionState.realItems.count
    }

    // MARK: - Extraction Dialog State

    var suggestedExtractDestinationName: String? {
        if let level = archiveSession.currentLevel {
            if !level.currentSubdir.isEmpty {
                return level.currentSubdir.split(separator: "/").last.map(String.init)
            }

            let archiveURL = URL(fileURLWithPath: level.archivePath)
            return archiveURL.deletingPathExtension().lastPathComponent
        }

        guard let archiveURL = selectedArchiveCandidateURL() else {
            return nil
        }

        return archiveURL.deletingPathExtension().lastPathComponent
    }

    func selectedItemNames(limit: Int? = nil) -> [String] {
        let selection = paneSelectionState
        if isInsideArchive {
            return FileManagerItemPresentation.displayNames(for: selection.archiveItems, limit: limit)
        }
        return FileManagerItemPresentation.displayNames(for: selection.fileSystemItems, limit: limit)
    }

    func extractDialogInfoText(previewItemLimit: Int = 5) -> String {
        let selection = paneSelectionState
        guard isInsideArchive else {
            return FileManagerItemPresentation.fileSystemItemsInfoText(location: currentLocationDisplayPath,
                                                                       items: selection.fileSystemItems,
                                                                       previewItemLimit: previewItemLimit)
        }

        return FileManagerItemPresentation.archiveItemsInfoText(location: currentLocationDisplayPath,
                                                                items: selection.archiveItemsForSelectionOrDisplayedItems,
                                                                previewItemLimit: previewItemLimit,
                                                                includeSummary: true)
    }

    // MARK: - Quick Look Preparation

    func prepareQuickLookPreviewForFileSystem() throws -> FileManagerQuickLookPreparedPreview? {
        try FileManagerQuickLookPanePreparation.fileSystemPreview(isVirtualLocation: isVirtualLocation,
                                                                  selectedEntries: selectedQuickLookRowsAndItems(),
                                                                  sourceProvider: quickLookSourceInfo(forRow:paneItem:))
    }

    @MainActor
    func prepareQuickLookPreview(maxArchiveItemSize: UInt64,
                                 maxArchiveCombinedSize: UInt64,
                                 maxSolidArchiveSize: UInt64) async throws -> FileManagerQuickLookPreparedPreview
    {
        try await FileManagerQuickLookPanePreparation.preview(isVirtualLocation: isVirtualLocation,
                                                              selectedEntries: selectedQuickLookRowsAndItems(),
                                                              archiveLevel: archiveSession.currentLevel,
                                                              archiveContextProvider: { [self] in currentArchiveItemWorkflowContext() },
                                                              parentWindow: view.window,
                                                              maxArchiveItemSize: maxArchiveItemSize,
                                                              maxArchiveCombinedSize: maxArchiveCombinedSize,
                                                              maxSolidArchiveSize: maxSolidArchiveSize,
                                                              sourceProvider: quickLookSourceInfo(forRow:paneItem:))
        { [archiveSession] items, context, session in
            try archiveSession.itemWorkflowService.stageQuickLookItems(items,
                                                                       context: context,
                                                                       session: session)
        }
    }

    func cleanupQuickLookTemporaryDirectories(_ temporaryDirectories: [URL]) {
        FileManagerQuickLookPanePreparation.cleanupTemporaryDirectories(temporaryDirectories) { [archiveSession] url in
            archiveSession.cleanupTemporaryDirectory(url)
        }
    }

    func handleQuickLookEvent(_ event: NSEvent) -> Bool {
        if handleShortcutEvent(event) {
            return true
        }

        let action = FileManagerQuickLookEventHandling.keyAction(for: event)
        guard action != .ignore else {
            return false
        }

        delegate?.paneDidBecomeActive(self)

        switch action {
        case .activateSelection:
            doubleClickRow(nil)
        case .navigateUp:
            goUp()
        case .forwardToTable:
            tableView.keyDown(with: event)
        case .ignore:
            return false
        }

        return true
    }

    private func handleShortcutEvent(_ event: NSEvent) -> Bool {
        guard let command = FileManagerShortcuts.command(for: event) else {
            return false
        }

        delegate?.paneDidBecomeActive(self)
        return delegate?.pane(self, didRequestShortcutCommand: command) ?? false
    }

    // MARK: - File System Selection

    func selectedFilePaths() -> [String] {
        paneSelectionState.filePaths
    }

    func selectedFileURLs() -> [URL] {
        paneSelectionState.fileURLs
    }

    // MARK: - File System Navigation

    @discardableResult
    func revealFileSystemItemURLs(_ urls: [URL]) async -> Bool {
        guard let navigationGeneration = beginNavigation() else { return false }
        guard let target = FileManagerFileSystemNavigation.revealTarget(for: urls) else { return false }

        if isInsideArchive {
            guard let transitionToken = beginNavigationTransition(navigationGeneration) else {
                return false
            }
            let didClose = await closeAllArchives(showError: true)
            endNavigationTransition(transitionToken)
            guard didClose else { return false }
        }
        guard isCurrentNavigation(navigationGeneration) else { return false }

        let selectionState = FileManagerFileSystemSelectionState(selectedPaths: target.selectedPaths,
                                                                 focusedPath: target.focusedPath,
                                                                 scrollPlacement: .centered)
        return navigateToDirectory(target.parentDirectory,
                                   showError: true,
                                   selectionState: selectionState,
                                   focusAfterLoad: true,
                                   budget: FileManagerPaneDirectoryCoordinator.navigationBudget,
                                   expectedNavigationGeneration: navigationGeneration)
    }

    @discardableResult
    func openInitialFileSystemItemURL(_ url: URL) async -> Bool {
        guard let navigationGeneration = beginNavigation() else { return false }
        precondition(!isInsideArchive,
                     "Initial file-system navigation requires an empty archive stack")

        switch FileManagerFileSystemNavigation.openTarget(for: url) {
        case let .directory(directoryURL):
            return navigateToDirectory(directoryURL,
                                       showError: true,
                                       focusAfterLoad: true,
                                       budget: FileManagerPaneDirectoryCoordinator.navigationBudget,
                                       expectedNavigationGeneration: navigationGeneration)
        case let .file(fileURL, hostDirectory):
            return await openInitialFileSystemArchiveURL(fileURL,
                                                         hostDirectory: hostDirectory,
                                                         navigationGeneration: navigationGeneration)
        case nil:
            return false
        }
    }

    private func openInitialFileSystemArchiveURL(_ fileURL: URL,
                                                 hostDirectory: URL,
                                                 navigationGeneration: Int) async -> Bool
    {
        guard isCurrentNavigation(navigationGeneration) else { return false }
        switch await archiveCoordinator.openArchiveInline(fileURL,
                                                          hostDirectory: hostDirectory,
                                                          showError: false)
        {
        case .opened:
            guard isCurrentNavigation(navigationGeneration) else { return false }
            focusFileList()
            return true
        case .unsupportedArchive:
            guard isCurrentNavigation(navigationGeneration),
                  let target = FileManagerFileSystemNavigation.revealTarget(for: [fileURL])
            else {
                return false
            }
            let selectionState = FileManagerFileSystemSelectionState(selectedPaths: target.selectedPaths,
                                                                     focusedPath: target.focusedPath,
                                                                     scrollPlacement: .centered)
            return navigateToDirectory(target.parentDirectory,
                                       showError: true,
                                       selectionState: selectionState,
                                       focusAfterLoad: true,
                                       budget: FileManagerPaneDirectoryCoordinator.navigationBudget,
                                       expectedNavigationGeneration: navigationGeneration)
        case .cancelled:
            return false
        case let .failed(error):
            guard isCurrentNavigation(navigationGeneration) else { return false }
            showErrorAlert(error)
            return false
        }
    }

    // MARK: - Creation Operations

    func createFolder(named name: String) {
        FileManagerPaneMutationCommandSupport.createFolder(named: name,
                                                           in: self)
    }

    func createFile(named name: String) {
        FileManagerPaneMutationCommandSupport.createFile(named: name,
                                                         in: self)
    }

    // MARK: - Presentation State

    private func updateStatusBar() {
        let content: FileManagerStatusBarContent = if let archiveLevel = archiveSession.currentLevel {
            FileManagerItemPresentation.statusBarContent(
                displayed: FileManagerItemPresentation.summary(for: archiveSession.displayItems),
                selected: FileManagerItemPresentation.summary(for: paneSelectionState.archiveItems),
                location: .archive(uncompressedSize: archiveLevel.statistics.uncompressedSize),
            )
        } else {
            FileManagerItemPresentation.statusBarContent(
                displayed: FileManagerItemPresentation.summary(for: directoryCoordinator.items),
                selected: FileManagerItemPresentation.summary(for: paneSelectionState.fileSystemItems),
                location: .fileSystem,
            )
        }
        statusView.setContent(content)
    }

    // MARK: - Settings

    private func applyFileManagerSettings() {
        tableView.style = .fullWidth
        tableView.gridStyleMask = SZSettings.bool(.showGridLines)
            ? [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
            : []
        tableView.allowsMultipleSelection = true

        if SZSettings.bool(.singleClickOpen) {
            tableView.action = #selector(singleClickRow(_:))
            tableView.doubleAction = nil
        } else {
            tableView.action = nil
            tableView.doubleAction = #selector(doubleClickRow(_:))
        }
    }

    func handleSettingsDidChange(_ settingsKey: SZSettingsKey) {
        switch settingsKey {
        case .showDots, .showRealFileIcons, .showGridLines, .singleClickOpen:
            if settingsKey == .showRealFileIcons {
                iconProvider.removeAllCachedImages()
            }
            applyFileManagerSettings()
        case .showHiddenFiles:
            if isInsideArchive {
                archiveCoordinator.reapplyHiddenVisibility()
            } else {
                directoryCoordinator.reapplyHiddenFileVisibility()
            }
            return
        case .fileManagerShortcutPreset, .fileManagerCustomShortcuts:
            refreshContextMenu()
            return
        default:
            return
        }

        tableView.reloadData()
        updateStatusBar()
    }

    func handleLanguageDidChange() {
        refreshColumnTitles()
        refreshContextMenu()
        updateStatusBar()
    }

    // MARK: - Quick Look Presentation

    private func quickLookSourceInfo(forRow row: Int,
                                     paneItem: FileManagerPaneItem) -> FileManagerQuickLookItemSource
    {
        let transitionImage = makeQuickLookTransitionImage(for: paneItem)
        return FileManagerQuickLookItemSource(frameOnScreen: FileManagerQuickLookSourceGeometry.frameOnScreen(forRow: row,
                                                                                                              in: tableView,
                                                                                                              window: view.window,
                                                                                                              iconSize: iconSize),
                                              transitionImage: transitionImage)
    }

    private func makeQuickLookTransitionImage(for paneItem: FileManagerPaneItem) -> NSImage? {
        let itemName: String
        let isDirectory: Bool
        let iconPath: String

        switch paneItem {
        case .parent:
            return nil
        case let .filesystem(item):
            itemName = item.name
            isDirectory = item.isDirectory
            iconPath = item.url.path
        case let .archive(item):
            itemName = item.name
            isDirectory = item.isDirectory
            iconPath = item.path
        }

        return iconProvider.transitionImage(for: iconSource(for: paneItem,
                                                            isDirectory: isDirectory,
                                                            iconPath: iconPath),
                                            accessibilityDescription: itemName,
                                            showsRealFileIcons: showsRealFileIcons)
    }

    private func iconImage(for paneItem: FileManagerPaneItem, isDirectory: Bool, iconPath: String) -> NSImage? {
        iconProvider.image(for: iconSource(for: paneItem,
                                           isDirectory: isDirectory,
                                           iconPath: iconPath),
                           showsRealFileIcons: showsRealFileIcons)
    }

    private func iconSource(for paneItem: FileManagerPaneItem,
                            isDirectory: Bool,
                            iconPath: String) -> FileManagerPaneIconSource
    {
        switch paneItem {
        case .parent:
            .parent
        case .archive:
            .archive(isDirectory: isDirectory,
                     iconPath: iconPath)
        case .filesystem:
            .filesystem(isDirectory: isDirectory,
                        iconPath: iconPath)
        }
    }

    // MARK: - Archive Opening

    @discardableResult
    func showArchive(at url: URL) async -> Bool {
        await showArchive(at: url, openMode: .defaultBehavior)
    }

    @discardableResult
    func showArchive(at url: URL,
                     openMode: FileManagerArchiveOpenMode) async -> Bool
    {
        guard let navigationGeneration = beginNavigation() else { return false }
        let parentDirectory = url.deletingLastPathComponent()
        let result = await archiveCoordinator.openArchiveInline(url,
                                                                hostDirectory: parentDirectory,
                                                                openMode: openMode,
                                                                replaceCurrentState: true)
        if case .opened = result,
           isCurrentNavigation(navigationGeneration)
        {
            return true
        }
        return false
    }

    func prepareExtraction(to destinationURL: URL,
                           overwriteMode: SZOverwriteMode = .ask,
                           pathMode: SZPathMode = .currentPaths,
                           password: String? = nil,
                           preserveNtSecurityInfo: Bool = false,
                           eliminateDuplicates: Bool = false,
                           inheritDownloadedFileQuarantine: Bool = SZSettings.bool(.inheritDownloadedFileQuarantine)) throws -> FileManagerPreparedExtraction
    {
        try archiveCoordinator.prepareExtraction(of: archiveItemsForSelectionOrDisplayedItems(),
                                                 emptySelectionMessage: SZL10n.string("app.fileManager.error.noArchiveItemsToExtract"),
                                                 to: destinationURL,
                                                 overwriteMode: overwriteMode,
                                                 pathMode: pathMode,
                                                 password: password,
                                                 preserveNtSecurityInfo: preserveNtSecurityInfo,
                                                 eliminateDuplicates: eliminateDuplicates,
                                                 inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine,
                                                 quarantineSourceArchivePath: quarantineSourceArchiveURLForExtraction()?.path)
    }

    /// Returns the current archive paired with an operation-gate lease, for use off the main actor.
    func currentArchiveForTest() throws -> FileManagerLeasedArchive {
        try archiveCoordinator.currentArchiveForTest()
    }

    /// Prepares extraction of the selected archive items (not all displayed items)
    /// so the actual bridge call can run on a background thread.
    func prepareSelectedItemExtraction(to destinationURL: URL,
                                       overwriteMode: SZOverwriteMode = .ask,
                                       pathMode: SZPathMode = .currentPaths,
                                       password: String? = nil,
                                       preserveNtSecurityInfo: Bool = false,
                                       eliminateDuplicates: Bool = false,
                                       inheritDownloadedFileQuarantine: Bool = SZSettings.bool(.inheritDownloadedFileQuarantine)) throws -> FileManagerPreparedExtraction
    {
        try archiveCoordinator.prepareExtraction(of: selectedArchiveItems(),
                                                 emptySelectionMessage: SZL10n.string("app.fileManager.error.selectArchiveItems"),
                                                 to: destinationURL,
                                                 overwriteMode: overwriteMode,
                                                 pathMode: pathMode,
                                                 password: password,
                                                 preserveNtSecurityInfo: preserveNtSecurityInfo,
                                                 eliminateDuplicates: eliminateDuplicates,
                                                 inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine,
                                                 quarantineSourceArchivePath: quarantineSourceArchiveURLForExtraction()?.path)
    }

    func paneItem(at row: Int) -> FileManagerPaneItem? {
        tableModel.item(at: row)
    }

    // MARK: - Transfer Host

    var transferLocation: FileManagerPaneTransferLocation {
        FileManagerPaneTransferLocation(isVirtualLocation: isVirtualLocation,
                                        currentDirectoryURL: currentDirectoryURL,
                                        presentationWindow: view.window)
    }

    func transferItem(at row: Int) -> FileManagerPaneItem? {
        paneItem(at: row)
    }

    func transferArchiveDragContext(acquireLease: Bool) -> FileManagerPaneArchiveDragContext? {
        guard let level = archiveSession.currentLevel,
              let context = currentArchiveItemWorkflowContext(acquireLease: acquireLease)
        else { return nil }

        return FileManagerPaneArchiveDragContext(itemWorkflowContext: context,
                                                 operationGate: level.operationGate,
                                                 workflowService: archiveSession.itemWorkflowService)
    }

    func transferCurrentArchiveMutationTarget() -> FileManagerPaneArchiveTransferTarget? {
        guard let target = currentArchiveMutationTarget() else { return nil }
        return transferArchiveTarget(for: target.archive,
                                     subdir: target.subdir)
    }

    func transferArchiveMutationTarget(for archive: SZArchive, subdir: String) -> FileManagerPaneArchiveTransferTarget? {
        transferArchiveTarget(for: archive,
                              subdir: subdir)
    }

    func transferLeasedArchiveMutationTarget(for archive: SZArchive, subdir: String) -> FileManagerLeasedArchiveMutationTarget? {
        archiveCoordinator.revalidatedMutationTarget(for: (archive, subdir))
    }

    func transferRefresh() {
        refresh()
    }

    func transferDidMutateArchive(targetSubdir: String?,
                                  selectingPaths paths: [String],
                                  reopenBeforeListing: Bool)
    {
        refreshArchiveAfterMutation(targetSubdir: targetSubdir,
                                    selectingPaths: paths,
                                    reopenBeforeListing: reopenBeforeListing)
        publishArchiveMutationIfNeeded(targetSubdir: targetSubdir,
                                       selectingPaths: paths)
    }

    func transferShowError(_ error: Error) {
        showErrorAlert(error)
    }

    func transferShowReadOnlyArchiveMutationAlert(action: String) {
        showReadOnlyArchiveMutationAlert(action: action)
    }

    // MARK: - Selection Queries

    var paneSelectionState: FileManagerPaneSelectionState {
        FileManagerPaneSelectionState(tableModel: tableModel,
                                      selectedRowIndexes: tableView.selectedRowIndexes)
    }

    private func selectedQuickLookRowsAndItems() -> [(row: Int, item: FileManagerPaneItem)] {
        paneSelectionState.rowsAndItems(excludingParent: true)
    }

    private func selectedRealPaneItems() -> [FileManagerPaneItem] {
        paneSelectionState.realItems
    }

    func selectedFileSystemItems() -> [FileSystemItem] {
        paneSelectionState.fileSystemItems
    }

    func selectedArchiveItems() -> [ArchiveItem] {
        paneSelectionState.archiveItems
    }

    private func archiveItemsForSelectionOrDisplayedItems() -> [ArchiveItem] {
        paneSelectionState.archiveItemsForSelectionOrDisplayedItems
    }

    // MARK: - Archive Context

    private func currentArchiveDisplayPathPrefix() -> String {
        archiveSession.currentDisplayPathPrefix ?? currentDirectory.path
    }

    func archiveHostDirectory() -> URL {
        archiveCoordinator.archiveHostDirectory()
    }

    func currentArchiveItemWorkflowContext(acquireLease: Bool = true) -> FileManagerArchiveItemWorkflowContext? {
        archiveCoordinator.currentItemWorkflowContext(acquireLease: acquireLease,
                                                      quarantineSourceArchivePath: quarantineSourceArchiveURLForExtraction()?.path)
    }

    // MARK: - Archive Coordination

    func hasConflictingNestedArchiveInstance(for identity: FileManagerNestedArchiveIdentity) -> Bool {
        FileManagerNestedArchiveConflictDetector.hasConflictingOpenInstance(for: identity,
                                                                            in: allVisibleArchiveCoordinationSnapshots())
    }

    func hasDirtyNestedArchiveInstance(for identity: FileManagerNestedArchiveIdentity) -> Bool {
        FileManagerNestedArchiveConflictDetector.hasDirtyOpenInstance(for: identity,
                                                                      in: allVisibleArchiveCoordinationSnapshots())
    }

    private func allVisibleArchiveCoordinationSnapshots() -> [FileManagerNestedArchiveOpenSnapshot] {
        archiveCoordinationProvider?.archiveCoordinationSnapshots() ?? archiveCoordinationSnapshots()
    }

    func canOpenArchive(at url: URL) -> Bool {
        let archive = SZArchive()
        do {
            try archive.open(atPath: url.path)
            archive.close()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Archive Stack Closing

    @discardableResult
    func closeArchiveLevel(_ level: FileManagerArchiveLevel,
                           showError: Bool = false) async -> Bool
    {
        await archiveCoordinator.closeLevel(level,
                                            showError: showError)
    }

    @discardableResult
    func closeAllArchives(showError: Bool = false) async -> Bool {
        await archiveCoordinator.closeAll(showError: showError)
    }

    // MARK: - Pane Suspension

    func beginClosePreparation() -> UUID {
        let token = activityState.beginClosePreparation()
        archiveCoordinatorStorage?.invalidatePendingArchiveOpen()
        return token
    }

    func cancelClosePreparation(_ token: UUID,
                                reactivateIfSuspended: Bool = false)
    {
        activityState.endClosePreparation(token)
        if reactivateIfSuspended {
            reactivatesAfterCloseCancellation = true
        }
        reactivateAfterCloseCancellationIfPossible()
    }

    @discardableResult
    func prepareForClose(closePreparationToken: UUID,
                         showError: Bool = true) async -> Bool
    {
        precondition(activityState.containsClosePreparation(closePreparationToken))
        return await suspensionCoordinator.prepareForClose(showError: showError)
    }

    @discardableResult
    func prepareForDeactivation(showError: Bool = true) async -> Bool {
        let token = beginClosePreparation()
        let didPrepare = await suspensionCoordinator.prepareForDeactivation(showError: showError)
        if didPrepare {
            deactivationPreparationToken = token
        } else {
            cancelClosePreparation(token)
        }
        return didPrepare
    }

    func prepareEmptyPaneForDeactivation() {
        precondition(!isInsideArchive,
                     "Initial pane deactivation requires an empty archive stack")
        deactivationPreparationToken = beginClosePreparation()
        suspensionCoordinator.prepareEmptyPaneForDeactivation()
    }

    func reactivateIfSuspended() {
        reactivatesAfterCloseCancellation = false
        if let deactivationPreparationToken {
            cancelClosePreparation(deactivationPreparationToken)
            self.deactivationPreparationToken = nil
        }
        suspensionCoordinatorStorage?.reactivateIfSuspended()
    }

    func closeDirectory() async {
        let token = beginClosePreparation()
        await suspensionCoordinator.closeDirectory()
        cancelClosePreparation(token)
    }

    private func reactivateAfterCloseCancellationIfPossible() {
        guard reactivatesAfterCloseCancellation,
              !activityState.isClosePreparationActive,
              !activityState.isNavigationTransitionActive
        else {
            return
        }
        reactivatesAfterCloseCancellation = false
        suspensionCoordinatorStorage?.reactivateIfSuspended()
    }

    // MARK: - Archive Reloads And Change Propagation

    private func reloadCurrentArchiveEntries(selectingPaths paths: [String] = []) {
        archiveCoordinator.reloadCurrentArchiveEntries(selectingPaths: paths)
    }

    func handlePublishedArchiveChange(_ change: FileManagerArchiveChange) {
        archiveCoordinator.handlePublishedArchiveChange(change)
    }

    func publishArchiveMutationIfNeeded(targetSubdir: String? = nil,
                                        selectingPaths paths: [String] = [])
    {
        archiveCoordinator.publishMutationIfNeeded(targetSubdir: targetSubdir,
                                                   selectingPaths: paths)
    }

    func refreshArchiveAfterMutation(targetSubdir: String? = nil,
                                     selectingPaths paths: [String] = [],
                                     reopenBeforeListing: Bool = false)
    {
        archiveCoordinator.refreshAfterMutation(targetSubdir: targetSubdir,
                                                selectingPaths: paths,
                                                reopenBeforeListing: reopenBeforeListing)
    }

    private func cancelPendingArchiveRefresh() {
        archiveCoordinatorStorage?.cancelPendingReload()
    }

    private func selectArchivePaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }

        let selectedPaths = Set(paths.map(normalizeArchivePath))
        var rows = IndexSet()
        for (index, item) in archiveSession.displayItems.enumerated() {
            if selectedPaths.contains(normalizeArchivePath(item.path)) {
                rows.insert(index + (showsParentRow ? 1 : 0))
            }
        }

        guard !rows.isEmpty else { return }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let firstRow = rows.first {
            scrollFileListRow(firstRow, placement: .visible)
        }
    }

    private func scrollFileListRow(_ row: Int,
                                   placement: FileManagerFileSystemSelectionScrollPlacement)
    {
        switch placement {
        case .visible:
            tableView.scrollRowToVisible(row)
        case .centered:
            scrollFileListRowToCenter(row)
        }
    }

    private func scrollFileListRowToCenter(_ row: Int) {
        guard row >= 0,
              row < tableView.numberOfRows,
              let clipView = tableView.enclosingScrollView?.contentView
        else {
            tableView.scrollRowToVisible(row)
            return
        }

        tableView.layoutSubtreeIfNeeded()
        let rowRect = tableView.rect(ofRow: row)
        let visibleHeight = clipView.bounds.height
        let documentHeight = tableView.bounds.height
        guard visibleHeight > 0,
              documentHeight > visibleHeight
        else {
            tableView.scrollRowToVisible(row)
            return
        }

        let maximumY = max(0, documentHeight - visibleHeight)
        let centeredY = rowRect.midY - (visibleHeight / 2)
        let targetY = min(max(0, centeredY), maximumY)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x,
                                    y: targetY))
        tableView.enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    private func normalizeArchivePath(_ path: String) -> String {
        FileManagerArchiveChange.normalizeArchivePath(path)
    }

    // MARK: - Error Presentation

    func showErrorAlert(_ error: Error) {
        szPresentError(error, for: view.window)
    }

    func showReadOnlyArchiveMutationAlert(action: String) {
        if let level = archiveSession.currentLevel,
           level.operationGate.hasActiveLeases
        {
            return
        }

        if let level = archiveSession.currentLevel,
           let nestedIdentity = level.nestedIdentity,
           hasConflictingNestedArchiveInstance(for: nestedIdentity)
        {
            szPresentMessage(title: SZL10n.string("app.fileManager.alert.actionNotAvailableTitle", action),
                             message: SZL10n.string("app.fileManager.alert.nestedArchiveConflict"),
                             for: view.window)
            return
        }

        if let level = archiveSession.currentLevel,
           !level.archive.canWrite
        {
            let archiveFormat = level.archive.formatName ?? SZL10n.string("app.fileManager.alert.thisArchiveFormat")
            szPresentMessage(title: SZL10n.string("app.fileManager.alert.actionNotAvailableTitle", action),
                             message: SZL10n.string("app.fileManager.alert.formatNoInPlaceUpdate", archiveFormat),
                             for: view.window)
            return
        }

        szPresentMessage(title: SZL10n.string("app.fileManager.alert.actionNotAvailableTitle", action),
                         message: SZL10n.string("app.fileManager.alert.temporaryCopyNoModification"),
                         for: view.window)
    }

    // MARK: - Item Sorting

    private func sortCurrentItemsByCurrentListViewDescriptors() {
        guard isViewLoaded else { return }
        listViewCoordinator.sortItemsUsingCurrentDescriptors()
    }

    // MARK: - Actions

    @objc private func pathFieldSubmitted(_ sender: NSTextField) {
        delegate?.paneDidBecomeActive(self)
        FileManagerPaneNavigationCommands.submitPath(sender.stringValue,
                                                     in: self)
    }

    @objc private func goUpClicked(_: Any?) {
        goUp()
    }

    func updatePathField() {
        if isInsideArchive {
            guard let level = archiveSession.currentLevel else { return }
            pathField.stringValue = level.currentSubdir.isEmpty
                ? level.displayPathPrefix
                : level.displayPathPrefix + "/" + level.currentSubdir
        } else {
            pathField.stringValue = currentDirectory.path
        }

        updateLocationIcon()
        delegate?.paneLocationDidChange(self)
    }

    private func updateLocationIcon() {
        let image: NSImage? = if let level = archiveSession.currentLevel {
            if level.currentSubdir.isEmpty {
                NSWorkspace.shared.icon(forFile: level.archivePath)
            } else {
                NSImage(named: NSImage.folderName)
                    ?? NSWorkspace.shared.icon(forFile: level.filesystemDirectory.path)
            }
        } else {
            NSWorkspace.shared.icon(forFile: currentDirectory.path)
        }

        locationIconView.image = image
    }

    @objc private func doubleClickRow(_: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        FileManagerPaneOpenCommandSupport.activateItem(at: row,
                                                       in: self)
    }

    @objc private func singleClickRow(_: Any?) {
        guard SZSettings.bool(.singleClickOpen) else { return }
        guard tableView.selectedRowIndexes.count <= 1 else { return }
        guard let event = NSApp.currentEvent else { return }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers.isEmpty else { return }

        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        FileManagerPaneOpenCommandSupport.activateItem(at: row,
                                                       in: self)
    }

    private func goUp() {
        FileManagerPaneNavigationCommands.goUp(in: self)
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in _: NSTableView) -> Int {
        tableModel.rowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        guard let paneItem = paneItem(at: row) else { return nil }

        return FileManagerPaneTableCellRenderer.view(in: tableView,
                                                     for: paneItem,
                                                     tableColumn: tableColumn,
                                                     columns: listViewCoordinator.currentColumns,
                                                     fallbackColumns: listViewCoordinator.availableColumns,
                                                     dateFormatter: FileManagerViewPreferences.makeListDateFormatter(),
                                                     owner: self,
                                                     iconSize: iconSize,
                                                     showsRealFileIcons: showsRealFileIcons)
        { [self] item, isDirectory, iconPath in
            iconImage(for: item,
                      isDirectory: isDirectory,
                      iconPath: iconPath)
        }
    }

    func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
        listRowHeight
    }

    // MARK: - Drag Source

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        transferCoordinator.pasteboardWriter(forRow: row,
                                             host: self)
    }

    // MARK: - Drop Destination (accept files dragged into this folder)

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        transferCoordinator.validateDrop(info,
                                         proposedRow: row,
                                         dropOperation: dropOperation,
                                         in: tableView,
                                         host: self)
    }

    func tableView(_: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        transferCoordinator.acceptDrop(info,
                                       row: row,
                                       dropOperation: dropOperation,
                                       host: self)
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateStatusBar()
        delegate?.paneDidBecomeActive(self)
        delegate?.paneSelectionDidChange(self)
    }

    func beginArchiveTransfer(_ urls: [URL],
                              to target: (archive: SZArchive, subdir: String),
                              operation: NSDragOperation,
                              sourcePane: FileManagerPaneController?,
                              cleanupDirectory: URL? = nil,
                              parentWindow: NSWindow? = nil,
                              requiresConfirmation: Bool = false,
                              operationTitle: String? = nil,
                              onSuccess: (@MainActor () -> Void)? = nil)
    {
        transferCoordinator.beginArchiveTransfer(urls,
                                                 to: target,
                                                 operation: operation,
                                                 sourceHost: sourcePane,
                                                 host: self,
                                                 cleanupDirectory: cleanupDirectory,
                                                 parentWindow: parentWindow,
                                                 requiresConfirmation: requiresConfirmation,
                                                 operationTitle: operationTitle,
                                                 onSuccess: onSuccess)
    }

    func beginConfirmedArchiveTransfer(_ urls: [URL],
                                       to target: (archive: SZArchive, subdir: String),
                                       operation: NSDragOperation,
                                       sourcePane: FileManagerPaneController?,
                                       cleanupDirectory: URL? = nil,
                                       parentWindow: NSWindow? = nil,
                                       operationTitle: String? = nil)
    {
        transferCoordinator.beginArchiveTransfer(urls,
                                                 to: target,
                                                 operation: operation,
                                                 sourceHost: sourcePane,
                                                 host: self,
                                                 cleanupDirectory: cleanupDirectory,
                                                 parentWindow: parentWindow,
                                                 requiresConfirmation: true,
                                                 operationTitle: operationTitle)
    }

    // MARK: - Sorting (matches PanelSort.cpp)

    func tableView(_: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
        listViewCoordinator.handleSortDescriptorsDidChange()
    }
}

// MARK: - Coordinator Hosts

extension FileManagerPaneController: FileManagerPaneDirectoryCoordinatorHost {
    func directorySelectionState() -> FileManagerFileSystemSelectionState {
        let selectedItems = selectedFileSystemItems()
        let focusedPath: String? = if let focusedItem = paneItem(at: tableView.selectedRow),
                                      case let .filesystem(item) = focusedItem
        {
            item.url.standardizedFileURL.path
        } else {
            selectedItems.first?.url.standardizedFileURL.path
        }
        return FileManagerFileSystemSelectionState(
            selectedPaths: Set(selectedItems.map(\.url.standardizedFileURL.path)),
            focusedPath: focusedPath,
            scrollPlacement: .visible,
        )
    }

    func directoryContentsDidChange(_ change: FileManagerDirectoryContentsChange) {
        if case .snapshot = change {
            updatePathField()
            updateTableColumnsForCurrentLocation()
        }
        sortCurrentItemsByCurrentListViewDescriptors()
        tableView.reloadData()
        updateStatusBar()
    }

    func directoryNavigationDidFinish(selection: FileManagerDirectorySelectionRestoration?,
                                      focusFileList: Bool)
    {
        clearSuspendedState()
        if let selection {
            restoreDirectorySelection(selection)
        }
        if focusFileList {
            self.focusFileList()
        }
    }

    func restoreDirectorySelection(_ selection: FileManagerDirectorySelectionRestoration) {
        guard !selection.rows.isEmpty else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(selection.rows, byExtendingSelection: false)
        if let focusedRow = selection.focusedRow {
            scrollFileListRow(focusedRow, placement: selection.scrollPlacement)
        }
    }

    func directoryInitialLoadDidFail() {
        updatePathField()
        updateStatusBar()
    }

    func directoryPresentationDidSuspend() {
        tableView.reloadData()
    }
}

extension FileManagerPaneController: FileManagerPaneArchiveCoordinatorHost {
    var archiveParentWindow: NSWindow? {
        isViewLoaded ? view.window : nil
    }

    var archiveSelectedPaths: [String] {
        selectedArchiveItems().map { normalizeArchivePath($0.path) }
    }

    func archivePrepareForPresentation(hostDirectory: URL) {
        directoryCoordinator.prepareForArchivePresentation(hostDirectory: hostDirectory)
    }

    func archiveLocationDidChange(selectingPaths paths: [String]) {
        updateTableColumnsForCurrentLocation()
        sortCurrentItemsByCurrentListViewDescriptors()
        updatePathField()
        updateStatusBar()
        tableView.reloadData()
        selectArchivePaths(paths)
    }

    func archiveVisibilityDidChange(restoringSelection paths: [String]) {
        tableView.reloadData()
        updateStatusBar()
        selectArchivePaths(paths)
    }

    func archiveStackDidCloseLevel() {
        if !isInsideArchive {
            updatePathField()
            updateStatusBar()
            tableView.reloadData()
            updateTableColumnsForCurrentLocation()
        } else if isViewLoaded {
            archiveLocationDidChange(selectingPaths: [])
        } else {
            updateTableColumnsForCurrentLocation()
        }
    }

    func archiveDidOpenTopLevel(_ url: URL) {
        RecentArchiveHistory.recordOpenedArchive(url)
    }

    func archiveBeginStateReplacement() -> UUID? {
        activityState.beginCurrentNavigationTransition()
    }

    func archiveEndStateReplacement(_ token: UUID) {
        activityState.endNavigationTransition(token)
    }
}

extension FileManagerPaneController: FileManagerPaneSuspensionHost {
    var suspensionOverlayViews: (container: NSView, content: NSView)? {
        guard isViewLoaded else { return nil }
        return (view, scrollView)
    }

    func preparePaneForSuspension() {
        directoryCoordinator.prepareForSuspension()
        cancelPendingArchiveRefresh()
        archiveSession.clearDisplayItems()
        statusView?.clear()
    }

    func reloadSuspendedDirectory() -> Bool {
        guard !activityState.isClosePreparationActive else { return false }
        return loadDirectory(currentDirectory, showError: true)
    }
}

extension FileManagerPaneController: FileManagerPaneEventHost {
    func handleViewPreferencesDidChange(resetListView: Bool) {
        if resetListView {
            listViewCoordinator.resetForCurrentLocation()
        } else {
            reloadPresentedValues()
        }
    }
}

// MARK: - Archive Inline Navigation (matches Panel.cpp _parentFolders stack)

extension FileManagerPaneController {
    func navigateArchiveSubdir(_ subdir: String) {
        guard beginNavigation() != nil else { return }
        archiveCoordinator.navigateSubdir(subdir)
    }
}

// MARK: - NSMenuDelegate (auto-select row on right-click)

extension FileManagerPaneController {
    func archiveCoordinationSnapshots() -> [FileManagerNestedArchiveOpenSnapshot] {
        archiveSession.coordinationSnapshots { level in
            level.nestedWriteBackInfo.flatMap { writeBackInfo in
                FileManagerArchiveFileFingerprint.captureIfPossible(for: URL(fileURLWithPath: level.archivePath).standardizedFileURL)
                    .map { $0 != writeBackInfo.initialFingerprint }
            } ?? false
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuHandler.menuNeedsUpdate(menu)
    }
}

// MARK: - Context Menu

extension FileManagerPaneController {
    private func populateColumnHeaderMenu(_ menu: NSMenu) {
        listViewCoordinator.populateColumnHeaderMenu(menu,
                                                     target: self,
                                                     action: #selector(toggleListViewColumnVisibility(_:)))
    }

    @objc private func toggleListViewColumnVisibility(_ sender: NSMenuItem) {
        guard let rawColumnID = sender.representedObject as? String else { return }
        let columnID = FileManagerColumnID(rawValue: rawColumnID)

        listViewCoordinator.toggleColumnVisibility(columnID)
    }

    private func refreshContextMenu() {
        tableView.menu = menuHandler.makeContextMenu(windowTarget: delegate as AnyObject?,
                                                     delegate: self)
    }

    func controlTextDidBeginEditing(_: Notification) {
        delegate?.paneDidBecomeActive(self)
    }
}
