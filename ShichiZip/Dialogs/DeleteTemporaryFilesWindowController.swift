import Cocoa

@MainActor
final class DeleteTemporaryFilesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case name
        case modified
        case size
        case files
        case folders
        case item

        var title: String {
            switch self {
            case .name:
                SZL10n.string("column.name")
            case .modified:
                SZL10n.string("column.modified")
            case .size:
                SZL10n.string("column.size")
            case .files:
                SZL10n.string("column.files")
            case .folders:
                SZL10n.string("column.folders")
            case .item:
                "Item"
            }
        }

        var width: CGFloat {
            switch self {
            case .name:
                220
            case .modified:
                170
            case .size:
                110
            case .files, .folders:
                72
            case .item:
                160
            }
        }

        var alignment: NSTextAlignment {
            switch self {
            case .size, .files, .folders:
                .right
            case .name, .modified, .item:
                .natural
            }
        }

        var defaultAscending: Bool {
            switch self {
            case .modified, .size, .files, .folders:
                false
            case .name, .item:
                true
            }
        }
    }

    private struct DirectorySummary {
        let totalSize: Int64
        let fileCount: Int
        let folderCount: Int
        let previewName: String?
    }

    private struct BrowserItem {
        let url: URL
        let name: String
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let modifiedDate: Date?
        let size: Int64
        let fileCount: Int?
        let folderCount: Int?
        let previewName: String?
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private let fileManager: FileManager
    private let tempRoot: URL

    private var currentDirectory: URL
    private var items: [BrowserItem] = []
    private var loadGeneration = 0
    private var isLoading = false
    private var isDeleting = false

    /// Cache of row icons keyed by filename extension (or a special
    /// sentinel for directories / extensionless files). NSWorkspace's
    /// icon(forFile:) is not cheap — each call resolves the UTI,
    /// consults LaunchServices, and returns a fresh NSImage — and
    /// tableView(_:viewFor:row:) fires this per visible cell on every
    /// reload or scroll. The temp folder browser lists homogenous
    /// extraction directories and a handful of file types, so keying
    /// by extension gives near-100 % hit rate without risking
    /// bundle-specific icons going stale (bundles live outside this
    /// browser's domain).
    private var iconCacheByExtension: [String: NSImage] = [:]

    private var deleteButton: NSButton!
    private var refreshButton: NSButton!
    private var parentButton: NSButton!
    private var pathField: NSTextField!
    private var statusLabel: NSTextField!
    private var tableView: NSTableView!

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        tempRoot = FileManagerTemporaryDirectorySupport.rootDirectory(fileManager: fileManager)
        currentDirectory = tempRoot

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = SZL10n.string("app.deleteTempFiles.title")
        window.minSize = NSSize(width: 700, height: 380)
        window.center()

        super.init(window: window)

        window.delegate = self
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(tableView)
        reloadContents()
    }

    private var isBusy: Bool {
        isLoading || isDeleting
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let rootStack = NSStackView()
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 10
        contentView.addSubview(rootStack)

        let controlsRow = NSStackView()
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 8

        deleteButton = NSButton(title: SZL10n.string("toolbar.delete"), target: self, action: #selector(deleteSelection(_:)))
        refreshButton = NSButton(title: SZL10n.string("view.refresh"), target: self, action: #selector(refreshContents(_:)))
        parentButton = NSButton(title: SZL10n.string("view.upOneLevel"), target: self, action: #selector(openParentFolder(_:)))

        deleteButton.setAccessibilityIdentifier("deleteTempFiles.deleteButton")
        refreshButton.setAccessibilityIdentifier("deleteTempFiles.refreshButton")
        parentButton.setAccessibilityIdentifier("deleteTempFiles.parentButton")

        controlsRow.addArrangedSubview(deleteButton)
        controlsRow.addArrangedSubview(refreshButton)
        controlsRow.addArrangedSubview(parentButton)
        controlsRow.setContentHuggingPriority(.required, for: .horizontal)
        rootStack.addArrangedSubview(controlsRow)

        let pathRow = NSStackView()
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 8

        let pathLabel = NSTextField(labelWithString: SZL10n.string("app.deleteTempFiles.folder"))
        pathLabel.font = .systemFont(ofSize: 12, weight: .medium)
        pathRow.addArrangedSubview(pathLabel)

        pathField = NSTextField(string: currentDirectory.path)
        pathField.isEditable = false
        pathField.isBezeled = true
        pathField.drawsBackground = true
        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.setAccessibilityIdentifier("deleteTempFiles.pathField")
        pathRow.addArrangedSubview(pathField)

        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rootStack.addArrangedSubview(pathRow)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true

        tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.doubleAction = #selector(doubleClickRow(_:))
        tableView.target = self
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.setAccessibilityIdentifier("deleteTempFiles.tableView")

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue,
                                                                   ascending: column.defaultAscending)
            tableView.addTableColumn(tableColumn)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: Column.modified.rawValue, ascending: false)]

        scrollView.documentView = tableView
        rootStack.addArrangedSubview(scrollView)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("deleteTempFiles.statusLabel")
        rootStack.addArrangedSubview(statusLabel)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])

        updateControls()
    }

    private func updateControls() {
        let atRoot = currentDirectory.standardizedFileURL.path == tempRoot.path
        deleteButton.isEnabled = !isBusy && !selectedItems().isEmpty
        refreshButton.isEnabled = !isBusy
        parentButton.isEnabled = !isBusy && !atRoot
        pathField.stringValue = currentDirectory.path

        if isLoading {
            statusLabel.stringValue = SZL10n.string("app.deleteTempFiles.loading")
        } else if isDeleting {
            statusLabel.stringValue = SZL10n.string("app.deleteTempFiles.deleting")
        } else {
            let itemLabel = items.count == 1 ? SZL10n.string("app.deleteTempFiles.item") : SZL10n.string("app.deleteTempFiles.items")
            statusLabel.stringValue = "\(items.count) \(itemLabel)"
        }
    }

    private func reloadContents(selectingNames namesToSelect: Set<String> = []) {
        if !FileManagerTemporaryDirectorySupport.isInsideRoot(currentDirectory, fileManager: fileManager) {
            currentDirectory = tempRoot
        }

        let directory = currentDirectory
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        updateControls()

        DispatchQueue.global(qos: .userInitiated).async { [tempRoot] in
            let fileManager = FileManager()
            let result: Result<[BrowserItem], Error>
            do {
                let loadedItems = try Self.loadItems(in: directory,
                                                     tempRoot: tempRoot,
                                                     fileManager: fileManager)
                result = .success(loadedItems)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, generation == loadGeneration else { return }
                isLoading = false

                switch result {
                case let .success(loadedItems):
                    items = sortedItems(loadedItems)
                    tableView.reloadData()
                    restoreSelection(names: namesToSelect)
                case let .failure(error):
                    let nsError = error as NSError
                    if directory.path != self.tempRoot.path,
                       nsError.domain == NSCocoaErrorDomain,
                       nsError.code == CocoaError.fileReadNoSuchFile.rawValue
                    {
                        currentDirectory = self.tempRoot
                        reloadContents()
                        return
                    }
                    items.removeAll()
                    tableView.reloadData()
                    szPresentError(error, for: window)
                }

                updateControls()
            }
        }
    }

    private func restoreSelection(names: Set<String>) {
        guard !names.isEmpty else {
            tableView.deselectAll(nil)
            return
        }

        let selection = IndexSet(items.enumerated().compactMap { names.contains($0.element.name) ? $0.offset : nil })
        guard !selection.isEmpty else {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(selection, byExtendingSelection: false)
        if let firstIndex = selection.first {
            tableView.scrollRowToVisible(firstIndex)
        }
    }

    private nonisolated static func loadItems(in directory: URL,
                                              tempRoot: URL,
                                              fileManager: FileManager) throws -> [BrowserItem]
    {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey,
                                                 .isSymbolicLinkKey,
                                                 .contentModificationDateKey,
                                                 .fileSizeKey]
        let contents = try fileManager.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: Array(resourceKeys),
                                                           options: [])
        let filteredContents: [URL] = if directory.standardizedFileURL.path == tempRoot.path {
            contents.filter(FileManagerTemporaryDirectorySupport.isManagedRootItem)
        } else {
            contents
        }

        return try filteredContents.map { try makeBrowserItem(for: $0, fileManager: fileManager) }
    }

    private nonisolated static func makeBrowserItem(for url: URL,
                                                    fileManager: FileManager) throws -> BrowserItem
    {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey,
                                                      .isSymbolicLinkKey,
                                                      .contentModificationDateKey,
                                                      .fileSizeKey])
        let isDirectory = values.isDirectory ?? false
        let isSymbolicLink = values.isSymbolicLink ?? false

        let summary: DirectorySummary? = if isDirectory, !isSymbolicLink {
            summarizeDirectory(at: url, fileManager: fileManager)
        } else {
            nil
        }

        return BrowserItem(url: url,
                           name: url.lastPathComponent,
                           isDirectory: isDirectory,
                           isSymbolicLink: isSymbolicLink,
                           modifiedDate: values.contentModificationDate,
                           size: summary?.totalSize ?? Int64(values.fileSize ?? 0),
                           fileCount: summary?.fileCount,
                           folderCount: summary?.folderCount,
                           previewName: summary?.previewName)
    }

    private nonisolated static func summarizeDirectory(at url: URL,
                                                       fileManager: FileManager) -> DirectorySummary
    {
        let childKeys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: url,
                                                      includingPropertiesForKeys: Array(childKeys),
                                                      options: [.skipsPackageDescendants])
        else {
            return DirectorySummary(totalSize: 0, fileCount: 0, folderCount: 0, previewName: nil)
        }

        var totalSize: Int64 = 0
        var fileCount = 0
        var folderCount = 0
        var previewName: String?

        for case let childURL as URL in enumerator {
            if previewName == nil {
                previewName = childURL.lastPathComponent
            }

            let values = try? childURL.resourceValues(forKeys: childKeys)
            if values?.isDirectory == true {
                folderCount += 1
            } else {
                fileCount += 1
                totalSize += Int64(values?.fileSize ?? 0)
            }
        }

        return DirectorySummary(totalSize: totalSize,
                                fileCount: fileCount,
                                folderCount: folderCount,
                                previewName: previewName)
    }

    private func selectedItems() -> [BrowserItem] {
        tableView.selectedRowIndexes.compactMap { index in
            guard items.indices.contains(index) else { return nil }
            return items[index]
        }
    }

    private func sortedItems(_ unsortedItems: [BrowserItem]) -> [BrowserItem] {
        let descriptors = tableView.sortDescriptors
        return unsortedItems.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }

            for descriptor in descriptors {
                let comparison = compare(lhs, rhs, key: descriptor.key ?? Column.name.rawValue)
                if comparison != .orderedSame {
                    return descriptor.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
                }
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func compare(_ lhs: BrowserItem,
                         _ rhs: BrowserItem,
                         key: String) -> ComparisonResult
    {
        switch key {
        case Column.modified.rawValue:
            switch (lhs.modifiedDate, rhs.modifiedDate) {
            case let (left?, right?):
                return left.compare(right)
            case (.some, .none):
                return .orderedDescending
            case (.none, .some):
                return .orderedAscending
            case (.none, .none):
                return .orderedSame
            }

        case Column.size.rawValue:
            return lhs.size == rhs.size ? .orderedSame : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)

        case Column.files.rawValue:
            let left = lhs.fileCount ?? -1
            let right = rhs.fileCount ?? -1
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)

        case Column.folders.rawValue:
            let left = lhs.folderCount ?? -1
            let right = rhs.folderCount ?? -1
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)

        case Column.item.rawValue:
            return (lhs.previewName ?? "").localizedStandardCompare(rhs.previewName ?? "")

        case Column.name.rawValue:
            fallthrough

        default:
            return lhs.name.localizedStandardCompare(rhs.name)
        }
    }

    private func stringValue(for item: BrowserItem,
                             column: Column) -> String
    {
        switch column {
        case .name:
            return item.name
        case .modified:
            guard let modifiedDate = item.modifiedDate else { return "" }
            return Self.dateFormatter.string(from: modifiedDate)
        case .size:
            guard item.size > 0 else { return "" }
            return ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        case .files:
            guard let fileCount = item.fileCount, fileCount > 0 else { return "" }
            return "\(fileCount)"
        case .folders:
            guard let folderCount = item.folderCount, folderCount > 0 else { return "" }
            return "\(folderCount)"
        case .item:
            return item.previewName ?? ""
        }
    }

    @objc private func refreshContents(_: Any?) {
        reloadContents(selectingNames: Set(selectedItems().map(\.name)))
    }

    @objc private func openParentFolder(_: Any?) {
        guard currentDirectory.path != tempRoot.path else { return }
        let parent = currentDirectory.deletingLastPathComponent().standardizedFileURL
        currentDirectory = FileManagerTemporaryDirectorySupport.isInsideRoot(parent, fileManager: fileManager) ? parent : tempRoot
        reloadContents()
    }

    @objc private func doubleClickRow(_: Any?) {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }

        let item = items[row]
        if item.isDirectory, !item.isSymbolicLink {
            currentDirectory = item.url.standardizedFileURL
            reloadContents()
            return
        }

        _ = NSWorkspace.shared.open(item.url)
    }

    @objc private func deleteSelection(_: Any?) {
        let selectedItems = selectedItems()
        guard !selectedItems.isEmpty,
              let window else { return }

        let message: String
        if selectedItems.count == 1, let item = selectedItems.first {
            message = item.isDirectory
                ? SZL10n.string("app.deleteTempFiles.deleteContents", item.name)
                : SZL10n.string("app.deleteTempFiles.deleteFile", item.name)
        } else {
            let preview = selectedItems.prefix(5).map(\.name).joined(separator: "\n")
            let suffix = selectedItems.count > 5 ? "\n…" : ""
            message = SZL10n.string("app.deleteTempFiles.deleteMultiple", selectedItems.count) + "\n\n\(preview)\(suffix)"
        }

        szBeginConfirmation(on: window,
                            title: SZL10n.string("app.deleteTempFiles.title"),
                            message: message,
                            confirmTitle: SZL10n.string("toolbar.delete"),
                            style: .warning)
        { [weak self] confirmed in
            guard confirmed else { return }
            self?.performDelete(items: selectedItems)
        }
    }

    private func performDelete(items itemsToDelete: [BrowserItem]) {
        isDeleting = true
        updateControls()

        let urls = itemsToDelete.map(\.url)
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager()
            let result: Result<Void, Error>
            do {
                for url in urls {
                    guard FileManagerTemporaryDirectorySupport.isInsideRoot(url, fileManager: fileManager) else {
                        continue
                    }
                    try fileManager.removeItem(at: url)
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isDeleting = false
                switch result {
                case .success:
                    reloadContents()
                case let .failure(error):
                    updateControls()
                    szPresentError(error, for: window)
                }
            }
        }
    }

    func numberOfRows(in _: NSTableView) -> Int {
        items.count
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateControls()
    }

    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange _: [NSSortDescriptor])
    {
        items = sortedItems(items)
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView?
    {
        guard items.indices.contains(row),
              let tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue)
        else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("DeleteTemporaryFiles.\(column.rawValue)")
        let item = items[row]
        let cell = makeCellView(for: column,
                                identifier: identifier,
                                tableView: tableView)
        cell.textField?.stringValue = stringValue(for: item, column: column)
        cell.textField?.alignment = column.alignment

        if column == .name {
            let image = cachedIcon(for: item)
            cell.imageView?.image = image
        } else {
            cell.imageView?.image = nil
        }

        return cell
    }

    private func cachedIcon(for item: BrowserItem) -> NSImage {
        // Bundle-style directories (.app, .bundle, .pkg, framework…)
        // each ship their own icon via NSWorkspace.icon(forFile:). They
        // must not share the generic "__dir__" cache slot, or the first
        // bundle's icon would be overwritten by a plain folder icon and
        // vice versa. Identify them via the URL resource key rather
        // than a hard-coded extension allow-list.
        let isPackage: Bool = (try? item.url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        let key: String
        if isPackage {
            // Per-path key: bundles are rare enough in the delete-temp
            // window that the extra cache entries are negligible, and
            // anything rarer than that falls through to a new entry.
            key = "pkg:" + item.url.path
        } else if item.isDirectory {
            key = "__dir__"
        } else {
            key = "ext:" + item.url.pathExtension.lowercased()
        }
        if let cached = iconCacheByExtension[key] {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        image.size = NSSize(width: 16, height: 16)
        iconCacheByExtension[key] = image
        return image
    }

    private func makeCellView(for column: Column,
                              identifier: NSUserInterfaceItemIdentifier,
                              tableView: NSTableView) -> NSTableCellView
    {
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.textField = textField
        cell.addSubview(textField)

        if column == .name {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            imageView.imageAlignment = .alignCenter
            cell.imageView = imageView
            cell.addSubview(imageView)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        return cell
    }
}
