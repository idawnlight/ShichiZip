import Cocoa

/// Dual-pane file manager window replicating 7-Zip File Manager
class FileManagerWindowController: NSWindowController, NSWindowDelegate, NSUserInterfaceValidations {

    private var splitView: NSSplitView!
    private var leftPane: FileManagerPaneController!
    private var rightPane: FileManagerPaneController!
    private var toolbar: NSToolbar!
    private var isDualPane = false
    private var keyEventMonitor: Any?

    var onWindowWillClose: ((FileManagerWindowController) -> Void)?

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
        self.window?.delegate = self
        setupUI()
        setupToolbar()
        setupMainMenu()
        self.window?.initialFirstResponder = leftPane.preferredInitialFirstResponder
        self.window?.makeFirstResponder(leftPane.preferredInitialFirstResponder)
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        activePane.focusFileList()
    }

    func windowWillClose(_ notification: Notification) {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
        onWindowWillClose?(self)
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
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.handleKeyEvent(event) ?? event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard window?.isKeyWindow == true else { return event }

        switch event.keyCode {
        case 48: // Tab - Switch panes (PanelKey.cpp)
            switchPanes(nil)
            return nil
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

    /// Navigate the active pane to show an archive's contents
    func navigateToArchive(_ url: URL) {
        activePane.showArchive(at: url)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleDualPane(_ sender: Any?) {
        isDualPane.toggle()
        if isDualPane {
            splitView.addArrangedSubview(rightPane.view)
        } else {
            rightPane.view.removeFromSuperview()
        }
    }

    @objc func addToArchive(_ sender: Any?) {
        let activePane = self.activePane
        guard activePane.canAddSelectedItemsToArchive() else {
            if activePane.isVirtualLocation {
                showUnsupportedOperationAlert("Creating or updating archives from inside an open archive is not implemented yet.")
            }
            return
        }

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
        let activePane = self.activePane
        guard activePane.canExtractSelectionOrArchive() else { return }

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
                    if activePane.isVirtualLocation {
                        try activePane.extractCurrentSelectionOrDisplayedArchiveItems(to: destURL,
                                                                                    progress: progressController,
                                                                                    overwriteMode: .ask)
                    } else {
                        guard let archiveURL = activePane.selectedArchiveCandidateURL() else {
                            throw NSError(domain: "SZArchiveErrorDomain",
                                          code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: "Select an archive to extract."])
                        }
                        let archive = SZArchive()
                        try archive.open(atPath: archiveURL.path)
                        let settings = SZExtractionSettings()
                        try archive.extract(toPath: destURL.path, settings: settings,
                                           progress: progressController)
                        archive.close()
                    }
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
        let activePane = self.activePane
        guard activePane.canTestArchiveSelection() else { return }

        let progressController = ProgressDialogController()
        progressController.operationTitle = "Testing archive..."
        window?.beginSheet(progressController.window!) { _ in }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                if activePane.isVirtualLocation {
                    try activePane.testCurrentArchive(progress: progressController)
                } else {
                    guard let archiveURL = activePane.selectedArchiveCandidateURL() else {
                        throw NSError(domain: "SZArchiveErrorDomain",
                                      code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "Select an archive to test."])
                    }
                    let archive = SZArchive()
                    try archive.open(atPath: archiveURL.path)
                    try archive.test(withProgress: progressController)
                    archive.close()
                }
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

    @objc func switchPanes(_ sender: Any?) {
        guard isDualPane else { return }
        if activePane === leftPane {
            rightPane.focusFileList()
        } else {
            leftPane.focusFileList()
        }
    }

    private var activePane: FileManagerPaneController {
        if isDualPane,
           let fr = window?.firstResponder as? NSView,
           fr === rightPane.view || fr.isDescendant(of: rightPane.view) {
            return rightPane
        }
        return leftPane
    }

    private var inactivePane: FileManagerPaneController? {
        guard isDualPane else { return nil }
        return activePane === leftPane ? rightPane : leftPane
    }

    // MARK: - Copy/Move (PanelCopy.cpp pattern)

    @objc func copyFiles(_ sender: Any?) {
        performFileOperation(move: false)
    }

    @objc func moveFiles(_ sender: Any?) {
        performFileOperation(move: true)
    }

    private func performFileOperation(move: Bool) {
        let pane = activePane

        if pane.isVirtualLocation {
            if move {
                showUnsupportedOperationAlert("Moving items from an open archive is not implemented yet. Use Copy to extract them out first.")
                return
            }

            guard pane.canCopySelection() else { return }
            guard let destURL = chooseDestinationURL(forMove: false) else { return }

            let progressController = ProgressDialogController()
            progressController.operationTitle = "Copying selected archive items..."
            window?.beginSheet(progressController.window!) { _ in }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try pane.extractSelectedArchiveItems(to: destURL,
                                                        progress: progressController,
                                                        overwriteMode: .ask)
                    DispatchQueue.main.async {
                        self?.window?.endSheet(progressController.window!)
                        self?.inactivePane?.refresh()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.window?.endSheet(progressController.window!)
                        if let win = self?.window {
                            NSAlert(error: error).beginSheetModal(for: win)
                        }
                    }
                }
            }
            return
        }

        let sourcePaths = pane.selectedFilePaths()
        guard !sourcePaths.isEmpty else { return }

        // Determine destination — other pane if dual, or ask via dialog
        guard let destURL = chooseDestinationURL(forMove: move) else { return }

        let operation = move ? "Moving" : "Copying"
        let progressController = ProgressDialogController()
        progressController.operationTitle = "\(operation) \(sourcePaths.count) item(s)..."
        window?.beginSheet(progressController.window!) { _ in }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var skipAll = false
            var overwriteAll = false

            for (i, sourcePath) in sourcePaths.enumerated() {
                let sourceURL = URL(fileURLWithPath: sourcePath)
                let destFile = destURL.appendingPathComponent(sourceURL.lastPathComponent)
                let fraction = Double(i) / Double(sourcePaths.count)

                DispatchQueue.main.async {
                    progressController.progressDidUpdate(fraction)
                    progressController.progressDidUpdateFileName(sourceURL.lastPathComponent)
                }

                // Overwrite check (matches COverwriteDialog in 7-Zip)
                if fm.fileExists(atPath: destFile.path) {
                    if skipAll { continue }
                    if !overwriteAll {
                        var shouldSkip = false
                        var cancelled = false
                        DispatchQueue.main.sync {
                            let alert = NSAlert()
                            alert.messageText = "File already exists"
                            let srcAttrs = try? fm.attributesOfItem(atPath: sourcePath)
                            let dstAttrs = try? fm.attributesOfItem(atPath: destFile.path)
                            let srcSize = (srcAttrs?[.size] as? UInt64) ?? 0
                            let dstSize = (dstAttrs?[.size] as? UInt64) ?? 0
                            let srcDate = (srcAttrs?[.modificationDate] as? Date)
                            let dstDate = (dstAttrs?[.modificationDate] as? Date)
                            let df = DateFormatter()
                            df.dateStyle = .medium; df.timeStyle = .medium

                            alert.informativeText = """
                            Destination: \(destFile.lastPathComponent)
                            Size: \(ByteCountFormatter.string(fromByteCount: Int64(dstSize), countStyle: .file))  Modified: \(dstDate.map { df.string(from: $0) } ?? "—")

                            Source: \(sourceURL.lastPathComponent)
                            Size: \(ByteCountFormatter.string(fromByteCount: Int64(srcSize), countStyle: .file))  Modified: \(srcDate.map { df.string(from: $0) } ?? "—")
                            """
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "Replace")
                            alert.addButton(withTitle: "Replace All")
                            alert.addButton(withTitle: "Skip")
                            alert.addButton(withTitle: "Skip All")
                            alert.addButton(withTitle: "Cancel")
                            let resp = alert.runModal()
                            // NSAlertFirstButtonReturn = 1000, second = 1001, etc.
                            switch resp.rawValue {
                            case 1000: break // Replace this one
                            case 1001: overwriteAll = true
                            case 1002: shouldSkip = true
                            case 1003: skipAll = true; shouldSkip = true
                            default: cancelled = true
                            }
                        }
                        if cancelled {
                            DispatchQueue.main.async { self?.window?.endSheet(progressController.window!) }
                            return
                        }
                        if shouldSkip { continue }
                    }
                    // Remove existing before copy/move
                    try? fm.removeItem(at: destFile)
                }

                do {
                    if move {
                        try fm.moveItem(at: sourceURL, to: destFile)
                    } else {
                        let r = copyfile(
                            sourceURL.path.cString(using: .utf8),
                            destFile.path.cString(using: .utf8),
                            nil,
                            copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE_FORCE)
                        )
                        if r != 0 {
                            let r2 = copyfile(
                                sourceURL.path.cString(using: .utf8),
                                destFile.path.cString(using: .utf8),
                                nil,
                                copyfile_flags_t(COPYFILE_ALL)
                            )
                            if r2 != 0 {
                                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                            }
                        }
                    }
                } catch {
                    // Stop on first error (matches 7-Zip behavior)
                    DispatchQueue.main.async {
                        self?.window?.endSheet(progressController.window!)
                        if let win = self?.window {
                            NSAlert(error: error).beginSheetModal(for: win)
                        }
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                self?.window?.endSheet(progressController.window!)
                pane.refresh()
                self?.inactivePane?.refresh()
            }
        }
    }

    @objc func createFolder(_ sender: Any?) {
        guard activePane.canCreateFolderHere() else {
            showUnsupportedOperationAlert("Creating folders inside an open archive is not implemented yet.")
            return
        }

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
            self?.activePane.createFolder(named: name)
        }
    }

    @objc func deleteFiles(_ sender: Any?) {
        let activePane = self.activePane
        guard activePane.canDeleteSelection() else {
            if activePane.isVirtualLocation {
                showUnsupportedOperationAlert("Deleting items from inside an open archive is not implemented yet.")
            }
            return
        }

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

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(addToArchive(_:)):
            return activePane.canAddSelectedItemsToArchive()
        case #selector(extractArchive(_:)):
            return activePane.canExtractSelectionOrArchive()
        case #selector(testArchive(_:)):
            return activePane.canTestArchiveSelection()
        case #selector(copyFiles(_:)):
            return activePane.canCopySelection()
        case #selector(moveFiles(_:)):
            return activePane.canMoveSelection()
        case #selector(createFolder(_:)):
            return activePane.canCreateFolderHere()
        case #selector(deleteFiles(_:)):
            return activePane.canDeleteSelection()
        case #selector(switchPanes(_:)):
            return isDualPane
        default:
            return true
        }
    }

    private func chooseDestinationURL(forMove move: Bool) -> URL? {
        if let otherPane = inactivePane, !otherPane.isVirtualLocation {
            return otherPane.currentDirectoryURL
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = move ? "Move" : "Copy"
        panel.message = move ? "Choose destination folder:" : "Choose destination folder:"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    private func showUnsupportedOperationAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Operation Not Available"
        alert.informativeText = message
        alert.alertStyle = .informational
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
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
    func paneDidRequestOpenArchiveInNewWindow(_ url: URL)
}

extension FileManagerWindowController: FileManagerPaneDelegate {
    func paneDidRequestOpenArchiveInNewWindow(_ url: URL) {
        (NSApp.delegate as? AppDelegate)?.openArchiveInNewFileManager(url)
    }
}
