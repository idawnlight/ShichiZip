import Cocoa

class ArchiveViewController: NSViewController {

    private var scrollView: NSScrollView!
    private var outlineView: NSOutlineView!
    private var statusBar: NSTextField!

    private var treeRoot: [ArchiveTreeNode] = []
    private var currentPath: [ArchiveTreeNode] = [] // breadcrumb navigation stack
    private var document: ArchiveDocument?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

        // Status bar at bottom
        statusBar = NSTextField(labelWithString: "No archive loaded")
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.font = .systemFont(ofSize: 11)
        statusBar.textColor = .secondaryLabelColor
        container.addSubview(statusBar)

        // Outline view for archive contents
        outlineView = NSOutlineView()
        outlineView.headerView = NSTableHeaderView()
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnResizing = true
        outlineView.allowsColumnReordering = true
        outlineView.rowSizeStyle = .small
        outlineView.style = .fullWidth

        // Columns
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 300
        nameCol.minWidth = 150
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
        outlineView.addTableColumn(nameCol)
        outlineView.outlineTableColumn = nameCol

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 60
        outlineView.addTableColumn(sizeCol)

        let packedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("packed"))
        packedCol.title = "Packed Size"
        packedCol.width = 80
        packedCol.minWidth = 60
        outlineView.addTableColumn(packedCol)

        let modifiedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified"))
        modifiedCol.title = "Modified"
        modifiedCol.width = 140
        modifiedCol.minWidth = 80
        outlineView.addTableColumn(modifiedCol)

        let methodCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("method"))
        methodCol.title = "Method"
        methodCol.width = 70
        methodCol.minWidth = 50
        outlineView.addTableColumn(methodCol)

        let crcCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("crc"))
        crcCol.title = "CRC"
        crcCol.width = 80
        crcCol.minWidth = 60
        outlineView.addTableColumn(crcCol)

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClickRow(_:))

        // Register for drag and drop
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -4),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            statusBar.heightAnchor.constraint(equalToConstant: 16),
        ])

        self.view = container
    }

    func loadArchive(_ doc: ArchiveDocument) {
        self.document = doc
        self.treeRoot = doc.treeRoot
        outlineView.reloadData()
        updateStatusBar()
    }

    private func updateStatusBar() {
        guard let doc = document else {
            statusBar.stringValue = "No archive loaded"
            return
        }

        let fileCount = doc.entries.filter { !$0.isDirectory }.count
        let dirCount = doc.entries.filter { $0.isDirectory }.count
        let totalSize = doc.entries.reduce(UInt64(0)) { $0 + $1.size }
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)

        statusBar.stringValue = "\(fileCount) files, \(dirCount) folders — \(sizeStr)"
    }

    @objc private func doubleClickRow(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }

        guard let node = outlineView.item(atRow: row) as? ArchiveTreeNode else { return }

        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        }
    }

    // MARK: - Context Menu

    @objc func extractSelected(_ sender: Any?) {
        guard let doc = document else { return }

        let selectedRows = outlineView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }

        var indices: [Int] = []
        for row in selectedRows {
            if let node = outlineView.item(atRow: row) as? ArchiveTreeNode,
               let item = node.item {
                indices.append(item.index)
            }
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract"

        panel.beginSheetModal(for: view.window!) { response in
            guard response == .OK, let url = panel.url else { return }

            let progressController = ProgressDialogController()
            progressController.operationTitle = "Extracting selected files..."

            self.view.window?.beginSheet(progressController.window!) { _ in }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try doc.extractEntries(indices: indices, to: url, progress: progressController)
                    DispatchQueue.main.async {
                        self.view.window?.endSheet(progressController.window!)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.view.window?.endSheet(progressController.window!)
                        let alert = NSAlert(error: error)
                        alert.beginSheetModal(for: self.view.window!)
                    }
                }
            }
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension ArchiveViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return treeRoot.count
        }
        if let node = item as? ArchiveTreeNode {
            return node.children.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return treeRoot[index]
        }
        if let node = item as? ArchiveTreeNode {
            return node.children[index]
        }
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let node = item as? ArchiveTreeNode {
            return node.isDirectory && !node.children.isEmpty
        }
        return false
    }
}

// MARK: - NSOutlineViewDelegate

extension ArchiveViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ArchiveTreeNode,
              let columnID = tableColumn?.identifier.rawValue else { return nil }

        let cellID = NSUserInterfaceItemIdentifier(columnID)
        let cell: NSTableCellView

        if let reused = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            if columnID == "name" {
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(imageView)
                cell.imageView = imageView

                NSLayoutConstraint.deactivate(textField.constraints.filter {
                    ($0.firstAttribute == .leading && $0.firstItem as? NSView == textField)
                })

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                ])
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        switch columnID {
        case "name":
            cell.textField?.stringValue = node.name
            if node.isDirectory {
                cell.imageView?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
                cell.imageView?.contentTintColor = .systemBlue
            } else {
                cell.imageView?.image = NSWorkspace.shared.icon(for: .init(filenameExtension: URL(fileURLWithPath: node.name).pathExtension) ?? .data)
                cell.imageView?.contentTintColor = nil
            }

        case "size":
            if node.isDirectory {
                cell.textField?.stringValue = ""
            } else {
                cell.textField?.stringValue = ByteCountFormatter.string(fromByteCount: Int64(node.totalSize), countStyle: .file)
            }
            cell.textField?.alignment = .right

        case "packed":
            if node.isDirectory {
                cell.textField?.stringValue = ""
            } else {
                cell.textField?.stringValue = ByteCountFormatter.string(fromByteCount: Int64(node.totalPackedSize), countStyle: .file)
            }
            cell.textField?.alignment = .right

        case "modified":
            if let date = node.item?.modifiedDate {
                cell.textField?.stringValue = dateFormatter.string(from: date)
            } else {
                cell.textField?.stringValue = ""
            }

        case "method":
            cell.textField?.stringValue = node.item?.method ?? ""

        case "crc":
            if let item = node.item, !item.isDirectory {
                cell.textField?.stringValue = String(format: "%08X", item.crc)
                cell.textField?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            } else {
                cell.textField?.stringValue = ""
            }

        default:
            break
        }

        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return 22
    }
}
