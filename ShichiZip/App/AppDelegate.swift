import Cocoa
import os

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, FileManagerDocumentOpenRouting {
    #if DEBUG
        private static let disableSmartQuickExtractRevealEnvironmentKey = "SHICHIZIP_DISABLE_SMART_QUICK_EXTRACT_REVEAL"
    #endif

    private static var shouldRevealSmartQuickExtractDestination: Bool {
        #if DEBUG
            if let value = getenv(disableSmartQuickExtractRevealEnvironmentKey) {
                return String(cString: value) != "1"
            }
        #endif

        return true
    }

    private let fileManagerWindowRegistry: FileManagerWindowRegistry
    private let quickActionHandler: AppQuickActionHandler
    private var benchmarkWindowController: BenchmarkWindowController?
    private var deleteTemporaryFilesWindowController: DeleteTemporaryFilesWindowController?
    private var settingsWindowController: SettingsWindowController?
    private let launchOpenCoordinator = LaunchOpenCoordinator()

    override init() {
        let fileManagerWindowRegistry = FileManagerWindowRegistry()
        self.fileManagerWindowRegistry = fileManagerWindowRegistry
        quickActionHandler = AppQuickActionHandler(fileManagerWindowRegistry: fileManagerWindowRegistry,
                                                   shouldRevealSmartQuickExtractDestination: {
                                                       AppDelegate.shouldRevealSmartQuickExtractDestination
                                                   })
        super.init()
    }

    func applicationWillFinishLaunching(_: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ShichiZipQuickActionTransport.cleanupStalePayloads()
        MainMenu.setup()
        var isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        SZLog.info("AppDelegate", "didFinishLaunching isDefaultLaunch=\(isDefaultLaunch)")
        #if DEBUG
            if getenv("SHICHIZIP_FORCE_DEFAULT_LAUNCH") != nil {
                isDefaultLaunch = true
                SZLog.info("AppDelegate", "Forcing isDefaultLaunch=true due to environment variable")
            }
        #endif
        if !isDefaultLaunch {
            launchOpenCoordinator.noteLaunchExpectsExternalOpen()
        }
        // Only show file manager if no documents are being opened
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let suppress = launchOpenCoordinator.shouldSuppressInitialFileManager
            let docsEmpty = NSDocumentController.shared.documents.isEmpty
            let noWindows = NSApp.windows.filter(\.isVisible).isEmpty
            if !suppress, docsEmpty, noWindows {
                showFileManager(nil)
            } else {
                SZLog.info("AppDelegate", "skipped file manager: suppress=\(suppress) docsEmpty=\(docsEmpty) noWindows=\(noWindows)")
            }
        }
    }

    func applicationWillTerminate(_: Notification) {}

    func applicationShouldOpenUntitledFile(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard fileManagerWindowRegistry.prepareForApplicationTermination() else {
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        guard SZSettings.bool(.quitAfterLastWindowClosed) else { return false }
        return !launchOpenCoordinator.shouldKeepProcessAlive
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showFileManager(nil)
        }
        return true
    }

    /// Handle files dropped onto dock icon
    func application(_: NSApplication, openFiles filenames: [String]) {
        beginExternalArchiveOpen()
        defer { endExternalArchiveOpen() }
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        openArchiveURLs(urls, preferReusableWindow: false)
    }

    func application(_: NSApplication, open urls: [URL]) {
        launchOpenCoordinator.suppressInitialFileManager()

        var archiveURLs: [URL] = []

        for url in urls {
            if url.isFileURL {
                archiveURLs.append(url)
            } else if ShichiZipQuickActionTransport.canHandle(url) {
                quickActionHandler.handleLaunchURL(url)
            }
        }

        guard !archiveURLs.isEmpty else { return }

        beginExternalArchiveOpen()
        defer { endExternalArchiveOpen() }
        openArchiveURLs(archiveURLs, preferReusableWindow: false)
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu Actions

    @IBAction func showFileManager(_ sender: Any?) {
        fileManagerWindowRegistry.showFileManager(sender)
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
            self?.openArchiveURLs(panel.urls, preferReusableWindow: true)
        }
    }

    /// Open an archive file in the file manager (navigate into it inline)
    func openArchiveInFileManager(_ url: URL) {
        fileManagerWindowRegistry.openArchiveInFileManager(url)
    }

    /// Open an archive in a NEW file manager window (for "Open With" from Finder)
    func openArchiveInNewFileManager(_ url: URL) {
        fileManagerWindowRegistry.openArchiveInNewFileManager(url)
    }

    @discardableResult
    func openFileSystemItemInNewFileManager(_ url: URL) -> Bool {
        fileManagerWindowRegistry.openFileSystemItemInNewFileManager(url)
    }

    func beginExternalArchiveOpen() {
        launchOpenCoordinator.beginExternalOpen()
    }

    func endExternalArchiveOpen() {
        launchOpenCoordinator.endExternalOpen()
    }

    private func openArchiveURLs(_ urls: [URL], preferReusableWindow: Bool) {
        guard !urls.isEmpty else { return }

        if preferReusableWindow {
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
        Task { @MainActor in
            let dialog = CompressDialogController(sourceURLs: sourceURLs)
            guard let result = await dialog.runModal(for: parentWindow) else { return }

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
}
