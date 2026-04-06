import Cocoa

/// Dual-pane file manager window replicating 7-Zip File Manager
class FileManagerWindowController: NSWindowController {

    private var splitView: NSSplitView!
    private var leftPane: FileManagerPaneController!
    private var rightPane: FileManagerPaneController!
    private var toolbar: NSToolbar!
    private var isDualPane = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ShichiZip"
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        self.init(window: window)
        setupUI()
        setupToolbar()
        setupMainMenu()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.dividerStyle = .thin
        splitView.isVertical = true

        leftPane = FileManagerPaneController()
        leftPane.delegate = self

        rightPane = FileManagerPaneController()
        rightPane.delegate = self

        splitView.addArrangedSubview(leftPane.view)

        contentView.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func setupToolbar() {
        toolbar = NSToolbar(identifier: "FileManagerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window?.toolbar = toolbar
    }

    private func setupMainMenu() {
        // Main menu is defined in MainMenu.xib or programmatically
        // We'll handle key events for F-key shortcuts
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.handleKeyEvent(event) ?? event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard window?.isKeyWindow == true else { return event }

        switch event.keyCode {
        case 96: // F5 - Copy
            copyFiles(nil)
            return nil
        case 97: // F6 - Move
            moveFiles(nil)
            return nil
        case 98: // F7 - Create folder
            createFolder(nil)
            return nil
        case 100: // F8 - Delete
            deleteFiles(nil)
            return nil
        case 101: // F9 - Toggle dual pane
            toggleDualPane(nil)
            return nil
        default:
            return event
        }
    }

    // MARK: - Actions

    @objc func toggleDualPane(_ sender: Any?) {
        isDualPane.toggle()
        if isDualPane {
            splitView.addArrangedSubview(rightPane.view)
        } else {
            rightPane.view.removeFromSuperview()
        }
    }

    @objc func addToArchive(_ sender: Any?) {
        let activePane = leftPane! // TODO: track active pane
        let selectedPaths = activePane.selectedFilePaths()
        guard !selectedPaths.isEmpty else { return }

        let compressDialog = CompressDialogController()
        compressDialog.sourcePaths = selectedPaths

        let dialogWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        dialogWindow.title = "Create Archive — ShichiZip"
        dialogWindow.contentViewController = compressDialog

        window?.beginSheet(dialogWindow) { _ in }

        compressDialog.completionHandler = { [weak self] settings, archivePath in
            self?.window?.endSheet(dialogWindow)
            guard let settings = settings, let archivePath = archivePath else { return }

            let progressController = ProgressDialogController()
            progressController.operationTitle = "Compressing..."

            let progressWindow = progressController.window!
            self?.window?.beginSheet(progressWindow) { _ in }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try SZArchive.create(
                        atPath: archivePath,
                        fromPaths: selectedPaths,
                        settings: settings,
                        progress: progressController
                    )
                    DispatchQueue.main.async {
                        self?.window?.endSheet(progressWindow)
                        activePane.refresh()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.window?.endSheet(progressWindow)
                        let alert = NSAlert(error: error)
                        if let win = self?.window {
                            alert.beginSheetModal(for: win)
                        }
                    }
                }
            }
        }
    }

    @objc func extractArchive(_ sender: Any?) {
        let activePane = leftPane! // TODO: track active pane
        let selectedPaths = activePane.selectedFilePaths()
        guard let firstPath = selectedPaths.first else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract"

        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let destURL = panel.url else { return }

            let progressController = ProgressDialogController()
            progressController.operationTitle = "Extracting..."

            self?.window?.beginSheet(progressController.window!) { _ in }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let archive = SZArchive()
                    try archive.open(atPath: firstPath)
                    let settings = SZExtractionSettings()
                    try archive.extract(toPath: destURL.path, settings: settings,
                                       progress: progressController)
                    archive.close()
                    DispatchQueue.main.async {
                        self?.window?.endSheet(progressController.window!)
                        NSWorkspace.shared.open(destURL)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.window?.endSheet(progressController.window!)
                        let alert = NSAlert(error: error)
                        if let win = self?.window {
                            alert.beginSheetModal(for: win)
                        }
                    }
                }
            }
        }
    }

    @objc func testArchive(_ sender: Any?) {
        let activePane = leftPane!
        guard let path = activePane.selectedFilePaths().first else { return }

        let progressController = ProgressDialogController()
        progressController.operationTitle = "Testing archive..."
        window?.beginSheet(progressController.window!) { _ in }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let archive = SZArchive()
                try archive.open(atPath: path)
                try archive.test(withProgress: progressController)
                archive.close()
                DispatchQueue.main.async {
                    self?.window?.endSheet(progressController.window!)
                    let alert = NSAlert()
                    alert.messageText = "Test OK"
                    alert.informativeText = "No errors found."
                    alert.alertStyle = .informational
                    if let win = self?.window {
                        alert.beginSheetModal(for: win)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.window?.endSheet(progressController.window!)
                    let alert = NSAlert(error: error)
                    if let win = self?.window {
                        alert.beginSheetModal(for: win)
                    }
                }
            }
        }
    }

    @objc func copyFiles(_ sender: Any?) {
        // TODO: Implement file copy between panes
    }

    @objc func moveFiles(_ sender: Any?) {
        // TODO: Implement file move between panes
    }

    @objc func createFolder(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Create Folder"
        alert.informativeText = "Enter folder name:"

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.placeholderString = "New Folder"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = input.stringValue
            guard !name.isEmpty else { return }
            self?.leftPane.createFolder(named: name)
        }
    }

    @objc func deleteFiles(_ sender: Any?) {
        let activePane = leftPane!
        let paths = activePane.selectedFilePaths()
        guard !paths.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(paths.count) item(s)?"
        alert.informativeText = "Items will be moved to Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window!) { response in
            guard response == .alertFirstButtonReturn else { return }
            for path in paths {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
            activePane.refresh()
        }
    }
}

// MARK: - NSToolbarDelegate

extension FileManagerWindowController: NSToolbarDelegate {

    static let addItem = NSToolbarItem.Identifier("fm_add")
    static let extractItem = NSToolbarItem.Identifier("fm_extract")
    static let testItem = NSToolbarItem.Identifier("fm_test")
    static let copyItem = NSToolbarItem.Identifier("fm_copy")
    static let moveItem = NSToolbarItem.Identifier("fm_move")
    static let deleteItem = NSToolbarItem.Identifier("fm_delete")
    static let infoItem = NSToolbarItem.Identifier("fm_info")
    static let splitItem = NSToolbarItem.Identifier("fm_split")

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        switch itemIdentifier {
        case Self.addItem:
            item.label = "Add"
            item.toolTip = "Add files to archive"
            item.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add")
            item.target = self
            item.action = #selector(addToArchive(_:))

        case Self.extractItem:
            item.label = "Extract"
            item.toolTip = "Extract archive"
            item.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Extract")
            item.target = self
            item.action = #selector(extractArchive(_:))

        case Self.testItem:
            item.label = "Test"
            item.toolTip = "Test archive integrity"
            item.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: "Test")
            item.target = self
            item.action = #selector(testArchive(_:))

        case Self.copyItem:
            item.label = "Copy (F5)"
            item.toolTip = "Copy files"
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            item.target = self
            item.action = #selector(copyFiles(_:))

        case Self.moveItem:
            item.label = "Move (F6)"
            item.toolTip = "Move files"
            item.image = NSImage(systemSymbolName: "folder.badge.questionmark", accessibilityDescription: "Move")
            item.target = self
            item.action = #selector(moveFiles(_:))

        case Self.deleteItem:
            item.label = "Delete (F8)"
            item.toolTip = "Delete files"
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            item.target = self
            item.action = #selector(deleteFiles(_:))

        case Self.splitItem:
            item.label = "Split (F9)"
            item.toolTip = "Toggle dual pane"
            item.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split")
            item.target = self
            item.action = #selector(toggleDualPane(_:))

        default:
            return nil
        }

        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.addItem, Self.extractItem, Self.testItem,
         .space,
         Self.copyItem, Self.moveItem, Self.deleteItem,
         .flexibleSpace,
         Self.splitItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.addItem, Self.extractItem, Self.testItem,
         Self.copyItem, Self.moveItem, Self.deleteItem, Self.splitItem,
         .space, .flexibleSpace]
    }
}

// MARK: - FileManagerPaneDelegate

protocol FileManagerPaneDelegate: AnyObject {
    func paneDidOpenArchive(_ path: String)
}

extension FileManagerWindowController: FileManagerPaneDelegate {
    func paneDidOpenArchive(_ path: String) {
        // Open archive in document-based window
        let url = URL(fileURLWithPath: path)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error = error {
                let alert = NSAlert(error: error)
                self.window.map { alert.beginSheetModal(for: $0) }
            }
        }
    }
}
