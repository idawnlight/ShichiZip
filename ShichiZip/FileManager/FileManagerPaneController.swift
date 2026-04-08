import Cocoa
import UniformTypeIdentifiers

private final class FileManagerTableView: NSTableView {
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        let clickedColumn = column(at: mouseDownPoint)
        guard clickedColumn >= 0,
              tableColumns[clickedColumn].identifier.rawValue == "name" else {
            return false
        }

        let clickedRow = row(at: mouseDownPoint)
        guard clickedRow >= 0, rowIndexes.contains(clickedRow) else {
            return false
        }

        return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }
}

/// Single pane of the file manager — displays file system contents
class FileManagerPaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate, NSMenuItemValidation {

    private struct DirectoryEntryFingerprint: Equatable {
        let path: String
        let isDirectory: Bool
        let size: Int
        let modifiedDate: Date?
        let createdDate: Date?
    }

    weak var delegate: FileManagerPaneDelegate?

    private var pathField: NSTextField!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var statusLabel: NSTextField!
    private var settingsObserver: NSObjectProtocol?
    private var viewPreferencesObserver: NSObjectProtocol?
    private var liveScrollStartObserver: NSObjectProtocol?
    private var liveScrollEndObserver: NSObjectProtocol?
    private var recentDirectories: [URL] = []
    private var isLiveScrolling = false
    private var pendingAutoRefresh = false
    private let iconCache = NSCache<NSString, NSImage>()
    private let iconSize = NSSize(width: 16, height: 16)
    private var currentDirectoryFingerprint: [DirectoryEntryFingerprint] = []

    private(set) var currentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var currentDirectoryURL: URL { currentDirectory }
    private var items: [FileSystemItem] = []

    private enum PaneItem {
        case parent
        case filesystem(FileSystemItem)
        case archive(ArchiveItem)
    }

    // Archive navigation state (matches CFolderLink stack in Panel.cpp)
    private struct ArchiveLevel {
        let filesystemDirectory: URL
        let archivePath: String
        let displayPathPrefix: String
        let archive: SZArchive
        let allEntries: [ArchiveItem]
        let currentSubdir: String
        let temporaryDirectory: URL?
    }
    private var archiveStack: [ArchiveLevel] = []
    private var isInsideArchive: Bool { !archiveStack.isEmpty }
    private var archiveDisplayItems: [ArchiveItem] = []
    private let archiveItemWorkflowService = FileManagerArchiveItemWorkflowService()
    private var showsRealFileIcons: Bool { SZSettings.bool(.showRealFileIcons) }
    private var showsParentRow: Bool {
        guard SZSettings.bool(.showDots) else {
            return false
        }
        if isInsideArchive {
            return true
        }
        return currentDirectory.path != currentDirectory.deletingLastPathComponent().path
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let viewPreferencesObserver {
            NotificationCenter.default.removeObserver(viewPreferencesObserver)
        }
        if let liveScrollStartObserver {
            NotificationCenter.default.removeObserver(liveScrollStartObserver)
        }
        if let liveScrollEndObserver {
            NotificationCenter.default.removeObserver(liveScrollEndObserver)
        }
        closeAllArchives()
        archiveItemWorkflowService.cleanupAll()
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))

        let upButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Up")!, target: self, action: #selector(goUpClicked(_:)))
        upButton.translatesAutoresizingMaskIntoConstraints = false
        upButton.bezelStyle = .accessoryBarAction
        upButton.isBordered = false
        upButton.refusesFirstResponder = true
        container.addSubview(upButton)

        pathField = NSTextField()
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.font = .systemFont(ofSize: 12)
        pathField.usesSingleLineMode = true
        pathField.lineBreakMode = .byTruncatingHead
        pathField.stringValue = currentDirectory.path
        pathField.target = self
        pathField.action = #selector(pathFieldSubmitted(_:))
        pathField.delegate = self
        container.addSubview(pathField)

        tableView = FileManagerTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.rowSizeStyle = .small

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 250
        nameCol.minWidth = 100
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
        tableView.addTableColumn(nameCol)

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 50
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
        tableView.addTableColumn(sizeCol)

        let modifiedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified"))
        modifiedCol.title = "Modified"
        modifiedCol.width = 140
        modifiedCol.minWidth = 80
        modifiedCol.sortDescriptorPrototype = NSSortDescriptor(key: "modified", ascending: false)
        tableView.addTableColumn(modifiedCol)

        let createdCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("created"))
        createdCol.title = "Created"
        createdCol.width = 140
        createdCol.minWidth = 80
        createdCol.sortDescriptorPrototype = NSSortDescriptor(key: "created", ascending: false)
        tableView.addTableColumn(createdCol)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.menu = buildContextMenu()
        NSLog("[ShichiZip] File manager pane context menu set with %ld items", tableView.menu?.items.count ?? 0)

        // Register for drag and drop
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

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
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        }

        liveScrollEndObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isLiveScrolling = false

            guard self.pendingAutoRefresh else { return }
            self.pendingAutoRefresh = false
            self.autoRefreshIfPossible()
        }

        // Status bar
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            upButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            upButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            upButton.widthAnchor.constraint(equalToConstant: 24),
            upButton.heightAnchor.constraint(equalToConstant: 24),

            pathField.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            pathField.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 2),
            pathField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            pathField.heightAnchor.constraint(equalToConstant: 24),

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
            queue: .main
        ) { [weak self] notification in
            self?.handleSettingsDidChange(notification)
        }

        viewPreferencesObserver = NotificationCenter.default.addObserver(
            forName: .fileManagerViewPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadPresentedValues()
        }

        applyFileManagerSettings()

        self.view = container
        loadDirectory(currentDirectory)
    }

    // MARK: - Navigation

    private struct FileSystemSelectionState {
        let selectedPaths: Set<String>
        let focusedPath: String?

        static let empty = FileSystemSelectionState(selectedPaths: [], focusedPath: nil)
    }

    func loadDirectory(_ url: URL) {
        do {
            let contents = try directoryContents(for: url)
            applyDirectoryContents(contents, for: url)
        } catch {
            return
        }
    }

    private func fileManagerDirectoryEnumerationOptions() -> FileManager.DirectoryEnumerationOptions {
        SZSettings.bool(.showHiddenFiles) ? [] : [.skipsHiddenFiles]
    }

    private func directoryContents(for url: URL) throws -> [URL] {
        try FileManagerDirectoryListing.contentsPreservingPresentedPath(for: url,
                                                                       options: fileManagerDirectoryEnumerationOptions())
    }

    private func makeDirectoryFingerprint(from contents: [URL]) -> [DirectoryEntryFingerprint] {
        contents.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey,
                                                           .fileSizeKey,
                                                           .contentModificationDateKey,
                                                           .creationDateKey])
            return DirectoryEntryFingerprint(path: url.standardizedFileURL.path,
                                             isDirectory: values?.isDirectory ?? false,
                                             size: values?.fileSize ?? 0,
                                             modifiedDate: values?.contentModificationDate,
                                             createdDate: values?.creationDate)
        }
        .sorted { $0.path < $1.path }
    }

    private func captureFileSystemSelectionState() -> FileSystemSelectionState {
        guard isViewLoaded, !isInsideArchive else {
            return .empty
        }

        let selectedPaths = Set(selectedFileSystemItems().map { $0.url.standardizedFileURL.path })
        let focusedPath: String?

        if let focusedItem = paneItem(at: tableView.selectedRow),
           case let .filesystem(item) = focusedItem {
            focusedPath = item.url.standardizedFileURL.path
        } else {
            focusedPath = selectedFileSystemItems().first?.url.standardizedFileURL.path
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
           let row = items.firstIndex(where: { $0.url.standardizedFileURL.path == focusedPath }).map({ baseRow + $0 }) {
            tableView.scrollRowToVisible(row)
        } else if let firstRow = selectedRows.first {
            tableView.scrollRowToVisible(firstRow)
        }
    }

    private func reloadCurrentDirectoryPreservingSelection() {
        let selectionState = captureFileSystemSelectionState()

        do {
            let contents = try directoryContents(for: currentDirectory)
            applyDirectoryContents(contents, for: currentDirectory)
            restoreFileSystemSelectionState(selectionState)
        } catch {
            return
        }
    }

    private func autoRefreshCurrentDirectoryIfNeeded() {
        let selectionState = captureFileSystemSelectionState()

        do {
            let contents = try directoryContents(for: currentDirectory)
            let fingerprint = makeDirectoryFingerprint(from: contents)
            guard fingerprint != currentDirectoryFingerprint else { return }

            applyDirectoryContents(contents, for: currentDirectory, fingerprint: fingerprint)
            restoreFileSystemSelectionState(selectionState)
        } catch {
            return
        }
    }

    private func applyDirectoryContents(_ contents: [URL],
                                        for url: URL,
                                        fingerprint: [DirectoryEntryFingerprint]? = nil) {
        currentDirectory = url
        recordDirectoryVisit(url)
        updatePathField()
        currentDirectoryFingerprint = fingerprint ?? makeDirectoryFingerprint(from: contents)
        items = contents.map { FileSystemItem(url: $0) }
        sortCurrentItems(by: tableView.sortDescriptors)
        tableView.reloadData()
        updateStatusBar()
    }

    func refresh() {
        if isInsideArchive {
            navigateArchiveSubdir(archiveStack.last?.currentSubdir ?? "")
        } else {
            reloadCurrentDirectoryPreservingSelection()
        }
    }

    func autoRefreshIfPossible() {
        guard isViewLoaded else { return }
        guard !isInsideArchive else { return }
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
        view.window?.makeFirstResponder(tableView)
    }

    var preferredInitialFirstResponder: NSView {
        tableView
    }

    var isVirtualLocation: Bool { isInsideArchive }

    func canAddSelectedItemsToArchive() -> Bool {
        !isInsideArchive && !selectedFileSystemItems().isEmpty
    }

    func canCreateFolderHere() -> Bool {
        !isInsideArchive
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
        !isInsideArchive && !selectedFileSystemItems().isEmpty
    }

    func canRenameSelection() -> Bool {
        !isInsideArchive && selectedFileSystemItems().count == 1
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

    func openSelection() {
        openSelectedItem(nil)
    }

    func goUpOneLevel() {
        goUp()
    }

    func renameSelection() {
        renameSelected(nil)
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

        let components = currentDirectory.standardizedFileURL.pathComponents
        let rootURL: URL

        if components.count >= 3, components[1] == "Volumes" {
            rootURL = URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(3))))
        } else {
            rootURL = URL(fileURLWithPath: "/")
        }

        loadDirectory(rootURL)
    }

    func recentDirectoryHistory() -> [URL] {
        recentDirectories
    }

    func openRecentDirectory(_ url: URL) {
        loadDirectory(url)
    }

    func selectAllItems() {
        let rowCount = numberOfRows(in: tableView)
        let firstSelectableRow = showsParentRow ? 1 : 0
        guard rowCount > firstSelectableRow else {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(IndexSet(integersIn: firstSelectableRow..<rowCount),
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
        for row in firstSelectableRow..<rowCount where !currentSelection.contains(row) {
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

    func selectedFilePaths() -> [String] {
        selectedFileSystemItems().map { $0.url.path }
    }

    func createFolder(named name: String) {
        guard !isInsideArchive else {
            showUnsupportedArchiveOperationAlert(action: "Creating folders")
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

    private func updateStatusBar() {
        let archiveItems = archiveDisplayItems
        let fileCount = (isInsideArchive ? archiveItems.filter { !$0.isDirectory }.count : items.filter { !$0.isDirectory }.count)
        let dirCount = (isInsideArchive ? archiveItems.filter { $0.isDirectory }.count : items.filter { $0.isDirectory }.count)
        let totalSize = isInsideArchive
            ? archiveItems.filter { !$0.isDirectory }.reduce(UInt64(0)) { $0 + $1.size }
            : items.filter { !$0.isDirectory }.reduce(UInt64(0)) { $0 + $1.size }
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
        statusLabel.stringValue = "\(fileCount) files, \(dirCount) folders — \(sizeStr)"
    }

    private func recordDirectoryVisit(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        recentDirectories.removeAll { $0.standardizedFileURL == standardizedURL }
        recentDirectories.insert(standardizedURL, at: 0)
        if recentDirectories.count > 20 {
            recentDirectories.removeSubrange(20..<recentDirectories.count)
        }
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

    private func handleSettingsDidChange(_ notification: Notification) {
        guard let key = notification.userInfo?["key"] as? String,
              let settingsKey = SZSettingsKey(rawValue: key) else {
            return
        }

        switch settingsKey {
        case .showDots, .showRealFileIcons, .showGridLines, .singleClickOpen:
            if settingsKey == .showRealFileIcons {
                iconCache.removeAllObjects()
            }
            applyFileManagerSettings()
        case .showHiddenFiles:
            refresh()
            return
        default:
            return
        }

        tableView.reloadData()
        updateStatusBar()
    }

    private func iconImage(for paneItem: PaneItem, isDirectory: Bool, iconPath: String) -> NSImage? {
        switch paneItem {
        case .parent:
            return cachedIcon(forKey: "parent") {
                let image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Parent")
                image?.isTemplate = true
                return image
            }

        case .archive:
            guard showsRealFileIcons else {
                return cachedIcon(forKey: isDirectory ? "template:archive:folder" : "template:archive:file") {
                    NSImage(systemSymbolName: isDirectory ? "folder.fill" : "doc.fill",
                            accessibilityDescription: isDirectory ? "Folder" : "File")
                }
            }

            if isDirectory {
                return cachedIcon(forKey: "real:archive:folder") {
                    NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
                }
            }

            let ext = (iconPath as NSString).pathExtension
            if let type = UTType(filenameExtension: ext) {
                return cachedIcon(forKey: "real:archive:type:\(ext.lowercased())") {
                    NSWorkspace.shared.icon(for: type)
                }
            }
            return cachedIcon(forKey: "real:archive:data") {
                NSWorkspace.shared.icon(for: .data)
            }

        case .filesystem:
            guard showsRealFileIcons else {
                return cachedIcon(forKey: isDirectory ? "template:filesystem:folder" : "template:filesystem:file") {
                    NSImage(systemSymbolName: isDirectory ? "folder.fill" : "doc.fill",
                            accessibilityDescription: isDirectory ? "Folder" : "File")
                }
            }
            return cachedIcon(forKey: "real:filesystem:\(iconPath)") {
                NSWorkspace.shared.icon(forFile: iconPath)
            }
        }
    }

    private func cachedIcon(forKey key: String, builder: () -> NSImage?) -> NSImage? {
        if let cachedImage = iconCache.object(forKey: key as NSString) {
            return cachedImage
        }

        guard let rawImage = builder() else {
            return nil
        }

        let image = (rawImage.copy() as? NSImage) ?? rawImage
        image.size = iconSize
        iconCache.setObject(image, forKey: key as NSString)
        return image
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
                                         showError: false) {
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
        let parentDirectory = url.deletingLastPathComponent()
        let result = openArchiveInline(url,
                                       hostDirectory: parentDirectory,
                                       replaceCurrentState: true)
        if case .opened = result {
            return true
        }
        return false
    }

    func extractSelectedArchiveItems(to destinationURL: URL,
                                     progress: SZProgressDelegate?,
                                     overwriteMode: SZOverwriteMode = .ask) throws {
        let selectedItems = selectedArchiveItems()
        guard !selectedItems.isEmpty else {
            throw paneOperationError("Select one or more archive items first.")
        }
        try extractArchiveItems(selectedItems,
                                to: destinationURL,
                                progress: progress,
                                session: nil,
                                overwriteMode: overwriteMode,
                                pathMode: .currentPaths)
    }

    func extractSelectedArchiveItems(to destinationURL: URL,
                                     session: SZOperationSession?,
                                     overwriteMode: SZOverwriteMode = .ask) throws {
        let selectedItems = selectedArchiveItems()
        guard !selectedItems.isEmpty else {
            throw paneOperationError("Select one or more archive items first.")
        }
        try extractArchiveItems(selectedItems,
                                to: destinationURL,
                                progress: nil,
                                session: session,
                                overwriteMode: overwriteMode,
                                pathMode: .currentPaths)
    }

    func extractCurrentSelectionOrDisplayedArchiveItems(to destinationURL: URL,
                                                        progress: SZProgressDelegate?,
                                                        overwriteMode: SZOverwriteMode = .ask) throws {
        let itemsToExtract = archiveItemsForSelectionOrDisplayedItems()
        guard !itemsToExtract.isEmpty else {
            throw paneOperationError("There are no archive items to extract.")
        }
        try extractArchiveItems(itemsToExtract,
                                to: destinationURL,
                                progress: progress,
                                session: nil,
                                overwriteMode: overwriteMode,
                                pathMode: .currentPaths)
    }

    func extractCurrentSelectionOrDisplayedArchiveItems(to destinationURL: URL,
                                                        session: SZOperationSession?,
                                                        overwriteMode: SZOverwriteMode = .ask) throws {
        let itemsToExtract = archiveItemsForSelectionOrDisplayedItems()
        guard !itemsToExtract.isEmpty else {
            throw paneOperationError("There are no archive items to extract.")
        }
        try extractArchiveItems(itemsToExtract,
                                to: destinationURL,
                                progress: nil,
                                session: session,
                                overwriteMode: overwriteMode,
                                pathMode: .currentPaths)
    }

    func testCurrentArchive(progress: SZProgressDelegate?) throws {
        guard let level = archiveStack.last else {
            throw paneOperationError("No archive is open.")
        }
        try level.archive.test(withProgress: progress)
    }

    func testCurrentArchive(session: SZOperationSession?) throws {
        guard let level = archiveStack.last else {
            throw paneOperationError("No archive is open.")
        }
        try level.archive.test(with: session)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openSelectedItem(_:)):
            return !selectedPaneItems().isEmpty
        case #selector(openInArchiveViewer(_:)):
            return selectedArchiveCandidateURL() != nil
        case #selector(compressSelected(_:)):
            return canAddSelectedItemsToArchive()
        case #selector(extractSelected(_:)), #selector(extractHere(_:)):
            return canExtractSelectionOrArchive()
        case #selector(renameSelected(_:)):
            return canRenameSelection()
        case #selector(deleteSelected(_:)):
            return canDeleteSelection()
        case #selector(createFolderFromMenu(_:)):
            return canCreateFolderHere()
        case #selector(showItemProperties(_:)):
            return !selectedRealPaneItems().isEmpty
        default:
            return true
        }
    }

    private func paneItem(at row: Int) -> PaneItem? {
        if showsParentRow && row == 0 {
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

    private func selectedPaneItems() -> [PaneItem] {
        tableView.selectedRowIndexes.compactMap { paneItem(at: $0) }
    }

    private func selectedRealPaneItems() -> [PaneItem] {
        selectedPaneItems().filter {
            if case .parent = $0 {
                return false
            }
            return true
        }
    }

    private func selectedFileSystemItems() -> [FileSystemItem] {
        selectedPaneItems().compactMap {
            guard case let .filesystem(item) = $0 else { return nil }
            return item
        }
    }

    private func selectedArchiveItems() -> [ArchiveItem] {
        selectedPaneItems().compactMap {
            guard case let .archive(item) = $0 else { return nil }
            return item
        }
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

    private func currentArchiveItemWorkflowContext() -> FileManagerArchiveItemWorkflowContext? {
        guard let level = archiveStack.last else { return nil }

        return FileManagerArchiveItemWorkflowContext(archive: level.archive,
                                                    hostDirectory: archiveHostDirectory(),
                                                    displayPathPrefix: currentArchiveDisplayPathPrefix())
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

    private func closeArchiveLevel(_ level: ArchiveLevel) {
        level.archive.close()
        archiveItemWorkflowService.cleanup(level.temporaryDirectory)
    }

    private func closeAllArchives() {
        while let level = archiveStack.popLast() {
            closeArchiveLevel(level)
        }
        archiveDisplayItems.removeAll()
    }

    @discardableResult
    private func openExternallyIfPossible(_ url: URL,
                                          preservingTemporaryDirectory temporaryDirectory: URL? = nil) -> Bool {
        guard let applicationURL = FileManagerExternalOpenRouter.preferredExternalApplicationURL(for: url) else {
            return false
        }

        return openExternally(url,
                              withApplicationAt: applicationURL,
                              preservingTemporaryDirectory: temporaryDirectory)
    }

    @discardableResult
    private func openExternally(_ url: URL,
                                withApplicationAt applicationURL: URL,
                                preservingTemporaryDirectory temporaryDirectory: URL? = nil) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { [weak self] app, error in
            guard app == nil else { return }

            if let temporaryDirectory {
                self?.archiveItemWorkflowService.cleanup(temporaryDirectory)
            }

            if let error {
                self?.showErrorAlert(error)
            }
        }
        return true
    }

    private func makeArchiveExtractionSettings(overwriteMode: SZOverwriteMode,
                                               pathMode: SZPathMode) -> SZExtractionSettings {
        let settings = SZExtractionSettings()
        settings.overwriteMode = overwriteMode
        settings.pathMode = pathMode
        if pathMode == .currentPaths,
           let level = archiveStack.last,
           !level.currentSubdir.isEmpty {
            settings.pathPrefixToStrip = level.currentSubdir
        }
        return settings
    }

    private func archiveEntryIndices(for selectedItems: [ArchiveItem]) -> [NSNumber] {
        guard let level = archiveStack.last else { return [] }

        var indices = Set<Int>()

        for item in selectedItems {
            if item.index >= 0 {
                indices.insert(item.index)
            }

            if item.isDirectory || item.index < 0 {
                let directoryPath = normalizeArchivePath(item.path)
                let prefix = directoryPath.isEmpty ? "" : directoryPath + "/"

                for entry in level.allEntries where entry.index >= 0 {
                    let entryPath = normalizeArchivePath(entry.path)
                    if entryPath == directoryPath || (!prefix.isEmpty && entryPath.hasPrefix(prefix)) {
                        indices.insert(entry.index)
                    }
                }
            }
        }

        return indices.sorted().map { NSNumber(value: $0) }
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
                                     selector: Selector? = nil) {
        let descriptor = NSSortDescriptor(key: key,
                                          ascending: ascending,
                                          selector: selector)
        tableView.sortDescriptors = [descriptor]
        if let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == columnIdentifier }) {
            tableView.highlightedTableColumn = column
        }
        sortCurrentItems(by: tableView.sortDescriptors)
        tableView.reloadData()
    }

    private func extractArchiveItems(_ itemsToExtract: [ArchiveItem],
                                     to destinationURL: URL,
                                     progress: SZProgressDelegate?,
                                     session: SZOperationSession?,
                                     overwriteMode: SZOverwriteMode,
                                     pathMode: SZPathMode) throws {
        guard let level = archiveStack.last else {
            throw paneOperationError("No archive is open.")
        }

        let indices = archiveEntryIndices(for: itemsToExtract)
        guard !indices.isEmpty else {
            throw paneOperationError("The selected archive items cannot be extracted.")
        }

        let settings = makeArchiveExtractionSettings(overwriteMode: overwriteMode, pathMode: pathMode)
        if let session {
            try level.archive.extractEntries(indices,
                                             toPath: destinationURL.path,
                                             settings: settings,
                                             session: session)
        } else {
            try level.archive.extractEntries(indices,
                                             toPath: destinationURL.path,
                                             settings: settings,
                                             progress: progress)
        }
    }

    private func paneOperationError(_ description: String) -> NSError {
        NSError(domain: SZArchiveErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func unavailableExternalOpenError(for itemName: String) -> NSError {
        paneOperationError("No application is available to open \"\(itemName)\".")
    }

    private func invalidAddressBarPathError(for path: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [
                    NSFilePathErrorKey: path,
                    NSLocalizedDescriptionKey: "The path \"\(path)\" does not exist."
                ])
    }

    private func showErrorAlert(_ error: Error) {
        szPresentError(error, for: view.window)
    }

    private func showUnsupportedArchiveOperationAlert(action: String) {
        szPresentMessage(title: "\(action) is not available here",
                         message: "This file-manager view can browse archives and extract or copy items out of them, but in-place archive modification is not implemented yet.",
                         for: view.window)
    }

    private func sortCurrentItems(by descriptors: [NSSortDescriptor]) {
        if isInsideArchive {
            sortArchiveItems(by: descriptors)
        } else {
            sortFileSystemItems(by: descriptors)
        }
    }

    private func sortFileSystemItems(by descriptors: [NSSortDescriptor]) {
        guard let descriptor = descriptors.first else {
            items.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return
        }

        let key = descriptor.key ?? "name"
        let ascending = descriptor.ascending

        items.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }

            let result: ComparisonResult
            switch key {
            case "name":
                result = a.name.localizedStandardCompare(b.name)
            case "type":
                let aType = a.url.pathExtension.localizedLowercase
                let bType = b.url.pathExtension.localizedLowercase
                let typeResult = aType.localizedStandardCompare(bType)
                result = typeResult == .orderedSame
                    ? a.name.localizedStandardCompare(b.name)
                    : typeResult
            case "size":
                result = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case "modified":
                let ad = a.modifiedDate ?? Date.distantPast
                let bd = b.modifiedDate ?? Date.distantPast
                result = ad.compare(bd)
            case "created":
                let ad = a.createdDate ?? Date.distantPast
                let bd = b.createdDate ?? Date.distantPast
                result = ad.compare(bd)
            default:
                result = a.name.localizedStandardCompare(b.name)
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func sortArchiveItems(by descriptors: [NSSortDescriptor]) {
        guard let descriptor = descriptors.first else {
            archiveDisplayItems.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return
        }

        let key = descriptor.key ?? "name"
        let ascending = descriptor.ascending

        archiveDisplayItems.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }

            let result: ComparisonResult
            switch key {
            case "name":
                result = a.name.localizedStandardCompare(b.name)
            case "type":
                let aType = a.fileExtension.localizedLowercase
                let bType = b.fileExtension.localizedLowercase
                let typeResult = aType.localizedStandardCompare(bType)
                result = typeResult == .orderedSame
                    ? a.name.localizedStandardCompare(b.name)
                    : typeResult
            case "size":
                result = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case "modified":
                let ad = a.modifiedDate ?? Date.distantPast
                let bd = b.modifiedDate ?? Date.distantPast
                result = ad.compare(bd)
            case "created":
                let ad = a.createdDate ?? Date.distantPast
                let bd = b.createdDate ?? Date.distantPast
                result = ad.compare(bd)
            default:
                result = a.name.localizedStandardCompare(b.name)
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    // MARK: - Actions

    @objc private func pathFieldSubmitted(_ sender: NSTextField) {
        let path = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return }

        // Expand ~ to home directory
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            do {
                let contents = try directoryContents(for: url)
                closeAllArchives()
                applyDirectoryContents(contents, for: url)
            } catch {
                updatePathField()
                showErrorAlert(error)
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            if FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(url) {
                updatePathField()
                if !openExternallyIfPossible(url) {
                    showErrorAlert(unavailableExternalOpenError(for: url.lastPathComponent))
                }
                view.window?.makeFirstResponder(tableView)
                return
            }

            if isInsideArchive && !canOpenArchive(at: url) {
                updatePathField()
                if !openExternallyIfPossible(url) {
                    showErrorAlert(unavailableExternalOpenError(for: url.lastPathComponent))
                }
                view.window?.makeFirstResponder(tableView)
                return
            }

            closeAllArchives()
            switch openArchiveInline(url,
                                     hostDirectory: url.deletingLastPathComponent(),
                                     showError: false) {
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
        } else {
            updatePathField()
            showErrorAlert(invalidAddressBarPathError(for: path))
        }
        // Resign focus back to table
        view.window?.makeFirstResponder(tableView)
    }

    @objc private func goUpClicked(_ sender: Any?) {
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
    }

    @objc private func doubleClickRow(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        activatePaneItem(at: row)
    }

    @objc private func singleClickRow(_ sender: Any?) {
        guard SZSettings.bool(.singleClickOpen) else { return }
        guard tableView.selectedRowIndexes.count <= 1 else { return }
        guard let event = NSApp.currentEvent else { return }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers.isEmpty else { return }

        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        activatePaneItem(at: row)
    }

    /// Open Inside (PanelItemOpen.cpp): try the extracted item as an archive first,
    /// then fall back to the system app.
    private func openItemInArchive(_ item: ArchiveItem) {
        guard item.index >= 0,
              let context = currentArchiveItemWorkflowContext() else { return }

        do {
            try archiveItemWorkflowService.open(item,
                                                context: context,
                                                openArchiveInline: { [self] url, temporaryDirectory, displayPathPrefix, hostDirectory in
                                                    openArchiveInline(url,
                                                                      hostDirectory: hostDirectory,
                                                                      temporaryDirectory: temporaryDirectory,
                                                                      displayPathPrefix: displayPathPrefix,
                                                                      showError: false,
                                                                      preserveTemporaryDirectoryOnUnsupported: true)
                                                },
                                                openExternally: { [self] url, applicationURL, temporaryDirectory in
                                                    openExternally(url,
                                                                   withApplicationAt: applicationURL,
                                                                   preservingTemporaryDirectory: temporaryDirectory)
                                                },
                                                openExternallyIfPossible: { [self] url, temporaryDirectory in
                                                    openExternallyIfPossible(url,
                                                                             preservingTemporaryDirectory: temporaryDirectory)
                                                })
        } catch {
            showErrorAlert(error)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Enter - Open
            doubleClickRow(nil)
        } else if event.keyCode == 51 { // Backspace - Go up
            goUp()
        } else if event.keyCode == 120 { // F2 - Rename (PanelKey.cpp)
            renameSelected(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    private func goUp() {
        if isInsideArchive {
            let level = archiveStack.last!
            if !level.currentSubdir.isEmpty {
                let parent: String
                if let lastSlash = level.currentSubdir.lastIndex(of: "/") {
                    parent = String(level.currentSubdir[level.currentSubdir.startIndex..<lastSlash])
                } else {
                    parent = ""
                }
                navigateArchiveSubdir(parent)
            } else {
                let fsDir = level.filesystemDirectory
                archiveStack.removeLast()
                closeArchiveLevel(level)
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

    func numberOfRows(in tableView: NSTableView) -> Int {
        let itemCount = isInsideArchive ? archiveDisplayItems.count : items.count
        return itemCount + (showsParentRow ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnID = tableColumn?.identifier.rawValue else { return nil }
        guard let paneItem = paneItem(at: row) else { return nil }

        let dateFormatter = FileManagerViewPreferences.makeListDateFormatter()

        let itemName: String
        let itemSize: String
        let itemModified: String
        let itemCreated: String
        let itemIsDir: Bool
        let itemIconPath: String

        switch paneItem {
        case .parent:
            itemName = ".."
            itemSize = ""
            itemModified = ""
            itemCreated = ""
            itemIsDir = true
            itemIconPath = ""

        case let .archive(ai):
            itemName = ai.name
            itemSize = ai.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: Int64(ai.size), countStyle: .file)
            itemModified = ai.modifiedDate.map { dateFormatter.string(from: $0) } ?? ""
            itemCreated = ai.createdDate.map { dateFormatter.string(from: $0) } ?? ""
            itemIsDir = ai.isDirectory
            itemIconPath = ai.name

        case let .filesystem(item):
            itemName = item.name
            itemSize = item.formattedSize
            itemModified = item.modifiedDate.map { dateFormatter.string(from: $0) } ?? ""
            itemCreated = item.createdDate.map { dateFormatter.string(from: $0) } ?? ""
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

        switch columnID {
        case "name":
            cell.textField?.stringValue = itemName
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

        case "size":
            cell.textField?.stringValue = itemSize
            cell.textField?.alignment = .right

        case "modified":
            cell.textField?.stringValue = itemModified

        case "created":
            cell.textField?.stringValue = itemCreated

        default:
            break
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 22
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let paneItem = paneItem(at: row) else { return nil }

        switch paneItem {
        case .parent:
            return nil

        case let .archive(ai):
            guard let context = currentArchiveItemWorkflowContext(),
                  let extractedFile = archiveItemWorkflowService.dragURL(for: ai, context: context) else {
                return nil
            }

            return extractedFile as NSURL

        case let .filesystem(item):
            return item.url as NSURL
        }
    }

    // MARK: - Drop destination (accept files dragged into this folder)

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if isInsideArchive { return [] }
        // Accept drops onto the table (not between rows)
        if dropOperation == .on { return [] }
        tableView.setDropRow(-1, dropOperation: .on) // highlight whole table
        return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if isInsideArchive { return false }
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }

        let destDir = currentDirectory
        let isMove = info.draggingSourceOperationMask.contains(.move)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for url in urls {
                let dest = destDir.appendingPathComponent(url.lastPathComponent)
                do {
                    if isMove {
                        // rename() is atomic and preserves all metadata on same volume
                        try FileManager.default.moveItem(at: url, to: dest)
                    } else {
                        // copyfile with CLONE for APFS, falls back to full copy preserving all metadata
                        let result = copyfile(
                            url.path.cString(using: .utf8),
                            dest.path.cString(using: .utf8),
                            nil,
                            copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE_FORCE)
                        )
                        if result != 0 {
                            // CLONE_FORCE failed (not APFS) — retry without clone (same as cp)
                            let r2 = copyfile(
                                url.path.cString(using: .utf8),
                                dest.path.cString(using: .utf8),
                                nil,
                                copyfile_flags_t(COPYFILE_ALL)
                            )
                            if r2 != 0 {
                                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                            }
                        }
                    }
                } catch {
                    NSLog("[ShichiZip] Drop error: %@", error.localizedDescription)
                }
            }
            DispatchQueue.main.async { self?.refresh() }
        }
        return true
    }

    // MARK: - Sorting (matches PanelSort.cpp: folders first, natural sort for names)

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortCurrentItems(by: tableView.sortDescriptors)
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
                                   showError: Bool = true,
                                   preserveTemporaryDirectoryOnUnsupported: Bool = false,
                                   replaceCurrentState: Bool = false) -> FileManagerArchiveOpenResult {
        let paneHostDirectory = hostDirectory ?? archiveHostDirectory()
        let resolvedDisplayPathPrefix = displayPathPrefix ?? url.path

        let preparedResult = FileManagerArchiveOpenService.openSynchronously(url: url,
                                                                             hostDirectory: paneHostDirectory,
                                                                             temporaryDirectory: temporaryDirectory,
                                                                             displayPathPrefix: resolvedDisplayPathPrefix)

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
                                   showError: Bool) -> FileManagerArchiveOpenResult {
        let result: FileManagerArchiveOpenResult
        switch preparedResult {
        case let .opened(prepared):
            commitPreparedArchive(prepared, replaceCurrentState: replaceCurrentState)
            return .opened
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
                                       replaceCurrentState: Bool) {
        if replaceCurrentState {
            closeAllArchives()
        }

        currentDirectory = prepared.hostDirectory
        recordDirectoryVisit(prepared.hostDirectory)
        if let temporaryDirectory = prepared.temporaryDirectory {
            archiveItemWorkflowService.register(temporaryDirectory)
        }

        let level = ArchiveLevel(
            filesystemDirectory: prepared.hostDirectory,
            archivePath: prepared.archivePath,
            displayPathPrefix: prepared.displayPathPrefix,
            archive: prepared.archive,
            allEntries: prepared.entries,
            currentSubdir: "",
            temporaryDirectory: prepared.temporaryDirectory
        )
        archiveStack.append(level)
        navigateArchiveSubdir("")
    }

    func navigateArchiveSubdir(_ subdir: String) {
        guard var level = archiveStack.last else { return }

        // Update current subdir in the stack
        archiveStack[archiveStack.count - 1] = ArchiveLevel(
            filesystemDirectory: level.filesystemDirectory,
            archivePath: level.archivePath,
            displayPathPrefix: level.displayPathPrefix,
            archive: level.archive,
            allEntries: level.allEntries,
            currentSubdir: subdir,
            temporaryDirectory: level.temporaryDirectory
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

            if currentDepth > 0 && Array(parts.prefix(currentDepth)) != subdirParts {
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
                    createdDate: nil, crc: 0, isDirectory: true,
                    isEncrypted: false, method: "", attributes: 0, comment: ""
                ))
            }
        }

        archiveDisplayItems = displayItems
        sortCurrentItems(by: tableView.sortDescriptors)

        // Update path field to show full path including archive
        updatePathField()
        updateStatusBar()
        tableView.reloadData()
    }
}

// MARK: - NSMenuDelegate (auto-select row on right-click)

extension FileManagerPaneController {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let clickedRow = tableView.clickedRow
        if clickedRow >= 0 && !tableView.selectedRowIndexes.contains(clickedRow) {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
    }
}

// MARK: - Context Menu

extension FileManagerPaneController {

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self  // auto-select row on right-click
        let items: [(String, Selector)] = [
            ("Open", #selector(openSelectedItem(_:))),
            ("Open in ShichiZip", #selector(openInArchiveViewer(_:))),
        ]
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [
            ("Compress...", #selector(compressSelected(_:))),
            ("Extract...", #selector(extractSelected(_:))),
            ("Extract Here", #selector(extractHere(_:))),
        ] as [(String, Selector)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [
            ("Rename", #selector(renameSelected(_:))),
            ("Delete", #selector(deleteSelected(_:))),
        ] as [(String, Selector)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let cf = NSMenuItem(title: "Create Folder", action: #selector(createFolderFromMenu(_:)), keyEquivalent: "")
        cf.target = self
        menu.addItem(cf)
        menu.addItem(.separator())
        let pr = NSMenuItem(title: "Properties", action: #selector(showItemProperties(_:)), keyEquivalent: "")
        pr.target = self
        menu.addItem(pr)
        return menu
    }

    @objc private func openSelectedItem(_ sender: Any?) {
        doubleClickRow(nil)
    }

    @objc private func openInArchiveViewer(_ sender: Any?) {
        guard let url = selectedArchiveCandidateURL() else { return }
        delegate?.paneDidRequestOpenArchiveInNewWindow(url)
    }

    @objc private func compressSelected(_ sender: Any?) {
        guard !isInsideArchive else {
            showUnsupportedArchiveOperationAlert(action: "Compressing archive items")
            return
        }

        // Forward to FileManagerWindowController
        if let wc = view.window?.windowController as? FileManagerWindowController {
            wc.addToArchive(nil)
        }
    }

    @objc private func extractSelected(_ sender: Any?) {
        if let wc = view.window?.windowController as? FileManagerWindowController {
            wc.extractArchive(nil)
        }
    }

    @objc private func extractHere(_ sender: Any?) {
        if isInsideArchive {
            let destinationURL = archiveHostDirectory()
            Task { @MainActor [weak self] in
                guard let self, let parentWindow = self.view.window else { return }
                do {
                    try await ArchiveOperationRunner.run(operationTitle: "Extracting...",
                                                         parentWindow: parentWindow) { session in
                        try self.extractCurrentSelectionOrDisplayedArchiveItems(to: destinationURL,
                                                                                session: session,
                                                                                overwriteMode: .ask)
                    }
                } catch {
                    self.showErrorAlert(error)
                }
            }
            return
        }

        guard let url = selectedArchiveCandidateURL() else { return }

        let destURL = currentDirectory
        Task { @MainActor [weak self] in
            guard let self, let parentWindow = self.view.window else { return }
            do {
                try await ArchiveOperationRunner.run(operationTitle: "Extracting...",
                                                     parentWindow: parentWindow) { session in
                    let archive = SZArchive()
                    try archive.open(atPath: url.path, session: session)
                    let settings = SZExtractionSettings()
                    settings.overwriteMode = .ask
                    try archive.extract(toPath: destURL.path, settings: settings, session: session)
                    archive.close()
                }
                self.refresh()
            } catch {
                self.showErrorAlert(error)
            }
        }
    }

    @objc private func renameSelected(_ sender: Any?) {
        guard !isInsideArchive else {
            showUnsupportedArchiveOperationAlert(action: "Renaming archive items")
            return
        }

        let selectedItems = selectedFileSystemItems()
        guard selectedItems.count == 1 else { return }
        let item = selectedItems[0]

        guard let window = view.window else { return }
        szBeginTextInput(on: window,
                         title: "Rename",
                         initialValue: item.name,
                         confirmTitle: "Rename") { [weak self] value in
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

    @objc private func deleteSelected(_ sender: Any?) {
        guard !isInsideArchive else {
            showUnsupportedArchiveOperationAlert(action: "Deleting archive items")
            return
        }

        let paths = selectedFilePaths()
        guard !paths.isEmpty else { return }

        guard let window = view.window else { return }
        szBeginConfirmation(on: window,
                            title: "Delete \(paths.count) item(s)?",
                            message: "Items will be moved to Trash.",
                            confirmTitle: "Move to Trash") { [weak self] confirmed in
            guard confirmed else { return }
            for path in paths {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
            self?.refresh()
        }
    }

    @objc private func createFolderFromMenu(_ sender: Any?) {
        guard let window = view.window else { return }
        szBeginTextInput(on: window,
                         title: "Create Folder",
                         placeholder: "New Folder",
                         confirmTitle: "Create") { [weak self] value in
            guard let name = value, !name.isEmpty else { return }
            self?.createFolder(named: name)
        }
    }

    @objc private func showItemProperties(_ sender: Any?) {
        guard let item = selectedRealPaneItems().first else { return }

        switch item {
        case let .filesystem(fileSystemItem):
            let url = fileSystemItem.url
            let resourceValues = try? url.resourceValues(forKeys: [
                .fileSizeKey, .isDirectoryKey, .contentModificationDateKey,
                .creationDateKey, .fileResourceTypeKey
            ])

            let size = ByteCountFormatter.string(fromByteCount: Int64(resourceValues?.fileSize ?? 0), countStyle: .file)
            let dateFormatter = FileManagerViewPreferences.makeDateFormatter(dateStyle: .long,
                                                                             timeStyle: .medium)
            let details = """
            Type: \(resourceValues?.isDirectory == true ? "Folder" : url.pathExtension.uppercased())
            Size: \(size)
            Modified: \(resourceValues?.contentModificationDate.map { dateFormatter.string(from: $0) } ?? "—")
            Created: \(resourceValues?.creationDate.map { dateFormatter.string(from: $0) } ?? "—")
            """
            szShowDetailsDialog(title: url.lastPathComponent,
                                details: details,
                                for: view.window)

        case let .archive(archiveItem):
            let dateFormatter = FileManagerViewPreferences.makeDateFormatter(dateStyle: .long,
                                                                             timeStyle: .medium)
            let sizeText = archiveItem.isDirectory
                ? "—"
                : ByteCountFormatter.string(fromByteCount: Int64(archiveItem.size), countStyle: .file)
            let packedText = archiveItem.isDirectory
                ? "—"
                : ByteCountFormatter.string(fromByteCount: Int64(archiveItem.packedSize), countStyle: .file)
            let typeText: String
            if archiveItem.isDirectory {
                typeText = archiveItem.index >= 0 ? "Folder in Archive" : "Virtual Folder in Archive"
            } else {
                typeText = archiveItem.method.isEmpty ? "File in Archive" : archiveItem.method
            }

            let details = """
            Type: \(typeText)
            Path: \(archiveItem.path)
            Size: \(sizeText)
            Packed Size: \(packedText)
            Modified: \(archiveItem.modifiedDate.map { dateFormatter.string(from: $0) } ?? "—")
            Created: \(archiveItem.createdDate.map { dateFormatter.string(from: $0) } ?? "—")
            Encrypted: \(archiveItem.isEncrypted ? "Yes" : "No")
            CRC: \(archiveItem.crc == 0 ? "—" : String(format: "%08X", archiveItem.crc))
            """
            szShowDetailsDialog(title: archiveItem.name,
                                details: details,
                                for: view.window)

        case .parent:
            return
        }
    }
}
