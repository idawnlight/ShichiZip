import Cocoa

class ArchiveWindowController: NSWindowController {

    private var archiveViewController: ArchiveViewController!
    private var toolbar: NSToolbar!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 600, height: 400)
        window.center()

        self.init(window: window)

        archiveViewController = ArchiveViewController()
        window.contentViewController = archiveViewController

        setupToolbar()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        updateTitle()
    }

    override var document: AnyObject? {
        didSet {
            updateTitle()
            if let doc = document as? ArchiveDocument {
                archiveViewController?.loadArchive(doc)
            }
        }
    }

    private func updateTitle() {
        guard let doc = document as? ArchiveDocument else { return }
        let fileName = doc.fileURL?.lastPathComponent ?? "Archive"
        window?.title = "\(fileName) — ShichiZip [\(doc.formatName)]"
    }

    // MARK: - Toolbar

    private func setupToolbar() {
        toolbar = NSToolbar(identifier: "ArchiveToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        window?.toolbar = toolbar
    }

    // MARK: - Actions

    @objc func extractAll(_ sender: Any?) {
        guard let doc = document as? ArchiveDocument else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract"
        panel.message = "Choose destination for extracted files"

        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let url = panel.url else { return }

            let progressController = ProgressDialogController()
            progressController.operationTitle = "Extracting..."

            self.window?.beginSheet(progressController.window!) { _ in }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try doc.extractAll(to: url, progress: progressController)
                    DispatchQueue.main.async {
                        self.window?.endSheet(progressController.window!)
                        NSWorkspace.shared.open(url)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.window?.endSheet(progressController.window!)
                        let alert = NSAlert(error: error)
                        alert.beginSheetModal(for: self.window!)
                    }
                }
            }
        }
    }

    @objc func testArchive(_ sender: Any?) {
        guard let doc = document as? ArchiveDocument else { return }

        let progressController = ProgressDialogController()
        progressController.operationTitle = "Testing archive..."

        window?.beginSheet(progressController.window!) { _ in }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try doc.testArchive(progress: progressController)
                DispatchQueue.main.async {
                    self.window?.endSheet(progressController.window!)
                    let alert = NSAlert()
                    alert.messageText = "Test Complete"
                    alert.informativeText = "No errors found. Archive is OK."
                    alert.alertStyle = .informational
                    alert.beginSheetModal(for: self.window!)
                }
            } catch {
                DispatchQueue.main.async {
                    self.window?.endSheet(progressController.window!)
                    let alert = NSAlert(error: error)
                    alert.beginSheetModal(for: self.window!)
                }
            }
        }
    }

    @objc func showInfo(_ sender: Any?) {
        guard let doc = document as? ArchiveDocument else { return }
        let alert = NSAlert()
        alert.messageText = "Archive Info"

        let totalSize = doc.entries.reduce(UInt64(0)) { $0 + $1.size }
        let totalPacked = doc.entries.reduce(UInt64(0)) { $0 + $1.packedSize }
        let fileCount = doc.entries.filter { !$0.isDirectory }.count
        let dirCount = doc.entries.filter { $0.isDirectory }.count

        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
        let packedStr = ByteCountFormatter.string(fromByteCount: Int64(totalPacked), countStyle: .file)
        let ratio = totalSize > 0 ? Double(totalPacked) / Double(totalSize) * 100.0 : 0

        alert.informativeText = """
        Format: \(doc.formatName)
        Files: \(fileCount)
        Folders: \(dirCount)
        Size: \(sizeStr)
        Packed Size: \(packedStr)
        Ratio: \(String(format: "%.1f%%", ratio))
        """
        alert.beginSheetModal(for: window!)
    }
}

// MARK: - NSToolbarDelegate

extension ArchiveWindowController: NSToolbarDelegate {

    static let extractItem = NSToolbarItem.Identifier("extract")
    static let testItem = NSToolbarItem.Identifier("test")
    static let infoItem = NSToolbarItem.Identifier("info")

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        switch itemIdentifier {
        case Self.extractItem:
            item.label = "Extract"
            item.paletteLabel = "Extract All"
            item.toolTip = "Extract all files from archive"
            item.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Extract")
            item.target = self
            item.action = #selector(extractAll(_:))

        case Self.testItem:
            item.label = "Test"
            item.paletteLabel = "Test Archive"
            item.toolTip = "Test archive integrity"
            item.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: "Test")
            item.target = self
            item.action = #selector(testArchive(_:))

        case Self.infoItem:
            item.label = "Info"
            item.paletteLabel = "Archive Info"
            item.toolTip = "Show archive information"
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Info")
            item.target = self
            item.action = #selector(showInfo(_:))

        default:
            return nil
        }

        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.extractItem, Self.testItem, .flexibleSpace, Self.infoItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.extractItem, Self.testItem, Self.infoItem, .flexibleSpace, .space]
    }
}
