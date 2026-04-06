import Cocoa

class CompressDialogController: NSViewController {

    private var formatPopup: NSPopUpButton!
    private var levelPopup: NSPopUpButton!
    private var methodPopup: NSPopUpButton!
    private var dictionaryPopup: NSPopUpButton!
    private var wordSizePopup: NSPopUpButton!
    private var solidCheckbox: NSButton!
    private var threadsField: NSTextField!
    private var encryptionPopup: NSPopUpButton!
    private var passwordField: NSSecureTextField!
    private var encryptNamesCheckbox: NSButton!
    private var splitField: NSTextField!
    private var archiveNameField: NSTextField!
    private var destinationField: NSPathControl!

    var sourcePaths: [String] = []
    var completionHandler: ((SZCompressionSettings?, String?) -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 550, height: 500))

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 10

        // Archive name
        let nameLabel = NSTextField(labelWithString: "Archive:")
        archiveNameField = NSTextField()
        archiveNameField.placeholderString = "archive.7z"
        if let firstName = sourcePaths.first {
            let name = URL(fileURLWithPath: firstName).deletingPathExtension().lastPathComponent
            archiveNameField.stringValue = name + ".7z"
        }
        grid.addRow(with: [nameLabel, archiveNameField])

        // Destination
        let destLabel = NSTextField(labelWithString: "Save to:")
        destinationField = NSPathControl()
        destinationField.pathStyle = .standard
        destinationField.isEditable = false
        destinationField.url = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        let browseButton = NSButton(title: "Browse...", target: self, action: #selector(browseDest(_:)))
        let destStack = NSStackView(views: [destinationField, browseButton])
        destStack.orientation = .horizontal
        grid.addRow(with: [destLabel, destStack])

        // Separator
        let sep1 = NSBox()
        sep1.boxType = .separator
        grid.addRow(with: [NSView(), sep1])

        // Format
        let fmtLabel = NSTextField(labelWithString: "Archive format:")
        formatPopup = NSPopUpButton(title: "", target: self, action: #selector(formatChanged(_:)))
        formatPopup.addItems(withTitles: ["7z", "zip", "tar", "gzip", "bzip2", "xz", "wim", "zstd"])
        grid.addRow(with: [fmtLabel, formatPopup])

        // Compression level
        let levelLabel = NSTextField(labelWithString: "Compression level:")
        levelPopup = NSPopUpButton(title: "", target: nil, action: nil)
        levelPopup.addItems(withTitles: ["Store", "Fastest", "Fast", "Normal", "Maximum", "Ultra"])
        levelPopup.selectItem(at: 3) // Normal
        grid.addRow(with: [levelLabel, levelPopup])

        // Method
        let methodLabel = NSTextField(labelWithString: "Compression method:")
        methodPopup = NSPopUpButton(title: "", target: nil, action: nil)
        methodPopup.addItems(withTitles: ["LZMA", "LZMA2", "PPMd", "BZip2", "Deflate", "Deflate64", "Copy"])
        methodPopup.selectItem(at: 1) // LZMA2
        grid.addRow(with: [methodLabel, methodPopup])

        // Dictionary size
        let dictLabel = NSTextField(labelWithString: "Dictionary size:")
        dictionaryPopup = NSPopUpButton(title: "", target: nil, action: nil)
        dictionaryPopup.addItems(withTitles: ["Auto", "64 KB", "256 KB", "1 MB", "4 MB", "8 MB", "16 MB", "32 MB", "64 MB", "128 MB", "256 MB"])
        grid.addRow(with: [dictLabel, dictionaryPopup])

        // Word size
        let wordLabel = NSTextField(labelWithString: "Word size:")
        wordSizePopup = NSPopUpButton(title: "", target: nil, action: nil)
        wordSizePopup.addItems(withTitles: ["Auto", "8", "12", "16", "24", "32", "48", "64", "96", "128", "192", "256", "273"])
        grid.addRow(with: [wordLabel, wordSizePopup])

        // Solid archive
        solidCheckbox = NSButton(checkboxWithTitle: "Solid archive", target: nil, action: nil)
        solidCheckbox.state = .on
        grid.addRow(with: [NSView(), solidCheckbox])

        // CPU threads
        let threadLabel = NSTextField(labelWithString: "CPU threads:")
        threadsField = NSTextField()
        threadsField.placeholderString = "Auto"
        threadsField.integerValue = 0
        grid.addRow(with: [threadLabel, threadsField])

        // Separator
        let sep2 = NSBox()
        sep2.boxType = .separator
        grid.addRow(with: [NSView(), sep2])

        // Encryption
        let encLabel = NSTextField(labelWithString: "Encryption method:")
        encryptionPopup = NSPopUpButton(title: "", target: self, action: #selector(encryptionChanged(_:)))
        encryptionPopup.addItems(withTitles: ["None", "AES-256", "ZipCrypto"])
        grid.addRow(with: [encLabel, encryptionPopup])

        // Password
        let passLabel = NSTextField(labelWithString: "Password:")
        passwordField = NSSecureTextField()
        passwordField.placeholderString = "Enter password"
        passwordField.isEnabled = false
        grid.addRow(with: [passLabel, passwordField])

        // Encrypt file names
        encryptNamesCheckbox = NSButton(checkboxWithTitle: "Encrypt file names", target: nil, action: nil)
        encryptNamesCheckbox.isEnabled = false
        grid.addRow(with: [NSView(), encryptNamesCheckbox])

        // Split volumes
        let splitLabel = NSTextField(labelWithString: "Split to volumes (bytes):")
        splitField = NSTextField()
        splitField.placeholderString = "0 (no split)"
        grid.addRow(with: [splitLabel, splitField])

        container.addSubview(grid)

        // Buttons
        let compressButton = NSButton(title: "Compress", target: self, action: #selector(doCompress(_:)))
        compressButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(doCancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonStack = NSStackView(views: [cancelButton, compressButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        container.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            buttonStack.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 20),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        self.view = container
    }

    @objc private func formatChanged(_ sender: Any?) {
        let ext: String
        switch formatPopup.indexOfSelectedItem {
        case 0: ext = "7z"
        case 1: ext = "zip"
        case 2: ext = "tar"
        case 3: ext = "gz"
        case 4: ext = "bz2"
        case 5: ext = "xz"
        case 6: ext = "wim"
        case 7: ext = "zst"
        default: ext = "7z"
        }

        // Update archive filename extension
        if !archiveNameField.stringValue.isEmpty {
            let url = URL(fileURLWithPath: archiveNameField.stringValue)
            archiveNameField.stringValue = url.deletingPathExtension().lastPathComponent + "." + ext
        }

        // Solid mode only for 7z
        solidCheckbox.isEnabled = formatPopup.indexOfSelectedItem == 0
        encryptNamesCheckbox.isEnabled = formatPopup.indexOfSelectedItem == 0 && encryptionPopup.indexOfSelectedItem != 0
    }

    @objc private func encryptionChanged(_ sender: Any?) {
        let hasEncryption = encryptionPopup.indexOfSelectedItem != 0
        passwordField.isEnabled = hasEncryption
        encryptNamesCheckbox.isEnabled = hasEncryption && formatPopup.indexOfSelectedItem == 0
    }

    @objc private func browseDest(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        if let window = view.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.destinationField.url = url
                }
            }
        }
    }

    private func buildSettings() -> SZCompressionSettings {
        let settings = SZCompressionSettings()
        settings.format = SZArchiveFormat(rawValue: formatPopup.indexOfSelectedItem) ?? .format7z

        let levelMap: [Int: SZCompressionLevel] = [0: .store, 1: .fastest, 2: .fast, 3: .normal, 4: .maximum, 5: .ultra]
        settings.level = levelMap[levelPopup.indexOfSelectedItem] ?? .normal

        settings.method = SZCompressionMethod(rawValue: methodPopup.indexOfSelectedItem) ?? .LZMA2
        settings.solidMode = solidCheckbox.state == .on

        let threadCount = threadsField.integerValue
        settings.numThreads = threadCount > 0 ? UInt32(threadCount) : 0

        settings.encryption = SZEncryptionMethod(rawValue: encryptionPopup.indexOfSelectedItem) ?? .none
        if settings.encryption != .none {
            settings.password = passwordField.stringValue
            settings.encryptFileNames = encryptNamesCheckbox.state == .on
        }

        let splitValue = UInt64(splitField.integerValue)
        settings.splitVolumeSize = splitValue

        return settings
    }

    @objc private func doCompress(_ sender: Any?) {
        let settings = buildSettings()
        let archiveName = archiveNameField.stringValue
        let destURL = destinationField.url ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        let archivePath = destURL.appendingPathComponent(archiveName).path

        view.window?.sheetParent?.endSheet(view.window!, returnCode: .OK)
        completionHandler?(settings, archivePath)
    }

    @objc private func doCancel(_ sender: Any?) {
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .cancel)
        completionHandler?(nil, nil)
    }

    /// Show as standalone window (for creating archive from Finder/menu)
    func showAsStandaloneDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Select files and folders to compress"

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.sourcePaths = panel.urls.map { $0.path }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 550, height: 500),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Create Archive — ShichiZip"
            window.contentViewController = self
            window.center()

            let wc = NSWindowController(window: window)
            self?.completionHandler = { [weak wc] settings, archivePath in
                guard let settings = settings, let archivePath = archivePath else {
                    wc?.close()
                    return
                }

                self?.performCompression(settings: settings, archivePath: archivePath,
                                         sources: self?.sourcePaths ?? [], windowController: wc)
            }

            wc.showWindow(nil)
        }
    }

    private func performCompression(settings: SZCompressionSettings, archivePath: String,
                                    sources: [String], windowController: NSWindowController?) {
        let progressController = ProgressDialogController()
        progressController.operationTitle = "Compressing..."

        let progressWindow = progressController.window!
        progressWindow.center()
        progressWindow.makeKeyAndOrderFront(nil)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SZArchive.create(
                    atPath: archivePath,
                    fromPaths: sources,
                    settings: settings,
                    progress: progressController
                )

                DispatchQueue.main.async {
                    progressWindow.close()
                    windowController?.close()
                    NSWorkspace.shared.selectFile(archivePath, inFileViewerRootedAtPath: "")
                }
            } catch {
                DispatchQueue.main.async {
                    progressWindow.close()
                    windowController?.close()
                    let alert = NSAlert(error: error)
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }
}
