import Cocoa

extension Notification.Name {
    static let fileManagerViewPreferencesDidChange = Notification.Name("FileManagerViewPreferencesDidChange")
}

enum FileManagerViewPreferences {
    private static let defaults = UserDefaults.standard
    private static let timestampUTCKey = "FileManager.TimestampUTC"
    private static let autoRefreshKey = "FileManager.AutoRefresh"

    static var usesUTCTimestamps: Bool {
        bool(forKey: timestampUTCKey, defaultValue: false)
    }

    static var autoRefreshEnabled: Bool {
        bool(forKey: autoRefreshKey, defaultValue: false)
    }

    static func setUsesUTCTimestamps(_ value: Bool) {
        set(value, forKey: timestampUTCKey)
    }

    static func setAutoRefreshEnabled(_ value: Bool) {
        set(value, forKey: autoRefreshKey)
    }

    static func makeDateFormatter(dateStyle: DateFormatter.Style,
                                  timeStyle: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        if usesUTCTimestamps {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
        }
        return formatter
    }

    private static func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .fileManagerViewPreferencesDidChange, object: nil)
    }

    private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

/// Dual-pane file manager window replicating 7-Zip File Manager
class FileManagerWindowController: NSWindowController, NSWindowDelegate, NSUserInterfaceValidations, NSMenuItemValidation {

    private enum ToolbarPreferences {
        private static let defaults = UserDefaults.standard
        private static let archiveToolbarKey = "FileManager.ShowArchiveToolbar"
        private static let standardToolbarKey = "FileManager.ShowStandardToolbar"
        private static let largeButtonsKey = "FileManager.ToolbarLargeButtons"
        private static let showTextKey = "FileManager.ToolbarShowButtonText"

        static var showsArchiveToolbar: Bool {
            bool(forKey: archiveToolbarKey, defaultValue: true)
        }

        static var showsStandardToolbar: Bool {
            bool(forKey: standardToolbarKey, defaultValue: true)
        }

        static var usesLargeButtons: Bool {
            bool(forKey: largeButtonsKey, defaultValue: true)
        }

        static var showsButtonText: Bool {
            bool(forKey: showTextKey, defaultValue: true)
        }

        static func setShowsArchiveToolbar(_ value: Bool) {
            defaults.set(value, forKey: archiveToolbarKey)
        }

        static func setShowsStandardToolbar(_ value: Bool) {
            defaults.set(value, forKey: standardToolbarKey)
        }

        static func setUsesLargeButtons(_ value: Bool) {
            defaults.set(value, forKey: largeButtonsKey)
        }

        static func setShowsButtonText(_ value: Bool) {
            defaults.set(value, forKey: showTextKey)
        }

        private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
            guard defaults.object(forKey: key) != nil else {
                return defaultValue
            }
            return defaults.bool(forKey: key)
        }
    }

    private var splitView: NSSplitView!
    private var leftPane: FileManagerPaneController!
    private var rightPane: FileManagerPaneController!
    private var toolbar: NSToolbar!
    private var isDualPane = false
    private var keyEventMonitor: Any?
    private var viewPreferencesObserver: NSObjectProtocol?
    private var autoRefreshTimer: Timer?

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
        observeViewPreferences()
        configureAutoRefreshTimer()
        self.window?.initialFirstResponder = leftPane.preferredInitialFirstResponder
        self.window?.makeFirstResponder(leftPane.preferredInitialFirstResponder)
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        if let viewPreferencesObserver {
            NotificationCenter.default.removeObserver(viewPreferencesObserver)
        }
        autoRefreshTimer?.invalidate()
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
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
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
        guard ToolbarPreferences.showsArchiveToolbar || ToolbarPreferences.showsStandardToolbar else {
            toolbar = nil
            window?.toolbar = nil
            return
        }

        let newToolbar = NSToolbar(identifier: "FileManagerToolbar")
        newToolbar.delegate = self
        newToolbar.displayMode = ToolbarPreferences.showsButtonText ? .iconAndLabel : .iconOnly
        newToolbar.sizeMode = ToolbarPreferences.usesLargeButtons ? .regular : .small
        toolbar = newToolbar
        window?.toolbar = newToolbar
    }

    private func setupMainMenu() {
        // Main menu is defined in MainMenu.xib or programmatically
        // We'll handle key events for F-key shortcuts
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.handleKeyEvent(event) ?? event
        }
    }

    private func observeViewPreferences() {
        viewPreferencesObserver = NotificationCenter.default.addObserver(
            forName: .fileManagerViewPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleViewPreferencesDidChange()
        }
    }

    private func handleViewPreferencesDidChange() {
        configureAutoRefreshTimer()
        leftPane.reloadPresentedValues()
        rightPane.reloadPresentedValues()
        if FileManagerViewPreferences.autoRefreshEnabled {
            performAutoRefreshTick()
        }
    }

    private func configureAutoRefreshTimer() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil

        guard FileManagerViewPreferences.autoRefreshEnabled else { return }

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.performAutoRefreshTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoRefreshTimer = timer
    }

    private func performAutoRefreshTick() {
        guard window?.isVisible == true else { return }
        leftPane.autoRefreshIfPossible()
        if isDualPane {
            rightPane.autoRefreshIfPossible()
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
    @discardableResult
    func navigateToArchive(_ url: URL, revealWindow: Bool = true) -> Bool {
        let opened = activePane.showArchive(at: url)
        if opened && revealWindow {
            window?.makeKeyAndOrderFront(nil)
        }
        return opened
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

            Task { @MainActor [weak self] in
                guard let self, let parentWindow = self.window else { return }
                do {
                    try await ArchiveOperationRunner.run(operationTitle: "Compressing...",
                                                         parentWindow: parentWindow) { session in
                        try SZArchive.create(
                            atPath: archivePath,
                            fromPaths: selectedPaths,
                            settings: settings,
                            session: session
                        )
                    }
                    activePane.refresh()
                } catch {
                    self.showErrorAlert(error)
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

            Task { @MainActor [weak self] in
                guard let self, let parentWindow = self.window else { return }
                do {
                    try await ArchiveOperationRunner.run(operationTitle: "Extracting...",
                                                         parentWindow: parentWindow) { session in
                        if activePane.isVirtualLocation {
                            try activePane.extractCurrentSelectionOrDisplayedArchiveItems(to: destURL,
                                                                                          session: session,
                                                                                          overwriteMode: .ask)
                        } else {
                            guard let archiveURL = activePane.selectedArchiveCandidateURL() else {
                                throw NSError(domain: SZArchiveErrorDomain,
                                              code: -1,
                                              userInfo: [NSLocalizedDescriptionKey: "Select an archive to extract."])
                            }
                            let archive = SZArchive()
                            try archive.open(atPath: archiveURL.path, session: session)
                            let settings = SZExtractionSettings()
                            try archive.extract(toPath: destURL.path, settings: settings,
                                                session: session)
                            archive.close()
                        }
                    }
                    NSWorkspace.shared.open(destURL)
                } catch {
                    self.showErrorAlert(error)
                }
            }
        }
    }

    @objc func testArchive(_ sender: Any?) {
        let activePane = self.activePane
        guard activePane.canTestArchiveSelection() else { return }

        Task { @MainActor [weak self] in
            guard let self, let parentWindow = self.window else { return }
            do {
                try await ArchiveOperationRunner.run(operationTitle: "Testing archive...",
                                                     parentWindow: parentWindow) { session in
                    if activePane.isVirtualLocation {
                        try activePane.testCurrentArchive(session: session)
                    } else {
                        guard let archiveURL = activePane.selectedArchiveCandidateURL() else {
                            throw NSError(domain: SZArchiveErrorDomain,
                                          code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: "Select an archive to test."])
                        }
                        let archive = SZArchive()
                        try archive.open(atPath: archiveURL.path, session: session)
                        try archive.test(with: session)
                        archive.close()
                    }
                }
                szPresentMessage(title: "Test OK",
                                 message: "No errors found.",
                                 for: self.window)
            } catch {
                self.showErrorAlert(error)
            }
        }
    }

    @objc func openSelectedItem(_ sender: Any?) {
        activePane.openSelection()
    }

    @objc func goUpOneLevel(_ sender: Any?) {
        activePane.goUpOneLevel()
    }

    @objc func renameSelection(_ sender: Any?) {
        activePane.renameSelection()
    }

    @objc func showProperties(_ sender: Any?) {
        activePane.showSelectedItemProperties()
    }

    @objc func extractHere(_ sender: Any?) {
        activePane.extractSelectionHere()
    }

    @objc func refreshActivePane(_ sender: Any?) {
        activePane.refresh()
    }

    @objc func selectAllItems(_ sender: Any?) {
        activePane.selectAllItems()
    }

    @objc func deselectAllItems(_ sender: Any?) {
        activePane.deselectAllItems()
    }

    @objc func invertSelection(_ sender: Any?) {
        activePane.invertSelection()
    }

    @objc func sortByName(_ sender: Any?) {
        activePane.sortByName()
    }

    @objc func sortBySize(_ sender: Any?) {
        activePane.sortBySize()
    }

    @objc func sortByType(_ sender: Any?) {
        activePane.sortByType()
    }

    @objc func sortByModifiedDate(_ sender: Any?) {
        activePane.sortByModifiedDate()
    }

    @objc func sortByCreatedDate(_ sender: Any?) {
        activePane.sortByCreatedDate()
    }

    @objc func showLocalTimestamps(_ sender: Any?) {
        FileManagerViewPreferences.setUsesUTCTimestamps(false)
    }

    @objc func showUTCTimestamps(_ sender: Any?) {
        FileManagerViewPreferences.setUsesUTCTimestamps(true)
    }

    @objc func toggleAutoRefresh(_ sender: Any?) {
        FileManagerViewPreferences.setAutoRefreshEnabled(!FileManagerViewPreferences.autoRefreshEnabled)
    }

    @objc func openRootFolder(_ sender: Any?) {
        activePane.openRootFolder()
    }

    @objc func showFoldersHistory(_ sender: Any?) {
        let entries = activePane.recentDirectoryHistory()
        guard !entries.isEmpty else { return }

        let historyPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        entries.forEach { historyPicker.addItem(withTitle: $0.path) }

        let alert = NSAlert()
        alert.messageText = "Folders History"
        alert.informativeText = "Choose a recent folder to open in the active pane."
        alert.accessoryView = historyPicker
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        activePane.openRecentDirectory(entries[historyPicker.indexOfSelectedItem])
    }

    @objc func toggleArchiveToolbar(_ sender: Any?) {
        ToolbarPreferences.setShowsArchiveToolbar(!ToolbarPreferences.showsArchiveToolbar)
        setupToolbar()
    }

    @objc func toggleStandardToolbar(_ sender: Any?) {
        ToolbarPreferences.setShowsStandardToolbar(!ToolbarPreferences.showsStandardToolbar)
        setupToolbar()
    }

    @objc func toggleLargeToolbarButtons(_ sender: Any?) {
        ToolbarPreferences.setUsesLargeButtons(!ToolbarPreferences.usesLargeButtons)
        setupToolbar()
    }

    @objc func toggleToolbarButtonText(_ sender: Any?) {
        ToolbarPreferences.setShowsButtonText(!ToolbarPreferences.showsButtonText)
        setupToolbar()
    }

    @objc func openFavoriteSlot(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let url = FileManagerFavoriteStore.url(for: menuItem.tag) else {
            return
        }

        activePane.openRecentDirectory(url)
    }

    @objc func saveFavoriteSlot(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }
        FileManagerFavoriteStore.set(url: activePane.currentDirectoryURL, for: menuItem.tag)
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

            Task { @MainActor [weak self] in
                guard let self, let parentWindow = self.window else { return }
                do {
                    try await ArchiveOperationRunner.run(operationTitle: "Copying selected archive items...",
                                                         parentWindow: parentWindow) { session in
                        try pane.extractSelectedArchiveItems(to: destURL,
                                                             session: session,
                                                             overwriteMode: .ask)
                    }
                    self.inactivePane?.refresh()
                } catch {
                    self.showErrorAlert(error)
                }
            }
            return
        }

        let sourcePaths = pane.selectedFilePaths()
        guard !sourcePaths.isEmpty else { return }

        // Determine destination — other pane if dual, or ask via dialog
        guard let destURL = chooseDestinationURL(forMove: move) else { return }

        let operation = move ? "Moving" : "Copying"
        Task { @MainActor [weak self] in
            guard let self, let parentWindow = self.window else { return }
            do {
                try await ArchiveOperationRunner.run(operationTitle: "\(operation) \(sourcePaths.count) item(s)...",
                                                     parentWindow: parentWindow) { session in
                    let fm = FileManager.default
                    var skipAll = false
                    var overwriteAll = false

                    for (index, sourcePath) in sourcePaths.enumerated() {
                        if session.shouldCancel() {
                            return
                        }

                        let sourceURL = URL(fileURLWithPath: sourcePath)
                        let destFile = destURL.appendingPathComponent(sourceURL.lastPathComponent)
                        let fraction = Double(index) / Double(sourcePaths.count)

                        session.reportProgressFraction(fraction)
                        session.reportCurrentFileName(sourceURL.lastPathComponent)

                        if fm.fileExists(atPath: destFile.path) {
                            if skipAll { continue }
                            if !overwriteAll {
                                let srcAttrs = try? fm.attributesOfItem(atPath: sourcePath)
                                let dstAttrs = try? fm.attributesOfItem(atPath: destFile.path)
                                let srcSize = (srcAttrs?[.size] as? UInt64) ?? 0
                                let dstSize = (dstAttrs?[.size] as? UInt64) ?? 0
                                let srcDate = srcAttrs?[.modificationDate] as? Date
                                let dstDate = dstAttrs?[.modificationDate] as? Date
                                let dateFormatter = FileManagerViewPreferences.makeDateFormatter(dateStyle: .medium,
                                                                                                 timeStyle: .medium)

                                let message = """
                                Destination: \(destFile.lastPathComponent)
                                Size: \(ByteCountFormatter.string(fromByteCount: Int64(dstSize), countStyle: .file))  Modified: \(dstDate.map { dateFormatter.string(from: $0) } ?? "—")

                                Source: \(sourceURL.lastPathComponent)
                                Size: \(ByteCountFormatter.string(fromByteCount: Int64(srcSize), countStyle: .file))  Modified: \(srcDate.map { dateFormatter.string(from: $0) } ?? "—")
                                """
                                let choice = session.requestChoice(with: .warning,
                                                                   title: "File already exists",
                                                                   message: message,
                                                                   buttonTitles: ["Replace", "Replace All", "Skip", "Skip All", "Cancel"])
                                switch choice {
                                case 0:
                                    break
                                case 1:
                                    overwriteAll = true
                                case 2:
                                    continue
                                case 3:
                                    skipAll = true
                                    continue
                                default:
                                    return
                                }
                            }
                            try? fm.removeItem(at: destFile)
                        }

                        if move {
                            try fm.moveItem(at: sourceURL, to: destFile)
                        } else {
                            let result = copyfile(sourceURL.path.cString(using: .utf8),
                                                  destFile.path.cString(using: .utf8),
                                                  nil,
                                                  copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE_FORCE))
                            if result != 0 {
                                let fallbackResult = copyfile(sourceURL.path.cString(using: .utf8),
                                                              destFile.path.cString(using: .utf8),
                                                              nil,
                                                              copyfile_flags_t(COPYFILE_ALL))
                                if fallbackResult != 0 {
                                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                                }
                            }
                        }
                    }

                    session.reportProgressFraction(1.0)
                }
                pane.refresh()
                self.inactivePane?.refresh()
            } catch {
                self.showErrorAlert(error)
            }
        }
    }

    @objc func createFolder(_ sender: Any?) {
        guard activePane.canCreateFolderHere() else {
            showUnsupportedOperationAlert("Creating folders inside an open archive is not implemented yet.")
            return
        }

        guard let window else { return }
        szBeginTextInput(on: window,
                         title: "Create Folder",
                         message: "Enter folder name.",
                         placeholder: "New Folder",
                         confirmTitle: "Create") { [weak self] value in
            guard let name = value, !name.isEmpty else { return }
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

        guard let window else { return }
        szBeginConfirmation(on: window,
                            title: "Delete \(paths.count) item(s)?",
                            message: "Items will be moved to Trash.",
                            confirmTitle: "Move to Trash") { confirmed in
            guard confirmed else { return }
            for path in paths {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
            activePane.refresh()
        }
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(openSelectedItem(_:)):
            return activePane.canOpenSelection()
        case #selector(addToArchive(_:)):
            return activePane.canAddSelectedItemsToArchive()
        case #selector(extractArchive(_:)):
            return activePane.canExtractSelectionOrArchive()
        case #selector(extractHere(_:)):
            return activePane.canExtractSelectionOrArchive()
        case #selector(testArchive(_:)):
            return activePane.canTestArchiveSelection()
        case #selector(copyFiles(_:)):
            return activePane.canCopySelection()
        case #selector(moveFiles(_:)):
            return activePane.canMoveSelection()
        case #selector(renameSelection(_:)):
            return activePane.canRenameSelection()
        case #selector(createFolder(_:)):
            return activePane.canCreateFolderHere()
        case #selector(deleteFiles(_:)):
            return activePane.canDeleteSelection()
        case #selector(showProperties(_:)):
            return activePane.canShowSelectedItemProperties()
        case #selector(goUpOneLevel(_:)):
            return activePane.canGoUp()
        case #selector(selectAllItems(_:)), #selector(invertSelection(_:)):
            return activePane.canSelectVisibleItems()
        case #selector(deselectAllItems(_:)):
            return activePane.canDeselectSelection()
        case #selector(refreshActivePane(_:)),
             #selector(sortByName(_:)),
             #selector(sortByType(_:)),
             #selector(sortBySize(_:)),
             #selector(sortByModifiedDate(_:)),
             #selector(sortByCreatedDate(_:)):
            return true
        case #selector(showLocalTimestamps(_:)),
             #selector(showUTCTimestamps(_:)),
             #selector(toggleAutoRefresh(_:)):
            return true
        case #selector(openRootFolder(_:)):
            return true
        case #selector(showFoldersHistory(_:)):
            return activePane.canShowFoldersHistory()
        case #selector(toggleArchiveToolbar(_:)),
             #selector(toggleStandardToolbar(_:)),
             #selector(toggleLargeToolbarButtons(_:)),
             #selector(toggleToolbarButtonText(_:)):
            return true
        case #selector(openFavoriteSlot(_:)):
            guard let menuItem = item as? NSMenuItem else { return false }
            return FileManagerFavoriteStore.url(for: menuItem.tag) != nil
        case #selector(saveFavoriteSlot(_:)):
            return true
        case #selector(toggleDualPane(_:)):
            return true
        case #selector(switchPanes(_:)):
            return isDualPane
        default:
            return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let isEnabled = validateUserInterfaceItem(menuItem)

        switch menuItem.action {
        case #selector(toggleDualPane(_:)):
            menuItem.state = isDualPane ? .on : .off
        case #selector(sortByName(_:)):
            menuItem.state = activePane.primarySortKey == "name" ? .on : .off
        case #selector(sortByType(_:)):
            menuItem.state = activePane.primarySortKey == "type" ? .on : .off
        case #selector(sortBySize(_:)):
            menuItem.state = activePane.primarySortKey == "size" ? .on : .off
        case #selector(sortByModifiedDate(_:)):
            menuItem.state = activePane.primarySortKey == "modified" ? .on : .off
        case #selector(sortByCreatedDate(_:)):
            menuItem.state = activePane.primarySortKey == "created" ? .on : .off
        case #selector(showLocalTimestamps(_:)):
            menuItem.state = FileManagerViewPreferences.usesUTCTimestamps ? .off : .on
        case #selector(showUTCTimestamps(_:)):
            menuItem.state = FileManagerViewPreferences.usesUTCTimestamps ? .on : .off
        case #selector(toggleAutoRefresh(_:)):
            menuItem.state = FileManagerViewPreferences.autoRefreshEnabled ? .on : .off
        case #selector(toggleArchiveToolbar(_:)):
            menuItem.state = ToolbarPreferences.showsArchiveToolbar ? .on : .off
        case #selector(toggleStandardToolbar(_:)):
            menuItem.state = ToolbarPreferences.showsStandardToolbar ? .on : .off
        case #selector(toggleLargeToolbarButtons(_:)):
            menuItem.state = ToolbarPreferences.usesLargeButtons ? .on : .off
        case #selector(toggleToolbarButtonText(_:)):
            menuItem.state = ToolbarPreferences.showsButtonText ? .on : .off
        default:
            menuItem.state = .off
        }

        return isEnabled
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

    private func showErrorAlert(_ error: Error) {
        szPresentError(error, for: window)
    }

    private func showUnsupportedOperationAlert(_ message: String) {
        szPresentMessage(title: "Operation Not Available",
                         message: message,
                         for: window)
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
            item.label = "Copy"
            item.toolTip = "Copy files"
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            item.target = self
            item.action = #selector(copyFiles(_:))

        case Self.moveItem:
            item.label = "Move"
            item.toolTip = "Move files"
            item.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: "Move")
            item.target = self
            item.action = #selector(moveFiles(_:))

        case Self.deleteItem:
            item.label = "Delete"
            item.toolTip = "Delete files"
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            item.target = self
            item.action = #selector(deleteFiles(_:))

        case Self.infoItem:
            item.label = "Info"
            item.toolTip = "Show item properties"
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Info")
            item.target = self
            item.action = #selector(showProperties(_:))

        default:
            return nil
        }

        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = []

        if ToolbarPreferences.showsArchiveToolbar {
            identifiers.append(contentsOf: [Self.addItem, Self.extractItem, Self.testItem])
        }

        if ToolbarPreferences.showsStandardToolbar {
            if !identifiers.isEmpty {
                identifiers.append(.space)
            }
            identifiers.append(contentsOf: [Self.copyItem, Self.moveItem, Self.deleteItem, Self.infoItem])
        }

        return identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.addItem, Self.extractItem, Self.testItem,
         Self.copyItem, Self.moveItem, Self.deleteItem, Self.infoItem,
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
