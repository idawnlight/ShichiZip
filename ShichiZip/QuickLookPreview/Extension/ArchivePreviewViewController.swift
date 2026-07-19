import AppKit
import QuickLookUI
import UniformTypeIdentifiers

final class ArchivePreviewViewController: NSViewController, @MainActor QLPreviewingController {
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let hiddenItemsButton = NSButton(
        checkboxWithTitle: ArchivePreviewLocalization.string("app.quickLook.archivePreview.showHiddenItems"),
        target: nil,
        action: nil,
    )
    private let tableView = NSOutlineView()
    private let scrollView = NSScrollView()

    private var snapshot: ArchivePreviewSnapshot?
    private var rootNodes: [ArchivePreviewTreeNode] = []
    private var visibleColumns: [ArchivePreviewColumn] = []
    private var iconCache: [ArchivePreviewIconKey: NSImage] = [:]
    private var expandedDirectoryIDs = Set<ArchiveDirectoryID>()
    private var hasRecordedExpansionState = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 520))
        view.wantsLayer = true
        configureHeader()
        configureTable()
        configureLayout()
    }

    func preparePreviewOfFile(at url: URL,
                              completionHandler handler: @escaping (Error?) -> Void)
    {
        Task {
            do {
                try await applyPreview(Self.loadSnapshot(at: url))
            } catch {
                applyPreviewFailure(error)
            }
            handler(nil)
        }
    }

    private static func loadSnapshot(at url: URL) async throws -> ArchivePreviewSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try ArchivePreviewLoader.loadArchiveContents(at: url)
        }.value
    }

    private func applyPreview(_ loadedSnapshot: ArchivePreviewSnapshot) {
        snapshot = loadedSnapshot
        expandedDirectoryIDs.removeAll()
        hasRecordedExpansionState = false
        configureColumns(for: loadedSnapshot)
        hiddenItemsButton.isEnabled = true
        statusLabel.stringValue = ""
        reloadTable()
    }

    private func applyPreviewFailure(_ error: Error) {
        snapshot = nil
        rootNodes = []
        tableView.reloadData()
        hiddenItemsButton.isEnabled = false
        showErrorState(error)
    }

    @objc private func hiddenItemsChanged(_: Any?) {
        recordVisibleExpansionState()
        hasRecordedExpansionState = true
        reloadTable()
    }

    private func configureHeader() {
        summaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize,
                                        weight: .semibold)
        summaryLabel.lineBreakMode = .byTruncatingTail

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        hiddenItemsButton.target = self
        hiddenItemsButton.action = #selector(hiddenItemsChanged(_:))
        hiddenItemsButton.state = SZSharedUserDefaults.defaults.bool(forKey: "ShowHiddenFiles")
            ? .on
            : .off
    }

    private func configureTable() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.headerView = NSTableHeaderView()
        tableView.indentationPerLevel = 16
        tableView.autosaveExpandedItems = false
        tableView.delegate = self
        tableView.dataSource = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    private func configureLayout() {
        let spacer = NSView()
        let headerStack = NSStackView(views: [summaryLabel,
                                              statusLabel,
                                              spacer,
                                              hiddenItemsButton])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hiddenItemsButton.setContentHuggingPriority(.required, for: .horizontal)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerStack)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func showErrorState(_ error: Error) {
        summaryLabel.stringValue = ArchivePreviewLocalization.string("app.quickLook.archivePreview.unavailable")
        statusLabel.stringValue = error.localizedDescription
        statusLabel.textColor = .secondaryLabelColor
    }

    private func reloadTable() {
        guard let snapshot else {
            summaryLabel.stringValue = ArchivePreviewLocalization.string("app.quickLook.archivePreview.empty")
            rootNodes = []
            tableView.reloadData()
            return
        }

        let showHiddenItems = hiddenItemsButton.state == .on
        rootNodes = snapshot.treeNodes(showHiddenItems: showHiddenItems)
        summaryLabel.stringValue = snapshot.summaryText(showHiddenItems: showHiddenItems)
        tableView.reloadData()
        restoreExpansionState()
    }

    private func configureColumns(for snapshot: ArchivePreviewSnapshot) {
        let resolvedColumns = ArchivePreviewColumnPreferences.resolvedColumns(snapshot.availableColumns,
                                                                              folderTypeID: snapshot.folderTypeID)
        resetColumns()
        visibleColumns = resolvedColumns.map(\.column)

        for resolvedColumn in resolvedColumns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(resolvedColumn.column.id.rawValue))
            tableColumn.title = resolvedColumn.column.title
            tableColumn.width = resolvedColumn.width
            tableColumn.minWidth = resolvedColumn.column.minWidth
            tableView.addTableColumn(tableColumn)
            if resolvedColumn.column.id == .name {
                tableView.outlineTableColumn = tableColumn
            }
        }
    }

    private func resetColumns() {
        visibleColumns = []
        for tableColumn in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(tableColumn)
        }
    }

    private func icon(for row: ArchivePreviewRow) -> NSImage {
        if let cachedIcon = iconCache[row.iconKey] {
            return cachedIcon
        }

        let icon: NSImage = switch row.iconKey {
        case .folder:
            NSWorkspace.shared.icon(for: .folder)
        case let .fileExtension(fileExtension):
            if let type = UTType(filenameExtension: fileExtension) {
                NSWorkspace.shared.icon(for: type)
            } else {
                NSWorkspace.shared.icon(for: .data)
            }
        case .genericFile:
            NSWorkspace.shared.icon(for: .data)
        }

        iconCache[row.iconKey] = icon
        return icon
    }

    private func column(for tableColumn: NSTableColumn) -> ArchivePreviewColumn? {
        let id = ArchivePreviewColumnID(rawValue: tableColumn.identifier.rawValue)
        return visibleColumns.first { $0.id == id }
    }

    private func recordVisibleExpansionState() {
        recordExpansionState(for: rootNodes)
    }

    private func recordExpansionState(for nodes: [ArchivePreviewTreeNode]) {
        var stack = nodes
        while let node = stack.popLast() {
            guard !node.children.isEmpty,
                  let directoryID = node.directoryID
            else { continue }
            if tableView.isItemExpanded(node) {
                expandedDirectoryIDs.insert(directoryID)
                stack.append(contentsOf: node.children)
            } else {
                expandedDirectoryIDs.remove(directoryID)
            }
        }
    }

    private func restoreExpansionState() {
        if hasRecordedExpansionState {
            restoreExpansionState(for: rootNodes)
            return
        }

        expandDefaultItems()
    }

    private func restoreExpansionState(for nodes: [ArchivePreviewTreeNode]) {
        var stack = nodes
        while let node = stack.popLast() {
            guard !node.children.isEmpty,
                  let directoryID = node.directoryID,
                  expandedDirectoryIDs.contains(directoryID)
            else { continue }
            tableView.expandItem(node)
            stack.append(contentsOf: node.children)
        }
    }

    private func expandDefaultItems() {
        let depth = ArchivePreviewPreferences.expansionDepth()
        guard depth > 0 else { return }
        expandDefaultItems(for: rootNodes,
                           remainingDepth: depth)
    }

    private func expandDefaultItems(for nodes: [ArchivePreviewTreeNode],
                                    remainingDepth: Int)
    {
        guard remainingDepth > 0 else { return }

        var stack = nodes.map { ($0, remainingDepth) }
        while let (node, depth) = stack.popLast() {
            guard !node.children.isEmpty else { continue }
            tableView.expandItem(node)
            if depth > 1 {
                stack.append(contentsOf: node.children.map { ($0, depth - 1) })
            }
        }
    }
}

private final class ArchivePreviewTextCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ArchivePreviewTextCellView")

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String,
                   alignment: NSTextAlignment,
                   font: NSFont,
                   isHidden: Bool)
    {
        label.stringValue = text
        label.alignment = alignment
        label.font = font
        label.textColor = isHidden ? .secondaryLabelColor : .labelColor
        label.alphaValue = isHidden ? 0.7 : 1.0
    }

    private func configureSubviews() {
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

private final class ArchivePreviewNameCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ArchivePreviewNameCellView")

    private let iconImageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String,
                   icon: NSImage,
                   alignment: NSTextAlignment,
                   font: NSFont,
                   isHidden: Bool)
    {
        label.stringValue = text
        label.alignment = alignment
        label.font = font
        label.textColor = isHidden ? .secondaryLabelColor : .labelColor
        label.alphaValue = isHidden ? 0.7 : 1.0
        iconImageView.image = icon
        iconImageView.alphaValue = isHidden ? 0.5 : 1.0
    }

    private func configureSubviews() {
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyDown
        imageView = iconImageView
        addSubview(iconImageView)

        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        addSubview(label)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

extension ArchivePreviewViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_: NSOutlineView,
                     numberOfChildrenOfItem item: Any?) -> Int
    {
        node(for: item)?.children.count ?? rootNodes.count
    }

    func outlineView(_: NSOutlineView,
                     child index: Int,
                     ofItem item: Any?) -> Any
    {
        if let node = node(for: item) {
            return node.children[index]
        }

        return rootNodes[index]
    }

    func outlineView(_: NSOutlineView,
                     isItemExpandable item: Any) -> Bool
    {
        node(for: item)?.children.isEmpty == false
    }

    func outlineView(_: NSOutlineView,
                     shouldSelectItem _: Any) -> Bool
    {
        false
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView?
    {
        guard let tableColumn,
              let column = column(for: tableColumn)
        else {
            return nil
        }

        guard let node = node(for: item) else {
            return nil
        }

        let previewRow = node.row
        let alignment = column.alignment.textAlignment
        let font = column.textStyle.font
        if column.id == .name {
            let cell = outlineView.makeView(withIdentifier: ArchivePreviewNameCellView.reuseIdentifier,
                                            owner: self) as? ArchivePreviewNameCellView
                ?? ArchivePreviewNameCellView()
            cell.configure(text: node.text(for: column.id),
                           icon: icon(for: previewRow),
                           alignment: alignment,
                           font: font,
                           isHidden: previewRow.isHidden)
            return cell
        }

        let cell = outlineView.makeView(withIdentifier: ArchivePreviewTextCellView.reuseIdentifier,
                                        owner: self) as? ArchivePreviewTextCellView
            ?? ArchivePreviewTextCellView()
        cell.configure(text: node.text(for: column.id),
                       alignment: alignment,
                       font: font,
                       isHidden: previewRow.isHidden)
        return cell
    }

    private func node(for item: Any?) -> ArchivePreviewTreeNode? {
        item as? ArchivePreviewTreeNode
    }
}

private extension ArchivePreviewColumnAlignment {
    var textAlignment: NSTextAlignment {
        switch self {
        case .left:
            .left
        case .right:
            .right
        }
    }
}

private extension ArchivePreviewColumnTextStyle {
    var font: NSFont {
        switch self {
        case .standard:
            .systemFont(ofSize: NSFont.systemFontSize)
        case .tabularNumbers:
            .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                       weight: .regular)
        case .fixedWidth:
            .monospacedSystemFont(ofSize: NSFont.systemFontSize,
                                  weight: .regular)
        }
    }
}
