import Cocoa

extension Notification.Name {
    static let fileManagerViewPreferencesDidChange = Notification.Name("FileManagerViewPreferencesDidChange")
}

private final class FileOperationDestinationPicker: NSObject {
    private weak var ownerWindow: NSWindow?
    private weak var pathField: NSComboBox?
    private let baseDirectory: URL

    init(ownerWindow: NSWindow?,
         pathField: NSComboBox,
         baseDirectory: URL) {
        self.ownerWindow = ownerWindow
        self.pathField = pathField
        self.baseDirectory = baseDirectory.standardizedFileURL
    }

    @objc func browse(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose destination folder:"
        panel.directoryURL = suggestedDirectoryURL()

        if let ownerWindow {
            panel.beginSheetModal(for: ownerWindow) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.pathField?.stringValue = url.standardizedFileURL.path
            }
            return
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathField?.stringValue = url.standardizedFileURL.path
    }

    private func suggestedDirectoryURL() -> URL {
        guard let pathField else {
            return baseDirectory
        }

        let currentValue = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentValue.isEmpty else {
            return baseDirectory
        }

        let expandedPath = NSString(string: currentValue).expandingTildeInPath
        let candidateURL: URL
        if NSString(string: expandedPath).isAbsolutePath {
            candidateURL = URL(fileURLWithPath: expandedPath)
        } else {
            candidateURL = URL(fileURLWithPath: expandedPath, relativeTo: baseDirectory)
        }

        let standardizedURL = candidateURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? standardizedURL : standardizedURL.deletingLastPathComponent()
        }

        return standardizedURL.deletingLastPathComponent()
    }
}

enum FileManagerViewPreferences {
    private static var fixedFormatFormatterCache: [String: DateFormatter] = [:]
    private static var styleFormatterCache: [String: DateFormatter] = [:]

    enum TimestampDisplayLevel: Int, CaseIterable {
        case day
        case minute
        case second
        case ntfs
        case nanoseconds

        fileprivate var dateFormat: String {
            switch self {
            case .day:
                return "yyyy-MM-dd"
            case .minute:
                return "yyyy-MM-dd HH:mm"
            case .second:
                return "yyyy-MM-dd HH:mm:ss"
            case .ntfs:
                return "yyyy-MM-dd HH:mm:ss.SSSSSSS"
            case .nanoseconds:
                return "yyyy-MM-dd HH:mm:ss.SSSSSSSSS"
            }
        }
    }

    private static let defaults = UserDefaults.standard
    private static let timestampUTCKey = "FileManager.TimestampUTC"
    private static let timestampLevelKey = "FileManager.TimestampLevel"
    private static let autoRefreshKey = "FileManager.AutoRefresh"

    static var usesUTCTimestamps: Bool {
        bool(forKey: timestampUTCKey, defaultValue: false)
    }

    static var timestampDisplayLevel: TimestampDisplayLevel {
        TimestampDisplayLevel(rawValue: integer(forKey: timestampLevelKey,
                                                defaultValue: TimestampDisplayLevel.minute.rawValue)) ?? .minute
    }

    static var autoRefreshEnabled: Bool {
        bool(forKey: autoRefreshKey, defaultValue: false)
    }

    static func setUsesUTCTimestamps(_ value: Bool) {
        set(value, forKey: timestampUTCKey)
    }

    static func setTimestampDisplayLevel(_ value: TimestampDisplayLevel) {
        set(value.rawValue, forKey: timestampLevelKey)
    }

    static func setAutoRefreshEnabled(_ value: Bool) {
        set(value, forKey: autoRefreshKey)
    }

    static func timeMenuPreviewTitle(for level: TimestampDisplayLevel, referenceDate: Date = Date()) -> String {
        makeFixedFormatFormatter(format: level.dateFormat).string(from: referenceDate)
    }

    static func makeListDateFormatter() -> DateFormatter {
        makeFixedFormatFormatter(format: timestampDisplayLevel.dateFormat)
    }

    static func makeDateFormatter(dateStyle: DateFormatter.Style,
                                  timeStyle: DateFormatter.Style) -> DateFormatter {
        let cacheKey = "\(dateStyle.rawValue)|\(timeStyle.rawValue)|\(usesUTCTimestamps ? 1 : 0)"
        if let formatter = styleFormatterCache[cacheKey] {
            return formatter
        }

        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        formatter.timeZone = usesUTCTimestamps ? TimeZone(secondsFromGMT: 0) : .current
        styleFormatterCache[cacheKey] = formatter
        return formatter
    }

    private static func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
        resetFormatterCaches()
        NotificationCenter.default.post(name: .fileManagerViewPreferencesDidChange, object: nil)
    }

    private static func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
        resetFormatterCaches()
        NotificationCenter.default.post(name: .fileManagerViewPreferencesDidChange, object: nil)
    }

    private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    private static func integer(forKey key: String, defaultValue: Int) -> Int {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.integer(forKey: key)
    }

    private static func makeFixedFormatFormatter(format: String) -> DateFormatter {
        let cacheKey = "\(format)|\(usesUTCTimestamps ? 1 : 0)"
        if let formatter = fixedFormatFormatterCache[cacheKey] {
            return formatter
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.timeZone = usesUTCTimestamps ? TimeZone(secondsFromGMT: 0) : .current
        fixedFormatFormatterCache[cacheKey] = formatter
        return formatter
    }

    private static func resetFormatterCaches() {
        fixedFormatFormatterCache.removeAll()
        styleFormatterCache.removeAll()
    }
}

private enum FileManagerHashAlgorithm {
    case all
    case crc32
    case crc64
    case xxh64
    case md5
    case sha1
    case sha256
    case sha384
    case sha512
    case sha3256
    case blake2sp

    private static let orderedAlgorithms: [FileManagerHashAlgorithm] = [
        .crc32,
        .crc64,
        .xxh64,
        .md5,
        .sha1,
        .sha256,
        .sha384,
        .sha512,
        .sha3256,
        .blake2sp,
    ]

    var displayedAlgorithms: [FileManagerHashAlgorithm] {
        switch self {
        case .all:
            return Self.orderedAlgorithms
        default:
            return [self]
        }
    }

    var title: String {
        switch self {
        case .all:
            return "*"
        case .crc32:
            return "CRC-32"
        case .crc64:
            return "CRC-64"
        case .xxh64:
            return "XXH64"
        case .md5:
            return "MD5"
        case .sha1:
            return "SHA-1"
        case .sha256:
            return "SHA-256"
        case .sha384:
            return "SHA-384"
        case .sha512:
            return "SHA-512"
        case .sha3256:
            return "SHA3-256"
        case .blake2sp:
            return "BLAKE2sp"
        }
    }

    var bridgeName: String {
        switch self {
        case .all:
            return "*"
        case .crc32:
            return "CRC32"
        case .crc64:
            return "CRC64"
        case .xxh64:
            return "XXH64"
        case .md5:
            return "MD5"
        case .sha1:
            return "SHA1"
        case .sha256:
            return "SHA256"
        case .sha384:
            return "SHA384"
        case .sha512:
            return "SHA512"
        case .sha3256:
            return "SHA3-256"
        case .blake2sp:
            return "BLAKE2sp"
        }
    }
}

/// Dual-pane file manager window replicating 7-Zip File Manager
class FileManagerWindowController: NSWindowController, NSWindowDelegate, NSUserInterfaceValidations, NSMenuItemValidation {

    private enum PanePreferences {
        private static let defaults = UserDefaults.standard
        private static let dualPaneKey = "FileManager.IsDualPane"

        static var showsDualPane: Bool {
            bool(forKey: dualPaneKey, defaultValue: false)
        }

        static func setShowsDualPane(_ value: Bool) {
            defaults.set(value, forKey: dualPaneKey)
        }

        private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
            guard defaults.object(forKey: key) != nil else {
                return defaultValue
            }
            return defaults.bool(forKey: key)
        }
    }

    private enum ToolbarPreferences {
        private static let defaults = UserDefaults.standard
        private static let archiveToolbarKey = "FileManager.ShowArchiveToolbar"
        private static let standardToolbarKey = "FileManager.ShowStandardToolbar"
        private static let showTextKey = "FileManager.ToolbarShowButtonText"

        static var showsArchiveToolbar: Bool {
            bool(forKey: archiveToolbarKey, defaultValue: true)
        }

        static var showsStandardToolbar: Bool {
            bool(forKey: standardToolbarKey, defaultValue: true)
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

    private enum FileOperationDestinationHistory {
        private static let defaults = UserDefaults.standard
        private static let entriesKey = "FileManager.CopyMoveDestinationHistory"
        private static let maxEntries = 20

        static func entries() -> [String] {
            defaults.stringArray(forKey: entriesKey) ?? []
        }

        static func record(_ path: String) {
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            var updatedEntries = entries().filter { $0 != normalizedPath }
            updatedEntries.insert(normalizedPath, at: 0)
            if updatedEntries.count > maxEntries {
                updatedEntries.removeSubrange(maxEntries..<updatedEntries.count)
            }
            defaults.set(updatedEntries, forKey: entriesKey)
        }
    }

    private var splitView: NSSplitView!
    private var leftPane: FileManagerPaneController!
    private var rightPane: FileManagerPaneController!
    private var toolbar: NSToolbar!
    private var isDualPane = PanePreferences.showsDualPane
    private weak var trackedActivePane: FileManagerPaneController?
    private var fileOperationDestinationPicker: FileOperationDestinationPicker?
    private var keyEventMonitor: Any?
    private var viewPreferencesObserver: NSObjectProtocol?
    private var autoRefreshTimer: Timer?
    private var foldersHistoryWindowController: FoldersHistoryWindowController?
    private var pendingEvenSplitLayout = false

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
        trackedActivePane = leftPane
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
        applyPendingEvenSplitLayoutIfNeeded()
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
        if isDualPane {
            splitView.addArrangedSubview(rightPane.view)
            pendingEvenSplitLayout = true
        }

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
        toolbar = newToolbar
        window?.toolbarStyle = .expanded
        window?.toolbar = newToolbar
        applyToolbarPresentation()
    }

    private func applyToolbarPresentation() {
        guard let toolbar else { return }
        toolbar.displayMode = ToolbarPreferences.showsButtonText ? .iconAndLabel : .iconOnly
        toolbar.sizeMode = .regular
        window?.toolbarStyle = .expanded
        refreshToolbarItemPresentation()
        toolbar.validateVisibleItems()
    }

    private func toolbarImage(systemSymbolName name: String,
                              accessibilityDescription: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
    }

    private func refreshToolbarItemPresentation() {
        toolbar?.items.forEach(configureToolbarItem(_:))
    }

    private func configureToolbarItem(_ item: NSToolbarItem) {
        item.target = self

        switch item.itemIdentifier {
        case Self.addItem:
            item.label = "Add"
            item.toolTip = "Add files to archive"
            item.image = toolbarImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add")
            item.action = #selector(addToArchive(_:))

        case Self.extractItem:
            item.label = "Extract"
            item.toolTip = "Extract archive"
            item.image = toolbarImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Extract")
            item.action = #selector(extractArchive(_:))

        case Self.testItem:
            item.label = "Test"
            item.toolTip = "Test archive integrity"
            item.image = toolbarImage(systemSymbolName: "checkmark.shield", accessibilityDescription: "Test")
            item.action = #selector(testArchive(_:))

        case Self.copyItem:
            item.label = "Copy"
            item.toolTip = "Copy files"
            item.image = toolbarImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            item.action = #selector(copyFiles(_:))

        case Self.moveItem:
            item.label = "Move"
            item.toolTip = "Move files"
            item.image = toolbarImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: "Move")
            item.action = #selector(moveFiles(_:))

        case Self.deleteItem:
            item.label = "Delete"
            item.toolTip = "Delete files"
            item.image = toolbarImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            item.action = #selector(deleteFiles(_:))

        case Self.infoItem:
            item.label = "Info"
            item.toolTip = "Show item properties"
            item.image = toolbarImage(systemSymbolName: "info.circle", accessibilityDescription: "Info")
            item.action = #selector(showProperties(_:))

        default:
            break
        }
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
        MainMenu.refreshDynamicMenuState()
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

    @discardableResult
    func revealFileSystemItems(_ urls: [URL], revealWindow: Bool = true) -> Bool {
        let standardizedURLs = urls.map(\.standardizedFileURL)
        guard !standardizedURLs.isEmpty else { return false }

        let parentDirectory = standardizedURLs[0].deletingLastPathComponent().standardizedFileURL
        let targetPane: FileManagerPaneController
        if !leftPane.isVirtualLocation,
           leftPane.currentDirectoryURL.standardizedFileURL == parentDirectory {
            targetPane = leftPane
        } else if isDualPane,
                  !rightPane.isVirtualLocation,
                  rightPane.currentDirectoryURL.standardizedFileURL == parentDirectory {
            targetPane = rightPane
        } else {
            targetPane = activePane
        }

        let revealed = targetPane.revealFileSystemItemURLs(standardizedURLs)
        if revealed && revealWindow {
            window?.makeKeyAndOrderFront(nil)
        }
        return revealed
    }

    @discardableResult
    func openFileSystemItem(_ url: URL, revealWindow: Bool = true) -> Bool {
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) else {
            return false
        }

        let targetPane: FileManagerPaneController
        if isDirectory.boolValue,
           !leftPane.isVirtualLocation,
           leftPane.currentDirectoryURL.standardizedFileURL == standardizedURL {
            targetPane = leftPane
        } else if isDirectory.boolValue,
                  isDualPane,
                  !rightPane.isVirtualLocation,
                  rightPane.currentDirectoryURL.standardizedFileURL == standardizedURL {
            targetPane = rightPane
        } else if !isDirectory.boolValue,
                  !leftPane.isVirtualLocation,
                  leftPane.currentDirectoryURL.standardizedFileURL == standardizedURL.deletingLastPathComponent().standardizedFileURL {
            targetPane = leftPane
        } else if !isDirectory.boolValue,
                  isDualPane,
                  !rightPane.isVirtualLocation,
                  rightPane.currentDirectoryURL.standardizedFileURL == standardizedURL.deletingLastPathComponent().standardizedFileURL {
            targetPane = rightPane
        } else {
            targetPane = activePane
        }

        let opened = targetPane.openFileSystemItemURL(standardizedURL)
        if opened && revealWindow {
            window?.makeKeyAndOrderFront(nil)
        }
        return opened
    }

    @objc func toggleDualPane(_ sender: Any?) {
        let wasRightPaneActive = isDualPane && activePane === rightPane
        isDualPane.toggle()
        PanePreferences.setShowsDualPane(isDualPane)

        if isDualPane {
            splitView.addArrangedSubview(rightPane.view)
            scheduleEvenSplitLayout()
        } else {
            rightPane.view.removeFromSuperview()
            pendingEvenSplitLayout = false
            if wasRightPaneActive {
                leftPane.focusFileList()
            }
        }
    }

    private func scheduleEvenSplitLayout() {
        guard isDualPane else {
            pendingEvenSplitLayout = false
            return
        }

        pendingEvenSplitLayout = true
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingEvenSplitLayoutIfNeeded()
        }
    }

    private func applyPendingEvenSplitLayoutIfNeeded() {
        guard pendingEvenSplitLayout, isDualPane else { return }
        guard splitView.arrangedSubviews.count > 1 else { return }

        window?.contentView?.layoutSubtreeIfNeeded()
        splitView.layoutSubtreeIfNeeded()

        let availableWidth = splitView.bounds.width - splitView.dividerThickness
        guard availableWidth > 0 else { return }

        splitView.setPosition(floor(availableWidth / 2.0), ofDividerAt: 0)
        pendingEvenSplitLayout = false
    }

    @objc func addToArchive(_ sender: Any?) {
        let activePane = self.activePane
        guard activePane.canAddSelectedItemsToArchive() else {
            if activePane.isVirtualLocation {
                showUnsupportedOperationAlert("Creating or updating archives from inside an open archive is not implemented yet.")
            }
            return
        }

        let selectedURLs = activePane.selectedFileURLs()
        guard !selectedURLs.isEmpty else { return }

        let compressDialog = CompressDialogController(sourceURLs: selectedURLs,
                                                      baseDirectory: activePane.currentDirectoryURL)
        guard let result = compressDialog.runModal(for: window) else { return }

        Task { @MainActor [weak self] in
            guard let self, let parentWindow = self.window else { return }
            do {
                try await ArchiveOperationRunner.run(operationTitle: "Compressing...",
                                                     parentWindow: parentWindow) { session in
                    try SZArchive.create(atPath: result.archiveURL.path,
                                         fromPaths: selectedURLs.map(\.path),
                                         settings: result.settings,
                                         session: session)
                }
                activePane.refresh()
            } catch {
                self.showErrorAlert(error)
            }
        }
    }

    @objc func extractArchive(_ sender: Any?) {
        let activePane = self.activePane
        guard activePane.canExtractSelectionOrArchive() else { return }

        guard let extractResult = promptForArchiveDestination(from: activePane) else { return }
        let sourceArchiveURL = activePane.sourceArchiveURLForExtraction()

        Task { @MainActor [weak self] in
            guard let self, let parentWindow = self.window else { return }
            do {
                var extractedItems: [ArchiveItem] = []
                var pathPrefixToStrip: String?

                try await ArchiveOperationRunner.run(operationTitle: "Extracting...",
                                                     parentWindow: parentWindow) { session in
                    if activePane.isVirtualLocation {
                        extractedItems = activePane.selectedOrDisplayedArchiveEntriesForExtraction()
                        pathPrefixToStrip = activePane.pathPrefixToStripForCurrentExtraction(destinationURL: extractResult.destinationURL,
                                                                                            pathMode: extractResult.pathMode,
                                                                                            eliminateDuplicates: extractResult.eliminateDuplicates)
                        try activePane.extractCurrentSelectionOrDisplayedArchiveItems(to: extractResult.destinationURL,
                                                                                      session: session,
                                                                                      overwriteMode: extractResult.overwriteMode,
                                                                                      pathMode: extractResult.pathMode,
                                                                                      password: extractResult.password,
                                                                                      preserveNtSecurityInfo: extractResult.preserveNtSecurityInfo,
                                                                                      eliminateDuplicates: extractResult.eliminateDuplicates)
                    } else {
                        guard let archiveURL = activePane.selectedArchiveCandidateURL() else {
                            throw NSError(domain: SZArchiveErrorDomain,
                                          code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: "Select an archive to extract."])
                        }
                        let archive = SZArchive()
                        try archive.open(atPath: archiveURL.path,
                                         password: extractResult.password,
                                         session: session)
                        let archiveItems = archive.entries().map(ArchiveItem.init)
                        extractedItems = archiveItems
                        let settings = SZExtractionSettings()
                        settings.overwriteMode = extractResult.overwriteMode
                        settings.pathMode = extractResult.pathMode
                        settings.password = extractResult.password
                        settings.preserveNtSecurityInfo = extractResult.preserveNtSecurityInfo
                        pathPrefixToStrip = self.archiveExtractionPathPrefixToStrip(for: archiveItems,
                                                                                   destinationURL: extractResult.destinationURL,
                                                                                   pathMode: extractResult.pathMode,
                                                                                   eliminateDuplicates: extractResult.eliminateDuplicates)
                        settings.pathPrefixToStrip = pathPrefixToStrip
                        try archive.extract(toPath: extractResult.destinationURL.path,
                                            settings: settings,
                                            session: session)
                        archive.close()
                    }
                }

                let postProcessResult: ArchiveExtractionPostProcessResult
                let postProcessError: Error?
                do {
                    postProcessResult = try ArchiveExtractionPostProcessor.finalizeExtraction(sourceArchiveURL: sourceArchiveURL,
                                                                                            extractedItems: extractedItems,
                                                                                            destinationURL: extractResult.destinationURL,
                                                                                            pathMode: extractResult.pathMode,
                                                                                            pathPrefixToStrip: pathPrefixToStrip,
                                                                                            moveSourceArchiveToTrash: extractResult.moveArchiveToTrashAfterExtraction,
                                                                                            inheritSourceQuarantine: extractResult.inheritDownloadedFileQuarantine)
                    postProcessError = nil
                } catch {
                    postProcessResult = ArchiveExtractionPostProcessResult(movedSourceArchiveToTrash: false)
                    postProcessError = error
                }
                self.refreshPaneDisplayingDirectory(extractResult.destinationURL)
                if postProcessResult.movedSourceArchiveToTrash,
                   let sourceArchiveURL {
                    self.refreshPaneDisplayingDirectory(sourceArchiveURL.deletingLastPathComponent())
                }
                NSWorkspace.shared.open(extractResult.destinationURL)
                if let postProcessError {
                    self.showErrorAlert(postProcessError)
                }
            } catch {
                self.showErrorAlert(error)
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

    @objc func openSelectedItemInside(_ sender: Any?) {
        activePane.openSelectionInside(.defaultBehavior)
    }

    @objc func openSelectedItemInsideWildcard(_ sender: Any?) {
        activePane.openSelectionInside(.wildcard)
    }

    @objc func openSelectedItemInsideParser(_ sender: Any?) {
        activePane.openSelectionInside(.parser)
    }

    @objc func openSelectedItemOutside(_ sender: Any?) {
        activePane.openSelectionOutside()
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

    @objc func showCRC32Hash(_ sender: Any?) {
        presentSelectionHash(.crc32)
    }

    @objc func showAllHashes(_ sender: Any?) {
        presentSelectionHash(.all)
    }

    @objc func showCRC64Hash(_ sender: Any?) {
        presentSelectionHash(.crc64)
    }

    @objc func showXXH64Hash(_ sender: Any?) {
        presentSelectionHash(.xxh64)
    }

    @objc func showMD5Hash(_ sender: Any?) {
        presentSelectionHash(.md5)
    }

    @objc func showSHA1Hash(_ sender: Any?) {
        presentSelectionHash(.sha1)
    }

    @objc func showSHA256Hash(_ sender: Any?) {
        presentSelectionHash(.sha256)
    }

    @objc func showSHA384Hash(_ sender: Any?) {
        presentSelectionHash(.sha384)
    }

    @objc func showSHA512Hash(_ sender: Any?) {
        presentSelectionHash(.sha512)
    }

    @objc func showSHA3256Hash(_ sender: Any?) {
        presentSelectionHash(.sha3256)
    }

    @objc func showBLAKE2spHash(_ sender: Any?) {
        presentSelectionHash(.blake2sp)
    }

    private func firstResponderSupportsTextEditingAction(_ action: Selector) -> Bool {
        guard let firstResponder = window?.firstResponder as? NSResponder,
              firstResponder is NSTextView else {
            return false
        }

        return firstResponder.responds(to: action)
    }

    @discardableResult
    private func dispatchTextEditingActionIfPossible(_ action: Selector,
                                                     sender: Any?) -> Bool {
        guard firstResponderSupportsTextEditingAction(action) else {
            return false
        }

        return NSApp.sendAction(action, to: nil, from: sender)
    }

    @objc func selectAllItems(_ sender: Any?) {
        if dispatchTextEditingActionIfPossible(#selector(NSText.selectAll(_:)), sender: sender) {
            return
        }
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

    @objc func showTimestampDay(_ sender: Any?) {
        FileManagerViewPreferences.setTimestampDisplayLevel(.day)
    }

    @objc func showTimestampMinute(_ sender: Any?) {
        FileManagerViewPreferences.setTimestampDisplayLevel(.minute)
    }

    @objc func showTimestampSecond(_ sender: Any?) {
        FileManagerViewPreferences.setTimestampDisplayLevel(.second)
    }

    @objc func showTimestampNTFS(_ sender: Any?) {
        FileManagerViewPreferences.setTimestampDisplayLevel(.ntfs)
    }

    @objc func showTimestampNanoseconds(_ sender: Any?) {
        FileManagerViewPreferences.setTimestampDisplayLevel(.nanoseconds)
    }

    @objc func toggleTimestampUTC(_ sender: Any?) {
        FileManagerViewPreferences.setUsesUTCTimestamps(!FileManagerViewPreferences.usesUTCTimestamps)
    }

    @objc func toggleAutoRefresh(_ sender: Any?) {
        FileManagerViewPreferences.setAutoRefreshEnabled(!FileManagerViewPreferences.autoRefreshEnabled)
    }

    @objc func openRootFolder(_ sender: Any?) {
        activePane.openRootFolder()
    }

    @objc func showFoldersHistory(_ sender: Any?) {
        let pane = activePane
        let entries = pane.recentDirectoryHistory()
        guard !entries.isEmpty, let window else { return }

        let controller = FoldersHistoryWindowController(entries: entries)
        foldersHistoryWindowController = controller
        controller.beginSheetModal(for: window) { [weak self, weak pane] result in
            self?.foldersHistoryWindowController = nil
            guard let pane, let result else { return }

            pane.setRecentDirectoryHistory(result.updatedEntries)
            if let selectedURL = result.selectedURL {
                pane.openRecentDirectory(selectedURL)
            }
        }
    }

    @objc func toggleArchiveToolbar(_ sender: Any?) {
        ToolbarPreferences.setShowsArchiveToolbar(!ToolbarPreferences.showsArchiveToolbar)
        setupToolbar()
    }

    @objc func toggleStandardToolbar(_ sender: Any?) {
        ToolbarPreferences.setShowsStandardToolbar(!ToolbarPreferences.showsStandardToolbar)
        setupToolbar()
    }

    @objc func toggleToolbarButtonText(_ sender: Any?) {
        ToolbarPreferences.setShowsButtonText(!ToolbarPreferences.showsButtonText)
        applyToolbarPresentation()
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
        if !isDualPane {
            return leftPane
        }

        if let firstResponderPane = paneContainingFirstResponder() {
            return firstResponderPane
        }

        if let trackedActivePane {
            return trackedActivePane
        }

        return leftPane
    }

    private var inactivePane: FileManagerPaneController? {
        guard isDualPane else { return nil }
        return activePane === leftPane ? rightPane : leftPane
    }

    private func paneContainingFirstResponder() -> FileManagerPaneController? {
        guard isDualPane,
              let firstResponder = window?.firstResponder as? NSView else {
            return nil
        }

        if firstResponder === rightPane.view || firstResponder.isDescendant(of: rightPane.view) {
            return rightPane
        }

        if firstResponder === leftPane.view || firstResponder.isDescendant(of: leftPane.view) {
            return leftPane
        }

        return nil
    }

    private func setActivePane(_ pane: FileManagerPaneController) {
        trackedActivePane = pane === rightPane ? rightPane : leftPane
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
            guard let destURL = promptForFileOperationDestination(forMove: false, sourcePane: pane) else { return }

            Task { @MainActor [weak self] in
                guard let self, let parentWindow = self.window else { return }
                do {
                    try await ArchiveOperationRunner.run(operationTitle: "Copying selected archive items...",
                                                         parentWindow: parentWindow) { session in
                        try pane.extractSelectedArchiveItems(to: destURL,
                                                             session: session,
                                                             overwriteMode: .ask)
                    }
                    self.refreshPaneDisplayingDirectory(destURL)
                } catch {
                    self.showErrorAlert(error)
                }
            }
            return
        }

        let sourceURLs = pane.selectedFileURLs()
        guard !sourceURLs.isEmpty else { return }

        guard let destURL = promptForFileOperationDestination(forMove: move, sourcePane: pane) else { return }
        guard validateTransferDestination(destURL, for: pane, move: move) else { return }

        let operation = move ? "Moving" : "Copying"
        let dragOperation: NSDragOperation = move ? .move : .copy
        Task { @MainActor [weak self] in
            guard let self, let parentWindow = self.window else { return }
            do {
                try await ArchiveOperationRunner.run(operationTitle: "\(operation) \(sourceURLs.count) item(s)...",
                                                     parentWindow: parentWindow) { session in
                    try pane.transferFileSystemItemURLs(sourceURLs,
                                                        to: destURL,
                                                        operation: dragOperation,
                                                        session: session)
                }
                self.refreshAfterFilesystemTransfer(from: pane,
                                                   to: destURL,
                                                   operation: dragOperation)
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

    @objc func createFile(_ sender: Any?) {
        guard activePane.canCreateFileHere() else {
            showUnsupportedOperationAlert("Creating files inside an open archive is not implemented yet.")
            return
        }

        guard let window else { return }
        szBeginTextInput(on: window,
                         title: "Create File",
                         message: "Enter file name.",
                         placeholder: "New File.txt",
                         confirmTitle: "Create") { [weak self] value in
            guard let name = value, !name.isEmpty else { return }
            self?.activePane.createFile(named: name)
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

    private func presentSelectionHash(_ algorithm: FileManagerHashAlgorithm) {
        guard let item = activePane.selectedSingleFileSystemFile() else { return }

        let itemName = item.name
        let itemPath = item.url.path

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let hashValues = try await ArchiveOperationRunner.run(operationTitle: "Calculating checksum...",
                                                                     initialFileName: itemPath,
                                                                     parentWindow: self.window,
                                                                     deferredDisplay: true) { session in
                    try SZArchive.calculateHash(forPath: itemPath, session: session)
                }
                let details = self.hashDetails(for: algorithm, hashValues: hashValues)
                szShowDetailsDialog(title: itemName,
                                    summary: itemPath,
                                    details: details,
                                    for: self.window)
            } catch {
                self.showErrorAlert(error)
            }
        }
    }

    private func hashDetails(for algorithm: FileManagerHashAlgorithm,
                             hashValues: [String: String]) -> String {
        algorithm.displayedAlgorithms
            .map { currentAlgorithm in
                let value = hashValues[currentAlgorithm.bridgeName] ?? "unavailable"
                return "\(currentAlgorithm.title): \(value)"
            }
            .joined(separator: "\n")
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(openSelectedItem(_:)):
            return activePane.canOpenSelection()
        case #selector(openSelectedItemInside(_:)),
             #selector(openSelectedItemInsideWildcard(_:)),
             #selector(openSelectedItemInsideParser(_:)):
            return activePane.canOpenSelectionInside()
        case #selector(openSelectedItemOutside(_:)):
            return activePane.canOpenSelectionOutside()
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
        case #selector(createFile(_:)):
            return activePane.canCreateFileHere()
        case #selector(deleteFiles(_:)):
            return activePane.canDeleteSelection()
        case #selector(showProperties(_:)):
            return activePane.canShowSelectedItemProperties()
        case #selector(showCRC32Hash(_:)),
               #selector(showAllHashes(_:)),
             #selector(showCRC64Hash(_:)),
               #selector(showXXH64Hash(_:)),
               #selector(showMD5Hash(_:)),
             #selector(showSHA1Hash(_:)),
             #selector(showSHA256Hash(_:)),
               #selector(showSHA384Hash(_:)),
               #selector(showSHA512Hash(_:)),
               #selector(showSHA3256Hash(_:)),
             #selector(showBLAKE2spHash(_:)):
            return activePane.canCalculateSelectionHashes()
        case #selector(goUpOneLevel(_:)):
            return activePane.canGoUp()
        case #selector(selectAllItems(_:)):
            return firstResponderSupportsTextEditingAction(#selector(NSText.selectAll(_:))) ||
                activePane.canSelectVisibleItems()
        case #selector(invertSelection(_:)):
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
           case #selector(showTimestampDay(_:)),
               #selector(showTimestampMinute(_:)),
               #selector(showTimestampSecond(_:)),
               #selector(showTimestampNTFS(_:)),
               #selector(showTimestampNanoseconds(_:)),
               #selector(toggleTimestampUTC(_:)),
             #selector(toggleAutoRefresh(_:)):
            return true
        case #selector(openRootFolder(_:)):
            return true
        case #selector(showFoldersHistory(_:)):
            return activePane.canShowFoldersHistory()
        case #selector(toggleArchiveToolbar(_:)),
             #selector(toggleStandardToolbar(_:)),
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
        case #selector(showTimestampDay(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .day ? .on : .off
        case #selector(showTimestampMinute(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .minute ? .on : .off
        case #selector(showTimestampSecond(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .second ? .on : .off
        case #selector(showTimestampNTFS(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .ntfs ? .on : .off
        case #selector(showTimestampNanoseconds(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .nanoseconds ? .on : .off
        case #selector(toggleTimestampUTC(_:)):
            menuItem.state = FileManagerViewPreferences.usesUTCTimestamps ? .on : .off
        case #selector(toggleAutoRefresh(_:)):
            menuItem.state = FileManagerViewPreferences.autoRefreshEnabled ? .on : .off
        case #selector(toggleArchiveToolbar(_:)):
            menuItem.state = ToolbarPreferences.showsArchiveToolbar ? .on : .off
        case #selector(toggleStandardToolbar(_:)):
            menuItem.state = ToolbarPreferences.showsStandardToolbar ? .on : .off
        case #selector(toggleToolbarButtonText(_:)):
            menuItem.state = ToolbarPreferences.showsButtonText ? .on : .off
        default:
            menuItem.state = .off
        }

        return isEnabled
    }

    private func suggestedDestinationURL(for sourcePane: FileManagerPaneController) -> URL {
        if let otherPane = inactivePane, !otherPane.isVirtualLocation {
            return otherPane.currentDirectoryURL.standardizedFileURL
        }

        return sourcePane.currentDirectoryURL.standardizedFileURL
    }

    private func promptForArchiveDestination(from sourcePane: FileManagerPaneController) -> ExtractDialogResult? {
        let dialog = ExtractDialogController(suggestedDestinationURL: sourcePane.currentDirectoryURL,
                                             baseDirectory: sourcePane.currentDirectoryURL,
                                             message: extractDialogInfoText(for: sourcePane),
                                             defaultPathMode: sourcePane.isVirtualLocation ? .currentPaths : .fullPaths,
                                             showsCurrentPathsOption: sourcePane.isVirtualLocation,
                                             suggestedSplitDestinationName: sourcePane.suggestedExtractDestinationName,
                                             sourceArchiveAvailableForPostProcessing: sourcePane.sourceArchiveURLForExtraction() != nil)
        return dialog.runModal(for: window)
    }

    private func extractDialogInfoText(for sourcePane: FileManagerPaneController) -> String {
        var lines: [String] = []
        lines.append(sourcePane.currentLocationDisplayPath)

        let names = sourcePane.selectedItemNames(limit: 5)
        if names.isEmpty {
            if sourcePane.isVirtualLocation {
                lines.append("Displayed items in the current archive folder will be extracted.")
            }
        } else {
            lines.append(contentsOf: names.map { "  \($0)" })
            if sourcePane.selectedRealItemCount > names.count {
                lines.append("  ...")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func archiveExtractionPathPrefixToStrip(for items: [ArchiveItem],
                                                    destinationURL: URL,
                                                    pathMode: SZPathMode,
                                                    eliminateDuplicates: Bool) -> String? {
        guard eliminateDuplicates,
              pathMode != .absolutePaths,
              pathMode != .noPaths else {
            return nil
        }

        return ArchiveItem.duplicateRootPrefixToStrip(for: items,
                                                      destinationLeafName: destinationURL.lastPathComponent)
    }

    private func promptForFileOperationDestination(forMove move: Bool,
                                                   sourcePane: FileManagerPaneController) -> URL? {
        let title = move ? "Move" : "Copy"
        let actionTitle = move ? "Move" : "Copy"
        let labelTitle = move ? "Move to:" : "Copy to:"
        let historyEntries = FileOperationDestinationHistory.entries()
        let defaultPath = suggestedDestinationURL(for: sourcePane).path
        let infoText = fileOperationInfoText(for: sourcePane)

        while true {
            let pathField = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
            pathField.isEditable = true
            pathField.usesDataSource = false
            pathField.completes = false
            pathField.addItems(withObjectValues: historyEntries)
            pathField.stringValue = defaultPath
            pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let browseButton = NSButton(title: "Browse…", target: nil, action: nil)
            browseButton.bezelStyle = .rounded
            browseButton.setContentHuggingPriority(.required, for: .horizontal)
            browseButton.setContentCompressionResistancePriority(.required, for: .horizontal)

            let label = NSTextField(labelWithString: labelTitle)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.setContentHuggingPriority(.required, for: .vertical)

            let inputRow = NSStackView(views: [pathField, browseButton])
            inputRow.orientation = .horizontal
            inputRow.alignment = .centerY
            inputRow.spacing = 8
            inputRow.distribution = .fill

            let stack = NSStackView(views: [label, inputRow])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

            let controller = SZModalDialogController(style: .informational,
                                                     title: title,
                                                     message: infoText,
                                                     buttonTitles: ["Cancel", actionTitle],
                                                     accessoryView: stack,
                                                     preferredFirstResponder: pathField,
                                                     cancelButtonIndex: 0)

            let windowBoundPicker = FileOperationDestinationPicker(ownerWindow: controller.window,
                                                                   pathField: pathField,
                                                                   baseDirectory: sourcePane.currentDirectoryURL)
            fileOperationDestinationPicker = windowBoundPicker
            browseButton.target = windowBoundPicker
            browseButton.action = #selector(FileOperationDestinationPicker.browse(_:))

            defer {
                fileOperationDestinationPicker = nil
            }

            guard controller.runModal() == 1 else {
                return nil
            }

            let enteredPath = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                let destinationURL = try resolveDestinationDirectoryURL(from: enteredPath,
                                                                        relativeTo: sourcePane.currentDirectoryURL)
                FileOperationDestinationHistory.record(destinationURL.path)
                return destinationURL
            } catch {
                showErrorAlert(error)
            }
        }
    }

    private func resolveDestinationDirectoryURL(from enteredPath: String,
                                                relativeTo baseDirectory: URL) throws -> URL {
        guard !enteredPath.isEmpty else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileNoSuchFileError,
                          userInfo: [NSLocalizedDescriptionKey: "Enter a destination folder."])
        }

        let expandedPath = NSString(string: enteredPath).expandingTildeInPath
        let candidateURL: URL
        if NSString(string: expandedPath).isAbsolutePath {
            candidateURL = URL(fileURLWithPath: expandedPath)
        } else {
            candidateURL = URL(fileURLWithPath: expandedPath, relativeTo: baseDirectory)
        }

        let standardizedURL = candidateURL.standardizedFileURL
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteInvalidFileNameError,
                              userInfo: [
                                  NSFilePathErrorKey: standardizedURL.path,
                                  NSLocalizedDescriptionKey: "The destination path must be a folder."
                              ])
            }
            return standardizedURL
        }

        try FileManager.default.createDirectory(at: standardizedURL, withIntermediateDirectories: true)
        return standardizedURL
    }

    private func fileOperationInfoText(for sourcePane: FileManagerPaneController) -> String {
        var lines: [String] = []
        lines.append(sourcePane.currentLocationDisplayPath)

        let names = sourcePane.selectedItemNames(limit: 5)
        lines.append(contentsOf: names.map { "  \($0)" })

        if sourcePane.selectedRealItemCount > names.count {
            lines.append("  ...")
        }

        return lines.joined(separator: "\n")
    }

    private func validateTransferDestination(_ destinationURL: URL,
                                             for sourcePane: FileManagerPaneController,
                                             move: Bool) -> Bool {
        let sourceDirectory = sourcePane.currentDirectoryURL.standardizedFileURL
        let standardizedDestination = destinationURL.standardizedFileURL

        guard sourceDirectory != standardizedDestination else {
            let action = move ? "move" : "copy"
            szPresentMessage(title: "Cannot \(action) files onto itself",
                             message: "Choose a different destination folder.",
                             style: .warning,
                             for: window)
            return false
        }

        return true
    }

    private func refreshPaneDisplayingDirectory(_ directoryURL: URL) {
        let standardizedDirectory = directoryURL.standardizedFileURL

        if !leftPane.isVirtualLocation,
           leftPane.currentDirectoryURL.standardizedFileURL == standardizedDirectory {
            leftPane.refresh()
        }

        if isDualPane,
           !rightPane.isVirtualLocation,
           rightPane.currentDirectoryURL.standardizedFileURL == standardizedDirectory {
            rightPane.refresh()
        }
    }

    private func refreshAfterFilesystemTransfer(from sourcePane: FileManagerPaneController,
                                                to destinationURL: URL,
                                                operation: NSDragOperation) {
        refreshPaneDisplayingDirectory(destinationURL)

        if operation == .move {
            sourcePane.refresh()
        }
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

        guard toolbarAllowedItemIdentifiers(toolbar).contains(itemIdentifier) else {
            return nil
        }

        configureToolbarItem(item)

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
    func paneDidBecomeActive(_ pane: FileManagerPaneController)
}

extension FileManagerWindowController: FileManagerPaneDelegate {
    func paneDidRequestOpenArchiveInNewWindow(_ url: URL) {
        (NSApp.delegate as? AppDelegate)?.openArchiveInNewFileManager(url)
    }

    func paneDidBecomeActive(_ pane: FileManagerPaneController) {
        setActivePane(pane)
    }
}
