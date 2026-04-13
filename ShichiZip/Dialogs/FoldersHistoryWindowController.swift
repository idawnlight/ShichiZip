import Cocoa

private final class FoldersHistoryTableView: NSTableView {
    var onDelete: (() -> Void)?
    var onConfirm: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onConfirm?()
        case 51, 117:
            onDelete?()
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class FoldersHistoryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Result {
        let selectedURL: URL?
        let updatedEntries: [URL]
    }

    private enum ButtonIndex {
        static let cancel = 0
        static let open = 1
    }

    private var entries: [URL]
    private var dialogController: SZModalDialogController?
    private var completionHandler: ((Result?) -> Void)?
    private var hasCompleted = false

    private let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
    private var tableView: FoldersHistoryTableView!
    private var statusLabel: NSTextField!
    private var deleteButton: NSButton!
    private var clearButton: NSButton!

    init(entries: [URL]) {
        let standardizedEntries = entries.map(\.standardizedFileURL)
        self.entries = standardizedEntries

        super.init()
        setupUI()
    }

    func beginSheetModal(for window: NSWindow,
                         completionHandler: @escaping (Result?) -> Void)
    {
        self.completionHandler = completionHandler
        hasCompleted = false

        updateControls()
        tableView.reloadData()
        tableView.selectRowIndexes(entries.isEmpty ? [] : IndexSet(integer: 0), byExtendingSelection: false)

        let controller = SZModalDialogController(style: .informational,
                                                 title: "Folders History",
                                                 message: nil,
                                                 buttonTitles: ["Cancel", "Open"],
                                                 accessoryView: accessoryView,
                                                 preferredFirstResponder: tableView,
                                                 cancelButtonIndex: ButtonIndex.cancel)
        dialogController = controller
        controller.setButtonEnabled(selectedEntry() != nil, at: ButtonIndex.open)
        controller.beginSheetModal(for: window) { [weak self] buttonIndex in
            self?.complete(buttonIndex: buttonIndex)
        }
    }

    func numberOfRows(in _: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor _: NSTableColumn?,
                   row: Int) -> NSView?
    {
        guard row >= 0, row < entries.count else { return nil }

        let cellIdentifier = NSUserInterfaceItemIdentifier("FolderHistoryCell")
        let cell: NSTableCellView

        if let existing = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingMiddle
            textField.translatesAutoresizingMaskIntoConstraints = false

            let container = NSTableCellView()
            container.identifier = cellIdentifier
            container.textField = textField
            container.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            cell = container
        }

        cell.textField?.stringValue = entries[row].path
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateControls()
    }

    @objc private func openSelection(_: Any?) {
        guard !entries.isEmpty else { return }
        dialogController?.finish(withButtonIndex: ButtonIndex.open)
    }

    @objc private func cancel(_: Any?) {
        dialogController?.finish(withButtonIndex: ButtonIndex.cancel)
    }

    @objc private func deleteSelection(_: Any?) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < entries.count else { return }

        entries.remove(at: selectedRow)
        tableView.reloadData()

        if entries.isEmpty {
            tableView.deselectAll(nil)
        } else {
            let nextRow = min(selectedRow, entries.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        }

        updateControls()
    }

    @objc private func clearHistory(_: Any?) {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        tableView.reloadData()
        tableView.deselectAll(nil)
        updateControls()
    }

    @objc private func doubleClickRow(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        openSelection(sender)
    }

    private func setupUI() {
        let rootStack = NSStackView()
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        accessoryView.addSubview(rootStack)

        let controlsRow = NSStackView()
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 8

        deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelection(_:)))
        clearButton = NSButton(title: "Clear", target: self, action: #selector(clearHistory(_:)))

        controlsRow.addArrangedSubview(deleteButton)
        controlsRow.addArrangedSubview(clearButton)
        rootStack.addArrangedSubview(controlsRow)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
        scrollView.heightAnchor.constraint(equalToConstant: 220).isActive = true

        tableView = FoldersHistoryTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.rowSizeStyle = .default
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickRow(_:))
        tableView.onDelete = { [weak self] in self?.deleteSelection(nil) }
        tableView.onConfirm = { [weak self] in self?.openSelection(nil) }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.title = "Folder"
        column.width = 560
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        rootStack.addArrangedSubview(scrollView)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.textColor = .secondaryLabelColor
        rootStack.addArrangedSubview(statusLabel)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: accessoryView.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: accessoryView.bottomAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: 520),
        ])
    }

    private func selectedEntry() -> URL? {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < entries.count else { return nil }
        return entries[selectedRow]
    }

    private func updateControls() {
        let hasSelection = selectedEntry() != nil
        deleteButton?.isEnabled = hasSelection
        clearButton?.isEnabled = !entries.isEmpty
        dialogController?.setButtonEnabled(hasSelection, at: ButtonIndex.open)

        let itemLabel = entries.count == 1 ? "folder" : "folders"
        statusLabel?.stringValue = "\(entries.count) \(itemLabel)"
    }

    private func complete(buttonIndex: Int) {
        guard !hasCompleted else { return }
        hasCompleted = true
        dialogController = nil

        let completionHandler = self.completionHandler
        self.completionHandler = nil

        guard buttonIndex == ButtonIndex.open, !entries.isEmpty else {
            completionHandler?(nil)
            return
        }

        completionHandler?(Result(selectedURL: selectedEntry(),
                                  updatedEntries: entries))
    }
}
