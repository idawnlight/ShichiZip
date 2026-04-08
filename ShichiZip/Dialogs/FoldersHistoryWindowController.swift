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

final class FoldersHistoryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Result {
        let selectedURL: URL?
        let updatedEntries: [URL]
    }

    private var entries: [URL]
    private weak var parentWindow: NSWindow?
    private var completionHandler: ((Result?) -> Void)?
    private var hasCompleted = false

    private var tableView: FoldersHistoryTableView!
    private var statusLabel: NSTextField!
    private var deleteButton: NSButton!
    private var clearButton: NSButton!
    private var openButton: NSButton!

    init(entries: [URL]) {
        let standardizedEntries = entries.map(\.standardizedFileURL)
        self.entries = standardizedEntries

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Folders History"
        window.minSize = NSSize(width: 520, height: 280)

        super.init(window: window)

        window.delegate = self
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func beginSheetModal(for window: NSWindow,
                         completionHandler: @escaping (Result?) -> Void) {
        guard let sheetWindow = self.window else {
            completionHandler(nil)
            return
        }

        self.parentWindow = window
        self.completionHandler = completionHandler
        hasCompleted = false

        updateControls()
        tableView.reloadData()
        tableView.selectRowIndexes(entries.isEmpty ? [] : IndexSet(integer: 0), byExtendingSelection: false)
        window.beginSheet(sheetWindow) { _ in }
        sheetWindow.makeFirstResponder(tableView)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel(nil)
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    @objc private func openSelection(_ sender: Any?) {
        guard !entries.isEmpty else { return }
        finish(with: Result(selectedURL: selectedEntry(),
                            updatedEntries: entries))
    }

    @objc private func cancel(_ sender: Any?) {
        finish(with: nil)
    }

    @objc private func deleteSelection(_ sender: Any?) {
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

    @objc private func clearHistory(_ sender: Any?) {
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
        guard let contentView = window?.contentView else { return }

        let rootStack = NSStackView()
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        contentView.addSubview(rootStack)

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

        let buttonsRow = NSStackView()
        buttonsRow.orientation = .horizontal
        buttonsRow.alignment = .centerY
        buttonsRow.spacing = 8

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonsRow.addArrangedSubview(spacer)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        openButton = NSButton(title: "Open", target: self, action: #selector(openSelection(_:)))
        openButton.keyEquivalent = "\r"

        buttonsRow.addArrangedSubview(cancelButton)
        buttonsRow.addArrangedSubview(openButton)
        rootStack.addArrangedSubview(buttonsRow)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
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
        openButton?.isEnabled = hasSelection

        let itemLabel = entries.count == 1 ? "folder" : "folders"
        statusLabel?.stringValue = "\(entries.count) \(itemLabel)"
    }

    private func finish(with result: Result?) {
        guard !hasCompleted else { return }
        hasCompleted = true

        let completionHandler = self.completionHandler
        self.completionHandler = nil

        if let sheetWindow = window, let parentWindow {
            parentWindow.endSheet(sheetWindow)
        } else {
            close()
        }

        completionHandler?(result)
    }
}