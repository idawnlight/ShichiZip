import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    private var fileManagerWindowController: FileManagerWindowController?
    private var additionalFileManagerWindows: [FileManagerWindowController] = []
    private var benchmarkWindowController: BenchmarkWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var pendingDeferredArchiveOpens = 0
    private var shouldPresentInitialFileManager = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.setup()
        // Delay slightly — if we're opening a file, the document system will handle it
        // Only show file manager if no documents are being opened
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.shouldPresentInitialFileManager &&
               self.pendingDeferredArchiveOpens == 0 &&
               NSDocumentController.shared.documents.isEmpty &&
               NSApp.windows.filter({ $0.isVisible }).isEmpty {
                self.showFileManager(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showFileManager(nil)
        }
        return true
    }

    // Handle files dropped onto dock icon
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        beginDeferredArchiveOpen()
        defer { endDeferredArchiveOpen() }
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        openArchiveURLs(urls, preferPrimaryWindow: false)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Menu Actions

    @IBAction func showFileManager(_ sender: Any?) {
        if fileManagerWindowController == nil {
            fileManagerWindowController = FileManagerWindowController()
            fileManagerWindowController?.onWindowWillClose = { [weak self] controller in
                if self?.fileManagerWindowController === controller {
                    self?.fileManagerWindowController = nil
                }
            }
        }
        fileManagerWindowController?.showWindow(self)
    }

    @IBAction func openArchives(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose archive files to open in ShichiZip"

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.openArchiveURLs(panel.urls, preferPrimaryWindow: true)
        }
    }

    /// Open an archive file in the file manager (navigate into it inline)
    func openArchiveInFileManager(_ url: URL) {
        showFileManager(nil)
        fileManagerWindowController?.navigateToArchive(url, revealWindow: true)
    }

    /// Open an archive in a NEW file manager window (for "Open With" from Finder)
    func openArchiveInNewFileManager(_ url: URL) {
        let wc = FileManagerWindowController()
        wc.onWindowWillClose = { [weak self] controller in
            self?.additionalFileManagerWindows.removeAll { $0 === controller }
        }
        additionalFileManagerWindows.append(wc)
        if wc.navigateToArchive(url, revealWindow: false) {
            wc.showWindow(self)
        } else {
            additionalFileManagerWindows.removeAll { $0 === wc }
        }
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

    @IBAction func newArchive(_ sender: Any?) {
        let dialog = CompressDialogController()
        dialog.showAsStandaloneDialog()
    }

    @IBAction func showBenchmark(_ sender: Any?) {
        if benchmarkWindowController == nil {
            benchmarkWindowController = BenchmarkWindowController()
        }
        benchmarkWindowController?.showWindow(self)
    }

    @IBAction func showPreferences(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(self)
    }
}
