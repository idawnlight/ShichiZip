import Cocoa

struct ArchiveExtractionPostProcessResult {
    let movedSourceArchiveToTrash: Bool
}

enum ArchiveExtractionPostProcessor {
    static func finalizeExtraction(sourceArchiveURL: URL?,
                                   moveSourceArchiveToTrash: Bool) throws -> ArchiveExtractionPostProcessResult
    {
        let standardizedSourceArchiveURL = sourceArchiveURL?.standardizedFileURL

        guard moveSourceArchiveToTrash,
              let standardizedSourceArchiveURL,
              FileManager.default.fileExists(atPath: standardizedSourceArchiveURL.path)
        else {
            return ArchiveExtractionPostProcessResult(movedSourceArchiveToTrash: false)
        }

        try FileManager.default.trashItem(at: standardizedSourceArchiveURL, resultingItemURL: nil)
        return ArchiveExtractionPostProcessResult(movedSourceArchiveToTrash: true)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private static let disableSmartQuickExtractRevealEnvironmentKey = "SHICHIZIP_DISABLE_SMART_QUICK_EXTRACT_REVEAL"
    private static let quickActionLogPrefix = "QuickActionTransport"

    /// Test-only override for smart quick extract reveal behavior.
    nonisolated(unsafe) static var testingShouldRevealSmartQuickExtractDestinationOverride: Bool?

    private struct SmartQuickExtractPlan {
        let destinationURL: URL
        let pathPrefixToStrip: String?
        let extractedItems: [ArchiveItem]
    }

    private static var shouldRevealSmartQuickExtractDestination: Bool {
        if let override = testingShouldRevealSmartQuickExtractDestinationOverride {
            return override
        }

        guard let value = getenv(disableSmartQuickExtractRevealEnvironmentKey) else {
            return true
        }

        return String(cString: value) != "1"
    }

    private var fileManagerWindowController: FileManagerWindowController?
    private var additionalFileManagerWindows: [FileManagerWindowController] = []
    private var benchmarkWindowController: BenchmarkWindowController?
    private var deleteTemporaryFilesWindowController: DeleteTemporaryFilesWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var pendingDeferredArchiveOpens = 0
    private var shouldPresentInitialFileManager = true

    func applicationWillFinishLaunching(_: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_: Notification) {
        ShichiZipQuickActionTransport.cleanupStalePayloads()
        MainMenu.setup()
        // Delay slightly — if we're opening a file, the document system will handle it
        // Only show file manager if no documents are being opened
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if shouldPresentInitialFileManager,
               pendingDeferredArchiveOpens == 0,
               NSDocumentController.shared.documents.isEmpty,
               NSApp.windows.filter(\.isVisible).isEmpty
            {
                showFileManager(nil)
            }
        }
    }

    func applicationWillTerminate(_: Notification) {}

    func applicationShouldOpenUntitledFile(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        let controllers = activeFileManagerWindowControllers()
        for controller in controllers {
            if !controller.prepareForClose() {
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        SZSettings.bool(.quitAfterLastWindowClosed)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showFileManager(nil)
        }
        return true
    }

    /// Handle files dropped onto dock icon
    func application(_: NSApplication, openFiles filenames: [String]) {
        beginDeferredArchiveOpen()
        defer { endDeferredArchiveOpen() }
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        openArchiveURLs(urls, preferPrimaryWindow: false)
    }

    func application(_: NSApplication, open urls: [URL]) {
        shouldPresentInitialFileManager = false

        var archiveURLs: [URL] = []

        for url in urls {
            if url.isFileURL {
                archiveURLs.append(url)
            } else if ShichiZipQuickActionTransport.canHandle(url) {
                SZLog.info(Self.quickActionLogPrefix, "received launchURL=\(url.absoluteString)")
                handleQuickActionLaunchURL(url)
            }
        }

        guard !archiveURLs.isEmpty else { return }

        beginDeferredArchiveOpen()
        defer { endDeferredArchiveOpen() }
        openArchiveURLs(archiveURLs, preferPrimaryWindow: false)
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu Actions

    @IBAction func showFileManager(_: Any?) {
        let controller = ensurePrimaryFileManagerWindowController()
        controller.showWindow(self)
    }

    @IBAction func openArchives(_: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = SZL10n.string("menu.open")
        panel.message = SZL10n.string("app.panel.chooseArchives", AppBuildInfo.appDisplayName())

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.openArchiveURLs(panel.urls, preferPrimaryWindow: true)
        }
    }

    /// Open an archive file in the file manager (navigate into it inline)
    func openArchiveInFileManager(_ url: URL) {
        let controller = ensurePrimaryFileManagerWindowController()
        controller.navigateToArchive(url, revealWindow: true)
    }

    /// Open an archive in a NEW file manager window (for "Open With" from Finder)
    func openArchiveInNewFileManager(_ url: URL) {
        let wc = makeAdditionalFileManagerWindowController()
        if wc.navigateToArchive(url, revealWindow: false) {
            wc.showWindow(self)
        } else {
            additionalFileManagerWindows.removeAll { $0 === wc }
        }
    }

    @discardableResult
    func openFileSystemItemInNewFileManager(_ url: URL) -> Bool {
        let controller = makeAdditionalFileManagerWindowController()
        if controller.openFileSystemItem(url, revealWindow: false) {
            controller.showWindow(self)
            return true
        }

        additionalFileManagerWindows.removeAll { $0 === controller }
        return false
    }

    func beginDeferredArchiveOpen() {
        shouldPresentInitialFileManager = false
        pendingDeferredArchiveOpens += 1
    }

    func endDeferredArchiveOpen() {
        pendingDeferredArchiveOpens = max(0, pendingDeferredArchiveOpens - 1)
    }

    private func openArchiveURLs(_ urls: [URL], preferPrimaryWindow: Bool) {
        guard !urls.isEmpty else { return }

        if preferPrimaryWindow {
            openArchiveInFileManager(urls[0])
            for url in urls.dropFirst() {
                openArchiveInNewFileManager(url)
            }
            return
        }

        for url in urls {
            openArchiveInNewFileManager(url)
        }
    }

    @IBAction func newArchive(_: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = SZL10n.string("toolbar.add")
        panel.message = SZL10n.string("app.panel.selectFilesToCompress")

        guard panel.runModal() == .OK else { return }

        let sourceURLs = panel.urls.map(\.standardizedFileURL)
        guard !sourceURLs.isEmpty else { return }

        let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let dialog = CompressDialogController(sourceURLs: sourceURLs)
        guard let result = dialog.runModal(for: parentWindow) else { return }

        Task { @MainActor in
            do {
                try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.compressing"),
                                                     parentWindow: parentWindow)
                { session in
                    try SZArchive.create(atPath: result.archiveURL.path,
                                         fromPaths: sourceURLs.map(\.path),
                                         settings: result.settings,
                                         session: session)
                }
                NSWorkspace.shared.selectFile(result.archiveURL.path, inFileViewerRootedAtPath: "")
            } catch {
                szPresentError(error, for: parentWindow)
            }
        }
    }

    @IBAction func showBenchmark(_: Any?) {
        if benchmarkWindowController == nil {
            benchmarkWindowController = BenchmarkWindowController()
        }
        benchmarkWindowController?.showWindow(self)
    }

    @IBAction func showDeleteTemporaryFiles(_: Any?) {
        if deleteTemporaryFilesWindowController == nil {
            deleteTemporaryFilesWindowController = DeleteTemporaryFilesWindowController()
        }
        deleteTemporaryFilesWindowController?.showWindow(self)
    }

    @IBAction func showPreferences(_: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(self)
    }

    @IBAction func showAbout(_: Any?) {
        let appName = AppBuildInfo.appDisplayName()
        let details = AppBuildInfo.bundled7ZipLicense() ?? AppBuildInfo.missingLicenseMessage()
        let summary = AppBuildInfo.aboutSummary()
        let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow

        szShowDetailsDialog(title: SZL10n.string("app.menu.about", appName),
                            summary: summary,
                            details: details,
                            detailsHeight: 320,
                            for: parentWindow)
    }

    @discardableResult
    private func ensurePrimaryFileManagerWindowController() -> FileManagerWindowController {
        if fileManagerWindowController == nil {
            fileManagerWindowController = FileManagerWindowController()
            fileManagerWindowController?.onWindowWillClose = { [weak self] controller in
                if self?.fileManagerWindowController === controller {
                    self?.fileManagerWindowController = nil
                }
            }
        }

        return fileManagerWindowController!
    }

    private func activeFileManagerWindowControllers() -> [FileManagerWindowController] {
        var controllers: [FileManagerWindowController] = []

        if let fileManagerWindowController {
            controllers.append(fileManagerWindowController)
        }

        for controller in additionalFileManagerWindows where !controllers.contains(where: { $0 === controller }) {
            controllers.append(controller)
        }

        return controllers
    }

    func activeFileManagerWindowControllersForArchiveCoordination() -> [FileManagerWindowController] {
        activeFileManagerWindowControllers()
    }

    private func handleQuickActionLaunchURL(_ url: URL) {
        do {
            SZLog.info(Self.quickActionLogPrefix, "consuming launchURL=\(url.absoluteString)")
            let request = try ShichiZipQuickActionTransport.consumeRequest(from: url)
            SZLog.info(Self.quickActionLogPrefix, "decoded request action=\(request.action.rawValue) paths=\(request.paths.joined(separator: ", "))")
            NSApp.activate(ignoringOtherApps: true)
            try handleQuickAction(request)
        } catch {
            SZLog.error(Self.quickActionLogPrefix, "failed launchURL=\(url.absoluteString) error=\(String(describing: error))")
            szPresentError(error, for: NSApp.keyWindow ?? NSApp.mainWindow)
        }
    }

    private func handleQuickAction(_ request: ShichiZipQuickActionRequest) throws {
        switch request.action {
        case .showInFileManager:
            try handleShowInFileManagerQuickAction(request)
        case .openInShichiZip:
            try handleOpenInShichiZipQuickAction(request)
        case .smartQuickExtract:
            try handleSmartQuickExtractQuickAction(request)
        }
    }

    private func handleShowInFileManagerQuickAction(_ request: ShichiZipQuickActionRequest) throws {
        let fileURLs = try existingFileURLs(from: request)
        let groups = groupedFileSystemItemsByParentDirectory(fileURLs)

        guard !groups.isEmpty else {
            throw ShichiZipQuickActionError.unsupportedSelection("Select one or more files or folders.")
        }

        for group in groups {
            SZLog.info(Self.quickActionLogPrefix, "show-in-file-manager opening new window urls=\(group.map(\.path).joined(separator: ", "))")
            revealFileSystemItemsInNewWindow(group)
        }
    }

    private func handleOpenInShichiZipQuickAction(_ request: ShichiZipQuickActionRequest) throws {
        let itemURL = try existingSingleURL(from: request,
                                            selectionError: "Select a single file or folder to open in \(AppBuildInfo.appDisplayName()).")
        SZLog.info(Self.quickActionLogPrefix, "open-in-shichizip opening new window item=\(itemURL.path)")
        _ = openFileSystemItemInNewFileManager(itemURL)
    }

    private func handleSmartQuickExtractQuickAction(_ request: ShichiZipQuickActionRequest) throws {
        let archiveURL = try existingSingleFileURL(from: request,
                                                   selectionError: "Select a single archive to extract.",
                                                   directoryError: "Folders cannot be extracted as archives.")
        let defaults = ExtractDialogController.quickActionDefaults()
        let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let plan = try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                                                initialFileName: archiveURL.lastPathComponent,
                                                                parentWindow: parentWindow,
                                                                deferredDisplay: false)
                { session in
                    let archive = SZArchive()
                    try archive.open(atPath: archiveURL.path, session: session)
                    defer { archive.close() }

                    let archiveItems = archive.entries().map(ArchiveItem.init)
                    let plan = self.smartQuickExtractPlan(for: archiveURL,
                                                          archiveItems: archiveItems,
                                                          eliminateDuplicates: defaults.eliminateDuplicates)
                    let settings = SZExtractionSettings()
                    settings.overwriteMode = defaults.overwriteMode
                    settings.pathMode = .fullPaths
                    settings.preserveNtSecurityInfo = defaults.preserveNtSecurityInfo
                    settings.pathPrefixToStrip = plan.pathPrefixToStrip
                    if defaults.inheritDownloadedFileQuarantine {
                        settings.sourceArchivePathForQuarantine = archiveURL.path
                    }
                    try archive.extract(toPath: plan.destinationURL.path,
                                        settings: settings,
                                        session: session)
                    return plan
                }

                let postProcessError: Error?
                do {
                    _ = try ArchiveExtractionPostProcessor.finalizeExtraction(sourceArchiveURL: archiveURL,
                                                                              moveSourceArchiveToTrash: defaults.moveArchiveToTrashAfterExtraction)
                    postProcessError = nil
                } catch {
                    postProcessError = error
                }

                let baseDirectory = archiveURL.deletingLastPathComponent().standardizedFileURL
                if Self.shouldRevealSmartQuickExtractDestination {
                    if plan.destinationURL != baseDirectory {
                        NSWorkspace.shared.selectFile(plan.destinationURL.path,
                                                      inFileViewerRootedAtPath: baseDirectory.path)
                    } else {
                        NSWorkspace.shared.open(plan.destinationURL)
                    }
                }

                if let postProcessError {
                    szPresentError(postProcessError, for: parentWindow)
                }
            } catch {
                szPresentError(error, for: parentWindow)
            }
        }
    }

    private func existingFileURLs(from request: ShichiZipQuickActionRequest) throws -> [URL] {
        let fileURLs = request.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !fileURLs.isEmpty else {
            throw ShichiZipQuickActionError.unsupportedSelection("The selected files are no longer available.")
        }

        return fileURLs
    }

    private func existingSingleFileURL(from request: ShichiZipQuickActionRequest,
                                       selectionError: String,
                                       directoryError: String) throws -> URL
    {
        let fileURLs = try existingFileURLs(from: request)
        guard fileURLs.count == 1 else {
            throw ShichiZipQuickActionError.unsupportedSelection(selectionError)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURLs[0].path, isDirectory: &isDirectory) else {
            throw ShichiZipQuickActionError.unsupportedSelection("The selected file is no longer available.")
        }
        guard !isDirectory.boolValue else {
            throw ShichiZipQuickActionError.unsupportedSelection(directoryError)
        }

        return fileURLs[0]
    }

    private func existingSingleURL(from request: ShichiZipQuickActionRequest,
                                   selectionError: String) throws -> URL
    {
        let fileURLs = try existingFileURLs(from: request)
        guard fileURLs.count == 1 else {
            throw ShichiZipQuickActionError.unsupportedSelection(selectionError)
        }

        return fileURLs[0]
    }

    private func groupedFileSystemItemsByParentDirectory(_ urls: [URL]) -> [[URL]] {
        var orderedParentPaths: [String] = []
        var groups: [String: [URL]] = [:]

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            let parentDirectory = standardizedURL.deletingLastPathComponent().standardizedFileURL
            let parentPath = parentDirectory.path

            if groups[parentPath] == nil {
                groups[parentPath] = []
                orderedParentPaths.append(parentPath)
            }

            groups[parentPath]?.append(standardizedURL)
        }

        return orderedParentPaths.compactMap { groups[$0] }
    }

    private func revealFileSystemItemsInPrimaryWindow(_ urls: [URL]) {
        let controller = ensurePrimaryFileManagerWindowController()
        _ = controller.revealFileSystemItems(urls, revealWindow: true)
    }

    private func revealFileSystemItemsInNewWindow(_ urls: [URL]) {
        let controller = makeAdditionalFileManagerWindowController()

        if controller.revealFileSystemItems(urls, revealWindow: false) {
            controller.showWindow(self)
        } else {
            additionalFileManagerWindows.removeAll { $0 === controller }
        }
    }

    private func makeAdditionalFileManagerWindowController() -> FileManagerWindowController {
        let controller = FileManagerWindowController()
        controller.onWindowWillClose = { [weak self] closingController in
            self?.additionalFileManagerWindows.removeAll { $0 === closingController }
        }
        additionalFileManagerWindows.append(controller)
        return controller
    }

    private nonisolated func smartQuickExtractPlan(for archiveURL: URL,
                                                   archiveItems: [ArchiveItem],
                                                   eliminateDuplicates: Bool) -> SmartQuickExtractPlan
    {
        let baseDestinationURL = archiveURL.deletingLastPathComponent().standardizedFileURL
        let suggestedFolderName = archiveURL.deletingPathExtension().lastPathComponent
        let topLevelNames = Set(archiveItems.compactMap(\.pathParts.first).filter { !$0.isEmpty })
        let usesSplitDestination = topLevelNames.count > 1
        let destinationURL = usesSplitDestination
            ? baseDestinationURL.appendingPathComponent(suggestedFolderName, isDirectory: true).standardizedFileURL
            : baseDestinationURL
        let pathPrefixToStrip: String? = if usesSplitDestination, eliminateDuplicates {
            ArchiveItem.duplicateRootPrefixToStrip(for: archiveItems,
                                                   destinationLeafName: destinationURL.lastPathComponent)
        } else {
            nil
        }

        return SmartQuickExtractPlan(destinationURL: destinationURL,
                                     pathPrefixToStrip: pathPrefixToStrip,
                                     extractedItems: archiveItems)
    }
}
