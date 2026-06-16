import Cocoa
import UniformTypeIdentifiers

// MARK: - Settings Window Controller (matches Windows 7-Zip Options dialog)

class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private enum LayoutMetrics {
        static let outerInset: CGFloat = 12
        static let segmentSpacing: CGFloat = 12
        static let integrationContentWidth: CGFloat = 480
        static let integrationListHeight: CGFloat = 240
        static let integrationArchiveTypeWidth: CGFloat = 200
        static let integrationDefaultApplicationWidth: CGFloat = 120
        static let integrationActionButtonWidth: CGFloat = 124
        static let quickLookExpansionDepthIdentifier = "settings.quickLook.expansionDepth"
    }

    private var tabView: NSTabView!
    private var tabSegmentedControl: NSSegmentedControl!
    private var shortcutPresetPopup: NSPopUpButton?
    private var shortcutPresetDescriptionLabel: NSTextField?
    private var shortcutBindingsStack: NSStackView?
    private var shortcutRecorders: [FileManagerShortcutCommand: ShortcutRecorderButton] = [:]
    private var integrationFileAssociationStates: [String: IntegrationFileAssociationState] = [:]
    private weak var integrationTableView: NSTableView?
    private var pendingFileAssociationUpdates: Set<String> = []
    private var isUpdatingShortcutControls = false
    var onWindowWillClose: (() -> Void)?

    private static let supportedFileAssociations = IntegrationFileAssociation.integrationDocumentTypes()
    /// https://gist.github.com/rmcdongit/f66ff91e0dad78d4d6346a75ded4b751?permalink_comment_id=5507723#gistcomment-5507723
    private static let finderQuickActionsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.finder-quick-actions")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 536, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
        )
        window.title = SZL10n.string("settings.options")
        window.center()
        self.init(window: window)
        window.delegate = self
        setupUI()
    }

    override func showWindow(_ sender: Any?) {
        window?.title = SZL10n.string("settings.options")
        super.showWindow(sender)
    }

    func windowWillClose(_: Notification) {
        onWindowWillClose?()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .noTabsNoBorder // hide default tabs, use toolbar

        // Settings tab (SettingsPage.cpp)
        let settingsTab = NSTabViewItem(identifier: "settings")
        settingsTab.label = SZL10n.string("settings.title")
        settingsTab.view = createSettingsPage()
        tabView.addTabViewItem(settingsTab)

        let shortcutsTab = NSTabViewItem(identifier: "shortcuts")
        shortcutsTab.label = SZL10n.string("app.settings.shortcuts")
        shortcutsTab.view = createShortcutsPage()
        tabView.addTabViewItem(shortcutsTab)

        // Folders tab (FoldersPage.cpp)
        let foldersTab = NSTabViewItem(identifier: "folders")
        foldersTab.label = SZL10n.string("settings.folders")
        foldersTab.view = createFoldersPage()
        tabView.addTabViewItem(foldersTab)

        let integrationTab = NSTabViewItem(identifier: "integration")
        integrationTab.label = SZL10n.string("app.settings.integration")
        integrationTab.view = createIntegrationPage()
        tabView.addTabViewItem(integrationTab)

        contentView.addSubview(tabView)

        // Segmented control for tab switching
        tabSegmentedControl = NSSegmentedControl(labels: [SZL10n.string("settings.title"), SZL10n.string("app.settings.shortcuts"), SZL10n.string("settings.folders"), SZL10n.string("app.settings.integration")],
                                                 trackingMode: .selectOne,
                                                 target: self,
                                                 action: #selector(tabSegmentChanged(_:)))
        tabSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        tabSegmentedControl.selectedSegment = 0
        tabSegmentedControl.segmentStyle = .automatic
        tabSegmentedControl.setAccessibilityIdentifier("settings.tabSegment")
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
        if tabView.selectedTabViewItem?.identifier as? String == "integration" {
            refreshIntegrationFileAssociationRows()
        }
        resizeWindowToFitSelectedTab(animated: true)
    }

    // MARK: - Settings Page (SettingsPage.cpp)

    private func createSettingsPage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        // --- Language selector ---
        let langRow = NSStackView()
        langRow.orientation = .horizontal
        langRow.alignment = .centerY
        langRow.spacing = 8

        let langLabel = NSTextField(labelWithString: SZL10n.string("settings.languageLabel"))
        langRow.addArrangedSubview(langLabel)

        let langPopup = NSPopUpButton()
        langPopup.addItem(withTitle: SZL10n.string("app.settings.followSystem"))
        langPopup.lastItem?.representedObject = "" as NSString
        langPopup.menu?.addItem(.separator())

        let currentOverride = SZSettings.string(.languageOverride)
        for lang in SZL10n.availableLanguages() {
            langPopup.addItem(withTitle: lang.displayName)
            langPopup.lastItem?.representedObject = lang.localeCode as NSString
            if lang.localeCode == currentOverride {
                langPopup.select(langPopup.lastItem)
            }
        }

        if currentOverride.isEmpty {
            langPopup.selectItem(at: 0)
        }

        langPopup.target = self
        langPopup.action = #selector(languageChanged(_:))
        langPopup.setAccessibilityIdentifier("settings.language")
        langRow.addArrangedSubview(langPopup)

        stack.addArrangedSubview(langRow)

        let langSeparator = makeSettingsSeparator()
        stack.addArrangedSubview(langSeparator)
        langSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let generalCheckboxes: [(String, SZSettingsKey)] = [
            (SZL10n.string("settings.showDotDot"), .showDots),
            (SZL10n.string("settings.showRealIcons"), .showRealFileIcons),
            (SZL10n.string("app.settings.showHiddenFiles"), .showHiddenFiles),
            (SZL10n.string("settings.showGridLines"), .showGridLines),
            (SZL10n.string("settings.singleClick"), .singleClickOpen),
            (SZL10n.string("app.settings.quitOnLastClose"), .quitAfterLastWindowClosed),
        ]

        for (title, key) in generalCheckboxes {
            let cb = NSButton(checkboxWithTitle: title, target: self, action: #selector(settingsCheckboxChanged(_:)))
            cb.tag = key.hashValue
            cb.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
            cb.state = SZSettings.bool(key) ? .on : .off
            stack.addArrangedSubview(cb)
        }

        let windowSeparator = makeSettingsSeparator()
        stack.addArrangedSubview(windowSeparator)
        windowSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(makeSectionLabel(SZL10n.string("app.settings.layout")))

        let rememberWindowFrameCheckbox = NSButton(checkboxWithTitle: SZL10n.string("app.settings.rememberFileManagerWindowFrame"),
                                                   target: self,
                                                   action: #selector(rememberWindowFrameChanged(_:)))
        rememberWindowFrameCheckbox.state = FileManagerWindowPreferences.remembersWindowFrame ? .on : .off
        rememberWindowFrameCheckbox.setAccessibilityIdentifier("settings.rememberFileManagerWindowFrame")
        stack.addArrangedSubview(rememberWindowFrameCheckbox)

        let resetWindowFrameButton = NSButton(title: SZL10n.string("app.settings.resetFileManagerWindowFrame"),
                                              target: self,
                                              action: #selector(resetFileManagerWindowFrame(_:)))
        resetWindowFrameButton.setAccessibilityIdentifier("settings.resetFileManagerWindowFrame")
        stack.addArrangedSubview(resetWindowFrameButton)

        let resetFileListPreferencesButton = NSButton(title: SZL10n.string("app.settings.resetFileListLayout"),
                                                      target: self,
                                                      action: #selector(resetFileListPreferences(_:)))
        resetFileListPreferencesButton.setAccessibilityIdentifier("settings.resetFileListLayout")
        stack.addArrangedSubview(resetFileListPreferencesButton)

        let resetFileListPreferencesNote = NSTextField(wrappingLabelWithString: SZL10n.string("app.settings.resetFileListLayoutNote"))
        resetFileListPreferencesNote.textColor = .secondaryLabelColor
        resetFileListPreferencesNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        resetFileListPreferencesNote.maximumNumberOfLines = 0
        resetFileListPreferencesNote.preferredMaxLayoutWidth = 480
        stack.addArrangedSubview(resetFileListPreferencesNote)

        let statusBarSizeRow = NSStackView()
        statusBarSizeRow.orientation = .horizontal
        statusBarSizeRow.alignment = .centerY
        statusBarSizeRow.spacing = 8

        let statusBarSizeLabel = NSTextField(labelWithString: SZL10n.string("app.settings.statusBarSize"))
        statusBarSizeRow.addArrangedSubview(statusBarSizeLabel)

        let statusBarSizePopup = NSPopUpButton()
        let statusBarSizeItems: [(String, Int)] = [
            (SZL10n.string("app.settings.statusBarSize.always"), 0),
            (SZL10n.string("app.settings.statusBarSize.archiveOnly"), 1),
        ]
        for item in statusBarSizeItems {
            statusBarSizePopup.addItem(withTitle: item.0)
            statusBarSizePopup.lastItem?.tag = item.1
        }
        if let item = statusBarSizePopup.itemArray.first(where: { $0.tag == SZSettings.statusBarSizeMode }) {
            statusBarSizePopup.select(item)
        }
        statusBarSizePopup.target = self
        statusBarSizePopup.action = #selector(statusBarSizeModeChanged(_:))
        statusBarSizePopup.setAccessibilityIdentifier("settings.statusBarSizeMode")
        statusBarSizeRow.addArrangedSubview(statusBarSizePopup)

        stack.addArrangedSubview(statusBarSizeRow)

        let compressionSeparator = makeSettingsSeparator()
        stack.addArrangedSubview(compressionSeparator)
        compressionSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(makeSectionLabel(SZL10n.string("app.settings.compression")))

        let compressionCheckbox = NSButton(checkboxWithTitle: SZL10n.string("app.settings.excludeMacResourceForks"),
                                           target: self,
                                           action: #selector(settingsCheckboxChanged(_:)))
        compressionCheckbox.tag = SZSettingsKey.excludeMacResourceFilesByDefault.hashValue
        compressionCheckbox.identifier = NSUserInterfaceItemIdentifier(SZSettingsKey.excludeMacResourceFilesByDefault.rawValue)
        compressionCheckbox.state = SZSettings.bool(.excludeMacResourceFilesByDefault) ? .on : .off
        stack.addArrangedSubview(compressionCheckbox)

        let extractionSeparator = makeSettingsSeparator()
        stack.addArrangedSubview(extractionSeparator)
        extractionSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(makeSectionLabel(SZL10n.string("app.settings.extraction")))

        let extractionCheckboxes: [(String, SZSettingsKey)] = [
            (SZL10n.string("app.extract.moveToTrash"), .moveArchiveToTrashAfterExtraction),
            (SZL10n.string("app.extract.inheritQuarantine"), .inheritDownloadedFileQuarantine),
        ]

        for (title, key) in extractionCheckboxes {
            let cb = NSButton(checkboxWithTitle: title, target: self, action: #selector(settingsCheckboxChanged(_:)))
            cb.tag = key.hashValue
            cb.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
            cb.state = SZSettings.bool(key) ? .on : .off
            stack.addArrangedSubview(cb)
        }

        let memLabel = NSTextField(labelWithString: SZL10n.string("app.settings.maxRAMForExtraction"))
        stack.addArrangedSubview(memLabel)

        let memRow = NSStackView()
        memRow.orientation = .horizontal
        memRow.spacing = 8

        let memCheck = NSButton(checkboxWithTitle: SZL10n.string("app.settings.limitTo"), target: self, action: #selector(memLimitCheckChanged(_:)))
        memCheck.state = SZSettings.bool(.memLimitEnabled) ? .on : .off
        memCheck.setAccessibilityIdentifier("settings.memLimitCheck")
        memRow.addArrangedSubview(memCheck)

        let memField = NSTextField()
        memField.integerValue = SZSettings.memLimitGB
        memField.identifier = NSUserInterfaceItemIdentifier("memLimitField")
        memField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        memField.isEnabled = SZSettings.bool(.memLimitEnabled)
        memField.target = self
        memField.action = #selector(memLimitChanged(_:))
        memField.setAccessibilityIdentifier("settings.memLimitField")
        memRow.addArrangedSubview(memField)

        let gbLabel = NSTextField(labelWithString: "GB")
        memRow.addArrangedSubview(gbLabel)

        stack.addArrangedSubview(memRow)

        addLaunchOpenSection(to: stack)

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
              let selectedView = tabView.selectedTabViewItem?.view as? SettingsPageContainerView
        else {
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

        stack.addArrangedSubview(makeSectionLabel(SZL10n.string("app.settings.preset")))

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

        let presetLabel = NSTextField(labelWithString: SZL10n.string("app.settings.scheme"))
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
        presetPopup.setAccessibilityIdentifier("settings.shortcutPreset")
        shortcutPresetPopup = presetPopup
        presetRow.addArrangedSubview(presetPopup)

        stack.addArrangedSubview(presetRow)

        let noteLabel = NSTextField(wrappingLabelWithString: SZL10n.string("app.settings.shortcutsNote"))
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.maximumNumberOfLines = 0
        noteLabel.preferredMaxLayoutWidth = 480
        stack.addArrangedSubview(noteLabel)

        let customNoteLabel = NSTextField(wrappingLabelWithString: SZL10n.string("app.settings.shortcutsCustomNote"))
        customNoteLabel.textColor = .secondaryLabelColor
        customNoteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        customNoteLabel.maximumNumberOfLines = 0
        customNoteLabel.preferredMaxLayoutWidth = 480
        stack.addArrangedSubview(customNoteLabel)

        let separator = makeSettingsSeparator()
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(makeSectionLabel(SZL10n.string("app.settings.currentShortcuts")))

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

            let clearButton = NSButton(title: SZL10n.string("app.settings.clear"), target: self, action: #selector(clearShortcutBinding(_:)))
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
                                       to shortcut: FileManagerShortcut?)
    {
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

        integrationFileAssociationStates.removeAll()

        stack.addArrangedSubview(makeSectionLabel(SZL10n.string("app.settings.defaultOpeners")))

        let associationDescriptionLabel = NSTextField(wrappingLabelWithString: SZL10n.string("app.settings.defaultOpenersDescription", AppBuildInfo.appDisplayName()))
        associationDescriptionLabel.textColor = .secondaryLabelColor
        associationDescriptionLabel.maximumNumberOfLines = 0
        associationDescriptionLabel.preferredMaxLayoutWidth = LayoutMetrics.integrationContentWidth
        stack.addArrangedSubview(associationDescriptionLabel)

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.heightAnchor.constraint(equalToConstant: LayoutMetrics.integrationListHeight).isActive = true
        stack.addArrangedSubview(scrollView)
        let preferredWidthConstraint = scrollView.widthAnchor.constraint(equalToConstant: LayoutMetrics.integrationContentWidth)
        preferredWidthConstraint.priority = .defaultHigh
        preferredWidthConstraint.isActive = true
        scrollView.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true

        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.focusRingType = .none
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .none
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsColumnSelection = false
        tableView.allowsTypeSelect = false

        let rowColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("IntegrationRowColumn"))
        rowColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(rowColumn)

        scrollView.documentView = tableView
        integrationTableView = tableView

        let setAllButton = NSButton(title: SZL10n.string("app.settings.setAllAsDefault"), target: self, action: #selector(makeDefaultApplicationForAllFileAssociations(_:)))
        setAllButton.setAccessibilityIdentifier("settings.setAllAsDefault")
        stack.addArrangedSubview(setAllButton)

        let associationsNoteLabel = NSTextField(wrappingLabelWithString: SZL10n.string("app.settings.defaultOpenersNote"))
        associationsNoteLabel.textColor = .secondaryLabelColor
        associationsNoteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        associationsNoteLabel.maximumNumberOfLines = 0
        associationsNoteLabel.preferredMaxLayoutWidth = LayoutMetrics.integrationContentWidth
        stack.addArrangedSubview(associationsNoteLabel)

        let fileAssociationSeparator = makeSettingsSeparator()
        stack.addArrangedSubview(fileAssociationSeparator)
        fileAssociationSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(makeSectionLabel(SZL10n.string("app.settings.finderQuickActions")))

        let descriptionLabel = NSTextField(wrappingLabelWithString: SZL10n.string("app.settings.quickActionsDescription", AppBuildInfo.appDisplayName()))
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.preferredMaxLayoutWidth = LayoutMetrics.integrationContentWidth
        stack.addArrangedSubview(descriptionLabel)

        let openSettingsButton = NSButton(title: SZL10n.string("app.settings.openFinderQuickActionsSettings"), target: self, action: #selector(openFinderQuickActionsSettings(_:)))
        openSettingsButton.setAccessibilityIdentifier("settings.openQuickActionsSettings")
        stack.addArrangedSubview(openSettingsButton)

        let noteLabel = NSTextField(wrappingLabelWithString: SZL10n.string("app.settings.quickActionsNote"))
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.maximumNumberOfLines = 0
        noteLabel.preferredMaxLayoutWidth = LayoutMetrics.integrationContentWidth
        stack.addArrangedSubview(noteLabel)

        addQuickLookSection(to: stack)

        refreshIntegrationFileAssociationRows()

        return makePageView(containing: stack)
    }

    private static func currentApplicationURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func applicationBundleIdentifier(at applicationURL: URL) -> String? {
        Bundle(url: applicationURL)?.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCurrentApplication(_ applicationURL: URL,
                                             currentBundle: Bundle = .main) -> Bool
    {
        let normalizedApplicationURL = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        let currentApplicationURL = currentApplicationURL(bundle: currentBundle)
        if normalizedApplicationURL == currentApplicationURL {
            return true
        }

        guard let currentBundleIdentifier = currentBundle.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !currentBundleIdentifier.isEmpty,
            let applicationBundleIdentifier = applicationBundleIdentifier(at: normalizedApplicationURL),
            !applicationBundleIdentifier.isEmpty
        else {
            return false
        }

        return applicationBundleIdentifier == currentBundleIdentifier
    }

    private static func applicationDisplayName(at applicationURL: URL) -> String {
        let displayName = FileManager.default.displayName(atPath: applicationURL.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !displayName.isEmpty {
            return displayName
        }

        return applicationURL.deletingPathExtension().lastPathComponent
    }

    private static func applicationIdentity(for applicationURL: URL) -> String {
        let normalizedApplicationURL = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        if let bundleIdentifier = applicationBundleIdentifier(at: normalizedApplicationURL),
           !bundleIdentifier.isEmpty
        {
            return "bundle:\(bundleIdentifier)"
        }

        return "path:\(normalizedApplicationURL.path)"
    }

    private func refreshIntegrationFileAssociationRows() {
        var updatedStates: [String: IntegrationFileAssociationState] = [:]

        for association in Self.supportedFileAssociations {
            var defaultApplications: [(identity: String, url: URL)] = []
            var seenApplicationIdentities: Set<String> = []
            var isCurrentDefault = !association.contentTypes.isEmpty

            for contentType in association.contentTypes {
                guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: contentType)?
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                else {
                    isCurrentDefault = false
                    continue
                }

                if !Self.isCurrentApplication(applicationURL) {
                    isCurrentDefault = false
                }

                let identity = Self.applicationIdentity(for: applicationURL)
                if seenApplicationIdentities.insert(identity).inserted {
                    defaultApplications.append((identity, applicationURL))
                }
            }

            let displayStatus: IntegrationFileAssociationDisplayStatus = switch defaultApplications.count {
            case 0:
                .noDefaultApp
            case 1:
                .defaultApp(Self.applicationDisplayName(at: defaultApplications[0].url))
            default:
                .multipleDefaultApps
            }

            updatedStates[association.primaryTypeIdentifier] = IntegrationFileAssociationState(
                displayStatus: displayStatus,
                isCurrentDefault: isCurrentDefault,
                isPendingUpdate: pendingFileAssociationUpdates.contains(association.primaryTypeIdentifier),
            )
        }

        integrationFileAssociationStates = updatedStates
        integrationTableView?.reloadData()
    }

    func numberOfRows(in _: NSTableView) -> Int {
        Self.supportedFileAssociations.count
    }

    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < Self.supportedFileAssociations.count else {
            return nil
        }

        let association = Self.supportedFileAssociations[row]
        let state = integrationFileAssociationStates[association.primaryTypeIdentifier] ?? IntegrationFileAssociationState(
            displayStatus: .noDefaultApp,
            isCurrentDefault: false,
            isPendingUpdate: false,
        )

        let identifier = NSUserInterfaceItemIdentifier("IntegrationRowCell")
        let cellView = (tableView.makeView(withIdentifier: identifier, owner: self) as? IntegrationRowTableCellView)
            ?? {
                let view = IntegrationRowTableCellView()
                view.identifier = identifier
                return view
            }()
        cellView.configureLayout(titleWidth: LayoutMetrics.integrationArchiveTypeWidth,
                                 statusWidth: LayoutMetrics.integrationDefaultApplicationWidth,
                                 actionWidth: LayoutMetrics.integrationActionButtonWidth)
        cellView.apply(association: association,
                       state: state,
                       target: self,
                       action: #selector(makeDefaultApplicationForFileAssociation(_:)))
        return cellView
    }

    // MARK: - Folders Page (FoldersPage.cpp)

    private func createFoldersPage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let titleLabel = NSTextField(labelWithString: SZL10n.string("app.settings.workingFolderTitle"))
        titleLabel.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(titleLabel)

        let mode = SZSettings.workDirMode

        let systemTempRadio = NSButton(radioButtonWithTitle: SZL10n.string("settings.systemTempFolder"), target: self, action: #selector(workDirModeChanged(_:)))
        systemTempRadio.tag = 0
        systemTempRadio.state = mode == 0 ? .on : .off
        systemTempRadio.setAccessibilityIdentifier("settings.workDirSystemTemp")
        stack.addArrangedSubview(systemTempRadio)

        let currentRadio = NSButton(radioButtonWithTitle: SZL10n.string("settings.current"), target: self, action: #selector(workDirModeChanged(_:)))
        currentRadio.tag = 1
        currentRadio.state = mode == 1 ? .on : .off
        currentRadio.setAccessibilityIdentifier("settings.workDirCurrent")
        stack.addArrangedSubview(currentRadio)

        let specifiedRow = NSStackView()
        specifiedRow.orientation = .horizontal
        specifiedRow.spacing = 8

        let specifiedRadio = NSButton(radioButtonWithTitle: SZL10n.string("settings.specified"), target: self, action: #selector(workDirModeChanged(_:)))
        specifiedRadio.tag = 2
        specifiedRadio.state = mode == 2 ? .on : .off
        specifiedRadio.setAccessibilityIdentifier("settings.workDirSpecified")
        specifiedRow.addArrangedSubview(specifiedRadio)

        let pathField = NSTextField()
        pathField.stringValue = SZSettings.string(.workDirPath)
        pathField.identifier = NSUserInterfaceItemIdentifier(SZSettingsKey.workDirPath.rawValue)
        pathField.isEnabled = mode == 2
        pathField.target = self
        pathField.action = #selector(workDirPathChanged(_:))
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        pathField.setAccessibilityIdentifier("settings.workDirPath")
        specifiedRow.addArrangedSubview(pathField)

        let browseBtn = NSButton(title: "...", target: self, action: #selector(browseWorkDir(_:)))
        browseBtn.widthAnchor.constraint(equalToConstant: 30).isActive = true
        browseBtn.setAccessibilityIdentifier("settings.workDirBrowse")
        specifiedRow.addArrangedSubview(browseBtn)

        stack.addArrangedSubview(specifiedRow)

        let sep = NSBox()
        sep.boxType = .separator
        stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let removableCheck = NSButton(checkboxWithTitle: SZL10n.string("settings.removableDrivesOnly"), target: self, action: #selector(removableOnlyChanged(_:)))
        removableCheck.state = SZSettings.bool(.workDirRemovableOnly) ? .on : .off
        removableCheck.setAccessibilityIdentifier("settings.workDirRemovableOnly")
        stack.addArrangedSubview(removableCheck)

        return makePageView(containing: stack)
    }

    // MARK: - When opening an archive

    private static let launchOpenDelayChoices: [TimeInterval] = [0.0, 1.0, 2.0, 5.0, 10.0]
    private static let launchOpenIndent: CGFloat = 22

    /// Controls enabled only when "Extract immediately" is selected.
    private var launchOpenExtractControls: [NSControl] = []
    private var launchOpenExtractLabels: [NSTextField] = []
    private var launchOpenDelaySlider: NSSlider?
    private var launchOpenDelayField: NSTextField?

    private static let quickLookExpansionDepthFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = NSNumber(value: ArchivePreviewPreferences.maximumExpansionDepth)
        return formatter
    }()

    private func addLaunchOpenSection(to stack: NSStackView) {
        launchOpenExtractControls.removeAll()
        launchOpenExtractLabels.removeAll()
        launchOpenDelaySlider = nil
        launchOpenDelayField = nil

        let separator = makeSettingsSeparator()
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(makeSectionLabel(SZL10n.string("app.settings.launchOpen")))

        let current = SZSettings.launchOpenDefaultAction

        let browseRadio = NSButton(radioButtonWithTitle: SZL10n.string("app.settings.launchOpen.showContents"),
                                   target: self,
                                   action: #selector(launchOpenActionChanged(_:)))
        browseRadio.identifier = NSUserInterfaceItemIdentifier(LaunchOpenAction.browse.rawValue)
        browseRadio.state = current == .browse ? .on : .off
        browseRadio.setAccessibilityIdentifier("settings.launchOpen.browse")
        stack.addArrangedSubview(browseRadio)

        let extractRadio = NSButton(radioButtonWithTitle: SZL10n.string("app.settings.launchOpen.extractImmediately"),
                                    target: self,
                                    action: #selector(launchOpenActionChanged(_:)))
        extractRadio.identifier = NSUserInterfaceItemIdentifier(LaunchOpenAction.extract.rawValue)
        extractRadio.state = current == .extract ? .on : .off
        extractRadio.setAccessibilityIdentifier("settings.launchOpen.extract")
        stack.addArrangedSubview(extractRadio)

        let revealCheck = NSButton(checkboxWithTitle: SZL10n.string("app.settings.launchOpen.revealAfterExtract"),
                                   target: self,
                                   action: #selector(launchOpenRevealChanged(_:)))
        revealCheck.state = SZSettings.launchOpenRevealAfterExtract ? .on : .off
        revealCheck.setAccessibilityIdentifier("settings.launchOpen.reveal")
        stack.addArrangedSubview(indentedRow(revealCheck))
        launchOpenExtractControls.append(revealCheck)

        // Continuous slider with common tick marks; field accepts exact values.
        let cancelLabel = NSTextField(labelWithString: SZL10n.string("app.settings.launchOpen.cancelWindow"))
        let currentDelay = SZSettings.launchOpenDelaySeconds

        let delaySlider = NSSlider(value: launchOpenSliderPosition(forSeconds: currentDelay),
                                   minValue: 0,
                                   maxValue: Double(Self.launchOpenDelayChoices.count - 1),
                                   target: self,
                                   action: #selector(launchOpenDelaySliderChanged(_:)))
        delaySlider.allowsTickMarkValuesOnly = false
        delaySlider.numberOfTickMarks = Self.launchOpenDelayChoices.count
        delaySlider.tickMarkPosition = .below
        delaySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        delaySlider.setAccessibilityIdentifier("settings.launchOpen.cancelWindow")
        launchOpenDelaySlider = delaySlider

        let delayField = NSTextField()
        delayField.alignment = .right
        delayField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        delayField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        delayField.target = self
        delayField.action = #selector(launchOpenDelayFieldChanged(_:))
        delayField.formatter = Self.launchOpenDelayFormatter
        delayField.doubleValue = currentDelay
        delayField.setAccessibilityIdentifier("settings.launchOpen.cancelWindow.field")
        launchOpenDelayField = delayField

        let secondsSuffix = NSTextField(labelWithString: SZL10n.string("app.settings.launchOpen.cancelWindow.secondsSuffix"))
        secondsSuffix.textColor = .secondaryLabelColor

        let delayRow = NSStackView(views: [cancelLabel, delaySlider, delayField, secondsSuffix])
        delayRow.orientation = .horizontal
        delayRow.alignment = .centerY
        delayRow.spacing = 8
        stack.addArrangedSubview(indentedRow(delayRow))
        launchOpenExtractLabels.append(cancelLabel)
        launchOpenExtractLabels.append(secondsSuffix)
        launchOpenExtractControls.append(delaySlider)
        launchOpenExtractControls.append(delayField)

        let modifierLabel = NSTextField(labelWithString: SZL10n.string("app.settings.launchOpen.modifierToInvert"))
        let modifierPopup = NSPopUpButton()
        let currentModifier = SZSettings.launchOpenBrowseModifier
        let modifierChoices: [(LaunchOpenBrowseModifier, String)] = [
            (.none, SZL10n.string("app.settings.launchOpen.modifier.none")),
            (.option, "⌥ Option"),
            (.control, "⌃ Control"),
            (.shift, "⇧ Shift"),
        ]
        for (index, choice) in modifierChoices.enumerated() {
            modifierPopup.addItem(withTitle: choice.1)
            modifierPopup.lastItem?.representedObject = choice.0.rawValue as NSString
            if choice.0 == currentModifier {
                modifierPopup.selectItem(at: index)
            }
        }
        modifierPopup.target = self
        modifierPopup.action = #selector(launchOpenModifierChanged(_:))
        modifierPopup.setAccessibilityIdentifier("settings.launchOpen.modifier")

        let modifierRow = NSStackView(views: [modifierLabel, modifierPopup])
        modifierRow.orientation = .horizontal
        modifierRow.alignment = .centerY
        modifierRow.spacing = 8
        stack.addArrangedSubview(indentedRow(modifierRow))
        launchOpenExtractLabels.append(modifierLabel)
        launchOpenExtractControls.append(modifierPopup)

        updateLaunchOpenExtractControlsEnabled()
    }

    private func addQuickLookSection(to stack: NSStackView) {
        let separator = makeSettingsSeparator()
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(makeSectionLabel("Quick Look"))

        let depthLabel = NSTextField(labelWithString: SZL10n.string("app.settings.quickLookExpansionDepth"))
        let depthField = NSTextField()
        depthField.alignment = .right
        depthField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                     weight: .regular)
        depthField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        depthField.formatter = Self.quickLookExpansionDepthFormatter
        depthField.integerValue = SZSettings.quickLookPreviewExpansionDepth
        depthField.target = self
        depthField.action = #selector(quickLookExpansionDepthChanged(_:))
        depthField.delegate = self
        depthField.identifier = NSUserInterfaceItemIdentifier(LayoutMetrics.quickLookExpansionDepthIdentifier)
        depthField.setAccessibilityIdentifier(LayoutMetrics.quickLookExpansionDepthIdentifier)

        let levelsLabel = NSTextField(labelWithString: SZL10n.string("app.settings.quickLookExpansionDepthLevels"))
        levelsLabel.textColor = .secondaryLabelColor

        let depthRow = NSStackView(views: [depthLabel, depthField, levelsLabel])
        depthRow.orientation = .horizontal
        depthRow.alignment = .centerY
        depthRow.spacing = 8
        stack.addArrangedSubview(depthRow)
    }

    private func indentedRow(_ view: NSView) -> NSView {
        let container = NSStackView(views: [view])
        container.orientation = .horizontal
        container.edgeInsets = NSEdgeInsets(top: 0, left: Self.launchOpenIndent, bottom: 0, right: 0)
        return container
    }

    private static let launchOpenDelayFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        f.minimum = 0
        f.allowsFloats = true
        return f
    }()

    /// Map seconds to the slider's nonuniform tick scale.
    private func launchOpenSliderPosition(forSeconds seconds: TimeInterval) -> Double {
        let choices = Self.launchOpenDelayChoices
        if seconds <= choices.first ?? 0 { return 0 }
        if seconds >= choices.last ?? 0 { return Double(choices.count - 1) }
        for i in 0 ..< (choices.count - 1) {
            let lo = choices[i], hi = choices[i + 1]
            if seconds >= lo, seconds <= hi {
                let span = hi - lo
                let frac = span > 0 ? (seconds - lo) / span : 0
                return Double(i) + frac
            }
        }
        return Double(choices.count - 1)
    }

    /// Map slider position back to seconds, rounded to 0.1s.
    private func launchOpenSeconds(forSliderPosition position: Double) -> TimeInterval {
        let choices = Self.launchOpenDelayChoices
        let clamped = max(0, min(Double(choices.count - 1), position))
        let lo = Int(clamped.rounded(.down))
        let hi = min(lo + 1, choices.count - 1)
        let frac = clamped - Double(lo)
        let value = choices[lo] + (choices[hi] - choices[lo]) * frac
        return (value * 10).rounded() / 10
    }

    private func updateLaunchOpenExtractControlsEnabled() {
        let enabled = SZSettings.launchOpenDefaultAction == .extract
        for control in launchOpenExtractControls {
            control.isEnabled = enabled
        }
        for label in launchOpenExtractLabels {
            label.textColor = enabled ? .labelColor : .disabledControlTextColor
        }
    }

    // MARK: - Actions

    @objc private func settingsCheckboxChanged(_ sender: NSButton) {
        guard let keyStr = sender.identifier?.rawValue,
              let key = SZSettingsKey(rawValue: keyStr) else { return }
        SZSettings.set(sender.state == .on, for: key)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let selectedItem = sender.selectedItem,
              let localeCode = selectedItem.representedObject as? String
        else { return }

        SZSettings.set(localeCode, for: .languageOverride)
        SZL10n.reloadBundle()

        // Rebuild UI with new language
        window?.title = SZL10n.string("settings.options")
        let selectedTab = tabSegmentedControl.selectedSegment
        for subview in window?.contentView?.subviews ?? [] {
            subview.removeFromSuperview()
        }
        shortcutRecorders.removeAll()
        setupUI()
        tabSegmentedControl.selectedSegment = selectedTab
        tabView.selectTabViewItem(at: selectedTab)
        resizeWindowToFitSelectedTab(animated: false)

        NotificationCenter.default.post(name: .szLanguageDidChange, object: nil)
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

    @objc private func statusBarSizeModeChanged(_ sender: NSPopUpButton) {
        SZSettings.set(sender.selectedItem?.tag ?? 0, for: .statusBarSizeMode)
    }

    @objc private func launchOpenActionChanged(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let action = LaunchOpenAction(rawValue: rawValue)
        else { return }
        SZSettings.launchOpenDefaultAction = action
        updateLaunchOpenExtractControlsEnabled()
    }

    @objc private func launchOpenRevealChanged(_ sender: NSButton) {
        SZSettings.launchOpenRevealAfterExtract = sender.state == .on
    }

    @objc private func launchOpenDelaySliderChanged(_ sender: NSSlider) {
        let seconds = launchOpenSeconds(forSliderPosition: sender.doubleValue)
        SZSettings.launchOpenDelaySeconds = seconds
        launchOpenDelayField?.doubleValue = seconds
    }

    @objc private func launchOpenDelayFieldChanged(_ sender: NSTextField) {
        let seconds = max(0, sender.doubleValue)
        SZSettings.launchOpenDelaySeconds = seconds
        launchOpenDelaySlider?.doubleValue = launchOpenSliderPosition(forSeconds: seconds)
        sender.doubleValue = seconds
    }

    @objc private func launchOpenModifierChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let modifier = LaunchOpenBrowseModifier(rawValue: rawValue)
        else { return }
        SZSettings.launchOpenBrowseModifier = modifier
    }

    @objc private func quickLookExpansionDepthChanged(_ sender: NSTextField) {
        let depth = persistQuickLookExpansionDepth(from: sender)
        sender.integerValue = depth
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField,
              textField.identifier?.rawValue == LayoutMetrics.quickLookExpansionDepthIdentifier
        else {
            return
        }

        persistValidQuickLookExpansionDepth(from: textField)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField,
              textField.identifier?.rawValue == LayoutMetrics.quickLookExpansionDepthIdentifier
        else {
            return
        }

        let depth = persistQuickLookExpansionDepth(from: textField)
        textField.integerValue = depth
    }

    @discardableResult
    private func persistQuickLookExpansionDepth(from textField: NSTextField) -> Int {
        let depth = ArchivePreviewPreferences.normalizedExpansionDepth(textField.integerValue)
        SZSettings.quickLookPreviewExpansionDepth = depth
        return depth
    }

    private func persistValidQuickLookExpansionDepth(from textField: NSTextField) {
        let trimmedValue = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let depth = Int(trimmedValue),
              (0 ... ArchivePreviewPreferences.maximumExpansionDepth).contains(depth)
        else {
            return
        }

        SZSettings.quickLookPreviewExpansionDepth = depth
    }

    @objc private func shortcutPresetChanged(_ sender: NSPopUpButton) {
        guard !isUpdatingShortcutControls else { return }

        let previousPreset = SZSettings.fileManagerShortcutPreset
        guard let selectedItem = sender.selectedItem,
              let preset = FileManagerShortcutPreset(rawValue: selectedItem.tag)
        else {
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
              let command = FileManagerShortcutCommand(rawValue: commandRawValue)
        else {
            return
        }

        updateShortcutBinding(for: command, to: nil)
    }

    @objc private func resetFileListPreferences(_: NSButton) {
        guard confirmSettingsAction(SZL10n.string("app.settings.resetFileListLayout"),
                                    informativeText: SZL10n.string("app.settings.resetFileListLayoutConfirmDetail"))
        else { return }

        FileManagerViewPreferences.removeAllListViewInfos()
    }

    @objc private func rememberWindowFrameChanged(_ sender: NSButton) {
        FileManagerWindowPreferences.setRemembersWindowFrame(sender.state == .on)
    }

    @objc private func resetFileManagerWindowFrame(_: NSButton) {
        guard confirmSettingsAction(SZL10n.string("app.settings.resetFileManagerWindowFrame")) else { return }
        FileManagerWindowPreferences.resetSavedWindowFrame()
    }

    private func confirmSettingsAction(_ actionTitle: String,
                                       informativeText: String? = nil) -> Bool
    {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = SZL10n.string("app.settings.confirmActionFormat", actionTitle)
        if let informativeText {
            alert.informativeText = informativeText
        }
        alert.addButton(withTitle: SZL10n.string("app.settings.reset"))
        alert.addButton(withTitle: SZL10n.string("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
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

    @objc private func openFinderQuickActionsSettings(_: Any?) {
        guard let url = Self.finderQuickActionsSettingsURL,
              NSWorkspace.shared.open(url)
        else {
            let alert = NSAlert()
            alert.messageText = SZL10n.string("app.settings.quickActionsOpenError")
            alert.informativeText = SZL10n.string("app.settings.quickActionsOpenErrorDetail", AppBuildInfo.appDisplayName())
            alert.runModal()
            return
        }
    }

    @objc private func makeDefaultApplicationForAllFileAssociations(_: NSButton) {
        let nonDefaultAssociations = Self.supportedFileAssociations.filter { association in
            let state = integrationFileAssociationStates[association.primaryTypeIdentifier]
            return !(state?.isCurrentDefault ?? false)
        }
        guard !nonDefaultAssociations.isEmpty else { return }

        var allContentTypes: [(contentType: UTType, primaryTypeIdentifier: String)] = []
        for association in nonDefaultAssociations {
            pendingFileAssociationUpdates.insert(association.primaryTypeIdentifier)
            for contentType in association.contentTypes {
                allContentTypes.append((contentType, association.primaryTypeIdentifier))
            }
        }
        refreshIntegrationFileAssociationRows()

        let updateState = IntegrationFileAssociationUpdateState(remainingUpdates: allContentTypes.count)
        let currentApplicationURL = Self.currentApplicationURL()

        for entry in allContentTypes {
            NSWorkspace.shared.setDefaultApplication(at: currentApplicationURL,
                                                     toOpen: entry.contentType)
            { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    let result = await updateState.recordCompletion(error: error)
                    guard result.isFinished else {
                        return
                    }

                    for association in nonDefaultAssociations {
                        pendingFileAssociationUpdates.remove(association.primaryTypeIdentifier)
                    }
                    refreshIntegrationFileAssociationRows()

                    if result.failureCount > 0 {
                        presentDefaultOpenerFailureAlert(failureCount: result.failureCount)
                    }
                }
            }
        }
    }

    @objc private func makeDefaultApplicationForFileAssociation(_ sender: NSButton) {
        guard let typeIdentifier = sender.identifier?.rawValue,
              let association = Self.supportedFileAssociations.first(where: { $0.primaryTypeIdentifier == typeIdentifier })
        else {
            return
        }

        pendingFileAssociationUpdates.insert(typeIdentifier)
        refreshIntegrationFileAssociationRows()

        let updateState = IntegrationFileAssociationUpdateState(remainingUpdates: association.contentTypes.count)
        let currentApplicationURL = Self.currentApplicationURL()

        for contentType in association.contentTypes {
            NSWorkspace.shared.setDefaultApplication(at: currentApplicationURL,
                                                     toOpen: contentType)
            { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    let result = await updateState.recordCompletion(error: error)
                    guard result.isFinished else {
                        return
                    }

                    pendingFileAssociationUpdates.remove(typeIdentifier)
                    refreshIntegrationFileAssociationRows()

                    if result.failureCount > 0 {
                        presentDefaultOpenerFailureAlert(failureCount: result.failureCount)
                    }
                }
            }
        }
    }

    private func presentDefaultOpenerFailureAlert(failureCount: Int) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = SZL10n.string("app.settings.defaultOpenerFailedTitle")
        alert.informativeText = SZL10n.string("app.settings.defaultOpenerFailedDetail", failureCount)
        alert.runModal()
    }
}
