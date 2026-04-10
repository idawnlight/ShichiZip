import Cocoa

// MARK: - Settings Window Controller (matches Windows 7-Zip Options dialog)

private final class SettingsPageContainerView: NSView {
    private let contentStack: NSStackView
    private let contentInsets: NSEdgeInsets

    init(contentStack: NSStackView,
         contentInsets: NSEdgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)) {
        self.contentStack = contentStack
        self.contentInsets = contentInsets
        super.init(frame: .zero)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: contentInsets.top),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInsets.left),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInsets.right),
            bottomAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: contentInsets.bottom),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var preferredHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return contentStack.fittingSize.height + contentInsets.top + contentInsets.bottom
    }
}

private final class ShortcutRecorderButton: NSButton {
    var shortcut: FileManagerShortcut? {
        didSet {
            if !isRecording {
                updateAppearance()
            }
        }
    }

    var onShortcutChanged: ((FileManagerShortcut?) -> Void)?

    private var recordingMonitor: Any?
    private var isRecording = false {
        didSet {
            updateAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording(_:))
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopRecording()
    }

    @objc private func toggleRecording(_ sender: Any?) {
        if isRecording {
            cancelRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard recordingMonitor == nil else { return }

        isRecording = true
        window?.makeFirstResponder(self)
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else {
                return event
            }

            return self.capture(event)
        }
    }

    private func cancelRecording() {
        stopRecording()
    }

    private func stopRecording() {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
            self.recordingMonitor = nil
        }
        isRecording = false
    }

    private func capture(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            cancelRecording()
            return nil
        }

        guard let shortcut = FileManagerShortcut(event: event) else {
            NSSound.beep()
            return nil
        }

        self.shortcut = shortcut
        stopRecording()
        onShortcutChanged?(shortcut)
        return nil
    }

    private func updateAppearance() {
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        if isRecording {
            attributedTitle = NSAttributedString(
                string: "Type Shortcut…",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.controlAccentColor,
                ]
            )
            return
        }

        if let shortcut {
            attributedTitle = NSAttributedString(
                string: shortcut.displayName,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            return
        }

        let placeholderFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        attributedTitle = NSAttributedString(
            string: "Record Shortcut",
            attributes: [
                .font: placeholderFont,
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        )
    }
}

class SettingsWindowController: NSWindowController {

    private enum LayoutMetrics {
        static let outerInset: CGFloat = 12
        static let segmentSpacing: CGFloat = 12
    }

    private var tabView: NSTabView!
    private var tabSegmentedControl: NSSegmentedControl!
    private var shortcutPresetPopup: NSPopUpButton?
    private var shortcutPresetDescriptionLabel: NSTextField?
    private var shortcutBindingsStack: NSStackView?
    private var shortcutRecorders: [FileManagerShortcutCommand: ShortcutRecorderButton] = [:]
    private var isUpdatingShortcutControls = false

    private static let finderQuickActionsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.services")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
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

        let shortcutsTab = NSTabViewItem(identifier: "shortcuts")
        shortcutsTab.label = "Shortcuts"
        shortcutsTab.view = createShortcutsPage()
        tabView.addTabViewItem(shortcutsTab)

        // Folders tab (FoldersPage.cpp)
        let foldersTab = NSTabViewItem(identifier: "folders")
        foldersTab.label = "Folders"
        foldersTab.view = createFoldersPage()
        tabView.addTabViewItem(foldersTab)

        let integrationTab = NSTabViewItem(identifier: "integration")
        integrationTab.label = "Integration"
        integrationTab.view = createIntegrationPage()
        tabView.addTabViewItem(integrationTab)

        contentView.addSubview(tabView)

        // Segmented control for tab switching
        tabSegmentedControl = NSSegmentedControl(labels: ["Settings", "Shortcuts", "Folders", "Integration"],
                                                trackingMode: .selectOne,
                                                target: self,
                                                action: #selector(tabSegmentChanged(_:)))
        tabSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        tabSegmentedControl.selectedSegment = 0
        tabSegmentedControl.segmentStyle = .automatic
        contentView.addSubview(tabSegmentedControl)

        NSLayoutConstraint.activate([
            tabSegmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: LayoutMetrics.outerInset),
            tabSegmentedControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            tabView.topAnchor.constraint(equalTo: tabSegmentedControl.bottomAnchor, constant: LayoutMetrics.segmentSpacing),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: LayoutMetrics.outerInset),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -LayoutMetrics.outerInset),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -LayoutMetrics.outerInset),
        ])

        contentView.layoutSubtreeIfNeeded()
        resizeWindowToFitSelectedTab(animated: false)
    }

    @objc private func tabSegmentChanged(_ sender: NSSegmentedControl) {
        tabView.selectTabViewItem(at: sender.selectedSegment)
        resizeWindowToFitSelectedTab(animated: true)
    }

    // MARK: - Settings Page (SettingsPage.cpp)

    private func createSettingsPage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let generalCheckboxes: [(String, SZSettingsKey)] = [
            ("Show \"..\" item", .showDots),
            ("Show real file icons", .showRealFileIcons),
            ("Show hidden files in File Manager", .showHiddenFiles),
            ("Show grid lines", .showGridLines),
            ("Single-click to open an item", .singleClickOpen),
            ("Quit the app when the last window closes", .quitAfterLastWindowClosed),
        ]

        for (title, key) in generalCheckboxes {
            let cb = NSButton(checkboxWithTitle: title, target: self, action: #selector(settingsCheckboxChanged(_:)))
            cb.tag = key.hashValue
            cb.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
            cb.state = SZSettings.bool(key) ? .on : .off
            stack.addArrangedSubview(cb)
        }

        let compressionSeparator = makeSettingsSeparator()
        stack.addArrangedSubview(compressionSeparator)
        compressionSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(makeSectionLabel("Compression"))

        let compressionCheckbox = NSButton(checkboxWithTitle: "Exclude macOS resource fork files by default",
                                           target: self,
                                           action: #selector(settingsCheckboxChanged(_:)))
        compressionCheckbox.tag = SZSettingsKey.excludeMacResourceFilesByDefault.hashValue
        compressionCheckbox.identifier = NSUserInterfaceItemIdentifier(SZSettingsKey.excludeMacResourceFilesByDefault.rawValue)
        compressionCheckbox.state = SZSettings.bool(.excludeMacResourceFilesByDefault) ? .on : .off
        stack.addArrangedSubview(compressionCheckbox)

        let extractionSeparator = makeSettingsSeparator()
        stack.addArrangedSubview(extractionSeparator)
        extractionSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(makeSectionLabel("Extraction"))

        let extractionCheckboxes: [(String, SZSettingsKey)] = [
            ("Move compressed file to Trash after extraction", .moveArchiveToTrashAfterExtraction),
            ("Inherit quarantine from downloaded file (if applicable)", .inheritDownloadedFileQuarantine),
        ]

        for (title, key) in extractionCheckboxes {
            let cb = NSButton(checkboxWithTitle: title, target: self, action: #selector(settingsCheckboxChanged(_:)))
            cb.tag = key.hashValue
            cb.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
            cb.state = SZSettings.bool(key) ? .on : .off
            stack.addArrangedSubview(cb)
        }

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

        return makePageView(containing: stack)
    }

    private func makeSettingsSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 12)
        return label
    }

    private func makePageView(containing stack: NSStackView) -> NSView {
        SettingsPageContainerView(contentStack: stack)
    }

    private func resizeWindowToFitSelectedTab(animated: Bool) {
        guard let window,
              let contentView = window.contentView,
              let selectedView = tabView.selectedTabViewItem?.view as? SettingsPageContainerView else {
            return
        }

        contentView.layoutSubtreeIfNeeded()
        selectedView.layoutSubtreeIfNeeded()

        let desiredContentHeight = LayoutMetrics.outerInset
            + tabSegmentedControl.fittingSize.height
            + LayoutMetrics.segmentSpacing
            + selectedView.preferredHeight
            + LayoutMetrics.outerInset

        let currentFrame = window.frame
        let currentContentRect = window.contentRect(forFrameRect: currentFrame)
        let targetContentRect = NSRect(x: 0,
                                       y: 0,
                                       width: currentContentRect.width,
                                       height: desiredContentHeight)
        var targetFrame = window.frameRect(forContentRect: targetContentRect)
        targetFrame.origin.x = currentFrame.origin.x
        targetFrame.origin.y = currentFrame.maxY - targetFrame.height

        window.setFrame(targetFrame, display: true, animate: animated)
    }

    // MARK: - Shortcuts Page

    private func createShortcutsPage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        stack.addArrangedSubview(makeSectionLabel("Preset"))

        let descriptionLabel = NSTextField(wrappingLabelWithString: "")
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.preferredMaxLayoutWidth = 480
        shortcutPresetDescriptionLabel = descriptionLabel
        stack.addArrangedSubview(descriptionLabel)

        let presetRow = NSStackView()
        presetRow.orientation = .horizontal
        presetRow.alignment = .centerY
        presetRow.spacing = 8

        let presetLabel = NSTextField(labelWithString: "Scheme:")
        presetRow.addArrangedSubview(presetLabel)

        let presetPopup = NSPopUpButton()
        for preset in FileManagerShortcutPreset.allCases {
            presetPopup.addItem(withTitle: preset.displayName)
            presetPopup.lastItem?.tag = preset.rawValue
        }
        if let item = presetPopup.itemArray.first(where: { $0.tag == SZSettings.fileManagerShortcutPreset.rawValue }) {
            presetPopup.select(item)
        }
        presetPopup.target = self
        presetPopup.action = #selector(shortcutPresetChanged(_:))
        shortcutPresetPopup = presetPopup
        presetRow.addArrangedSubview(presetPopup)

        stack.addArrangedSubview(presetRow)

        let noteLabel = NSTextField(wrappingLabelWithString: "These shortcuts apply to file manager commands. Standard app shortcuts such as Preferences and Quit stay unchanged.")
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.maximumNumberOfLines = 0
        noteLabel.preferredMaxLayoutWidth = 480
        stack.addArrangedSubview(noteLabel)

        let customNoteLabel = NSTextField(wrappingLabelWithString: "Changing an individual binding switches the preset to Custom. Reusing a shortcut clears it from the previous command. Click a shortcut field and press any key combination. Press Escape to cancel recording.")
        customNoteLabel.textColor = .secondaryLabelColor
        customNoteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        customNoteLabel.maximumNumberOfLines = 0
        customNoteLabel.preferredMaxLayoutWidth = 480
        stack.addArrangedSubview(customNoteLabel)

        let separator = makeSettingsSeparator()
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(makeSectionLabel("Current Shortcuts"))

        let bindingsStack = NSStackView()
        bindingsStack.orientation = .vertical
        bindingsStack.alignment = .leading
        bindingsStack.spacing = 6
        shortcutBindingsStack = bindingsStack

        for command in FileManagerShortcutCommand.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12

            let titleLabel = NSTextField(labelWithString: command.title)
            titleLabel.preferredMaxLayoutWidth = 260
            titleLabel.widthAnchor.constraint(equalToConstant: 220).isActive = true
            row.addArrangedSubview(titleLabel)

            let recorder = ShortcutRecorderButton(frame: .zero)
            recorder.shortcut = FileManagerShortcuts.binding(for: command).shortcut
            recorder.widthAnchor.constraint(equalToConstant: 190).isActive = true
            recorder.onShortcutChanged = { [weak self] shortcut in
                self?.updateShortcutBinding(for: command, to: shortcut)
            }
            shortcutRecorders[command] = recorder
            row.addArrangedSubview(recorder)

            let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearShortcutBinding(_:)))
            clearButton.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            row.addArrangedSubview(clearButton)

            bindingsStack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(bindingsStack)

        updateShortcutPresetUI(for: SZSettings.fileManagerShortcutPreset)
        return makePageView(containing: stack)
    }

    private func updateShortcutPresetUI(for preset: FileManagerShortcutPreset) {
        shortcutPresetDescriptionLabel?.stringValue = preset.descriptionText
        if let item = shortcutPresetPopup?.itemArray.first(where: { $0.tag == preset.rawValue }) {
            shortcutPresetPopup?.select(item)
        }
        rebuildShortcutBindingsList(for: preset)
    }

    private func rebuildShortcutBindingsList(for preset: FileManagerShortcutPreset) {
        isUpdatingShortcutControls = true
        defer { isUpdatingShortcutControls = false }

        let bindingMap = FileManagerShortcuts.resolvedBindingMap(for: preset)
        for command in FileManagerShortcutCommand.allCases {
            guard let recorder = shortcutRecorders[command] else { continue }
            recorder.shortcut = bindingMap[command]
        }
    }

    private func seedCustomShortcutMapIfNeeded(from preset: FileManagerShortcutPreset) {
        guard !SZSettings.hasFileManagerCustomShortcutMap else { return }
        SZSettings.setFileManagerCustomShortcutMap(FileManagerShortcuts.resolvedBindingMap(for: preset))
    }

    private func updateShortcutBinding(for command: FileManagerShortcutCommand,
                                       to shortcut: FileManagerShortcut?) {
        guard !isUpdatingShortcutControls else { return }

        let previousPreset = SZSettings.fileManagerShortcutPreset
        var bindingMap = FileManagerShortcuts.resolvedBindingMap(for: previousPreset)

        if let shortcut {
            for otherCommand in FileManagerShortcutCommand.allCases where otherCommand != command {
                if bindingMap[otherCommand] == shortcut {
                    bindingMap.removeValue(forKey: otherCommand)
                }
            }
            bindingMap[command] = shortcut
        } else {
            bindingMap.removeValue(forKey: command)
        }

        SZSettings.setFileManagerCustomShortcutMap(bindingMap)

        if previousPreset != .custom {
            SZSettings.setFileManagerShortcutPreset(.custom)
        }

        updateShortcutPresetUI(for: .custom)
        resizeWindowToFitSelectedTab(animated: true)
    }

    // MARK: - Integration Page

    private func createIntegrationPage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        stack.addArrangedSubview(makeSectionLabel("Finder Quick Actions"))

        let descriptionLabel = NSTextField(wrappingLabelWithString: "Open the Finder Quick Actions page in System Settings and review whether ShichiZip's Quick Actions are currently enabled.")
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.preferredMaxLayoutWidth = 440
        stack.addArrangedSubview(descriptionLabel)

        let openSettingsButton = NSButton(title: "Open Finder Quick Actions Settings", target: self, action: #selector(openFinderQuickActionsSettings(_:)))
        stack.addArrangedSubview(openSettingsButton)

        let noteLabel = NSTextField(wrappingLabelWithString: "Finder Quick Action enablement is managed by macOS in System Settings.")
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.maximumNumberOfLines = 0
        noteLabel.preferredMaxLayoutWidth = 440
        stack.addArrangedSubview(noteLabel)

        return makePageView(containing: stack)
    }

    // MARK: - Folders Page (FoldersPage.cpp)

    private func createFoldersPage() -> NSView {
        let stack = NSStackView()
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

        return makePageView(containing: stack)
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

    @objc private func shortcutPresetChanged(_ sender: NSPopUpButton) {
        guard !isUpdatingShortcutControls else { return }

        let previousPreset = SZSettings.fileManagerShortcutPreset
        guard let selectedItem = sender.selectedItem,
              let preset = FileManagerShortcutPreset(rawValue: selectedItem.tag) else {
            return
        }

        if preset == previousPreset {
            return
        }

        if preset == .custom {
            seedCustomShortcutMapIfNeeded(from: previousPreset)
        }

        SZSettings.setFileManagerShortcutPreset(preset)
        updateShortcutPresetUI(for: preset)
        resizeWindowToFitSelectedTab(animated: true)
    }

    @objc private func clearShortcutBinding(_ sender: NSButton) {
        guard let commandRawValue = sender.identifier?.rawValue,
              let command = FileManagerShortcutCommand(rawValue: commandRawValue) else {
            return
        }

        updateShortcutBinding(for: command, to: nil)
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

    @objc private func openFinderQuickActionsSettings(_ sender: Any?) {
        guard let url = Self.finderQuickActionsSettingsURL,
              NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = "Unable to open Finder Quick Actions settings."
            alert.informativeText = "Open System Settings and go to Extensions > Finder to manage ShichiZip's Quick Actions."
            alert.runModal()
            return
        }
    }
}
