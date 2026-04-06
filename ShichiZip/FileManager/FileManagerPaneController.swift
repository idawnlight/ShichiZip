import Cocoa

/// Single pane of the file manager — displays file system contents
class FileManagerPaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    weak var delegate: FileManagerPaneDelegate?

    private var pathBar: NSPathControl!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var statusLabel: NSTextField!

    private var currentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    private var items: [FileSystemItem] = []

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))

        // Path bar
        pathBar = NSPathControl()
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.pathStyle = .standard
        pathBar.url = currentDirectory
        pathBar.target = self
        pathBar.action = #selector(pathBarClicked(_:))
        container.addSubview(pathBar)

        // Table view for file listing
        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.rowSizeStyle = .small
        tableView.style = .fullWidth

        // Columns
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
        tableView.doubleAction = #selector(doubleClickRow(_:))
        tableView.menu = buildContextMenu()

        // Register for drag and drop
        tableView.registerForDraggedTypes([.fileURL])

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        container.addSubview(scrollView)

        // Status bar
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            pathBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            pathBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            pathBar.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
        ])

        self.view = container
        loadDirectory(currentDirectory)
    }

    // MARK: - Navigation

    func loadDirectory(_ url: URL) {
        currentDirectory = url
        pathBar.url = url

        let fm = FileManager.default
        do {
            let contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )
            items = contents.map { FileSystemItem(url: $0) }.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        } catch {
            items = []
        }

        tableView.reloadData()
        updateStatusBar()
    }

    func refresh() {
        loadDirectory(currentDirectory)
    }

    func selectedFilePaths() -> [String] {
        return tableView.selectedRowIndexes.compactMap { row -> String? in
            guard row < items.count else { return nil }
            return items[row].url.path
        }
    }

    func createFolder(named name: String) {
        let url = currentDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            refresh()
        } catch {
            let alert = NSAlert(error: error)
            view.window.map { alert.beginSheetModal(for: $0) }
        }
    }

    private func updateStatusBar() {
        let fileCount = items.filter { !$0.isDirectory }.count
        let dirCount = items.filter { $0.isDirectory }.count
        let totalSize = items.filter { !$0.isDirectory }.reduce(UInt64(0)) { $0 + $1.size }
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
        statusLabel.stringValue = "\(fileCount) files, \(dirCount) folders — \(sizeStr)"
    }

    // MARK: - Actions

    @objc private func pathBarClicked(_ sender: NSPathControl) {
        guard let url = sender.clickedPathItem?.url else { return }
        loadDirectory(url)
    }

    @objc private func doubleClickRow(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }

        let item = items[row]
        if item.isDirectory {
            loadDirectory(item.url)
        } else if item.isArchive {
            delegate?.paneDidOpenArchive(item.url.path)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // Handle keyboard navigation
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Enter
            doubleClickRow(nil)
        } else if event.keyCode == 51 { // Backspace - go up
            let parent = currentDirectory.deletingLastPathComponent()
            loadDirectory(parent)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count, let columnID = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]

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

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        switch columnID {
        case "name":
            cell.textField?.stringValue = item.name
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.imageView?.image?.size = NSSize(width: 16, height: 16)

        case "size":
            cell.textField?.stringValue = item.formattedSize
            cell.textField?.alignment = .right

        case "modified":
            cell.textField?.stringValue = item.modifiedDate.map { dateFormatter.string(from: $0) } ?? ""

        case "created":
            cell.textField?.stringValue = item.createdDate.map { dateFormatter.string(from: $0) } ?? ""

        default:
            break
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 22
    }

    // MARK: - Sorting (matches PanelSort.cpp: folders first, natural sort for names)

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortItems(by: tableView.sortDescriptors)
        tableView.reloadData()
    }

    private func sortItems(by descriptors: [NSSortDescriptor]) {
        guard let descriptor = descriptors.first else { return }
        let key = descriptor.key ?? "name"
        let ascending = descriptor.ascending

        items.sort { a, b in
            // PanelSort.cpp: folders always before files
            if a.isDirectory != b.isDirectory { return a.isDirectory }

            let result: ComparisonResult
            switch key {
            case "name":
                result = a.name.localizedStandardCompare(b.name)
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
}

// MARK: - Context Menu

extension FileManagerPaneController {

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open", action: #selector(openSelectedItem(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open in ShichiZip", action: #selector(openInArchiveViewer(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Compress...", action: #selector(compressSelected(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Extract Here", action: #selector(extractHere(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Rename", action: #selector(renameSelected(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteSelected(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Create Folder", action: #selector(createFolderFromMenu(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Properties", action: #selector(showItemProperties(_:)), keyEquivalent: ""))
        return menu
    }

    @objc private func openSelectedItem(_ sender: Any?) {
        doubleClickRow(nil)
    }

    @objc private func openInArchiveViewer(_ sender: Any?) {
        guard let path = selectedFilePaths().first else { return }
        delegate?.paneDidOpenArchive(path)
    }

    @objc private func compressSelected(_ sender: Any?) {
        // Forward to FileManagerWindowController
        if let wc = view.window?.windowController as? FileManagerWindowController {
            wc.addToArchive(nil)
        }
    }

    @objc private func extractHere(_ sender: Any?) {
        guard let path = selectedFilePaths().first else { return }
        guard FileSystemItem.archiveExtensions.contains(
            (path as NSString).pathExtension.lowercased()) else { return }

        let destURL = currentDirectory
        let progressController = ProgressDialogController()
        progressController.operationTitle = "Extracting..."
        view.window?.beginSheet(progressController.window!) { _ in }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let archive = SZArchive()
                try archive.open(atPath: path)
                let settings = SZExtractionSettings()
                settings.overwriteMode = .ask
                try archive.extract(toPath: destURL.path, settings: settings, progress: progressController)
                archive.close()
                DispatchQueue.main.async {
                    self?.view.window?.endSheet(progressController.window!)
                    self?.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.view.window?.endSheet(progressController.window!)
                    if let win = self?.view.window {
                        NSAlert(error: error).beginSheetModal(for: win)
                    }
                }
            }
        }
    }

    @objc private func renameSelected(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]

        let alert = NSAlert()
        alert.messageText = "Rename"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = item.name
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let newName = input.stringValue
            guard !newName.isEmpty, newName != item.name else { return }
            let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(at: item.url, to: newURL)
                self?.refresh()
            } catch {
                if let win = self?.view.window {
                    NSAlert(error: error).beginSheetModal(for: win)
                }
            }
        }
    }

    @objc private func deleteSelected(_ sender: Any?) {
        let paths = selectedFilePaths()
        guard !paths.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(paths.count) item(s)?"
        alert.informativeText = "Items will be moved to Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            for path in paths {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
            self?.refresh()
        }
    }

    @objc private func createFolderFromMenu(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Create Folder"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.placeholderString = "New Folder"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return }
            self?.createFolder(named: input.stringValue)
        }
    }

    @objc private func showItemProperties(_ sender: Any?) {
        guard let path = selectedFilePaths().first else { return }
        let url = URL(fileURLWithPath: path)
        let resourceValues = try? url.resourceValues(forKeys: [
            .fileSizeKey, .isDirectoryKey, .contentModificationDateKey,
            .creationDateKey, .fileResourceTypeKey
        ])

        let alert = NSAlert()
        alert.messageText = url.lastPathComponent
        let size = ByteCountFormatter.string(fromByteCount: Int64(resourceValues?.fileSize ?? 0), countStyle: .file)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .medium
        alert.informativeText = """
        Type: \(resourceValues?.isDirectory == true ? "Folder" : url.pathExtension.uppercased())
        Size: \(size)
        Modified: \(resourceValues?.contentModificationDate.map { dateFormatter.string(from: $0) } ?? "—")
        Created: \(resourceValues?.creationDate.map { dateFormatter.string(from: $0) } ?? "—")
        """
        alert.beginSheetModal(for: view.window!)
    }
}
