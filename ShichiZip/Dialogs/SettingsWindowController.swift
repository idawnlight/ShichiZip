import Cocoa

extension Notification.Name {
    static let szSettingsDidChange = Notification.Name("SZSettingsDidChange")
}

// MARK: - Settings Keys (maps to Windows 7-Zip registry keys)

enum SZSettingsKey: String {
    // Settings page
    case showDots = "ShowDots"
    case showRealFileIcons = "ShowRealFileIcons"
    case fullRowSelect = "FullRow"
    case showGridLines = "ShowGrid"
    case singleClickOpen = "SingleClick"
    case alternativeSelection = "AlternativeSelection"
    case memLimitEnabled = "MemLimitEnabled"
    case memLimitGB = "MemLimitGB"

    // Edit page
    case viewerPath = "Viewer"
    case editorPath = "Editor"
    case diffPath = "Diff"

    // Folders page
    case workDirMode = "WorkDirMode" // 0=system temp, 1=current, 2=specified
    case workDirPath = "WorkDirPath"
    case workDirRemovableOnly = "WorkDirForRemovableOnly"
}

// MARK: - Settings Access

struct SZSettings {
    static let defaults = UserDefaults.standard

    private static func postChange(for key: SZSettingsKey) {
        NotificationCenter.default.post(name: .szSettingsDidChange,
                                        object: nil,
                                        userInfo: ["key": key.rawValue])
    }

    static func bool(_ key: SZSettingsKey) -> Bool {
        return defaults.bool(forKey: key.rawValue)
    }

    static func set(_ value: Bool, for key: SZSettingsKey) {
        defaults.set(value, forKey: key.rawValue)
        postChange(for: key)
    }

    static func string(_ key: SZSettingsKey) -> String {
        return defaults.string(forKey: key.rawValue) ?? ""
    }

    static func set(_ value: String, for key: SZSettingsKey) {
        defaults.set(value, forKey: key.rawValue)
        postChange(for: key)
    }

    static func integer(_ key: SZSettingsKey) -> Int {
        return defaults.integer(forKey: key.rawValue)
    }

    static func set(_ value: Int, for key: SZSettingsKey) {
        defaults.set(value, forKey: key.rawValue)
        postChange(for: key)
    }

    static var memLimitGB: Int {
        let v = defaults.integer(forKey: SZSettingsKey.memLimitGB.rawValue)
        return v > 0 ? v : 4
    }

    static var workDirMode: Int {
        return defaults.integer(forKey: SZSettingsKey.workDirMode.rawValue)
    }

    /// Resolve the working directory based on settings
    static func resolvedWorkDir(currentDir: URL? = nil) -> URL {
        switch workDirMode {
        case 1: return currentDir ?? FileManager.default.temporaryDirectory
        case 2:
            let path = string(.workDirPath)
            if !path.isEmpty { return URL(fileURLWithPath: path) }
            return FileManager.default.temporaryDirectory
        default: return FileManager.default.temporaryDirectory
        }
    }
}

// MARK: - Settings Window Controller (matches Windows 7-Zip Options dialog)

class SettingsWindowController: NSWindowController {

    private var tabView: NSTabView!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Options"
        window.center()
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .noTabsNoBorder  // hide default tabs, use toolbar

        // Settings tab (SettingsPage.cpp)
        let settingsTab = NSTabViewItem(identifier: "settings")
        settingsTab.label = "Settings"
        settingsTab.view = createSettingsPage()
        tabView.addTabViewItem(settingsTab)

        // Editor tab (EditPage.cpp)
        let editTab = NSTabViewItem(identifier: "editor")
        editTab.label = "Editor"
        editTab.view = createEditorPage()
        tabView.addTabViewItem(editTab)

        // Folders tab (FoldersPage.cpp)
        let foldersTab = NSTabViewItem(identifier: "folders")
        foldersTab.label = "Folders"
        foldersTab.view = createFoldersPage()
        tabView.addTabViewItem(foldersTab)

        contentView.addSubview(tabView)

        // Segmented control for tab switching
        let segmented = NSSegmentedControl(labels: ["Settings", "Editor", "Folders"],
                                           trackingMode: .selectOne,
                                           target: self,
                                           action: #selector(tabSegmentChanged(_:)))
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.selectedSegment = 0
        segmented.segmentStyle = .automatic
        contentView.addSubview(segmented)

        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            segmented.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            tabView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    @objc private func tabSegmentChanged(_ sender: NSSegmentedControl) {
        tabView.selectTabViewItem(at: sender.selectedSegment)
    }

    // MARK: - Settings Page (SettingsPage.cpp)

    private func createSettingsPage() -> NSView {
        let view = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let checkboxes: [(String, SZSettingsKey)] = [
            ("Show \"..\" item", .showDots),
            ("Show real file icons", .showRealFileIcons),
            ("Full row select", .fullRowSelect),
            ("Show grid lines", .showGridLines),
            ("Single-click to open an item", .singleClickOpen),
            ("Alternative selection mode", .alternativeSelection),
        ]

        for (title, key) in checkboxes {
            let cb = NSButton(checkboxWithTitle: title, target: self, action: #selector(settingsCheckboxChanged(_:)))
            cb.tag = key.hashValue
            cb.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
            cb.state = SZSettings.bool(key) ? .on : .off
            stack.addArrangedSubview(cb)
        }

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Memory limit
        let memLabel = NSTextField(labelWithString: "Maximum RAM for extraction:")
        stack.addArrangedSubview(memLabel)

        let memRow = NSStackView()
        memRow.orientation = .horizontal
        memRow.spacing = 8

        let memCheck = NSButton(checkboxWithTitle: "Limit to", target: self, action: #selector(memLimitCheckChanged(_:)))
        memCheck.state = SZSettings.bool(.memLimitEnabled) ? .on : .off
        memRow.addArrangedSubview(memCheck)

        let memField = NSTextField()
        memField.integerValue = SZSettings.memLimitGB
        memField.identifier = NSUserInterfaceItemIdentifier("memLimitField")
        memField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        memField.isEnabled = SZSettings.bool(.memLimitEnabled)
        memField.target = self
        memField.action = #selector(memLimitChanged(_:))
        memRow.addArrangedSubview(memField)

        let gbLabel = NSTextField(labelWithString: "GB")
        memRow.addArrangedSubview(gbLabel)

        stack.addArrangedSubview(memRow)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        return view
    }

    // MARK: - Editor Page (EditPage.cpp)

    private func createEditorPage() -> NSView {
        let view = NSView()
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 8

        let fields: [(String, SZSettingsKey)] = [
            ("Viewer:", .viewerPath),
            ("Editor:", .editorPath),
            ("Diff:", .diffPath),
        ]

        for (label, key) in fields {
            let lbl = NSTextField(labelWithString: label)
            let field = NSTextField()
            field.stringValue = SZSettings.string(key)
            field.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
            field.placeholderString = "Path to application"
            field.target = self
            field.action = #selector(editorPathChanged(_:))

            let browseBtn = NSButton(title: "...", target: self, action: #selector(browseEditorPath(_:)))
            browseBtn.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
            browseBtn.widthAnchor.constraint(equalToConstant: 30).isActive = true

            grid.addRow(with: [lbl, field, browseBtn])
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        }

        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        return view
    }

    // MARK: - Folders Page (FoldersPage.cpp)

    private func createFoldersPage() -> NSView {
        let view = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let titleLabel = NSTextField(labelWithString: "Working folder for temporary archive files:")
        titleLabel.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(titleLabel)

        let mode = SZSettings.workDirMode

        let systemTempRadio = NSButton(radioButtonWithTitle: "System temp folder", target: self, action: #selector(workDirModeChanged(_:)))
        systemTempRadio.tag = 0
        systemTempRadio.state = mode == 0 ? .on : .off
        stack.addArrangedSubview(systemTempRadio)

        let currentRadio = NSButton(radioButtonWithTitle: "Current folder", target: self, action: #selector(workDirModeChanged(_:)))
        currentRadio.tag = 1
        currentRadio.state = mode == 1 ? .on : .off
        stack.addArrangedSubview(currentRadio)

        let specifiedRow = NSStackView()
        specifiedRow.orientation = .horizontal
        specifiedRow.spacing = 8

        let specifiedRadio = NSButton(radioButtonWithTitle: "Specified:", target: self, action: #selector(workDirModeChanged(_:)))
        specifiedRadio.tag = 2
        specifiedRadio.state = mode == 2 ? .on : .off
        specifiedRow.addArrangedSubview(specifiedRadio)

        let pathField = NSTextField()
        pathField.stringValue = SZSettings.string(.workDirPath)
        pathField.identifier = NSUserInterfaceItemIdentifier(SZSettingsKey.workDirPath.rawValue)
        pathField.isEnabled = mode == 2
        pathField.target = self
        pathField.action = #selector(workDirPathChanged(_:))
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        specifiedRow.addArrangedSubview(pathField)

        let browseBtn = NSButton(title: "...", target: self, action: #selector(browseWorkDir(_:)))
        browseBtn.widthAnchor.constraint(equalToConstant: 30).isActive = true
        specifiedRow.addArrangedSubview(browseBtn)

        stack.addArrangedSubview(specifiedRow)

        let sep = NSBox()
        sep.boxType = .separator
        stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let removableCheck = NSButton(checkboxWithTitle: "Use for removable drives only", target: self, action: #selector(removableOnlyChanged(_:)))
        removableCheck.state = SZSettings.bool(.workDirRemovableOnly) ? .on : .off
        stack.addArrangedSubview(removableCheck)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        return view
    }

    // MARK: - Actions

    @objc private func settingsCheckboxChanged(_ sender: NSButton) {
        guard let keyStr = sender.identifier?.rawValue,
              let key = SZSettingsKey(rawValue: keyStr) else { return }
        SZSettings.set(sender.state == .on, for: key)
    }

    @objc private func memLimitCheckChanged(_ sender: NSButton) {
        SZSettings.set(sender.state == .on, for: .memLimitEnabled)
        // Find and enable/disable the memLimitField
        if let stack = sender.superview as? NSStackView {
            for v in stack.arrangedSubviews {
                if let field = v as? NSTextField, field.identifier?.rawValue == "memLimitField" {
                    field.isEnabled = sender.state == .on
                }
            }
        }
    }

    @objc private func memLimitChanged(_ sender: NSTextField) {
        SZSettings.set(max(1, sender.integerValue), for: .memLimitGB)
    }

    @objc private func editorPathChanged(_ sender: NSTextField) {
        guard let keyStr = sender.identifier?.rawValue,
              let key = SZSettingsKey(rawValue: keyStr) else { return }
        SZSettings.set(sender.stringValue, for: key)
    }

    @objc private func browseEditorPath(_ sender: NSButton) {
        guard let keyStr = sender.identifier?.rawValue,
              let key = SZSettingsKey(rawValue: keyStr) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application, .executable]
        if panel.runModal() == .OK, let url = panel.url {
            SZSettings.set(url.path, for: key)
            // Update the corresponding text field
            if let grid = sender.superview?.superview as? NSGridView {
                for row in 0..<grid.numberOfRows {
                    if let field = grid.cell(atColumnIndex: 1, rowIndex: row).contentView as? NSTextField,
                       field.identifier?.rawValue == keyStr {
                        field.stringValue = url.path
                    }
                }
            }
        }
    }

    @objc private func workDirModeChanged(_ sender: NSButton) {
        SZSettings.set(sender.tag, for: .workDirMode)
        // Enable/disable path field based on mode
        if let stack = sender.superview?.superview as? NSStackView ?? sender.superview as? NSStackView {
            for v in stack.arrangedSubviews {
                if let row = v as? NSStackView {
                    for sv in row.arrangedSubviews {
                        if let field = sv as? NSTextField, field.identifier?.rawValue == SZSettingsKey.workDirPath.rawValue {
                            field.isEnabled = sender.tag == 2
                        }
                    }
                }
            }
        }
    }

    @objc private func workDirPathChanged(_ sender: NSTextField) {
        SZSettings.set(sender.stringValue, for: .workDirPath)
    }

    @objc private func browseWorkDir(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            SZSettings.set(url.path, for: .workDirPath)
            // Update path field
            if let row = sender.superview as? NSStackView {
                for v in row.arrangedSubviews {
                    if let field = v as? NSTextField, field.identifier?.rawValue == SZSettingsKey.workDirPath.rawValue {
                        field.stringValue = url.path
                    }
                }
            }
        }
    }

    @objc private func removableOnlyChanged(_ sender: NSButton) {
        SZSettings.set(sender.state == .on, for: .workDirRemovableOnly)
    }
}
