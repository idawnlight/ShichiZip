import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    private var fileManagerWindowController: FileManagerWindowController?
    private var benchmarkWindowController: BenchmarkWindowController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.setup()
        // Show file manager window on launch if no documents opened
        if NSDocumentController.shared.documents.isEmpty {
            showFileManager(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Menu Actions

    @IBAction func showFileManager(_ sender: Any?) {
        if fileManagerWindowController == nil {
            fileManagerWindowController = FileManagerWindowController()
        }
        fileManagerWindowController?.showWindow(self)
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
