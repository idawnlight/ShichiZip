import Cocoa
import os

/// Single pane of the file manager — displays file system contents
class FileManagerPaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    // MARK: - Types

    private static let addressBarIconSize: CGFloat = 14
    private static var directorySnapshotQueueLabel: String {
        "\(Bundle.main.bundleIdentifier ?? "ShichiZip").file-manager.directory-snapshot"
    }

    // MARK: - Properties

    weak var delegate: FileManagerPaneDelegate?
    weak var archiveCoordinationProvider: (any FileManagerArchiveCoordinationProviding)?

    private var locationIconView: NSImageView!
    private var pathField: NSTextField!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var statusLabel: NSTextField!
    private var currentColumns: [FileManagerColumn] = []
    private var columnHeaderMenu: NSMenu?
    private var settingsObserver: NSObjectProtocol?
    private var viewPreferencesObserver: NSObjectProtocol?
    private var archiveChangeObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var liveScrollStartObserver: NSObjectProtocol?
    private var liveScrollEndObserver: NSObjectProtocol?
    private var columnDidMoveObserver: NSObjectProtocol?
    private var columnDidResizeObserver: NSObjectProtocol?
    private var recentDirectories: [URL] = []
    private var isLiveScrolling = false
    private var isApplyingListViewPreferences = false
    private var pendingAutoRefresh = false
    private var directorySnapshotGeneration = 0
    private let directorySnapshotQueue = DispatchQueue(label: FileManagerPaneController.directorySnapshotQueueLabel,
                                                       qos: .userInitiated)
    private var directoryWatcher: DirectoryWatcher?
    private var archiveRefreshGeneration = 0
    private var archiveRefreshTask: Task<Void, Never>?
    private var pendingDropOperation: (sequenceNumber: Int, operation: NSDragOperation)?
    private let iconProvider = FileManagerPaneIconProvider(iconSize: NSSize(width: 16, height: 16))
    private var iconSize: NSSize {
        iconProvider.iconSize
    }

    private let listRowHeight: CGFloat = 22
    private var currentDirectoryFingerprint: [FileManagerDirectorySnapshot.EntryFingerprint] = []
    private var currentListViewFolderTypeID: String?
    private(set) var isSuspended = false
    private var suspendedOverlay: NSView?

    private(set) var currentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var currentDirectoryURL: URL {
        currentDirectory
    }

    private var items: [FileSystemItem] = []

    private enum PaneItem {
        case parent
        case filesystem(FileSystemItem)
        case archive(ArchiveItem)

        var fileSystemItem: FileSystemItem? {
            guard case let .filesystem(item) = self else { return nil }
            return item
        }

        var archiveItem: ArchiveItem? {
            guard case let .archive(item) = self else { return nil }
            return item
        }
    }

    /// Archive navigation state (matches CFolderLink stack in Panel.cpp)
    private struct ArchiveLevel {
        let filesystemDirectory: URL
        let archivePath: String
        let displayPathPrefix: String
        let archive: SZArchive
        let operationGate: FileManagerArchiveOperationGate
        let allEntries: [ArchiveItem]
        let entryProperties: [FileManagerArchiveEntryProperty]
        let currentSubdir: String
        let temporaryDirectory: URL?
        let nestedIdentity: FileManagerNestedArchiveIdentity?
        let nestedWriteBackInfo: FileManagerNestedArchiveWriteBackInfo?
    }

    private var archiveStack: [ArchiveLevel] = []
    private var isInsideArchive: Bool {
        !archiveStack.isEmpty
    }

    private var archiveDisplayItems: [ArchiveItem] = []
    private let archiveItemWorkflowService = FileManagerArchiveItemWorkflowService()
    private func archiveLevelSupportsInPlaceMutation(_ level: ArchiveLevel) -> Bool {
        guard !level.operationGate.hasActiveLeases else {
            return false
        }

        guard level.temporaryDirectory == nil || level.nestedWriteBackInfo != nil else {
            return false
        }

        guard level.archive.canWrite else {
            return false
        }

        guard let nestedIdentity = level.nestedIdentity else {
            return true
        }

        return !hasConflictingNestedArchiveInstance(for: nestedIdentity)
    }

    var supportsInPlaceArchiveMutation: Bool {
        guard let level = archiveStack.last else {
            return false
        }
        return archiveLevelSupportsInPlaceMutation(level)
    }

    private var showsRealFileIcons: Bool {
        SZSettings.bool(.showRealFileIcons)
    }

    private var showsParentRow: Bool {
        guard SZSettings.bool(.showDots) else {
            return false
        }
        if isInsideArchive {
            return true
        }
        return currentDirectory.path != currentDirectory.deletingLastPathComponent().path
    }

    // MARK: - Lifecycle

    isolated deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let viewPreferencesObserver {
            NotificationCenter.default.removeObserver(viewPreferencesObserver)
        }
        if let archiveChangeObserver {
            NotificationCenter.default.removeObserver(archiveChangeObserver)
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
        if let liveScrollStartObserver {
            NotificationCenter.default.removeObserver(liveScrollStartObserver)
        }
        if let liveScrollEndObserver {
            NotificationCenter.default.removeObserver(liveScrollEndObserver)
        }
        if let columnDidMoveObserver {
            NotificationCenter.default.removeObserver(columnDidMoveObserver)
        }
        if let columnDidResizeObserver {
            NotificationCenter.default.removeObserver(columnDidResizeObserver)
        }

        tearDownDirectoryWatcher()
        cancelPendingDirectorySnapshot()
        cancelPendingArchiveRefresh()

        let preservedTemporaryDirectories = preserveNestedArchiveTemporaryDirectories()
        let didCloseAllArchives = closeAllArchives(showError: false)
        if didCloseAllArchives {
            archiveItemWorkflowService.cleanupAll()
        } else {
            preserveRemainingTemporaryDirectories(preservedTemporaryDirectories)
        }
    }

    // MARK: - View Setup

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))

        let upButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Up")!, target: self, action: #selector(goUpClicked(_:)))
        upButton.translatesAutoresizingMaskIntoConstraints = false
        upButton.bezelStyle = .accessoryBarAction
        upButton.isBordered = false
        upButton.refusesFirstResponder = true
        upButton.setAccessibilityIdentifier("fileManager.upButton")
        container.addSubview(upButton)

        locationIconView = NSImageView()
        locationIconView.translatesAutoresizingMaskIntoConstraints = false
        locationIconView.imageScaling = .scaleProportionallyDown
        locationIconView.refusesFirstResponder = true
        locationIconView.image = NSWorkspace.shared.icon(forFile: currentDirectory.path)
        container.addSubview(locationIconView)

        pathField = NSTextField()
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.usesSingleLineMode = true
        pathField.lineBreakMode = .byTruncatingHead
        pathField.cell?.usesSingleLineMode = true
        pathField.cell?.wraps = false
        pathField.cell?.isScrollable = true
        pathField.stringValue = currentDirectory.path
        pathField.target = self
        pathField.action = #selector(pathFieldSubmitted(_:))
        pathField.delegate = self
        pathField.setAccessibilityIdentifier("fileManager.pathField")
        container.addSubview(pathField)

        NSLayoutConstraint.activate([
            locationIconView.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 6),
            locationIconView.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            locationIconView.widthAnchor.constraint(equalToConstant: Self.addressBarIconSize),
            locationIconView.heightAnchor.constraint(equalToConstant: Self.addressBarIconSize),
            pathField.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            pathField.leadingAnchor.constraint(equalTo: locationIconView.trailingAnchor, constant: 6),
            pathField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            pathField.heightAnchor.constraint(equalToConstant: 24),
        ])

        let fileTableView = FileManagerTableView()
        fileTableView.contextMenuPreparationHandler = { [weak self] clickedRow in
            self?.prepareContextMenu(forClickedRow: clickedRow)
        }
        fileTableView.quickLookPreviewHandler = { [weak self] in
            guard let self else { return }
            delegate?.paneDidRequestQuickLook(self)
        }
        fileTableView.shortcutEventHandler = { [weak self] event in
            self?.handleShortcutEvent(event) ?? false
        }
        fileTableView.pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        tableView = fileTableView
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = listRowHeight
        tableView.intercellSpacing = NSSize(width: tableView.intercellSpacing.width, height: 0)
        configureTableColumns(FileManagerColumn.fileSystemColumns,
                              folderTypeID: FileManagerViewPreferences.fileSystemListViewFolderTypeID)
        columnHeaderMenu = buildColumnHeaderMenu()
        tableView.headerView?.menu = columnHeaderMenu

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.menu = buildContextMenu()
        SZLog.debug("ShichiZip", "File manager pane context menu set with \(tableView.menu?.items.count ?? 0) items")

        // Register for drag and drop
        tableView.registerForDraggedTypes([.fileURL] + FileOperationDropResolver.promisedFilePasteboardTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setAccessibilityIdentifier("fileManager.tableView")

        columnDidMoveObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidMoveNotification,
            object: tableView,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTableColumnLayoutDidChange()
            }
        }

        columnDidResizeObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification,
            object: tableView,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTableColumnLayoutDidChange()
            }
        }

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        container.addSubview(scrollView)

        liveScrollStartObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLiveScrolling = true
            }
        }

        liveScrollEndObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLiveScrolling = false

                guard self.pendingAutoRefresh else { return }
                self.pendingAutoRefresh = false
                self.autoRefreshCurrentDirectoryIfNeeded()
            }
        }

        // Status bar
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.cell?.wraps = false
        statusLabel.cell?.usesSingleLineMode = true
        statusLabel.cell?.truncatesLastVisibleLine = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityIdentifier("fileManager.statusLabel")
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            upButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            upButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            upButton.widthAnchor.constraint(equalToConstant: 24),
            upButton.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
        ])

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .szSettingsDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            let settingsKey = (notification.userInfo?["key"] as? String)
                .flatMap(SZSettingsKey.init(rawValue:))
            MainActor.assumeIsolated {
                guard let settingsKey else { return }
                self?.handleSettingsDidChange(settingsKey)
            }
        }

        viewPreferencesObserver = NotificationCenter.default.addObserver(
            forName: .fileManagerViewPreferencesDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            let shouldResetListViewPreferences = notification.userInfo?[FileManagerViewPreferences.listViewPreferencesResetUserInfoKey] as? Bool == true
            MainActor.assumeIsolated {
                if shouldResetListViewPreferences {
                    self?.resetTableColumnsForCurrentLocation()
                } else {
                    self?.reloadPresentedValues()
                }
            }
        }

        archiveChangeObserver = NotificationCenter.default.addObserver(
            forName: .fileManagerArchiveDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            let change = FileManagerArchiveChange(notification: notification)
            MainActor.assumeIsolated {
                guard let self,
                      let change
                else {
                    return
                }
                self.handlePublishedArchiveChange(change)
            }
        }

        languageObserver = NotificationCenter.default.addObserver(
            forName: .szLanguageDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshColumnTitles()
                self?.tableView.menu = self?.buildContextMenu()
                self?.updateStatusBar()
            }
        }

        applyFileManagerSettings()

        view = container
        loadInitialDirectory(currentDirectory)
    }

    // MARK: - Navigation

    private struct FileSystemSelectionState {
        let selectedPaths: Set<String>
        let focusedPath: String?

        static let empty = FileSystemSelectionState(selectedPaths: [], focusedPath: nil)
    }

    private enum DirectorySnapshotPurpose {
        case refresh(selectionState: FileSystemSelectionState)
        case autoRefresh(selectionState: FileSystemSelectionState)
    }

    @discardableResult
    func loadDirectory(_ url: URL,
                       showError: Bool = true) -> Bool
    {
        navigateToDirectory(url, showError: showError)
    }

    @discardableResult
    private func navigateToDirectory(_ url: URL,
                                     showError: Bool,
                                     selectionState: FileSystemSelectionState? = nil,
                                     focusAfterLoad: Bool = false) -> Bool
    {
        cancelPendingDirectorySnapshot()

        do {
            let snapshot = try FileManagerDirectorySnapshot.make(for: url.standardizedFileURL,
                                                                 options: fileManagerDirectoryEnumerationOptions())
            applyDirectorySnapshot(snapshot)
            if isSuspended {
                clearSuspendedState()
            }
            if let selectionState {
                restoreFileSystemSelectionState(selectionState)
            }
            if focusAfterLoad {
                focusFileList()
            }
            return true
        } catch {
            if showError {
                showErrorAlert(error)
            }
            return false
        }
    }

    private func fileManagerDirectoryEnumerationOptions() -> FileManager.DirectoryEnumerationOptions {
        SZSettings.bool(.showHiddenFiles) ? [] : [.skipsHiddenFiles]
    }

    private func captureFileSystemSelectionState() -> FileSystemSelectionState {
        guard isViewLoaded, !isInsideArchive else {
            return .empty
        }

        let selectedPaths = Set(selectedFileSystemItems().map(\.url.standardizedFileURL.path))
        let focusedPath: String? = if let focusedItem = paneItem(at: tableView.selectedRow),
                                      case let .filesystem(item) = focusedItem
        {
            item.url.standardizedFileURL.path
        } else {
            selectedFileSystemItems().first?.url.standardizedFileURL.path
        }

        return FileSystemSelectionState(selectedPaths: selectedPaths, focusedPath: focusedPath)
    }

    private func restoreFileSystemSelectionState(_ selectionState: FileSystemSelectionState) {
        guard !isInsideArchive else { return }

        let baseRow = showsParentRow ? 1 : 0
        let selectedRows = IndexSet(items.enumerated().compactMap { index, item in
            selectionState.selectedPaths.contains(item.url.standardizedFileURL.path) ? baseRow + index : nil
        })

        if selectedRows.isEmpty {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)

        if let focusedPath = selectionState.focusedPath,
           let row = items.firstIndex(where: { $0.url.standardizedFileURL.path == focusedPath }).map({ baseRow + $0 })
        {
            tableView.scrollRowToVisible(row)
        } else if let firstRow = selectedRows.first {
            tableView.scrollRowToVisible(firstRow)
        }
    }

    private func reloadCurrentDirectoryPreservingSelection() {
        let selectionState = captureFileSystemSelectionState()
        scheduleDirectorySnapshot(for: currentDirectory,
                                  purpose: .refresh(selectionState: selectionState))
    }

    private func autoRefreshCurrentDirectoryIfNeeded() {
        let selectionState = captureFileSystemSelectionState()
        scheduleDirectorySnapshot(for: currentDirectory,
                                  purpose: .autoRefresh(selectionState: selectionState))
    }

    private func scheduleDirectorySnapshot(for url: URL,
                                           purpose: DirectorySnapshotPurpose)
    {
        directorySnapshotGeneration += 1
        let generation = directorySnapshotGeneration
        let options = fileManagerDirectoryEnumerationOptions()

        directorySnapshotQueue.async {
            let result = Result {
                try FileManagerDirectorySnapshot.make(for: url,
                                                      options: options)
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishDirectorySnapshot(result,
                                                  generation: generation,
                                                  purpose: purpose)
                }
            }
        }
    }

    private func cancelPendingDirectorySnapshot() {
        directorySnapshotGeneration += 1
    }

    private func finishDirectorySnapshot(_ result: Result<FileManagerDirectorySnapshot, Error>,
                                         generation: Int,
                                         purpose: DirectorySnapshotPurpose)
    {
        guard generation == directorySnapshotGeneration else { return }

        switch result {
        case let .success(snapshot):
            guard !isInsideArchive else { return }

            switch purpose {
            case let .autoRefresh(selectionState):
                guard snapshot.url.standardizedFileURL == currentDirectory.standardizedFileURL else { return }
                guard snapshot.fingerprint != currentDirectoryFingerprint else { return }
                applyDirectorySnapshot(snapshot)
                restoreFileSystemSelectionState(selectionState)

            case let .refresh(selectionState):
                guard snapshot.url.standardizedFileURL == currentDirectory.standardizedFileURL else { return }
                applyDirectorySnapshot(snapshot)
                restoreFileSystemSelectionState(selectionState)
            }

        case .failure:
            return
        }
    }

    private func loadInitialDirectory(_ url: URL) {
        do {
            let snapshot = try FileManagerDirectorySnapshot.make(for: url.standardizedFileURL,
                                                                 options: fileManagerDirectoryEnumerationOptions())
            applyDirectorySnapshot(snapshot)
        } catch {
            currentDirectory = url.standardizedFileURL
            updatePathField()
            updateStatusBar()
        }
    }

    private func applyDirectorySnapshot(_ snapshot: FileManagerDirectorySnapshot) {
        currentDirectory = snapshot.url
        recordDirectoryVisit(snapshot.url)
        updatePathField()
        currentDirectoryFingerprint = snapshot.fingerprint
        items = snapshot.items
        updateTableColumnsForCurrentLocation()
        sortCurrentItems(by: tableView.sortDescriptors)
        tableView.reloadData()
        updateStatusBar()
        installDirectoryWatcher(for: snapshot.url)
    }

    private func columnsForCurrentLocation() -> [FileManagerColumn] {
        if let level = archiveStack.last {
            return FileManagerColumn.archiveColumns(entryProperties: level.entryProperties)
        }
        return FileManagerColumn.fileSystemColumns
    }

    private func updateTableColumnsForCurrentLocation() {
        guard isViewLoaded else { return }
        configureTableColumns(columnsForCurrentLocation(),
                              folderTypeID: listViewFolderTypeIDForCurrentLocation())
    }

    private func configureTableColumns(_ columns: [FileManagerColumn],
                                       folderTypeID: String,
                                       preferSavedState: Bool = true)
    {
        let listViewInfo = preferSavedState
            ? FileManagerViewPreferences.listViewInfo(forFolderTypeID: folderTypeID)
            : nil
        let resolvedColumns = FileManagerViewPreferences.resolvedListViewColumns(columns,
                                                                                 using: listViewInfo)
        let resolvedColumnsByID = Dictionary(uniqueKeysWithValues: resolvedColumns.map { ($0.column.id, $0.column) })
        let currentIDs = Set(currentColumns.map(\.id))
        let newIDs = Set(resolvedColumns.map(\.column.id))

        if preferSavedState,
           currentListViewFolderTypeID == folderTypeID,
           currentIDs == newIDs
        {
            currentColumns = tableView.tableColumns.compactMap { tableColumn in
                resolvedColumnsByID[FileManagerColumnID(rawValue: tableColumn.identifier.rawValue)]
            }
            for tableColumn in tableView.tableColumns {
                let id = FileManagerColumnID(rawValue: tableColumn.identifier.rawValue)
                guard let column = resolvedColumnsByID[id]
                else {
                    continue
                }
                tableColumn.title = column.title
                tableColumn.minWidth = column.minWidth
                tableColumn.sortDescriptorPrototype = column.sortDescriptorPrototype
            }
            currentListViewFolderTypeID = folderTypeID
            return
        }

        isApplyingListViewPreferences = true
        defer { isApplyingListViewPreferences = false }

        for tableColumn in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(tableColumn)
        }

        currentColumns = resolvedColumns.map(\.column)
        for resolvedColumn in resolvedColumns {
            let tableColumn = resolvedColumn.column.makeTableColumn()
            tableColumn.width = resolvedColumn.width
            tableView.addTableColumn(tableColumn)
        }

        currentListViewFolderTypeID = folderTypeID

        let sortDescriptor = FileManagerViewPreferences.resolvedListViewSortDescriptor(using: listViewInfo,
                                                                                       columns: columns)
        tableView.sortDescriptors = sortDescriptor.map { [$0] } ?? []
        updateHighlightedTableColumn(for: tableView.sortDescriptors.first?.key)
    }

    private func refreshColumnTitles() {
        configureTableColumns(columnsForCurrentLocation(),
                              folderTypeID: currentListViewFolderTypeID ?? listViewFolderTypeIDForCurrentLocation())
    }

    private func listViewFolderTypeIDForCurrentLocation() -> String {
        if let level = archiveStack.last {
            return FileManagerViewPreferences.archiveListViewFolderTypeID(formatName: level.archive.formatName)
        }
        return FileManagerViewPreferences.fileSystemListViewFolderTypeID
    }

    private func handleTableColumnLayoutDidChange() {
        guard !isApplyingListViewPreferences else { return }
        currentColumns = FileManagerColumn.visibleColumns(inTableOrder: tableView.tableColumns,
                                                          availableColumns: columnsForCurrentLocation())
        persistCurrentListViewInfo()
    }

    private func persistCurrentListViewInfo() {
        guard isViewLoaded,
              !isApplyingListViewPreferences,
              !FileManagerViewPreferences.isListViewInfoPersistenceDisabled,
              let folderTypeID = currentListViewFolderTypeID
        else {
            return
        }

        let availableColumns = columnsForCurrentLocation()
        let existingInfo = FileManagerViewPreferences.listViewInfo(forFolderTypeID: folderTypeID)
        let visibleTableColumns = tableView.tableColumns.map { tableColumn in
            FileManagerViewPreferences.ListViewColumnInfo(id: FileManagerColumnID(rawValue: tableColumn.identifier.rawValue),
                                                          isVisible: true,
                                                          width: tableColumn.width)
        }
        let columnInfos = FileManagerViewPreferences.listViewColumnInfosPreservingHiddenColumns(
            availableColumns: availableColumns,
            visibleColumns: visibleTableColumns,
            previousInfo: existingInfo,
        )
        let sortDescriptor = tableView.sortDescriptors.first
        let info = FileManagerViewPreferences.ListViewInfo(
            sortKey: sortDescriptor?.key ?? FileManagerColumnID.name.rawValue,
            ascending: sortDescriptor?.ascending ?? true,
            columns: columnInfos,
        )

        guard FileManagerViewPreferences.listViewInfo(forFolderTypeID: folderTypeID) != info else { return }
        FileManagerViewPreferences.setListViewInfo(info, forFolderTypeID: folderTypeID)
    }

    private func resetTableColumnsForCurrentLocation() {
        guard isViewLoaded else { return }
        configureTableColumns(columnsForCurrentLocation(),
                              folderTypeID: listViewFolderTypeIDForCurrentLocation(),
                              preferSavedState: false)
        sortCurrentItems(by: tableView.sortDescriptors)
        tableView.reloadData()
    }

    private func updateHighlightedTableColumn(for sortKey: String?) {
        guard let sortKey,
              let columnID = FileManagerViewPreferences.highlightedColumnID(for: sortKey,
                                                                            columns: currentColumns)
        else {
            tableView.highlightedTableColumn = nil
            return
        }

        tableView.highlightedTableColumn = tableView.tableColumns.first { $0.identifier.rawValue == columnID.rawValue }
    }

    private func clearSuspendedState() {
        guard isSuspended else { return }
        isSuspended = false
        suspendedOverlay?.removeFromSuperview()
        suspendedOverlay = nil
    }

    private func installDirectoryWatcher(for url: URL) {
        directoryWatcher?.stop()
        let watcher = DirectoryWatcher(directory: url)
        watcher.onChange = { [weak self] in
            self?.autoRefreshIfPossible()
        }
        directoryWatcher = watcher
    }

    private func tearDownDirectoryWatcher() {
        directoryWatcher?.stop()
        directoryWatcher = nil
    }

    // MARK: - Public Interface

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
        guard directoryWatcher?.wasChanged() == true else { return }
        guard !isLiveScrolling else {
            pendingAutoRefresh = true
            return
        }

        pendingAutoRefresh = false
        autoRefreshCurrentDirectoryIfNeeded()
    }

    func reloadPresentedValues() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        updateStatusBar()
    }

    func focusFileList() {
        delegate?.paneDidBecomeActive(self)
        view.window?.makeFirstResponder(tableView)
    }

    var preferredInitialFirstResponder: NSView {
        tableView
    }

    var isVirtualLocation: Bool {
        isInsideArchive
    }

    func currentArchiveMutationTarget() -> (archive: SZArchive, subdir: String)? {
        guard let level = archiveStack.last,
              let target = archiveMutationTarget(for: level)
        else {
            return nil
        }
        return (target.archive, target.subdir)
    }

    func currentArchiveDestinationDisplayPath() -> String? {
        guard isInsideArchive, supportsInPlaceArchiveMutation else {
            return nil
        }
        return currentLocationDisplayPath
    }

    func currentArchiveMutationTarget(for archiveURL: URL,
                                      subdir: String) -> (archive: SZArchive, subdir: String)?
    {
        guard let level = archiveStack.last,
              URL(fileURLWithPath: level.archivePath).standardizedFileURL == archiveURL.standardizedFileURL
        else {
            return nil
        }

        guard let target = archiveMutationTarget(for: level, subdir: subdir) else {
            return nil
        }

        return (target.archive, target.subdir)
    }

    var canQuickLookSelection: Bool {
        !selectedRealPaneItems().isEmpty
    }

    func canAddSelectedItemsToArchive() -> Bool {
        if isInsideArchive {
            return supportsInPlaceArchiveMutation
        }
        return !selectedFileSystemItems().isEmpty
    }

    func canCreateFolderHere() -> Bool {
        if isInsideArchive {
            return supportsInPlaceArchiveMutation
        }
        return true
    }

    func canCopySelection() -> Bool {
        if isInsideArchive {
            return !selectedArchiveItems().isEmpty
        }
        return !selectedFileSystemItems().isEmpty
    }

    func canMoveSelection() -> Bool {
        !isInsideArchive && !selectedFileSystemItems().isEmpty
    }

    func canDeleteSelection() -> Bool {
        if isInsideArchive {
            return supportsInPlaceArchiveMutation && !selectedArchiveItems().isEmpty
        }
        return !selectedFileSystemItems().isEmpty
    }

    func canRenameSelection() -> Bool {
        if isInsideArchive {
            return supportsInPlaceArchiveMutation && selectedArchiveItems().count == 1
        }
        return selectedFileSystemItems().count == 1
    }

    func canExtractSelectionOrArchive() -> Bool {
        if isInsideArchive {
            return !archiveItemsForSelectionOrDisplayedItems().isEmpty
        }
        return selectedArchiveCandidateURL() != nil
    }

    func canTestArchiveSelection() -> Bool {
        if isInsideArchive {
            return archiveStack.last != nil
        }
        return selectedArchiveCandidateURL() != nil
    }

    func canOpenSelection() -> Bool {
        !selectedPaneItems().isEmpty
    }

    func canOpenSelectionInside() -> Bool {
        selectedRealPaneItems().count == 1
    }

    func canOpenSelectionOutside() -> Bool {
        guard let item = selectedSingleRealPaneItem() else { return false }

        switch item {
        case .parent:
            return false
        case .filesystem:
            return true
        case let .archive(archiveItem):
            return !archiveItem.isDirectory
        }
    }

    func canCreateFileHere() -> Bool {
        !isInsideArchive
    }

    func canCalculateSelectionHashes() -> Bool {
        selectedSingleFileSystemFile() != nil
    }

    func canShowSelectedItemProperties() -> Bool {
        !selectedRealPaneItems().isEmpty
    }

    func canGoUp() -> Bool {
        isInsideArchive || currentDirectory.path != currentDirectory.deletingLastPathComponent().path
    }

    func canSelectVisibleItems() -> Bool {
        let firstSelectableRow = showsParentRow ? 1 : 0
        return numberOfRows(in: tableView) > firstSelectableRow
    }

    func canDeselectSelection() -> Bool {
        !tableView.selectedRowIndexes.isEmpty
    }

    func canShowFoldersHistory() -> Bool {
        !recentDirectories.isEmpty
    }

    func selectedArchiveCandidateURL() -> URL? {
        let selectedItems = selectedFileSystemItems()
        guard selectedItems.count == 1, !selectedItems[0].isDirectory else { return nil }
        return selectedItems[0].url
    }

    func sourceArchiveURLForPostProcessing() -> URL? {
        if let level = archiveStack.last, level.temporaryDirectory == nil {
            return URL(fileURLWithPath: level.archivePath).standardizedFileURL
        }

        return selectedArchiveCandidateURL()?.standardizedFileURL
    }

    func quarantineSourceArchiveURLForExtraction() -> URL? {
        if let level = archiveStack.last {
            return URL(fileURLWithPath: level.archivePath).standardizedFileURL
        }

        return selectedArchiveCandidateURL()?.standardizedFileURL
    }

    func openSelection() {
        openSelectedItem(nil)
    }

    func openSelectionInside(_ openMode: FileManagerArchiveOpenMode) {
        guard let item = selectedSingleRealPaneItem() else { return }

        switch item {
        case .parent:
            return

        case let .filesystem(fileSystemItem):
            if fileSystemItem.isDirectory {
                loadDirectory(fileSystemItem.url)
            } else {
                _ = openArchiveInline(fileSystemItem.url,
                                      hostDirectory: currentDirectory,
                                      openMode: openMode)
            }

        case let .archive(archiveItem):
            if archiveItem.isDirectory {
                navigateArchiveSubdir(archiveItem.pathParts.joined(separator: "/"))
            } else {
                openItemInArchive(archiveItem, strategy: .forceInternal(openMode))
            }
        }
    }

    func openSelectionOutside() {
        guard let item = selectedSingleRealPaneItem() else { return }

        switch item {
        case .parent:
            return

        case let .filesystem(fileSystemItem):
            if fileSystemItem.isDirectory {
                _ = NSWorkspace.shared.open(fileSystemItem.url)
                return
            }

            if !openExternallyIfPossible(fileSystemItem.url) {
                showErrorAlert(unavailableExternalOpenError(for: fileSystemItem.name))
            }

        case let .archive(archiveItem):
            guard !archiveItem.isDirectory,
                  let context = currentArchiveItemWorkflowContext() else { return }

            openArchiveItemExternally(archiveItem,
                                      context: context,
                                      strategy: .forceExternal)
        }
    }

    func goUpOneLevel() {
        goUp()
    }

    func renameSelection() {
        renameSelected(nil)
    }

    func deleteSelection() {
        deleteSelected(nil)
    }

    func showSelectedItemProperties() {
        showItemProperties(nil)
    }

    func extractSelectionHere() {
        extractHere(nil)
    }

    func openRootFolder() {
        if isInsideArchive {
            navigateArchiveSubdir("")
            return
        }

        loadDirectory(FileManagerFileSystemNavigation.rootURL(for: currentDirectory))
    }

    func recentDirectoryHistory() -> [URL] {
        recentDirectories
    }

    func setRecentDirectoryHistory(_ entries: [URL]) {
        recentDirectories = FileManagerRecentDirectoryHistory.normalized(entries)
    }

    func openRecentDirectory(_ url: URL) {
        if isInsideArchive, !closeAllArchives(showError: true) {
            return
        }
        loadDirectory(url)
    }

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

    func sortByName() {
        applySortDescriptor(columnIdentifier: "name",
                            key: "name",
                            ascending: true,
                            selector: #selector(NSString.localizedStandardCompare(_:)))
    }

    func sortBySize() {
        applySortDescriptor(columnIdentifier: "size",
                            key: "size",
                            ascending: false)
    }

    func sortByType() {
        applySortDescriptor(columnIdentifier: "name",
                            key: "type",
                            ascending: true,
                            selector: #selector(NSString.localizedStandardCompare(_:)))
    }

    func sortByModifiedDate() {
        applySortDescriptor(columnIdentifier: "modified",
                            key: "modified",
                            ascending: false)
    }

    func sortByCreatedDate() {
        applySortDescriptor(columnIdentifier: "created",
                            key: "created",
                            ascending: false)
    }

    var primarySortKey: String? {
        tableView.sortDescriptors.first?.key
    }

    var currentLocationDisplayPath: String {
        isInsideArchive ? currentArchiveDisplayPathPrefix() : currentDirectory.path
    }

    var selectedRealItemCount: Int {
        selectedRealPaneItems().count
    }

    var suggestedExtractDestinationName: String? {
        if let level = archiveStack.last {
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

    func selectedOrDisplayedArchiveEntriesForExtraction() -> [ArchiveItem] {
        guard let context = currentArchiveExtractionContext else { return [] }

        let indices = Set(FileManagerArchiveExtraction.entryIndices(for: archiveItemsForSelectionOrDisplayedItems(),
                                                                    allEntries: context.allEntries).map(\.intValue))
        return context.allEntries.filter { indices.contains($0.index) }
    }

    func pathPrefixToStripForCurrentExtraction(destinationURL: URL,
                                               pathMode: SZPathMode,
                                               eliminateDuplicates: Bool) -> String?
    {
        guard let context = currentArchiveExtractionContext else { return nil }

        return FileManagerArchiveExtraction.pathPrefixToStrip(for: archiveItemsForSelectionOrDisplayedItems(),
                                                              context: context,
                                                              destinationURL: destinationURL,
                                                              pathMode: pathMode,
                                                              eliminateDuplicates: eliminateDuplicates)
    }

    func selectedItemNames(limit: Int? = nil) -> [String] {
        if isInsideArchive {
            return FileManagerItemPresentation.displayNames(for: selectedArchiveItems(), limit: limit)
        }
        return FileManagerItemPresentation.displayNames(for: selectedFileSystemItems(), limit: limit)
    }

    func extractDialogInfoText(previewItemLimit: Int = 5) -> String {
        guard isInsideArchive else {
            return FileManagerItemPresentation.fileSystemItemsInfoText(location: currentLocationDisplayPath,
                                                                       items: selectedFileSystemItems(),
                                                                       previewItemLimit: previewItemLimit)
        }

        return FileManagerItemPresentation.archiveItemsInfoText(location: currentLocationDisplayPath,
                                                                items: archiveItemsForSelectionOrDisplayedItems(),
                                                                previewItemLimit: previewItemLimit,
                                                                includeSummary: true)
    }

    func prepareQuickLookPreviewForFileSystem() throws -> FileManagerQuickLookPreparedPreview? {
        guard !isInsideArchive else { return nil }

        let selectedEntries = selectedQuickLookRowsAndItems()
        guard !selectedEntries.isEmpty else {
            throw FileManagerQuickLookPreparation.error(SZL10n.string("app.fileManager.quickLook.selectItems"))
        }

        let selection = selectedEntries.compactMap { entry -> FileManagerQuickLookFileSystemSelection? in
            guard case let .filesystem(item) = entry.item else { return nil }
            return FileManagerQuickLookFileSystemSelection(item: item,
                                                           source: quickLookSourceInfo(forRow: entry.row,
                                                                                       paneItem: entry.item))
        }
        return try FileManagerQuickLookPreparation.fileSystemPreview(for: selection)
    }

    @MainActor
    func prepareQuickLookPreview(maxArchiveItemSize: UInt64,
                                 maxArchiveCombinedSize: UInt64,
                                 maxSolidArchiveSize: UInt64) async throws -> FileManagerQuickLookPreparedPreview
    {
        if let filesystemPreview = try prepareQuickLookPreviewForFileSystem() {
            return filesystemPreview
        }

        let selectedEntries = selectedQuickLookRowsAndItems()
        guard !selectedEntries.isEmpty else {
            throw FileManagerQuickLookPreparation.error(SZL10n.string("app.fileManager.quickLook.selectItems"))
        }

        guard let level = archiveStack.last else {
            throw FileManagerQuickLookPreparation.error(SZL10n.string("app.fileManager.quickLook.cannotPreviewArchive"))
        }

        let archiveSelection = selectedEntries.compactMap { entry -> (row: Int, item: ArchiveItem)? in
            guard case let .archive(item) = entry.item else { return nil }
            return (entry.row, item)
        }
        let archiveItems = archiveSelection.map(\.item)
        try FileManagerQuickLookPreparation.validateArchiveItems(archiveItems,
                                                                 archiveHasActiveOperations: level.operationGate.hasActiveLeases,
                                                                 isSolidArchive: level.archive.isSolidArchive,
                                                                 archiveSizeProvider: {
                                                                     FileManagerQuickLookPreparation.archivePhysicalSize(reportedSize: level.archive.archivePhysicalSize,
                                                                                                                         archivePath: level.archivePath)
                                                                 },
                                                                 maxArchiveItemSize: maxArchiveItemSize,
                                                                 maxArchiveCombinedSize: maxArchiveCombinedSize,
                                                                 maxSolidArchiveSize: maxSolidArchiveSize)

        guard let context = currentArchiveItemWorkflowContext() else {
            throw FileManagerQuickLookPreparation.error(SZL10n.string("app.fileManager.quickLook.cannotPreviewArchive"))
        }

        let stagedPreview = try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("app.progress.working"),
                                                                 initialFileName: archiveItems.count == 1 ? archiveItems[0].path : nil,
                                                                 parentWindow: view.window,
                                                                 deferredDisplay: true)
        { session in
            try self.archiveItemWorkflowService.stageQuickLookItems(archiveItems,
                                                                    context: context,
                                                                    session: session)
        }

        let previewSelection = archiveSelection.map { selection in
            FileManagerQuickLookArchiveSelection(item: selection.item,
                                                 source: quickLookSourceInfo(forRow: selection.row,
                                                                             paneItem: .archive(selection.item)))
        }
        let previewItems = FileManagerQuickLookPreparation.archivePreviewItems(for: previewSelection,
                                                                               stagedFileURLs: stagedPreview.fileURLs)
        return FileManagerQuickLookPreparedPreview(items: previewItems,
                                                   temporaryDirectories: [stagedPreview.temporaryDirectory])
    }

    func cleanupQuickLookTemporaryDirectories(_ temporaryDirectories: [URL]) {
        for url in temporaryDirectories {
            archiveItemWorkflowService.cleanup(url)
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

    func selectedFilePaths() -> [String] {
        selectedFileSystemItems().map(\.url.path)
    }

    func selectedFileURLs() -> [URL] {
        selectedFileSystemItems().map(\.url.standardizedFileURL)
    }

    @discardableResult
    func revealFileSystemItemURLs(_ urls: [URL]) -> Bool {
        guard let target = FileManagerFileSystemNavigation.revealTarget(for: urls) else { return false }

        if isInsideArchive, !closeAllArchives(showError: true) {
            return false
        }

        let selectionState = FileSystemSelectionState(selectedPaths: target.selectedPaths,
                                                      focusedPath: target.focusedPath)
        navigateToDirectory(target.parentDirectory,
                            showError: true,
                            selectionState: selectionState,
                            focusAfterLoad: true)
        return true
    }

    @discardableResult
    func openFileSystemItemURL(_ url: URL) -> Bool {
        switch FileManagerFileSystemNavigation.openTarget(for: url) {
        case let .directory(directoryURL):
            if isInsideArchive, !closeAllArchives(showError: true) {
                return false
            }

            navigateToDirectory(directoryURL,
                                showError: true,
                                focusAfterLoad: true)
            return true
        case let .file(fileURL, hostDirectory):
            return openFileSystemArchiveURL(fileURL,
                                            hostDirectory: hostDirectory)
        case nil:
            return false
        }
    }

    private func openFileSystemArchiveURL(_ fileURL: URL,
                                          hostDirectory: URL) -> Bool
    {
        switch openArchiveInline(fileURL,
                                 hostDirectory: hostDirectory,
                                 showError: false,
                                 replaceCurrentState: true)
        {
        case .opened:
            focusFileList()
            return true
        case .unsupportedArchive:
            return revealFileSystemItemURLs([fileURL])
        case .cancelled:
            return false
        case let .failed(error):
            showErrorAlert(error)
            return false
        }
    }

    nonisolated func transferFileSystemItemURLs(_ urls: [URL],
                                                to destinationDirectory: URL,
                                                operation: NSDragOperation,
                                                session: SZOperationSession) throws
    {
        try FileOperationFileSystemTransfer.perform(urls,
                                                    to: destinationDirectory,
                                                    operation: operation,
                                                    session: session)
    }

    func canTransferFileSystemItemURLs(_ urls: [URL],
                                       to destinationURL: URL,
                                       operation: NSDragOperation,
                                       presentingIn window: NSWindow?) -> Bool
    {
        guard let conflict = FileManagerTransferPathValidation.ancestryConflict(sourceURLs: urls,
                                                                                destinationURL: destinationURL)
        else {
            return true
        }

        szPresentTransferAncestryConflict(conflict,
                                          move: operation == .move,
                                          for: window)
        return false
    }

    func canTransferFileSystemItemURLsToArchive(_ urls: [URL],
                                                archiveURL: URL?,
                                                operation: NSDragOperation,
                                                presentingIn window: NSWindow?) -> Bool
    {
        guard let archiveURL else {
            return true
        }

        let standardizedArchiveURL = archiveURL.standardizedFileURL
        let standardizedSourceURLs = Set(urls.map(\.standardizedFileURL))
        guard !standardizedSourceURLs.contains(standardizedArchiveURL) else {
            szPresentTransferArchiveSelfConflict(move: operation == .move,
                                                 for: window)
            return false
        }

        guard let conflict = FileManagerTransferPathValidation.ancestryConflict(sourceURLs: urls,
                                                                                destinationURL: standardizedArchiveURL)
        else {
            return true
        }

        szPresentTransferAncestryConflict(conflict,
                                          move: operation == .move,
                                          for: window)
        return false
    }

    func createFolder(named name: String) {
        if isInsideArchive {
            guard let target = currentArchiveMutationTarget() else {
                showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.creatingFolders"))
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let currentTarget = revalidatedArchiveMutationTarget(for: target) else {
                    showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.creatingFolders"))
                    return
                }

                let createdPath = currentTarget.subdir.isEmpty ? name : currentTarget.subdir + "/" + name

                do {
                    try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("create.folder"),
                                                         parentWindow: view.window,
                                                         deferredDisplay: true)
                    { session in
                        try currentTarget.archive.createFolderNamed(name,
                                                                    inArchiveSubdir: currentTarget.subdir,
                                                                    session: session)
                    }
                    refreshArchiveAfterMutation(selectingPath: createdPath)
                    publishArchiveMutationIfNeeded(selectingPaths: [createdPath])
                } catch {
                    showErrorAlert(error)
                }
            }
            return
        }

        let url = currentDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            refresh()
        } catch {
            showErrorAlert(error)
        }
    }

    func createFile(named name: String) {
        guard !isInsideArchive else {
            showUnsupportedArchiveOperationAlert(action: SZL10n.string("app.fileManager.action.creatingFiles"))
            return
        }

        let url = currentDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            showErrorAlert(NSError(domain: NSCocoaErrorDomain,
                                   code: NSFileWriteFileExistsError,
                                   userInfo: [
                                       NSFilePathErrorKey: url.path,
                                       NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.error.fileAlreadyExists", name),
                                   ]))
            return
        }

        if FileManager.default.createFile(atPath: url.path, contents: Data()) {
            refresh()
            return
        }

        showErrorAlert(NSError(domain: NSCocoaErrorDomain,
                               code: NSFileWriteUnknownError,
                               userInfo: [
                                   NSFilePathErrorKey: url.path,
                                   NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.error.unableToCreate", name),
                               ]))
    }

    private func updateStatusBar() {
        let displayedSummary = if isInsideArchive {
            FileManagerItemPresentation.summary(for: archiveDisplayItems)
        } else {
            FileManagerItemPresentation.summary(for: items)
        }

        let selectedSummary: FileManagerItemStatusSummary? = if isInsideArchive {
            FileManagerItemPresentation.summary(for: selectedArchiveItems())
        } else {
            FileManagerItemPresentation.summary(for: selectedFileSystemItems())
        }

        statusLabel.stringValue = FileManagerItemPresentation.statusBarText(displayed: displayedSummary,
                                                                            selected: selectedSummary)
    }

    private func recordDirectoryVisit(_ url: URL) {
        recentDirectories = FileManagerRecentDirectoryHistory.recordingVisit(url,
                                                                             in: recentDirectories)
    }

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

    private func handleSettingsDidChange(_ settingsKey: SZSettingsKey) {
        switch settingsKey {
        case .showDots, .showRealFileIcons, .showGridLines, .singleClickOpen:
            if settingsKey == .showRealFileIcons {
                iconProvider.removeAllCachedImages()
            }
            applyFileManagerSettings()
        case .showHiddenFiles:
            refresh()
            return
        case .fileManagerShortcutPreset, .fileManagerCustomShortcuts:
            tableView.menu = buildContextMenu()
            return
        default:
            return
        }

        tableView.reloadData()
        updateStatusBar()
    }

    private func quickLookSourceInfo(forRow row: Int,
                                     paneItem: PaneItem) -> FileManagerQuickLookItemSource
    {
        let transitionImage = makeQuickLookTransitionImage(for: paneItem)
        return FileManagerQuickLookItemSource(frameOnScreen: FileManagerQuickLookSourceGeometry.frameOnScreen(forRow: row,
                                                                                                              in: tableView,
                                                                                                              window: view.window,
                                                                                                              iconSize: iconSize),
                                              transitionImage: transitionImage)
    }

    private func makeQuickLookTransitionImage(for paneItem: PaneItem) -> NSImage? {
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

    private func iconImage(for paneItem: PaneItem, isDirectory: Bool, iconPath: String) -> NSImage? {
        iconProvider.image(for: iconSource(for: paneItem,
                                           isDirectory: isDirectory,
                                           iconPath: iconPath),
                           showsRealFileIcons: showsRealFileIcons)
    }

    private func iconSource(for paneItem: PaneItem,
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

    private func activatePaneItem(at row: Int) {
        guard let item = paneItem(at: row) else { return }

        switch item {
        case .parent:
            goUp()

        case let .archive(archiveItem):
            if archiveItem.isDirectory {
                navigateArchiveSubdir(archiveItem.pathParts.joined(separator: "/"))
            } else {
                openItemInArchive(archiveItem)
            }

        case let .filesystem(fileSystemItem):
            if fileSystemItem.isDirectory {
                loadDirectory(fileSystemItem.url)
            } else {
                if FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(fileSystemItem.url) {
                    if !openExternallyIfPossible(fileSystemItem.url) {
                        showErrorAlert(unavailableExternalOpenError(for: fileSystemItem.name))
                    }
                    return
                }

                switch openArchiveInline(fileSystemItem.url,
                                         hostDirectory: currentDirectory,
                                         showError: false)
                {
                case .opened:
                    break
                case let .unsupportedArchive(error):
                    let shouldFallbackExternally = FileManagerExternalOpenRouter.shouldFallbackUnsupportedArchiveExternally(for: fileSystemItem.url)
                    if shouldFallbackExternally {
                        if !openExternallyIfPossible(fileSystemItem.url) {
                            showErrorAlert(error)
                        }
                    } else {
                        showErrorAlert(error)
                    }
                case .cancelled:
                    break
                case let .failed(error):
                    showErrorAlert(error)
                }
            }
        }
    }

    @discardableResult
    func showArchive(at url: URL) -> Bool {
        showArchive(at: url, openMode: .defaultBehavior)
    }

    @discardableResult
    func showArchive(at url: URL,
                     openMode: FileManagerArchiveOpenMode) -> Bool
    {
        let parentDirectory = url.deletingLastPathComponent()
        let result = openArchiveInline(url,
                                       hostDirectory: parentDirectory,
                                       openMode: openMode,
                                       replaceCurrentState: true)
        if case .opened = result {
            return true
        }
        return false
    }

    func extractSelectedArchiveItems(to destinationURL: URL,
                                     session: SZOperationSession? = nil,
                                     overwriteMode: SZOverwriteMode = .ask,
                                     pathMode: SZPathMode = .currentPaths,
                                     password: String? = nil,
                                     preserveNtSecurityInfo: Bool = false,
                                     eliminateDuplicates: Bool = false,
                                     inheritDownloadedFileQuarantine: Bool = SZSettings.bool(.inheritDownloadedFileQuarantine)) throws
    {
        let selectedItems = selectedArchiveItems()
        guard !selectedItems.isEmpty else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.selectArchiveItems"))
        }
        try extractArchiveItems(selectedItems,
                                to: destinationURL,
                                session: session,
                                overwriteMode: overwriteMode,
                                pathMode: pathMode,
                                password: password,
                                preserveNtSecurityInfo: preserveNtSecurityInfo,
                                eliminateDuplicates: eliminateDuplicates,
                                inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
    }

    func extractCurrentSelectionOrDisplayedArchiveItems(to destinationURL: URL,
                                                        session: SZOperationSession? = nil,
                                                        overwriteMode: SZOverwriteMode = .ask,
                                                        pathMode: SZPathMode = .currentPaths,
                                                        password: String? = nil,
                                                        preserveNtSecurityInfo: Bool = false,
                                                        eliminateDuplicates: Bool = false,
                                                        inheritDownloadedFileQuarantine: Bool = SZSettings.bool(.inheritDownloadedFileQuarantine)) throws
    {
        let itemsToExtract = archiveItemsForSelectionOrDisplayedItems()
        guard !itemsToExtract.isEmpty else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.noArchiveItemsToExtract"))
        }
        try extractArchiveItems(itemsToExtract,
                                to: destinationURL,
                                session: session,
                                overwriteMode: overwriteMode,
                                pathMode: pathMode,
                                password: password,
                                preserveNtSecurityInfo: preserveNtSecurityInfo,
                                eliminateDuplicates: eliminateDuplicates,
                                inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
    }

    func prepareExtraction(to destinationURL: URL,
                           overwriteMode: SZOverwriteMode = .ask,
                           pathMode: SZPathMode = .currentPaths,
                           password: String? = nil,
                           preserveNtSecurityInfo: Bool = false,
                           eliminateDuplicates: Bool = false,
                           inheritDownloadedFileQuarantine: Bool = SZSettings.bool(.inheritDownloadedFileQuarantine)) throws -> FileManagerPreparedExtraction
    {
        let itemsToExtract = archiveItemsForSelectionOrDisplayedItems()
        return try prepareExtraction(of: itemsToExtract,
                                     emptySelectionMessage: SZL10n.string("app.fileManager.error.noArchiveItemsToExtract"),
                                     to: destinationURL,
                                     overwriteMode: overwriteMode,
                                     pathMode: pathMode,
                                     password: password,
                                     preserveNtSecurityInfo: preserveNtSecurityInfo,
                                     eliminateDuplicates: eliminateDuplicates,
                                     inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
    }

    func testCurrentArchive(session: SZOperationSession? = nil) throws {
        guard let level = archiveStack.last else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.noArchiveOpen"))
        }
        try level.archive.test(with: session)
    }

    /// Returns the archive handle for the currently open archive, for use off the main actor.
    func currentArchiveForTest() throws -> SZArchive {
        guard let level = archiveStack.last else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.noArchiveOpen"))
        }
        return level.archive
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
        let selectedItems = selectedArchiveItems()
        return try prepareExtraction(of: selectedItems,
                                     emptySelectionMessage: SZL10n.string("app.fileManager.error.selectArchiveItems"),
                                     to: destinationURL,
                                     overwriteMode: overwriteMode,
                                     pathMode: pathMode,
                                     password: password,
                                     preserveNtSecurityInfo: preserveNtSecurityInfo,
                                     eliminateDuplicates: eliminateDuplicates,
                                     inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
    }

    private var currentArchiveExtractionContext: FileManagerArchiveExtractionContext? {
        guard let level = archiveStack.last else { return nil }

        return FileManagerArchiveExtractionContext(archive: level.archive,
                                                   allEntries: level.allEntries,
                                                   currentSubdir: level.currentSubdir,
                                                   quarantineSourceArchivePath: quarantineSourceArchiveURLForExtraction()?.path)
    }

    private func prepareExtraction(of itemsToExtract: [ArchiveItem],
                                   emptySelectionMessage: String,
                                   to destinationURL: URL,
                                   overwriteMode: SZOverwriteMode,
                                   pathMode: SZPathMode,
                                   password: String?,
                                   preserveNtSecurityInfo: Bool,
                                   eliminateDuplicates: Bool,
                                   inheritDownloadedFileQuarantine: Bool) throws -> FileManagerPreparedExtraction
    {
        guard !itemsToExtract.isEmpty else {
            throw paneOperationError(emptySelectionMessage)
        }

        guard let context = currentArchiveExtractionContext else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.noArchiveOpen"))
        }

        guard let preparedExtraction = FileManagerArchiveExtraction.prepare(items: itemsToExtract,
                                                                            context: context,
                                                                            destinationURL: destinationURL,
                                                                            overwriteMode: overwriteMode,
                                                                            pathMode: pathMode,
                                                                            password: password,
                                                                            preserveNtSecurityInfo: preserveNtSecurityInfo,
                                                                            eliminateDuplicates: eliminateDuplicates,
                                                                            inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
        else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.cannotExtractSelected"))
        }

        return preparedExtraction
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let capabilities = paneCapabilities

        return switch menuItem.action {
        case #selector(openSelectedItem(_:)):
            capabilities.canOpenSelection
        case #selector(openInArchiveViewer(_:)):
            selectedArchiveCandidateURL() != nil
        case #selector(compressSelected(_:)):
            capabilities.canAddSelectedItemsToArchive
        case #selector(extractSelected(_:)), #selector(extractHere(_:)):
            capabilities.canExtractSelectionOrArchive
        case #selector(renameSelected(_:)):
            capabilities.canRenameSelection
        case #selector(deleteSelected(_:)):
            capabilities.canDeleteSelection
        case #selector(createFolderFromMenu(_:)):
            capabilities.canCreateFolderHere
        case #selector(showItemProperties(_:)):
            capabilities.canShowSelectedItemProperties
        default:
            true
        }
    }

    private func paneItem(at row: Int) -> PaneItem? {
        if showsParentRow, row == 0 {
            return .parent
        }

        let itemRow = row - (showsParentRow ? 1 : 0)
        if isInsideArchive {
            guard itemRow >= 0, itemRow < archiveDisplayItems.count else { return nil }
            return .archive(archiveDisplayItems[itemRow])
        }

        guard itemRow >= 0, itemRow < items.count else { return nil }
        return .filesystem(items[itemRow])
    }

    private func dropDestinationDirectory(for row: Int,
                                          dropOperation: NSTableView.DropOperation) -> URL?
    {
        guard !isInsideArchive else { return nil }
        return FileOperationDropTargetResolver.fileSystemDestination(currentDirectory: currentDirectory,
                                                                     dropOperation: dropOperation,
                                                                     item: paneItem(at: row)?.fileSystemItem)
    }

    private func archiveDropMutationTarget(for row: Int,
                                           dropOperation: NSTableView.DropOperation) -> (archive: SZArchive, subdir: String)?
    {
        guard let target = currentArchiveMutationTarget() else {
            return nil
        }

        guard let targetSubdir = FileOperationDropTargetResolver.archiveDestinationSubdir(currentSubdir: target.subdir,
                                                                                          dropOperation: dropOperation,
                                                                                          item: paneItem(at: row)?.archiveItem)
        else {
            return nil
        }
        return (target.archive, targetSubdir)
    }

    private func selectedPaneItems() -> [PaneItem] {
        tableView.selectedRowIndexes.compactMap { paneItem(at: $0) }
    }

    private func selectedQuickLookRowsAndItems() -> [(row: Int, item: PaneItem)] {
        tableView.selectedRowIndexes.compactMap { row in
            guard let item = paneItem(at: row) else { return nil }
            if case .parent = item {
                return nil
            }
            return (row, item)
        }
    }

    private func selectedRealPaneItems() -> [PaneItem] {
        selectedPaneItems().filter {
            if case .parent = $0 {
                return false
            }
            return true
        }
    }

    private func selectedSingleRealPaneItem() -> PaneItem? {
        let items = selectedRealPaneItems()
        guard items.count == 1 else { return nil }
        return items[0]
    }

    private func selectedFileSystemItems() -> [FileSystemItem] {
        selectedPaneItems().compactMap {
            guard case let .filesystem(item) = $0 else { return nil }
            return item
        }
    }

    func selectedSingleFileSystemFile() -> FileSystemItem? {
        let items = selectedFileSystemItems()
        guard items.count == 1, !items[0].isDirectory else { return nil }
        return items[0]
    }

    private func selectedArchiveItems() -> [ArchiveItem] {
        selectedPaneItems().compactMap {
            guard case let .archive(item) = $0 else { return nil }
            return item
        }
    }

    private func paneItemsForSelectionOrDisplayedItems() -> [PaneItem] {
        let selectedItems = selectedRealPaneItems()
        if !selectedItems.isEmpty {
            return selectedItems
        }
        return isInsideArchive ? archiveDisplayItems.map(PaneItem.archive) : []
    }

    private func archiveItemsForSelectionOrDisplayedItems() -> [ArchiveItem] {
        let selectedItems = selectedArchiveItems()
        return selectedItems.isEmpty ? archiveDisplayItems : selectedItems
    }

    private func currentArchiveDisplayPathPrefix() -> String {
        archiveStack.last?.displayPathPrefix ?? currentDirectory.path
    }

    private func archiveHostDirectory() -> URL {
        archiveStack.last?.filesystemDirectory ?? currentDirectory
    }

    private func currentArchiveItemWorkflowContext(acquireLease: Bool = true) -> FileManagerArchiveItemWorkflowContext? {
        guard let level = archiveStack.last else { return nil }
        let mutationTarget = acquireLease ? archiveMutationTarget(for: level) : nil
        let lease: FileManagerArchiveOperationGate.Lease?
        if acquireLease {
            guard let acquired = level.operationGate.acquireLease() else { return nil }
            lease = acquired
        } else {
            lease = nil
        }

        return FileManagerArchiveItemWorkflowContext(archive: level.archive,
                                                     hostDirectory: archiveHostDirectory(),
                                                     displayPathPrefix: currentArchiveDisplayPathPrefix(),
                                                     quarantineSourceArchivePath: quarantineSourceArchiveURLForExtraction()?.path,
                                                     mutationTarget: mutationTarget,
                                                     archiveOperationLease: lease)
    }

    private func hasConflictingNestedArchiveInstance(for identity: FileManagerNestedArchiveIdentity) -> Bool {
        FileManagerNestedArchiveConflictDetector.hasConflictingOpenInstance(for: identity,
                                                                            in: allVisibleArchiveCoordinationSnapshots())
    }

    private func hasDirtyNestedArchiveInstance(for identity: FileManagerNestedArchiveIdentity) -> Bool {
        FileManagerNestedArchiveConflictDetector.hasDirtyOpenInstance(for: identity,
                                                                      in: allVisibleArchiveCoordinationSnapshots())
    }

    private func allVisibleArchiveCoordinationSnapshots() -> [FileManagerNestedArchiveOpenSnapshot] {
        archiveCoordinationProvider?.archiveCoordinationSnapshots() ?? archiveCoordinationSnapshots()
    }

    private var coordinatedArchiveLocation: FileManagerCoordinatedArchiveLocation? {
        guard let level = archiveStack.last,
              level.temporaryDirectory == nil,
              level.nestedWriteBackInfo == nil
        else {
            return nil
        }

        return FileManagerCoordinatedArchiveLocation(archiveURL: URL(fileURLWithPath: level.archivePath),
                                                     currentSubdir: level.currentSubdir)
    }

    private func topLevelArchiveURL(for level: ArchiveLevel) -> URL? {
        guard level.temporaryDirectory == nil,
              level.nestedWriteBackInfo == nil
        else {
            return nil
        }

        return URL(fileURLWithPath: level.archivePath).standardizedFileURL
    }

    private func archiveMutationTarget(for level: ArchiveLevel,
                                       subdir: String? = nil) -> FileManagerArchiveMutationTarget?
    {
        guard archiveLevelSupportsInPlaceMutation(level) else {
            return nil
        }

        return FileManagerArchiveMutationTarget(archive: level.archive,
                                                subdir: subdir ?? level.currentSubdir,
                                                topLevelArchiveURL: topLevelArchiveURL(for: level))
    }

    private func canOpenArchive(at url: URL) -> Bool {
        let archive = SZArchive()
        do {
            try archive.open(atPath: url.path)
            archive.close()
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func materializedArchiveItems(from archive: SZArchive,
                                                             session: SZOperationSession?) throws -> [ArchiveItem]
    {
        try archive.entries(with: session).map { ArchiveItem(from: $0) }
    }

    private nonisolated static func materializedArchiveItemsAsync(from archive: SZArchive,
                                                                  session: SZOperationSession,
                                                                  reopenBeforeListing: Bool) async throws -> [ArchiveItem]
    {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    session.requestCancel()
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    let result: Result<[ArchiveItem], Error> = Result {
                        if reopenBeforeListing {
                            try archive.reopenAfterExternalMutation(with: session)
                        }
                        return try Self.materializedArchiveItems(from: archive,
                                                                 session: session)
                    }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            session.requestCancel()
        }
    }

    private func replaceArchiveLevelEntries(at index: Int,
                                            with entries: [ArchiveItem],
                                            preservingSubdir subdir: String? = nil)
    {
        guard archiveStack.indices.contains(index) else { return }

        let level = archiveStack[index]
        archiveStack[index] = ArchiveLevel(
            filesystemDirectory: level.filesystemDirectory,
            archivePath: level.archivePath,
            displayPathPrefix: level.displayPathPrefix,
            archive: level.archive,
            operationGate: level.operationGate,
            allEntries: entries,
            entryProperties: level.entryProperties,
            currentSubdir: subdir ?? level.currentSubdir,
            temporaryDirectory: level.temporaryDirectory,
            nestedIdentity: level.nestedIdentity,
            nestedWriteBackInfo: level.nestedWriteBackInfo,
        )
    }

    private func writeBackNestedArchiveChangesIfNeeded(for level: ArchiveLevel) throws -> (refreshedParent: (index: Int, entries: [ArchiveItem])?, publishedChange: FileManagerArchiveChange?) {
        guard let writeBackInfo = level.nestedWriteBackInfo else {
            return (nil, nil)
        }

        let temporaryArchiveURL = URL(fileURLWithPath: level.archivePath).standardizedFileURL
        guard let currentFingerprint = FileManagerArchiveFileFingerprint.captureIfPossible(for: temporaryArchiveURL) else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.nestedArchiveSyncFailed"))
        }

        guard currentFingerprint != writeBackInfo.initialFingerprint else {
            return (nil, nil)
        }

        let refreshedParentEntries = try ArchiveOperationRunner.runSynchronously(operationTitle: SZL10n.string("progress.updating"),
                                                                                 initialFileName: (writeBackInfo.parentItemPath as NSString).lastPathComponent,
                                                                                 parentWindow: view.window,
                                                                                 deferredDisplay: true)
        { session -> [ArchiveItem] in
            try writeBackInfo.parentTarget.archive.replaceItem(atPath: writeBackInfo.parentItemPath,
                                                               inArchiveSubdir: writeBackInfo.parentTarget.subdir,
                                                               withFileAtPath: temporaryArchiveURL.path,
                                                               session: session)
            return try Self.materializedArchiveItems(from: writeBackInfo.parentTarget.archive,
                                                     session: session)
        }

        let publishedChange = writeBackInfo.parentTarget.topLevelArchiveURL.map {
            FileManagerArchiveChange(archiveURL: $0,
                                     targetSubdir: writeBackInfo.parentTarget.subdir,
                                     selectingPaths: [writeBackInfo.parentItemPath],
                                     sourceIdentifier: ObjectIdentifier(self))
        }
        let refreshedParent = archiveStack.count >= 2
            ? (index: archiveStack.count - 2, entries: refreshedParentEntries)
            : nil
        return (refreshedParent, publishedChange)
    }

    @discardableResult
    private func closeArchiveLevel(_ level: ArchiveLevel,
                                   showError: Bool = false) -> Bool
    {
        cancelPendingArchiveRefresh()
        level.operationGate.beginClosingAndWaitForLeases()

        do {
            let nestedWriteBackResult = try writeBackNestedArchiveChangesIfNeeded(for: level)
            level.archive.close()
            archiveItemWorkflowService.cleanup(level.temporaryDirectory)

            if let lastLevel = archiveStack.last,
               lastLevel.archive === level.archive
            {
                archiveStack.removeLast()
            }

            if let refreshedParent = nestedWriteBackResult.refreshedParent {
                replaceArchiveLevelEntries(at: refreshedParent.index,
                                           with: refreshedParent.entries)
            }

            if let publishedChange = nestedWriteBackResult.publishedChange {
                FileManagerArchiveChangeCoordinator.publish(publishedChange)
            }

            if archiveStack.isEmpty {
                archiveDisplayItems.removeAll()
            } else if isViewLoaded, let currentLevel = archiveStack.last {
                navigateArchiveSubdir(currentLevel.currentSubdir)
            }
            updateTableColumnsForCurrentLocation()

            return true
        } catch {
            level.operationGate.cancelClosing()
            if showError {
                showErrorAlert(error)
            }
            return false
        }
    }

    @discardableResult
    private func closeAllArchives(showError: Bool = false) -> Bool {
        while let level = archiveStack.last {
            guard closeArchiveLevel(level, showError: showError) else {
                return false
            }
        }
        archiveDisplayItems.removeAll()
        updateTableColumnsForCurrentLocation()
        return true
    }

    @discardableResult
    func prepareForClose(showError: Bool = true) -> Bool {
        guard !isInsideArchive else {
            let didClose = closeAllArchives(showError: showError)
            if didClose, isViewLoaded {
                enterSuspendedState()
            }
            return didClose
        }
        return true
    }

    @discardableResult
    func prepareForDeactivation(showError: Bool = true) -> Bool {
        guard prepareForClose(showError: showError) else {
            return false
        }

        if isViewLoaded {
            enterSuspendedState()
        }

        return true
    }

    func reactivateIfSuspended() {
        guard isSuspended else { return }
        reactivatePane()
    }

    func closeDirectory() {
        guard !isSuspended else { return }
        if isInsideArchive {
            _ = closeAllArchives(showError: true)
        }
        if !isInsideArchive, isViewLoaded {
            enterSuspendedState()
        }
    }

    private func enterSuspendedState() {
        guard !isSuspended else { return }
        isSuspended = true

        tearDownDirectoryWatcher()
        cancelPendingDirectorySnapshot()
        cancelPendingArchiveRefresh()
        items.removeAll()
        archiveDisplayItems.removeAll()
        currentDirectoryFingerprint.removeAll()
        tableView.reloadData()
        statusLabel.stringValue = ""

        let overlay = NSView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        overlay.setAccessibilityIdentifier("fileManager.suspendedOverlay")

        let label = NSTextField(labelWithString: SZL10n.string("app.fileManager.suspendedDescription"))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        overlay.addSubview(label)

        let button = NSButton(title: SZL10n.string("app.fileManager.reactivatePane"),
                              target: self,
                              action: #selector(reactivatePaneClicked(_:)))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.setAccessibilityIdentifier("fileManager.reactivateButton")
        overlay.addSubview(button)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -12),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),
            button.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: 12),
        ])

        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])

        suspendedOverlay = overlay
    }

    @objc private func reactivatePaneClicked(_: Any?) {
        reactivatePane()
    }

    private func reactivatePane() {
        guard isSuspended else { return }
        loadDirectory(currentDirectory, showError: true)
    }

    private func preserveNestedArchiveTemporaryDirectories() -> [URL] {
        archiveStack.compactMap { level in
            guard level.nestedWriteBackInfo != nil,
                  let temporaryDirectory = level.temporaryDirectory
            else {
                return nil
            }

            archiveItemWorkflowService.unregister(temporaryDirectory)
            return temporaryDirectory.standardizedFileURL
        }
    }

    private func preserveRemainingTemporaryDirectories(_ urls: [URL]) {
        for url in urls {
            archiveItemWorkflowService.register(url)
        }
    }

    private func reloadCurrentArchiveEntries(selectingPaths paths: [String] = []) {
        guard let level = archiveStack.last else { return }
        scheduleArchiveEntriesReload(at: archiveStack.count - 1,
                                     selectingPaths: paths,
                                     preservingSubdir: level.currentSubdir)
    }

    func handlePublishedArchiveChange(_ change: FileManagerArchiveChange) {
        switch FileManagerArchiveChangeCoordinator.handlingDecision(for: change,
                                                                    currentLocation: coordinatedArchiveLocation,
                                                                    observerIdentifier: ObjectIdentifier(self))
        {
        case .ignore:
            return
        case let .reload(selectingPaths):
            reloadCoordinatedArchive(selectingPaths: selectingPaths)
        }
    }

    private func reloadCoordinatedArchive(selectingPaths paths: [String]) {
        guard let level = archiveStack.last,
              level.temporaryDirectory == nil,
              level.nestedWriteBackInfo == nil
        else {
            return
        }

        scheduleArchiveEntriesReload(at: archiveStack.count - 1,
                                     selectingPaths: paths,
                                     preservingSubdir: level.currentSubdir,
                                     reopenBeforeListing: true)
    }

    private func publishArchiveMutationIfNeeded(targetSubdir: String? = nil,
                                                selectingPaths paths: [String] = [])
    {
        guard let level = archiveStack.last,
              let archiveURL = topLevelArchiveURL(for: level)
        else {
            return
        }

        let normalizedTargetSubdir = normalizeArchivePath(targetSubdir ?? level.currentSubdir)
        let normalizedPaths = paths.map(normalizeArchivePath)

        FileManagerArchiveChangeCoordinator.publish(
            FileManagerArchiveChange(archiveURL: archiveURL,
                                     targetSubdir: normalizedTargetSubdir,
                                     selectingPaths: normalizedPaths,
                                     sourceIdentifier: ObjectIdentifier(self)),
        )
    }

    func refreshArchiveAfterMutation(targetSubdir: String? = nil,
                                     selectingPaths paths: [String] = [])
    {
        let normalizedTargetSubdir = normalizeArchivePath(targetSubdir ?? archiveStack.last?.currentSubdir ?? "")
        let normalizedCurrentSubdir = normalizeArchivePath(archiveStack.last?.currentSubdir ?? "")
        let selectionPaths = normalizedTargetSubdir == normalizedCurrentSubdir
            ? paths.map(normalizeArchivePath)
            : []
        reloadCurrentArchiveEntries(selectingPaths: selectionPaths)
    }

    private func refreshArchiveAfterMutation(selectingPath path: String? = nil) {
        refreshArchiveAfterMutation(selectingPaths: path.map { [$0] } ?? [])
    }

    private func reloadCurrentArchiveEntries(selectingPaths paths: [String],
                                             preservingSubdir subdir: String)
    {
        scheduleArchiveEntriesReload(at: archiveStack.count - 1,
                                     selectingPaths: paths,
                                     preservingSubdir: subdir)
    }

    private func scheduleArchiveEntriesReload(at index: Int,
                                              selectingPaths paths: [String],
                                              preservingSubdir subdir: String,
                                              reopenBeforeListing: Bool = false)
    {
        guard archiveStack.indices.contains(index) else { return }

        cancelPendingArchiveRefresh()

        guard let level = archiveStack.last else { return }
        guard index == archiveStack.count - 1 else { return }
        guard let lease = level.operationGate.acquireLease() else { return }

        archiveRefreshGeneration += 1
        let generation = archiveRefreshGeneration
        let archive = level.archive
        let archivePath = level.archivePath
        let normalizedPaths = paths.map(normalizeArchivePath)
        let session = SZOperationSession()

        archiveRefreshTask = Task { @MainActor [weak self] in
            defer { withExtendedLifetime(lease) {} }

            do {
                let refreshedEntries = try await Self.materializedArchiveItemsAsync(from: archive,
                                                                                    session: session,
                                                                                    reopenBeforeListing: reopenBeforeListing)
                guard !Task.isCancelled else { return }
                self?.finishArchiveEntriesReload(refreshedEntries,
                                                 generation: generation,
                                                 index: index,
                                                 archive: archive,
                                                 archivePath: archivePath,
                                                 subdir: subdir,
                                                 selectingPaths: normalizedPaths)
            } catch {
                guard !Task.isCancelled else { return }
                guard !szIsUserCancellation(error) else { return }
                guard self?.archiveRefreshGeneration == generation else { return }
                self?.showErrorAlert(error)
            }
        }
    }

    private func cancelPendingArchiveRefresh() {
        archiveRefreshGeneration += 1
        archiveRefreshTask?.cancel()
        archiveRefreshTask = nil
    }

    private func finishArchiveEntriesReload(_ entries: [ArchiveItem],
                                            generation: Int,
                                            index: Int,
                                            archive: SZArchive,
                                            archivePath: String,
                                            subdir: String,
                                            selectingPaths paths: [String])
    {
        guard archiveRefreshGeneration == generation else { return }
        guard archiveStack.indices.contains(index) else { return }

        let level = archiveStack[index]
        guard level.archive === archive,
              level.archivePath == archivePath
        else {
            return
        }

        replaceArchiveLevelEntries(at: index,
                                   with: entries,
                                   preservingSubdir: subdir)
        navigateArchiveSubdir(subdir)
        selectArchivePaths(paths)
    }

    private func selectArchivePaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }

        let selectedPaths = Set(paths.map(normalizeArchivePath))
        var rows = IndexSet()
        for (index, item) in archiveDisplayItems.enumerated() {
            if selectedPaths.contains(normalizeArchivePath(item.path)) {
                rows.insert(index + (showsParentRow ? 1 : 0))
            }
        }

        guard !rows.isEmpty else { return }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let firstRow = rows.first {
            tableView.scrollRowToVisible(firstRow)
        }
    }

    @discardableResult
    private func openExternallyIfPossible(_ url: URL,
                                          preservingTemporaryDirectory temporaryDirectory: URL? = nil) -> Bool
    {
        guard let applicationURL = FileManagerExternalOpenRouter.defaultExternalApplicationURL(for: url) else {
            return false
        }

        return openExternally(url,
                              withApplicationAt: applicationURL,
                              preservingTemporaryDirectory: temporaryDirectory)
    }

    @discardableResult
    private func openExternally(_ url: URL,
                                withApplicationAt applicationURL: URL,
                                preservingTemporaryDirectory temporaryDirectory: URL? = nil) -> Bool
    {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { [weak self] app, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let app {
                    if let temporaryDirectory {
                        archiveItemWorkflowService.scheduleCleanup(temporaryDirectory,
                                                                   when: app)
                    }
                    return
                }

                if let temporaryDirectory {
                    archiveItemWorkflowService.cleanup(temporaryDirectory)
                }

                if let error, !FileManagerExternalOpenRouter.shouldSuppressExternalOpenError(error) {
                    showErrorAlert(error)
                }
            }
        }
        return true
    }

    private func normalizeArchivePath(_ path: String) -> String {
        var normalized = path
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func applySortDescriptor(columnIdentifier: String,
                                     key: String,
                                     ascending: Bool,
                                     selector: Selector? = nil)
    {
        let descriptor = NSSortDescriptor(key: key,
                                          ascending: ascending,
                                          selector: selector)
        tableView.sortDescriptors = [descriptor]
        tableView.highlightedTableColumn = tableView.tableColumns.first { $0.identifier.rawValue == columnIdentifier }
        persistCurrentListViewInfo()
        sortCurrentItems(by: tableView.sortDescriptors)
        tableView.reloadData()
    }

    private func extractArchiveItems(_ itemsToExtract: [ArchiveItem],
                                     to destinationURL: URL,
                                     session: SZOperationSession?,
                                     overwriteMode: SZOverwriteMode,
                                     pathMode: SZPathMode,
                                     password: String?,
                                     preserveNtSecurityInfo: Bool,
                                     eliminateDuplicates: Bool,
                                     inheritDownloadedFileQuarantine: Bool) throws
    {
        let preparedExtraction = try prepareExtraction(of: itemsToExtract,
                                                       emptySelectionMessage: SZL10n.string("app.fileManager.error.cannotExtractSelected"),
                                                       to: destinationURL,
                                                       overwriteMode: overwriteMode,
                                                       pathMode: pathMode,
                                                       password: password,
                                                       preserveNtSecurityInfo: preserveNtSecurityInfo,
                                                       eliminateDuplicates: eliminateDuplicates,
                                                       inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
        try preparedExtraction.perform(session: session)
    }

    private func paneOperationError(_ description: String) -> NSError {
        NSError(domain: SZArchiveErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func unavailableExternalOpenError(for itemName: String) -> NSError {
        paneOperationError(SZL10n.string("app.fileManager.error.noAppToOpen", itemName))
    }

    private func invalidAddressBarPathError(for path: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [
                    NSFilePathErrorKey: path,
                    NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.error.pathNotFound", path),
                ])
    }

    private func showErrorAlert(_ error: Error) {
        szPresentError(error, for: view.window)
    }

    private func showUnsupportedArchiveOperationAlert(action: String) {
        szPresentMessage(title: SZL10n.string("app.fileManager.alert.actionNotAvailableTitle", action),
                         message: SZL10n.string("app.fileManager.alert.archiveModificationNotSupported"),
                         for: view.window)
    }

    func showReadOnlyArchiveMutationAlert(action: String) {
        if let level = archiveStack.last,
           level.operationGate.hasActiveLeases
        {
            return
        }

        if let level = archiveStack.last,
           let nestedIdentity = level.nestedIdentity,
           hasConflictingNestedArchiveInstance(for: nestedIdentity)
        {
            szPresentMessage(title: SZL10n.string("app.fileManager.alert.actionNotAvailableTitle", action),
                             message: SZL10n.string("app.fileManager.alert.nestedArchiveConflict"),
                             for: view.window)
            return
        }

        if let level = archiveStack.last,
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

    private func sortCurrentItems(by descriptors: [NSSortDescriptor]) {
        if isInsideArchive {
            FileManagerItemSorting.sort(&archiveDisplayItems, by: descriptors)
        } else {
            FileManagerItemSorting.sort(&items, by: descriptors)
        }
    }

    // MARK: - Actions

    @objc private func pathFieldSubmitted(_ sender: NSTextField) {
        delegate?.paneDidBecomeActive(self)
        let path = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return }

        switch FileManagerFileSystemNavigation.addressBarTarget(for: path) {
        case let .directory(url):
            guard closeAllArchives(showError: true) else {
                updatePathField()
                return
            }
            loadDirectory(url)
        case let .file(url, hostDirectory):
            if FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(url) {
                updatePathField()
                if !openExternallyIfPossible(url) {
                    showErrorAlert(unavailableExternalOpenError(for: url.lastPathComponent))
                }
                view.window?.makeFirstResponder(tableView)
                return
            }

            if isInsideArchive, !canOpenArchive(at: url) {
                updatePathField()
                if !openExternallyIfPossible(url) {
                    showErrorAlert(unavailableExternalOpenError(for: url.lastPathComponent))
                }
                view.window?.makeFirstResponder(tableView)
                return
            }

            guard closeAllArchives(showError: true) else {
                updatePathField()
                return
            }
            switch openArchiveInline(url,
                                     hostDirectory: hostDirectory,
                                     showError: false)
            {
            case .opened:
                break
            case let .unsupportedArchive(error):
                updatePathField()
                let shouldFallbackExternally = FileManagerExternalOpenRouter.shouldFallbackUnsupportedArchiveExternally(for: url)
                if shouldFallbackExternally {
                    if !openExternallyIfPossible(url) {
                        showErrorAlert(error)
                    }
                } else {
                    showErrorAlert(error)
                }
            case .cancelled:
                updatePathField()
            case let .failed(error):
                updatePathField()
                showErrorAlert(error)
            }
        case nil:
            updatePathField()
            showErrorAlert(invalidAddressBarPathError(for: path))
        }
        // Resign focus back to table
        view.window?.makeFirstResponder(tableView)
    }

    @objc private func goUpClicked(_: Any?) {
        goUp()
    }

    private func updatePathField() {
        if isInsideArchive {
            let level = archiveStack.last!
            pathField.stringValue = level.currentSubdir.isEmpty
                ? level.displayPathPrefix
                : level.displayPathPrefix + "/" + level.currentSubdir
        } else {
            pathField.stringValue = currentDirectory.path
        }

        updateLocationIcon()
    }

    private func updateLocationIcon() {
        let image: NSImage? = if let level = archiveStack.last {
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
        activatePaneItem(at: row)
    }

    @objc private func singleClickRow(_: Any?) {
        guard SZSettings.bool(.singleClickOpen) else { return }
        guard tableView.selectedRowIndexes.count <= 1 else { return }
        guard let event = NSApp.currentEvent else { return }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers.isEmpty else { return }

        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        activatePaneItem(at: row)
    }

    private func openItemInArchive(_ item: ArchiveItem,
                                   strategy: FileManagerArchiveItemOpenStrategy = .automatic)
    {
        guard item.index >= 0,
              let context = currentArchiveItemWorkflowContext() else { return }

        if case .forceExternal = strategy {
            openArchiveItemExternally(item,
                                      context: context,
                                      strategy: strategy)
            return
        }

        if case .automatic = strategy,
           FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(archiveItemPath: item.path)
        {
            openArchiveItemExternally(item,
                                      context: context,
                                      strategy: strategy)
            return
        }

        let openMode: FileManagerArchiveOpenMode
        let preserveTemporaryDirectoryOnUnsupported: Bool
        switch strategy {
        case .automatic:
            openMode = .defaultBehavior
            preserveTemporaryDirectoryOnUnsupported = true
        case let .forceInternal(mode):
            openMode = mode
            preserveTemporaryDirectoryOnUnsupported = false
        case .forceExternal:
            return
        }

        openArchiveItemInternally(item,
                                  context: context,
                                  openMode: openMode,
                                  preserveTemporaryDirectoryOnUnsupported: preserveTemporaryDirectoryOnUnsupported)
    }

    private func openArchiveItemExternally(_ item: ArchiveItem,
                                           context: FileManagerArchiveItemWorkflowContext,
                                           strategy: FileManagerArchiveItemOpenStrategy)
    {
        let displayPath = context.displayPath(for: item)

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let preparedOpen = try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                                                        initialFileName: displayPath,
                                                                        parentWindow: view.window,
                                                                        deferredDisplay: true)
                { [archiveItemWorkflowService] session in
                    try archiveItemWorkflowService.prepareExternalArchiveItemOpen(for: item,
                                                                                  context: context,
                                                                                  strategy: strategy,
                                                                                  session: session)
                }

                finishExternalArchiveItemOpen(preparedOpen,
                                              itemName: item.name)
            } catch {
                showErrorAlert(error)
            }
        }
    }

    private func finishExternalArchiveItemOpen(_ preparedOpen: FileManagerPreparedArchiveItemExternalOpen,
                                               itemName: String)
    {
        if let applicationURL = preparedOpen.applicationURL {
            _ = openExternally(preparedOpen.stagedFileURL,
                               withApplicationAt: applicationURL,
                               preservingTemporaryDirectory: preparedOpen.temporaryDirectory)
            return
        }

        if openExternallyIfPossible(preparedOpen.stagedFileURL,
                                    preservingTemporaryDirectory: preparedOpen.temporaryDirectory)
        {
            return
        }

        archiveItemWorkflowService.cleanup(preparedOpen.temporaryDirectory)
        showErrorAlert(unavailableExternalOpenError(for: itemName))
    }

    private func openArchiveItemInternally(_ item: ArchiveItem,
                                           context: FileManagerArchiveItemWorkflowContext,
                                           openMode: FileManagerArchiveOpenMode,
                                           preserveTemporaryDirectoryOnUnsupported: Bool)
    {
        let displayPath = context.displayPath(for: item)

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let preparedOpen = try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.opening"),
                                                                        initialFileName: displayPath,
                                                                        parentWindow: view.window,
                                                                        deferredDisplay: true)
                { [archiveItemWorkflowService] session in
                    try archiveItemWorkflowService.prepareInternalArchiveOpen(for: item,
                                                                              context: context,
                                                                              openMode: openMode,
                                                                              session: session)
                }

                let result = finishArchiveOpen(preparedOpen.preparedResult,
                                               temporaryDirectory: preparedOpen.temporaryDirectory,
                                               preserveTemporaryDirectoryOnUnsupported: preserveTemporaryDirectoryOnUnsupported,
                                               replaceCurrentState: false,
                                               showError: false)

                switch result {
                case .opened, .cancelled:
                    return

                case let .unsupportedArchive(error):
                    guard preserveTemporaryDirectoryOnUnsupported else {
                        showErrorAlert(error)
                        return
                    }

                    let shouldFallbackExternally = FileManagerExternalOpenRouter.shouldFallbackUnsupportedArchiveExternally(for: preparedOpen.stagedArchiveURL)
                    if shouldFallbackExternally {
                        if let applicationURL = FileManagerExternalOpenRouter.defaultExternalApplicationURL(forArchiveItemPath: item.path) {
                            _ = openExternally(preparedOpen.stagedArchiveURL,
                                               withApplicationAt: applicationURL,
                                               preservingTemporaryDirectory: preparedOpen.temporaryDirectory)
                        } else if !openExternallyIfPossible(preparedOpen.stagedArchiveURL,
                                                            preservingTemporaryDirectory: preparedOpen.temporaryDirectory)
                        {
                            archiveItemWorkflowService.cleanup(preparedOpen.temporaryDirectory)
                            showErrorAlert(error)
                        }
                    } else {
                        archiveItemWorkflowService.cleanup(preparedOpen.temporaryDirectory)
                        showErrorAlert(error)
                    }

                case let .failed(error):
                    showErrorAlert(error)
                }
            } catch {
                showErrorAlert(error)
            }
        }
    }

    private func goUp() {
        if isInsideArchive {
            let level = archiveStack.last!
            if !level.currentSubdir.isEmpty {
                let parent = if let lastSlash = level.currentSubdir.lastIndex(of: "/") {
                    String(level.currentSubdir[level.currentSubdir.startIndex ..< lastSlash])
                } else {
                    ""
                }
                navigateArchiveSubdir(parent)
            } else {
                let fsDir = level.filesystemDirectory
                guard closeArchiveLevel(level, showError: true) else {
                    return
                }
                if archiveStack.isEmpty {
                    loadDirectory(fsDir)
                } else {
                    let outer = archiveStack.last!
                    navigateArchiveSubdir(outer.currentSubdir)
                }
            }
        } else {
            let parent = currentDirectory.deletingLastPathComponent()
            loadDirectory(parent)
        }
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in _: NSTableView) -> Int {
        let itemCount = isInsideArchive ? archiveDisplayItems.count : items.count
        return itemCount + (showsParentRow ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnID = tableColumn?.identifier.rawValue else { return nil }
        guard let paneItem = paneItem(at: row) else { return nil }

        let requestedColumnID = FileManagerColumnID(rawValue: columnID)
        let dateFormatter = FileManagerViewPreferences.makeListDateFormatter()
        let itemText: String
        let itemIsDir: Bool
        let itemIconPath: String

        switch paneItem {
        case .parent:
            itemText = FileManagerItemPresentation.parentRowListCellText(for: requestedColumnID)
            itemIsDir = true
            itemIconPath = ""

        case let .archive(ai):
            itemText = FileManagerItemPresentation.listCellText(for: ai,
                                                                columnID: requestedColumnID,
                                                                dateFormatter: dateFormatter)
            itemIsDir = ai.isDirectory
            itemIconPath = ai.name

        case let .filesystem(item):
            itemText = FileManagerItemPresentation.listCellText(for: item,
                                                                columnID: requestedColumnID,
                                                                dateFormatter: dateFormatter)
            itemIsDir = item.isDirectory
            itemIconPath = item.url.path
        }

        let cellID = NSUserInterfaceItemIdentifier(columnID)
        let cell: NSTableCellView

        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(textField)
            cell.textField = textField

            if columnID == "name" {
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                imageView.imageAlignment = .alignCenter
                cell.addSubview(imageView)
                cell.imageView = imageView

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            } else {
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
        }

        let column = currentColumns.first(where: { $0.id == requestedColumnID })
            ?? columnsForCurrentLocation().first(where: { $0.id == requestedColumnID })
            ?? FileManagerColumn.definition(for: requestedColumnID)
        cell.textField?.alignment = column.alignment
        cell.textField?.font = column.font
        cell.textField?.lineBreakMode = columnID == "name" ? .byTruncatingMiddle : .byTruncatingTail

        func setDisplayText(_ text: String) {
            cell.textField?.stringValue = column.normalizedDisplayString(text)
        }

        setDisplayText(itemText)

        if requestedColumnID == .name {
            cell.imageView?.image = iconImage(for: paneItem, isDirectory: itemIsDir, iconPath: itemIconPath)
            switch paneItem {
            case .parent:
                cell.imageView?.contentTintColor = .secondaryLabelColor
            default:
                if showsRealFileIcons {
                    cell.imageView?.contentTintColor = nil
                } else {
                    cell.imageView?.contentTintColor = itemIsDir ? .systemBlue : .secondaryLabelColor
                }
            }
            cell.imageView?.image?.size = iconSize
        }

        return cell
    }

    func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
        listRowHeight
    }

    // MARK: - Drag Source

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let paneItem = paneItem(at: row) else { return nil }

        switch paneItem {
        case .parent:
            return nil

        case let .archive(ai):
            // Build context without a lease — the lease is acquired lazily in
            // writePromiseAsync so it doesn't outlive the extraction.
            guard let level = archiveStack.last,
                  let context = currentArchiveItemWorkflowContext(acquireLease: false)
            else { return nil }

            let promise = ArchiveDragPromise(item: ai,
                                             context: context,
                                             operationGate: level.operationGate,
                                             workflowService: archiveItemWorkflowService)
            let provider = NSFilePromiseProvider(fileType: ArchiveDragPromise.fileType(for: ai),
                                                 delegate: promise)
            provider.userInfo = promise
            return provider

        case let .filesystem(item):
            return item.url as NSURL
        }
    }

    // MARK: - Drop Destination (accept files dragged into this folder)

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if isInsideArchive {
            guard sourcePaneController(for: info)?.isVirtualLocation != true,
                  archiveDropMutationTarget(for: row, dropOperation: dropOperation) != nil
            else {
                pendingDropOperation = nil
                return []
            }

            if dropOperation == .on {
                tableView.setDropRow(row, dropOperation: .on)
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
            }

            let operation = resolvedArchiveDropOperation(for: info)
            pendingDropOperation = operation.isEmpty ? nil : (info.draggingSequenceNumber, operation)
            return operation
        }

        guard let destinationDirectory = dropDestinationDirectory(for: row, dropOperation: dropOperation) else {
            return []
        }

        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }

        let operation = resolvedDropOperation(for: info, destinationDirectory: destinationDirectory)
        pendingDropOperation = operation.isEmpty ? nil : (info.draggingSequenceNumber, operation)
        return operation
    }

    func tableView(_: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let sourcePane = sourcePaneController(for: info)

        if isInsideArchive {
            guard sourcePane?.isVirtualLocation != true,
                  let target = archiveDropMutationTarget(for: row, dropOperation: dropOperation)
            else {
                return false
            }

            let operation = takeResolvedArchiveDropOperation(for: info)

            let promiseReceivers = FileOperationDropResolver.promiseReceivers(in: info.draggingPasteboard)
            if !promiseReceivers.isEmpty {
                receivePromisedFiles(promiseReceivers,
                                     intoArchive: target,
                                     sourcePane: sourcePane)
                return true
            }

            guard !operation.isEmpty else { return false }
            let urls = FileOperationDropResolver.fileURLs(in: info.draggingPasteboard)
            guard !urls.isEmpty else { return false }

            guard canTransferFileSystemItemURLsToArchive(urls,
                                                         archiveURL: archiveDestinationFileURL(for: target),
                                                         operation: operation,
                                                         presentingIn: view.window)
            else {
                return false
            }

            beginConfirmedArchiveTransfer(urls,
                                          to: target,
                                          operation: operation,
                                          sourcePane: sourcePane)
            return true
        }

        guard let destDir = dropDestinationDirectory(for: row, dropOperation: dropOperation) else {
            return false
        }
        let operation = takeResolvedDropOperation(for: info, destinationDirectory: destDir)

        let promiseReceivers = FileOperationDropResolver.promiseReceivers(in: info.draggingPasteboard)
        if !promiseReceivers.isEmpty {
            receivePromisedFiles(promiseReceivers, at: destDir)
            return true
        }

        guard !operation.isEmpty else { return false }
        let urls = FileOperationDropResolver.fileURLs(in: info.draggingPasteboard)
        guard !urls.isEmpty else { return false }

        guard canTransferFileSystemItemURLs(urls,
                                            to: destDir,
                                            operation: operation,
                                            presentingIn: view.window)
        else {
            return false
        }

        beginDroppedFileTransfer(urls,
                                 to: destDir,
                                 operation: operation,
                                 sourcePane: sourcePane)
        return true
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateStatusBar()
        delegate?.paneDidBecomeActive(self)
        delegate?.paneSelectionDidChange(self)
    }

    private func resolvedDropOperation(for info: any NSDraggingInfo,
                                       destinationDirectory: URL) -> NSDragOperation
    {
        FileOperationDropResolver.fileSystemDropOperation(sourceMask: info.draggingSourceOperationMask,
                                                          containsFilePromises: FileOperationDropResolver.containsFilePromises(in: info.draggingPasteboard),
                                                          droppedFileURLs: FileOperationDropResolver.fileURLs(in: info.draggingPasteboard),
                                                          destinationDirectory: destinationDirectory)
    }

    private func takeResolvedDropOperation(for info: any NSDraggingInfo,
                                           destinationDirectory: URL) -> NSDragOperation
    {
        defer { pendingDropOperation = nil }

        if let pendingDropOperation,
           pendingDropOperation.sequenceNumber == info.draggingSequenceNumber
        {
            return pendingDropOperation.operation
        }

        return resolvedDropOperation(for: info, destinationDirectory: destinationDirectory)
    }

    private func resolvedArchiveDropOperation(for info: any NSDraggingInfo) -> NSDragOperation {
        FileOperationDropResolver.archiveDropOperation(sourceMask: info.draggingSourceOperationMask,
                                                       containsFilePromises: FileOperationDropResolver.containsFilePromises(in: info.draggingPasteboard))
    }

    private func takeResolvedArchiveDropOperation(for info: any NSDraggingInfo) -> NSDragOperation {
        defer { pendingDropOperation = nil }

        if let pendingDropOperation,
           pendingDropOperation.sequenceNumber == info.draggingSequenceNumber
        {
            return pendingDropOperation.operation
        }

        return resolvedArchiveDropOperation(for: info)
    }

    private func archiveDestinationFileURL(for target: (archive: SZArchive, subdir: String)) -> URL? {
        for level in archiveStack.reversed() {
            guard level.archive === target.archive else {
                continue
            }

            return URL(fileURLWithPath: level.archivePath).standardizedFileURL
        }

        return nil
    }

    private func revalidatedArchiveMutationTarget(for target: (archive: SZArchive, subdir: String)) -> (archive: SZArchive, subdir: String)? {
        guard let archiveURL = archiveDestinationFileURL(for: target) else {
            return nil
        }

        return currentArchiveMutationTarget(for: archiveURL,
                                            subdir: target.subdir)
    }

    private func sourcePaneController(for info: any NSDraggingInfo) -> FileManagerPaneController? {
        guard let sourceTableView = info.draggingSource as? NSTableView else {
            return nil
        }

        return sourceTableView.delegate as? FileManagerPaneController
    }

    private func beginDroppedFileTransfer(_ urls: [URL],
                                          to destinationDirectory: URL,
                                          operation: NSDragOperation,
                                          sourcePane: FileManagerPaneController?)
    {
        let operationTitle = operation == .move ? SZL10n.string("fileop.moving") : SZL10n.string("fileop.copying")

        Task { @MainActor [weak self, weak sourcePane] in
            guard let self else { return }

            do {
                try await ArchiveOperationRunner.run(operationTitle: operationTitle,
                                                     parentWindow: view.window,
                                                     deferredDisplay: true)
                { session in
                    try FileOperationFileSystemTransfer.perform(urls,
                                                                to: destinationDirectory,
                                                                operation: operation,
                                                                session: session)
                }

                refresh()
                if operation == .move,
                   let sourcePane,
                   sourcePane !== self
                {
                    sourcePane.refresh()
                }
            } catch {
                showErrorAlert(error)
            }
        }
    }

    func beginArchiveTransfer(_ urls: [URL],
                              to target: (archive: SZArchive, subdir: String),
                              operation: NSDragOperation,
                              sourcePane: FileManagerPaneController?,
                              cleanupDirectory: URL? = nil,
                              parentWindow: NSWindow? = nil,
                              requiresConfirmation: Bool = false,
                              operationTitle: String? = nil)
    {
        guard !urls.isEmpty else {
            if let cleanupDirectory {
                try? FileManager.default.removeItem(at: cleanupDirectory)
            }
            return
        }

        guard canTransferFileSystemItemURLsToArchive(urls,
                                                     archiveURL: archiveDestinationFileURL(for: target),
                                                     operation: operation,
                                                     presentingIn: parentWindow ?? view.window)
        else {
            if let cleanupDirectory {
                try? FileManager.default.removeItem(at: cleanupDirectory)
            }
            return
        }

        guard requiresConfirmation else {
            beginDroppedArchiveTransfer(urls,
                                        to: target,
                                        operation: operation,
                                        sourcePane: sourcePane,
                                        cleanupDirectory: cleanupDirectory,
                                        operationTitle: operationTitle)
            return
        }

        guard let window = parentWindow ?? view.window else {
            beginDroppedArchiveTransfer(urls,
                                        to: target,
                                        operation: operation,
                                        sourcePane: sourcePane,
                                        cleanupDirectory: cleanupDirectory,
                                        operationTitle: operationTitle)
            return
        }

        let archiveName = archiveStack.last.map { URL(fileURLWithPath: $0.archivePath).lastPathComponent } ?? "archive"
        let confirmation = FileOperationArchiveTransferConfirmation(sourceURLs: urls,
                                                                    archiveName: archiveName,
                                                                    targetSubdir: target.subdir,
                                                                    operation: operation)
        let confirmTitle = operation == .move ? SZL10n.string("toolbar.move") : SZL10n.string("toolbar.add")
        szBeginConfirmation(on: window,
                            title: confirmation.title,
                            message: confirmation.message,
                            confirmTitle: confirmTitle)
        { [weak self, weak sourcePane] confirmed in
            guard let self else {
                if let cleanupDirectory {
                    try? FileManager.default.removeItem(at: cleanupDirectory)
                }
                return
            }

            guard confirmed else {
                if let cleanupDirectory {
                    try? FileManager.default.removeItem(at: cleanupDirectory)
                }
                return
            }

            beginDroppedArchiveTransfer(urls,
                                        to: target,
                                        operation: operation,
                                        sourcePane: sourcePane,
                                        cleanupDirectory: cleanupDirectory,
                                        operationTitle: operationTitle)
        }
    }

    func beginConfirmedArchiveTransfer(_ urls: [URL],
                                       to target: (archive: SZArchive, subdir: String),
                                       operation: NSDragOperation,
                                       sourcePane: FileManagerPaneController?,
                                       cleanupDirectory: URL? = nil,
                                       parentWindow: NSWindow? = nil,
                                       operationTitle: String? = nil)
    {
        beginArchiveTransfer(urls,
                             to: target,
                             operation: operation,
                             sourcePane: sourcePane,
                             cleanupDirectory: cleanupDirectory,
                             parentWindow: parentWindow,
                             requiresConfirmation: true,
                             operationTitle: operationTitle)
    }

    private func beginDroppedArchiveTransfer(_ urls: [URL],
                                             to target: (archive: SZArchive, subdir: String),
                                             operation: NSDragOperation,
                                             sourcePane: FileManagerPaneController?,
                                             cleanupDirectory: URL? = nil,
                                             operationTitle: String? = nil)
    {
        let defaultOperationTitle = operation == .move ? SZL10n.string("fileop.moving") : SZL10n.string("fileop.copying")
        let resolvedOperationTitle = operationTitle ?? defaultOperationTitle

        Task { @MainActor [weak self, weak sourcePane] in
            defer {
                if let cleanupDirectory {
                    try? FileManager.default.removeItem(at: cleanupDirectory)
                }
            }

            guard let self else { return }
            guard let currentTarget = revalidatedArchiveMutationTarget(for: target) else {
                showReadOnlyArchiveMutationAlert(action: operation == .move ? SZL10n.string("app.fileManager.action.movingFilesIntoArchive") : SZL10n.string("app.fileManager.action.addingFilesToArchive"))
                return
            }

            let selectionPaths = FileOperationArchiveTransferSelection.selectionPaths(for: urls,
                                                                                      targetSubdir: currentTarget.subdir)

            do {
                try await ArchiveOperationRunner.run(operationTitle: resolvedOperationTitle,
                                                     parentWindow: view.window,
                                                     deferredDisplay: true)
                { session in
                    try currentTarget.archive.addPaths(urls.map(\.path),
                                                       toArchiveSubdir: currentTarget.subdir,
                                                       moveMode: operation == .move,
                                                       session: session)
                }

                refreshArchiveAfterMutation(targetSubdir: currentTarget.subdir,
                                            selectingPaths: selectionPaths)
                publishArchiveMutationIfNeeded(targetSubdir: currentTarget.subdir,
                                               selectingPaths: selectionPaths)
                if operation == .move,
                   let sourcePane,
                   sourcePane !== self
                {
                    sourcePane.refresh()
                }
            } catch {
                showErrorAlert(error)
            }
        }
    }

    private func receivePromisedFiles(_ promiseReceivers: [NSFilePromiseReceiver],
                                      at destinationDirectory: URL)
    {
        FileOperationPromisedFileReceiver.receive(promiseReceivers,
                                                  at: destinationDirectory)
        { [weak self] reception in
            self?.refresh()
            if let error = reception.firstError {
                self?.showErrorAlert(error)
            }
        }
    }

    private func receivePromisedFiles(_ promiseReceivers: [NSFilePromiseReceiver],
                                      intoArchive target: (archive: SZArchive, subdir: String),
                                      sourcePane: FileManagerPaneController?)
    {
        let stagingDirectory: URL
        do {
            stagingDirectory = try FileManagerTemporaryDirectorySupport.makeTemporaryDirectory(prefix: FileManagerTemporaryDirectorySupport.stagingPrefix)
        } catch {
            showErrorAlert(error)
            return
        }

        FileOperationPromisedFileReceiver.receive(promiseReceivers,
                                                  at: stagingDirectory)
        { [weak self, weak sourcePane] reception in
            guard let self else {
                try? FileManager.default.removeItem(at: stagingDirectory)
                return
            }

            if let firstError = reception.firstError {
                try? FileManager.default.removeItem(at: stagingDirectory)
                showErrorAlert(firstError)
                return
            }

            guard !reception.fileURLs.isEmpty else {
                try? FileManager.default.removeItem(at: stagingDirectory)
                return
            }

            beginConfirmedArchiveTransfer(reception.fileURLs,
                                          to: target,
                                          operation: .copy,
                                          sourcePane: sourcePane,
                                          cleanupDirectory: stagingDirectory)
        }
    }

    // MARK: - Sorting (matches PanelSort.cpp)

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
        guard !isApplyingListViewPreferences else { return }
        sortCurrentItems(by: tableView.sortDescriptors)
        updateHighlightedTableColumn(for: tableView.sortDescriptors.first?.key)
        persistCurrentListViewInfo()
        tableView.reloadData()
    }
}

// MARK: - Archive Inline Navigation (matches Panel.cpp _parentFolders stack)

extension FileManagerPaneController {
    @discardableResult
    private func openArchiveInline(_ url: URL,
                                   hostDirectory: URL? = nil,
                                   temporaryDirectory: URL? = nil,
                                   displayPathPrefix: String? = nil,
                                   nestedWriteBackInfo: FileManagerNestedArchiveWriteBackInfo? = nil,
                                   openMode: FileManagerArchiveOpenMode = .defaultBehavior,
                                   showError: Bool = true,
                                   preserveTemporaryDirectoryOnUnsupported: Bool = false,
                                   replaceCurrentState: Bool = false) -> FileManagerArchiveOpenResult
    {
        let paneHostDirectory = hostDirectory ?? archiveHostDirectory()
        let resolvedDisplayPathPrefix = displayPathPrefix ?? url.path
        let progressParentWindow: NSWindow? = if let window = view.window, window.isVisible {
            window
        } else {
            nil
        }

        let preparedResult = FileManagerArchiveOpenService.openSynchronously(url: url,
                                                                             hostDirectory: paneHostDirectory,
                                                                             temporaryDirectory: temporaryDirectory,
                                                                             displayPathPrefix: resolvedDisplayPathPrefix,
                                                                             parentWindow: progressParentWindow,
                                                                             nestedWriteBackInfo: nestedWriteBackInfo,
                                                                             openMode: openMode)

        return finishArchiveOpen(preparedResult,
                                 temporaryDirectory: temporaryDirectory,
                                 preserveTemporaryDirectoryOnUnsupported: preserveTemporaryDirectoryOnUnsupported,
                                 replaceCurrentState: replaceCurrentState,
                                 showError: showError)
    }

    private func finishArchiveOpen(_ preparedResult: FileManagerPreparedArchiveOpenResult,
                                   temporaryDirectory: URL?,
                                   preserveTemporaryDirectoryOnUnsupported: Bool,
                                   replaceCurrentState: Bool,
                                   showError: Bool) -> FileManagerArchiveOpenResult
    {
        let result: FileManagerArchiveOpenResult
        switch preparedResult {
        case let .opened(prepared):
            if let nestedIdentity = prepared.nestedWriteBackInfo?.identity,
               hasDirtyNestedArchiveInstance(for: nestedIdentity)
            {
                prepared.archive.close()
                archiveItemWorkflowService.cleanup(prepared.temporaryDirectory)
                result = .failed(paneOperationError(SZL10n.string("app.fileManager.error.nestedArchiveDirty")))
                break
            }

            if commitPreparedArchive(prepared, replaceCurrentState: replaceCurrentState) {
                return .opened
            }
            return .cancelled
        case let .unsupportedArchive(error):
            if !preserveTemporaryDirectoryOnUnsupported {
                archiveItemWorkflowService.cleanup(temporaryDirectory)
            }
            result = .unsupportedArchive(error)
        case .cancelled:
            archiveItemWorkflowService.cleanup(temporaryDirectory)
            result = .cancelled
        case let .failed(error):
            archiveItemWorkflowService.cleanup(temporaryDirectory)
            result = .failed(error)
        }

        if showError {
            switch result {
            case let .unsupportedArchive(error), let .failed(error):
                showErrorAlert(error)
            case .opened, .cancelled:
                break
            }
        }

        return result
    }

    private func commitPreparedArchive(_ prepared: FileManagerPreparedArchiveOpen,
                                       replaceCurrentState: Bool) -> Bool
    {
        if replaceCurrentState, !closeAllArchives(showError: true) {
            prepared.archive.close()
            archiveItemWorkflowService.cleanup(prepared.temporaryDirectory)
            return false
        }

        currentDirectory = prepared.hostDirectory
        recordDirectoryVisit(prepared.hostDirectory)
        cancelPendingDirectorySnapshot()
        tearDownDirectoryWatcher()
        if let temporaryDirectory = prepared.temporaryDirectory {
            archiveItemWorkflowService.register(temporaryDirectory)
        }

        let level = ArchiveLevel(
            filesystemDirectory: prepared.hostDirectory,
            archivePath: prepared.archivePath,
            displayPathPrefix: prepared.displayPathPrefix,
            archive: prepared.archive,
            operationGate: FileManagerArchiveOperationGate(),
            allEntries: prepared.entries,
            entryProperties: prepared.archive.entryProperties.map(FileManagerArchiveEntryProperty.init),
            currentSubdir: "",
            temporaryDirectory: prepared.temporaryDirectory,
            nestedIdentity: prepared.nestedWriteBackInfo?.identity,
            nestedWriteBackInfo: prepared.nestedWriteBackInfo,
        )
        archiveStack.append(level)
        navigateArchiveSubdir("")
        return true
    }

    func navigateArchiveSubdir(_ subdir: String) {
        guard var level = archiveStack.last else { return }

        // Update current subdir in the stack
        archiveStack[archiveStack.count - 1] = ArchiveLevel(
            filesystemDirectory: level.filesystemDirectory,
            archivePath: level.archivePath,
            displayPathPrefix: level.displayPathPrefix,
            archive: level.archive,
            operationGate: level.operationGate,
            allEntries: level.allEntries,
            entryProperties: level.entryProperties,
            currentSubdir: subdir,
            temporaryDirectory: level.temporaryDirectory,
            nestedIdentity: level.nestedIdentity,
            nestedWriteBackInfo: level.nestedWriteBackInfo,
        )
        level = archiveStack.last!

        let subdirParts = subdir.split(separator: "/").map(String.init)
        let currentDepth = subdirParts.count
        var seenDirs = Set<String>()
        var displayItems: [ArchiveItem] = []
        var realDirectoriesByPath: [String: ArchiveItem] = [:]

        for entry in level.allEntries where entry.isDirectory {
            realDirectoriesByPath[entry.pathParts.joined(separator: "/")] = entry
        }

        for entry in level.allEntries {
            let parts = entry.pathParts
            guard !parts.isEmpty else { continue }
            guard parts.count > currentDepth else { continue }

            if currentDepth > 0, Array(parts.prefix(currentDepth)) != subdirParts {
                continue
            }

            if parts.count == currentDepth + 1 {
                if !entry.isDirectory || !seenDirs.contains(entry.name) {
                    displayItems.append(entry)
                    if entry.isDirectory {
                        seenDirs.insert(entry.name)
                    }
                }
                continue
            }

            let childParts = Array(parts.prefix(currentDepth + 1))
            let childName = childParts[currentDepth]
            guard !seenDirs.contains(childName) else { continue }

            seenDirs.insert(childName)
            let childPath = childParts.joined(separator: "/")
            if let realDir = realDirectoriesByPath[childPath] {
                displayItems.append(realDir)
            } else {
                displayItems.append(ArchiveItem(
                    index: -1, path: childPath, pathParts: childParts, name: childName,
                    size: 0, packedSize: 0, modifiedDate: entry.modifiedDate,
                    createdDate: nil, accessedDate: nil, crc: 0, isDirectory: true,
                    isEncrypted: false, isAnti: false, method: "", attributes: 0, position: 0, block: 0,
                    comment: "",
                ))
            }
        }

        archiveDisplayItems = displayItems
        updateTableColumnsForCurrentLocation()
        sortCurrentItems(by: tableView.sortDescriptors)

        // Update path field to show full path including archive
        updatePathField()
        updateStatusBar()
        tableView.reloadData()
    }
}

// MARK: - NSMenuDelegate (auto-select row on right-click)

extension FileManagerPaneController {
    func archiveCoordinationSnapshots() -> [FileManagerNestedArchiveOpenSnapshot] {
        archiveStack.map { level in
            let isDirty = level.nestedWriteBackInfo.flatMap { writeBackInfo in
                FileManagerArchiveFileFingerprint.captureIfPossible(for: URL(fileURLWithPath: level.archivePath).standardizedFileURL)
                    .map { $0 != writeBackInfo.initialFingerprint }
            } ?? false

            return FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(level.archive),
                                                        identity: level.nestedIdentity,
                                                        isDirty: isDirty)
        }
    }

    private func prepareContextMenu(forClickedRow clickedRow: Int) {
        delegate?.paneDidBecomeActive(self)

        if clickedRow >= 0, !tableView.selectedRowIndexes.contains(clickedRow) {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        view.window?.makeFirstResponder(tableView)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let columnHeaderMenu, menu === columnHeaderMenu {
            delegate?.paneDidBecomeActive(self)
            populateColumnHeaderMenu(menu)
            return
        }

        delegate?.paneDidBecomeActive(self)

        let clickedRow = tableView.clickedRow
        if clickedRow >= 0, !tableView.selectedRowIndexes.contains(clickedRow) {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
    }
}

// MARK: - Context Menu

extension FileManagerPaneController {
    private func buildColumnHeaderMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }

    private func populateColumnHeaderMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let visibleIDs = Set(tableView.tableColumns.map { FileManagerColumnID(rawValue: $0.identifier.rawValue) })
        for column in columnsForCurrentLocation() {
            let item = NSMenuItem(title: column.title,
                                  action: #selector(toggleListViewColumnVisibility(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = column.id.rawValue
            item.state = visibleIDs.contains(column.id) ? .on : .off
            item.isEnabled = column.id != .name
            menu.addItem(item)
        }
    }

    @objc private func toggleListViewColumnVisibility(_ sender: NSMenuItem) {
        guard let rawColumnID = sender.representedObject as? String else { return }
        let columnID = FileManagerColumnID(rawValue: rawColumnID)
        guard columnID != .name else { return }

        let availableColumns = columnsForCurrentLocation()
        guard let column = availableColumns.first(where: { $0.id == columnID }) else { return }

        let folderTypeID = listViewFolderTypeIDForCurrentLocation()
        let isHidingColumn = tableView.tableColumns.contains { $0.identifier.rawValue == column.id.rawValue }
        if isHidingColumn {
            persistCurrentListViewInfo()
        }

        isApplyingListViewPreferences = true
        if let tableColumn = tableView.tableColumns.first(where: { $0.identifier.rawValue == column.id.rawValue }) {
            tableView.removeTableColumn(tableColumn)
        } else {
            let tableColumn = column.makeTableColumn()
            tableColumn.width = FileManagerViewPreferences.storedListViewColumnWidth(for: column,
                                                                                     folderTypeID: folderTypeID)
            tableView.addTableColumn(tableColumn)
            restoreColumnPosition(column.id,
                                  folderTypeID: folderTypeID,
                                  availableColumns: availableColumns)
        }

        currentColumns = FileManagerColumn.visibleColumns(inTableOrder: tableView.tableColumns,
                                                          availableColumns: availableColumns)
        let visibleIDs = Set(currentColumns.map(\.id))
        tableView.sortDescriptors = FileManagerViewPreferences.sortDescriptorsByResettingUnavailableColumn(tableView.sortDescriptors,
                                                                                                           visibleColumnIDs: visibleIDs,
                                                                                                           availableColumns: availableColumns)
        isApplyingListViewPreferences = false

        sortCurrentItems(by: tableView.sortDescriptors)
        updateHighlightedTableColumn(for: tableView.sortDescriptors.first?.key)
        persistCurrentListViewInfo()
        tableView.reloadData()
    }

    private func restoreColumnPosition(_ columnID: FileManagerColumnID,
                                       folderTypeID: String,
                                       availableColumns: [FileManagerColumn])
    {
        let currentColumnIDs = tableView.tableColumns.map { FileManagerColumnID(rawValue: $0.identifier.rawValue) }
        guard let move = FileManagerViewPreferences.restoredListViewColumnMove(for: columnID,
                                                                               currentColumnIDs: currentColumnIDs,
                                                                               folderTypeID: folderTypeID,
                                                                               availableColumns: availableColumns)
        else {
            return
        }

        tableView.moveColumn(move.from, toColumn: move.to)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = FileManagerMenuFactory.makeContextMenu(windowTarget: delegate as AnyObject?)
        menu.delegate = self
        return menu
    }

    func controlTextDidBeginEditing(_: Notification) {
        delegate?.paneDidBecomeActive(self)
    }

    @objc private func openSelectedItem(_: Any?) {
        doubleClickRow(nil)
    }

    @objc private func openInArchiveViewer(_: Any?) {
        guard let url = selectedArchiveCandidateURL() else { return }
        delegate?.paneDidRequestOpenArchiveInNewWindow(url)
    }

    @objc private func compressSelected(_: Any?) {
        if isInsideArchive, !supportsInPlaceArchiveMutation {
            showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.addingFilesToArchive"))
            return
        }

        // Forward to FileManagerWindowController
        if let wc = view.window?.windowController as? FileManagerWindowController {
            wc.addToArchive(nil)
        }
    }

    @objc private func extractSelected(_: Any?) {
        if let wc = view.window?.windowController as? FileManagerWindowController {
            wc.extractArchive(nil)
        }
    }

    @objc private func extractHere(_: Any?) {
        if isInsideArchive {
            let destinationURL = archiveHostDirectory()
            Task { @MainActor [weak self] in
                guard let self, let parentWindow = view.window else { return }
                do {
                    let prepared = try prepareExtraction(to: destinationURL,
                                                         overwriteMode: .ask,
                                                         inheritDownloadedFileQuarantine: SZSettings.bool(.inheritDownloadedFileQuarantine))
                    try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                                         parentWindow: parentWindow)
                    { session in
                        try prepared.perform(session: session)
                    }
                } catch {
                    showErrorAlert(error)
                }
            }
            return
        }

        guard let url = selectedArchiveCandidateURL() else { return }

        let destURL = currentDirectory
        Task { @MainActor [weak self] in
            guard let self, let parentWindow = view.window else { return }
            do {
                try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                                     parentWindow: parentWindow)
                { session in
                    let archive = SZArchive()
                    try archive.open(atPath: url.path, session: session)
                    let settings = SZExtractionSettings()
                    settings.overwriteMode = .ask
                    if SZSettings.bool(.inheritDownloadedFileQuarantine) {
                        settings.sourceArchivePathForQuarantine = url.path
                    }
                    try archive.extract(toPath: destURL.path, settings: settings, session: session)
                    archive.close()
                }
                refresh()
            } catch {
                showErrorAlert(error)
            }
        }
    }

    @objc private func renameSelected(_: Any?) {
        if isInsideArchive {
            guard let target = currentArchiveMutationTarget() else {
                showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.renamingArchiveItems"))
                return
            }

            let selectedItems = selectedArchiveItems()
            guard selectedItems.count == 1 else { return }
            let item = selectedItems[0]

            guard let window = view.window else { return }
            szBeginTextInput(on: window,
                             title: SZL10n.string("menu.rename"),
                             initialValue: item.name,
                             confirmTitle: SZL10n.string("menu.rename"))
            { [weak self] value in
                guard let self,
                      let newName = value else { return }
                guard !newName.isEmpty, newName != item.name else { return }

                let renamedPath = item.parentPath.isEmpty ? newName : item.parentPath + "/" + newName
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let currentTarget = revalidatedArchiveMutationTarget(for: target) else {
                        showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.renamingArchiveItems"))
                        return
                    }

                    do {
                        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("fileop.renaming"),
                                                             parentWindow: view.window,
                                                             deferredDisplay: true)
                        { session in
                            try currentTarget.archive.renameItem(atPath: item.path,
                                                                 inArchiveSubdir: currentTarget.subdir,
                                                                 newName: newName,
                                                                 session: session)
                        }
                        refreshArchiveAfterMutation(selectingPath: renamedPath)
                        publishArchiveMutationIfNeeded(selectingPaths: [renamedPath])
                    } catch {
                        showErrorAlert(error)
                    }
                }
            }
            return
        }

        let selectedItems = selectedFileSystemItems()
        guard selectedItems.count == 1 else { return }
        let item = selectedItems[0]

        guard let window = view.window else { return }
        szBeginTextInput(on: window,
                         title: SZL10n.string("menu.rename"),
                         initialValue: item.name,
                         confirmTitle: SZL10n.string("menu.rename"))
        { [weak self] value in
            guard let newName = value else { return }
            guard !newName.isEmpty, newName != item.name else { return }
            let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(at: item.url, to: newURL)
                self?.refresh()
            } catch {
                self?.showErrorAlert(error)
            }
        }
    }

    @objc private func deleteSelected(_: Any?) {
        if isInsideArchive {
            guard let target = currentArchiveMutationTarget() else {
                showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.deletingArchiveItems"))
                return
            }

            let selectedItems = selectedArchiveItems()
            guard !selectedItems.isEmpty else { return }

            let itemPaths = selectedItems.map(\.path)
            guard let window = view.window else { return }
            szBeginConfirmation(on: window,
                                title: SZL10n.string("app.fileManager.deleteFromArchiveTitle", itemPaths.count),
                                message: SZL10n.string("app.fileManager.deleteFromArchiveMessage"),
                                confirmTitle: SZL10n.string("toolbar.delete"))
            { [weak self] confirmed in
                guard let self, confirmed else { return }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let currentTarget = revalidatedArchiveMutationTarget(for: target) else {
                        showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.deletingArchiveItems"))
                        return
                    }

                    do {
                        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.deleting"),
                                                             parentWindow: view.window,
                                                             deferredDisplay: true)
                        { session in
                            try currentTarget.archive.deleteItems(atPaths: itemPaths,
                                                                  inArchiveSubdir: currentTarget.subdir,
                                                                  session: session)
                        }
                        refreshArchiveAfterMutation()
                        publishArchiveMutationIfNeeded(targetSubdir: currentTarget.subdir)
                    } catch {
                        showErrorAlert(error)
                    }
                }
            }
            return
        }

        let paths = selectedFilePaths()
        guard !paths.isEmpty else { return }

        guard let window = view.window else { return }
        szBeginConfirmation(on: window,
                            title: SZL10n.string("app.fileManager.deleteItemsTitle", paths.count),
                            message: SZL10n.string("app.fileManager.deleteItemsMessage"),
                            confirmTitle: SZL10n.string("toolbar.delete"))
        { [weak self] confirmed in
            guard confirmed else { return }
            let failures = FileManagerTrashOperation.trashItems(at: paths)
            self?.refresh()
            if let error = FileManagerTrashOperation.error(for: failures, attemptedCount: paths.count) {
                self?.showErrorAlert(error)
            }
        }
    }

    @objc private func createFolderFromMenu(_: Any?) {
        guard let window = view.window else { return }
        szBeginTextInput(on: window,
                         title: SZL10n.string("create.folder"),
                         placeholder: SZL10n.string("create.newFolder"),
                         confirmTitle: SZL10n.string("create.folder"))
        { [weak self] value in
            guard let name = value, !name.isEmpty else { return }
            self?.createFolder(named: name)
        }
    }

    @objc private func showItemProperties(_: Any?) {
        guard let item = selectedRealPaneItems().first else { return }

        switch item {
        case let .filesystem(fileSystemItem):
            let details = FileManagerItemPresentation.details(for: fileSystemItem)
            szShowDetailsDialog(title: details.title,
                                details: details.details,
                                for: view.window)

        case let .archive(archiveItem):
            let details = FileManagerItemPresentation.details(for: archiveItem,
                                                              entryProperties: archiveStack.last?.entryProperties ?? [])
            szShowDetailsDialog(title: details.title,
                                details: details.details,
                                for: view.window)

        case .parent:
            return
        }
    }
}
