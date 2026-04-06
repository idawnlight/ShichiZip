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

        // Columns — add sort descriptors (matches PanelSort.cpp logic)
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 300
        nameCol.minWidth = 150
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true,
            selector: #selector(NSString.localizedStandardCompare(_:)))
        outlineView.addTableColumn(nameCol)
        outlineView.outlineTableColumn = nameCol

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 60
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
        outlineView.addTableColumn(sizeCol)

        let packedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("packed"))
        packedCol.title = "Packed Size"
        packedCol.width = 80
        packedCol.minWidth = 60
        packedCol.sortDescriptorPrototype = NSSortDescriptor(key: "packed", ascending: false)
        outlineView.addTableColumn(packedCol)

        let modifiedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified"))
        modifiedCol.title = "Modified"
        modifiedCol.width = 140
        modifiedCol.minWidth = 80
        modifiedCol.sortDescriptorPrototype = NSSortDescriptor(key: "modified", ascending: false)
        outlineView.addTableColumn(modifiedCol)

        let methodCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("method"))
        methodCol.title = "Method"
        methodCol.width = 70
        methodCol.minWidth = 50
        methodCol.sortDescriptorPrototype = NSSortDescriptor(key: "method", ascending: true)
        outlineView.addTableColumn(methodCol)

        let crcCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("crc"))
        crcCol.title = "CRC"
        crcCol.width = 80
        crcCol.minWidth = 60
        crcCol.sortDescriptorPrototype = NSSortDescriptor(key: "crc", ascending: true)
        outlineView.addTableColumn(crcCol)

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClickRow(_:))

        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.menu = buildContextMenu()

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

            if columnID == "name" {
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
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

    // MARK: - Sorting (matches PanelSort.cpp)

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortTreeNodes(&treeRoot, by: outlineView.sortDescriptors)
        outlineView.reloadData()
    }

    private func sortTreeNodes(_ nodes: inout [ArchiveTreeNode], by descriptors: [NSSortDescriptor]) {
        guard let descriptor = descriptors.first else { return }
        let key = descriptor.key ?? "name"
        let ascending = descriptor.ascending

        // PanelSort.cpp: folders always before files
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }

            let result: ComparisonResult
            switch key {
            case "name":
                result = a.name.localizedStandardCompare(b.name)
            case "size":
                let aSize = a.item?.size ?? 0
                let bSize = b.item?.size ?? 0
                result = aSize == bSize ? .orderedSame : (aSize < bSize ? .orderedAscending : .orderedDescending)
            case "packed":
                let aSize = a.item?.packedSize ?? 0
                let bSize = b.item?.packedSize ?? 0
                result = aSize == bSize ? .orderedSame : (aSize < bSize ? .orderedAscending : .orderedDescending)
            case "modified":
                let aDate = a.item?.modifiedDate ?? Date.distantPast
                let bDate = b.item?.modifiedDate ?? Date.distantPast
                result = aDate.compare(bDate)
            case "method":
                result = (a.item?.method ?? "").localizedStandardCompare(b.item?.method ?? "")
            case "crc":
                let aCrc = a.item?.crc ?? 0
                let bCrc = b.item?.crc ?? 0
                result = aCrc == bCrc ? .orderedSame : (aCrc < bCrc ? .orderedAscending : .orderedDescending)
            default:
                result = a.name.localizedStandardCompare(b.name)
            }

            return ascending ? result == .orderedAscending : result == .orderedDescending
        }

        // Recursively sort children
        for node in nodes {
            sortTreeNodes(&node.children, by: descriptors)
        }
    }
}

// MARK: - Context Menu

extension ArchiveViewController {

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Extract Selected...", action: #selector(extractSelected(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a"))
        menu.addItem(NSMenuItem(title: "Invert Selection", action: #selector(invertSelection(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Properties", action: #selector(showProperties(_:)), keyEquivalent: ""))
        return menu
    }

    @objc func invertSelection(_ sender: Any?) {
        let allRows = IndexSet(0..<outlineView.numberOfRows)
        let selected = outlineView.selectedRowIndexes
        let inverted = allRows.subtracting(selected)
        outlineView.selectRowIndexes(inverted, byExtendingSelection: false)
    }

    @objc func showProperties(_ sender: Any?) {
        let selectedRows = outlineView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }

        var totalSize: UInt64 = 0
        var totalPacked: UInt64 = 0
        var fileCount = 0
        var dirCount = 0

        for row in selectedRows {
            if let node = outlineView.item(atRow: row) as? ArchiveTreeNode {
                if node.isDirectory { dirCount += 1 } else { fileCount += 1 }
                totalSize += node.item?.size ?? 0
                totalPacked += node.item?.packedSize ?? 0
            }
        }

        let alert = NSAlert()
        alert.messageText = "Properties"
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
        let packedStr = ByteCountFormatter.string(fromByteCount: Int64(totalPacked), countStyle: .file)
        let ratio = totalSize > 0 ? Double(totalPacked) / Double(totalSize) * 100.0 : 0
        alert.informativeText = """
        Files: \(fileCount)
        Folders: \(dirCount)
        Size: \(sizeStr)
        Packed Size: \(packedStr)
        Ratio: \(String(format: "%.1f%%", ratio))
        """
        alert.beginSheetModal(for: view.window!)
    }
}
