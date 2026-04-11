import Cocoa
import Darwin

struct ArchiveExtractionPostProcessResult {
    let movedSourceArchiveToTrash: Bool
}

enum ArchiveExtractionPostProcessor {
    private static let quarantineAttributeName = "com.apple.quarantine"

    static func finalizeExtraction(sourceArchiveURL: URL?,
                                   extractedItems: [ArchiveItem],
                                   destinationURL: URL,
                                   pathMode: SZPathMode,
                                   pathPrefixToStrip: String?,
                                   moveSourceArchiveToTrash: Bool,
                                   inheritSourceQuarantine: Bool) throws -> ArchiveExtractionPostProcessResult
    {
        let standardizedSourceArchiveURL = sourceArchiveURL?.standardizedFileURL

        if inheritSourceQuarantine,
           let standardizedSourceArchiveURL,
           let quarantineData = try quarantineData(for: standardizedSourceArchiveURL)
        {
            let extractedOutputURLs = ArchiveItem.extractedOutputURLs(for: extractedItems,
                                                                      destinationURL: destinationURL,
                                                                      pathMode: pathMode,
                                                                      pathPrefixToStrip: pathPrefixToStrip)
            try applyExtendedAttribute(named: quarantineAttributeName,
                                       data: quarantineData,
                                       to: extractedOutputURLs)
        }

        guard moveSourceArchiveToTrash,
              let standardizedSourceArchiveURL,
              FileManager.default.fileExists(atPath: standardizedSourceArchiveURL.path)
        else {
            return ArchiveExtractionPostProcessResult(movedSourceArchiveToTrash: false)
        }

        try FileManager.default.trashItem(at: standardizedSourceArchiveURL, resultingItemURL: nil)
        return ArchiveExtractionPostProcessResult(movedSourceArchiveToTrash: true)
    }

    private static func quarantineData(for url: URL) throws -> Data? {
        let size = url.path.withCString { pathPointer in
            quarantineAttributeName.withCString { namePointer in
                getxattr(pathPointer, namePointer, nil, 0, 0, XATTR_NOFOLLOW)
            }
        }

        if size < 0 {
            if errno == ENOATTR || errno == ENOENT {
                return nil
            }
            throw posixError(for: url)
        }

        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { buffer in
            url.path.withCString { pathPointer in
                quarantineAttributeName.withCString { namePointer in
                    getxattr(pathPointer,
                             namePointer,
                             buffer.baseAddress,
                             buffer.count,
                             0,
                             XATTR_NOFOLLOW)
                }
            }
        }

        if result < 0 {
            if errno == ENOATTR || errno == ENOENT {
                return nil
            }
            throw posixError(for: url)
        }

        return data
    }

    private static func applyExtendedAttribute(named name: String,
                                               data: Data,
                                               to urls: [URL]) throws
    {
        for url in urls {
            let result = data.withUnsafeBytes { buffer in
                url.path.withCString { pathPointer in
                    name.withCString { namePointer in
                        setxattr(pathPointer,
                                 namePointer,
                                 buffer.baseAddress,
                                 buffer.count,
                                 0,
                                 XATTR_NOFOLLOW)
                    }
                }
            }

            if result != 0, errno != ENOENT {
                throw posixError(for: url)
            }
        }
    }

    private static func posixError(for url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path])
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private struct SmartQuickExtractPlan {
        let destinationURL: URL
        let pathPrefixToStrip: String?
        let extractedItems: [ArchiveItem]
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
        MainMenu.setup()
        // Delay slightly — if we're opening a file, the document system will handle it
        // Only show file manager if no documents are being opened
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.shouldPresentInitialFileManager,
               self.pendingDeferredArchiveOpens == 0,
               NSDocumentController.shared.documents.isEmpty,
               NSApp.windows.filter({ $0.isVisible }).isEmpty
            {
                self.showFileManager(nil)
            }
        }
    }

    func applicationWillTerminate(_: Notification) {}

    func applicationShouldOpenUntitledFile(_: NSApplication) -> Bool {
        return false
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
                handleQuickActionLaunchURL(url)
            }
        }

        guard !archiveURLs.isEmpty else { return }

        beginDeferredArchiveOpen()
        defer { endDeferredArchiveOpen() }
        openArchiveURLs(archiveURLs, preferPrimaryWindow: false)
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        return true
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
        panel.prompt = "Open"
        panel.message = "Choose archive files to open in \(AppBuildInfo.appDisplayName())"

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

    @IBAction func newArchive(_: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Select files and folders to compress"

        guard panel.runModal() == .OK else { return }

        let sourceURLs = panel.urls.map { $0.standardizedFileURL }
        guard !sourceURLs.isEmpty else { return }

        let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let dialog = CompressDialogController(sourceURLs: sourceURLs)
        guard let result = dialog.runModal(for: parentWindow) else { return }

        Task { @MainActor in
            do {
                try await ArchiveOperationRunner.run(operationTitle: "Compressing...",
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

        szShowDetailsDialog(title: "About \(appName)",
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

    private func handleQuickActionLaunchURL(_ url: URL) {
        do {
            let request = try ShichiZipQuickActionTransport.consumeRequest(from: url)
            NSApp.activate(ignoringOtherApps: true)
            try handleQuickAction(request)
        } catch {
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

        guard let firstGroup = groups.first else {
            throw ShichiZipQuickActionError.unsupportedSelection("Select one or more files or folders.")
        }

        revealFileSystemItemsInPrimaryWindow(firstGroup)

        for group in groups.dropFirst() {
            revealFileSystemItemsInNewWindow(group)
        }
    }

    private func handleOpenInShichiZipQuickAction(_ request: ShichiZipQuickActionRequest) throws {
        let itemURL = try existingSingleURL(from: request,
                                            selectionError: "Select a single file or folder to open in \(AppBuildInfo.appDisplayName()).")
        let controller = ensurePrimaryFileManagerWindowController()
        _ = controller.openFileSystemItem(itemURL, revealWindow: true)
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
                let plan = try await ArchiveOperationRunner.run(operationTitle: "Extracting...",
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
                    try archive.extract(toPath: plan.destinationURL.path,
                                        settings: settings,
                                        session: session)
                    return plan
                }

                let postProcessError: Error?
                do {
                    _ = try ArchiveExtractionPostProcessor.finalizeExtraction(sourceArchiveURL: archiveURL,
                                                                              extractedItems: plan.extractedItems,
                                                                              destinationURL: plan.destinationURL,
                                                                              pathMode: .fullPaths,
                                                                              pathPrefixToStrip: plan.pathPrefixToStrip,
                                                                              moveSourceArchiveToTrash: defaults.moveArchiveToTrashAfterExtraction,
                                                                              inheritSourceQuarantine: defaults.inheritDownloadedFileQuarantine)
                    postProcessError = nil
                } catch {
                    postProcessError = error
                }

                let baseDirectory = archiveURL.deletingLastPathComponent().standardizedFileURL
                if plan.destinationURL != baseDirectory {
                    NSWorkspace.shared.selectFile(plan.destinationURL.path,
                                                  inFileViewerRootedAtPath: baseDirectory.path)
                } else {
                    NSWorkspace.shared.open(plan.destinationURL)
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
        let controller = FileManagerWindowController()
        controller.onWindowWillClose = { [weak self] closingController in
            self?.additionalFileManagerWindows.removeAll { $0 === closingController }
        }
        additionalFileManagerWindows.append(controller)

        if controller.revealFileSystemItems(urls, revealWindow: false) {
            controller.showWindow(self)
        } else {
            additionalFileManagerWindows.removeAll { $0 === controller }
        }
    }

    private func smartQuickExtractPlan(for archiveURL: URL,
                                       archiveItems: [ArchiveItem],
                                       eliminateDuplicates: Bool) -> SmartQuickExtractPlan
    {
        let baseDestinationURL = archiveURL.deletingLastPathComponent().standardizedFileURL
        let suggestedFolderName = archiveURL.deletingPathExtension().lastPathComponent
        let topLevelNames = Set(archiveItems.compactMap { $0.pathParts.first }.filter { !$0.isEmpty })
        let usesSplitDestination = topLevelNames.count > 1
        let destinationURL = usesSplitDestination
            ? baseDestinationURL.appendingPathComponent(suggestedFolderName, isDirectory: true).standardizedFileURL
            : baseDestinationURL
        let pathPrefixToStrip: String?

        if usesSplitDestination && eliminateDuplicates {
            pathPrefixToStrip = ArchiveItem.duplicateRootPrefixToStrip(for: archiveItems,
                                                                       destinationLeafName: destinationURL.lastPathComponent)
        } else {
            pathPrefixToStrip = nil
        }

        return SmartQuickExtractPlan(destinationURL: destinationURL,
                                     pathPrefixToStrip: pathPrefixToStrip,
                                     extractedItems: archiveItems)
    }
}
