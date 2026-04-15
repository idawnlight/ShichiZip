import Cocoa
import UniformTypeIdentifiers

// MARK: - Settings Window Controller (matches Windows 7-Zip Options dialog)

private final class SettingsPageContainerView: NSView {
    private let contentStack: NSStackView
    private let contentInsets: NSEdgeInsets

    init(contentStack: NSStackView,
         contentInsets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 16, right: 16))
    {
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
    required init?(coder _: NSCoder) {
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
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        stopRecording()
    }

    @objc private func toggleRecording(_: Any?) {
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
            guard let self, isRecording else {
                return event
            }

            return capture(event)
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
                string: SZL10n.string("app.settings.typeShortcut"),
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.controlAccentColor,
                ],
            )
            return
        }

        if let shortcut {
            attributedTitle = NSAttributedString(
                string: shortcut.displayName,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ],
            )
            return
        }

        let placeholderFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        attributedTitle = NSAttributedString(
            string: SZL10n.string("app.settings.recordShortcut"),
            attributes: [
                .font: placeholderFont,
                .foregroundColor: NSColor.placeholderTextColor,
            ],
        )
    }
}

private struct IntegrationFileAssociation {
    let displayName: String
    let handlerRank: String
    let contentTypeIdentifiers: [String]

    var primaryTypeIdentifier: String {
        contentTypeIdentifiers[0]
    }

    var contentTypes: [UTType] {
        contentTypeIdentifiers.map { UTType(importedAs: $0) }
    }

    var isDefaultRanked: Bool {
        handlerRank == "Default"
    }

    private static let excludedTypeIdentifiers: Set<String> = [
        "public.data",
        "com.aone.keka-extraction",
    ]

    static func supportedDocumentTypes(bundle: Bundle = .main) -> [IntegrationFileAssociation] {
        guard let documentTypes = bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] else {
            return []
        }

        return documentTypes.compactMap { documentType in
            guard let displayName = documentType["CFBundleTypeName"] as? String,
                  let declaredContentTypes = documentType["LSItemContentTypes"] as? [String]
            else {
                return nil
            }

            let contentTypeIdentifiers = declaredContentTypes.filter { !excludedTypeIdentifiers.contains($0) }
            guard !contentTypeIdentifiers.isEmpty else {
                return nil
            }

            return IntegrationFileAssociation(displayName: displayName,
                                              handlerRank: documentType["LSHandlerRank"] as? String ?? "Alternate",
                                              contentTypeIdentifiers: contentTypeIdentifiers)
        }
    }

    static func integrationDocumentTypes(bundle: Bundle = .main) -> [IntegrationFileAssociation] {
        supportedDocumentTypes(bundle: bundle).filter(\.isDefaultRanked)
    }
}

private enum IntegrationFileAssociationDisplayStatus {
    case noDefaultApp
    case defaultApp(String)
    case multipleDefaultApps
}

private struct IntegrationFileAssociationState {
    let displayStatus: IntegrationFileAssociationDisplayStatus
    let isCurrentDefault: Bool
    let isPendingUpdate: Bool
}

private actor IntegrationFileAssociationUpdateState {
    var remainingUpdates: Int
    var failureCount: Int = 0

    init(remainingUpdates: Int) {
        self.remainingUpdates = remainingUpdates
    }

    func recordCompletion(error: Error?) -> (isFinished: Bool, failureCount: Int) {
        if let error {
            let nsError = error as NSError
            if nsError.code != NSUserCancelledError {
                failureCount += 1
            }
        }

        remainingUpdates -= 1
        return (remainingUpdates == 0, failureCount)
    }
}

private final class IntegrationStatusView: NSView {
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(displayStatus: IntegrationFileAssociationDisplayStatus) {
        switch displayStatus {
        case .noDefaultApp:
            label.stringValue = SZL10n.string("app.settings.noDefaultApp")
            label.textColor = .placeholderTextColor

        case let .defaultApp(displayName):
            label.stringValue = displayName
            label.textColor = .labelColor

        case .multipleDefaultApps:
            label.stringValue = SZL10n.string("app.settings.multipleDefaultApps")
            label.textColor = .secondaryLabelColor
        }
    }
}

private final class IntegrationRowTableCellView: NSTableCellView {
    private let rowStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusView = IntegrationStatusView()
    let actionButton = NSButton(title: "", target: nil, action: nil)
    private var titleWidthConstraint: NSLayoutConstraint?
    private var statusWidthConstraint: NSLayoutConstraint?
    private var actionWidthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 12
        addSubview(rowStack)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        rowStack.addArrangedSubview(titleLabel)

        statusView.setContentCompressionResistancePriority(.required, for: .horizontal)
        rowStack.addArrangedSubview(statusView)

        actionButton.bezelStyle = .rounded
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        rowStack.addArrangedSubview(actionButton)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configureLayout(titleWidth: CGFloat,
                         statusWidth: CGFloat,
                         actionWidth: CGFloat)
    {
        if let titleWidthConstraint {
            titleWidthConstraint.constant = titleWidth
        } else {
            let constraint = titleLabel.widthAnchor.constraint(equalToConstant: titleWidth)
            constraint.isActive = true
            titleWidthConstraint = constraint
        }

        if let statusWidthConstraint {
            statusWidthConstraint.constant = statusWidth
        } else {
            let constraint = statusView.widthAnchor.constraint(equalToConstant: statusWidth)
            constraint.isActive = true
            statusWidthConstraint = constraint
        }

        if let actionWidthConstraint {
            actionWidthConstraint.constant = actionWidth
        } else {
            let constraint = actionButton.widthAnchor.constraint(equalToConstant: actionWidth)
            constraint.isActive = true
            actionWidthConstraint = constraint
        }
    }

    func apply(association: IntegrationFileAssociation,
               state: IntegrationFileAssociationState,
               target: AnyObject?,
               action: Selector)
    {
        titleLabel.stringValue = association.displayName
        statusView.apply(displayStatus: state.displayStatus)
        actionButton.title = state.isCurrentDefault
            ? SZL10n.string("app.settings.currentDefault")
            : SZL10n.string("app.settings.makeDefault")
        actionButton.isEnabled = !state.isCurrentDefault && !state.isPendingUpdate
        actionButton.identifier = NSUserInterfaceItemIdentifier(association.primaryTypeIdentifier)
        actionButton.setAccessibilityIdentifier("settings.makeDefault.\(association.primaryTypeIdentifier)")
        actionButton.target = target
        actionButton.action = action
    }
}

class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private enum LayoutMetrics {
        static let outerInset: CGFloat = 12
        static let segmentSpacing: CGFloat = 12
        static let integrationContentWidth: CGFloat = 480
        static let integrationListHeight: CGFloat = 240
        static let integrationArchiveTypeWidth: CGFloat = 200
        static let integrationDefaultApplicationWidth: CGFloat = 120
        static let integrationActionButtonWidth: CGFloat = 124
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

    private static let supportedFileAssociations = IntegrationFileAssociation.integrationDocumentTypes()
    private static let finderQuickActionsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.services")

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
        setupUI()
    }

    override func showWindow(_ sender: Any?) {
        window?.title = SZL10n.string("settings.options")
        super.showWindow(sender)
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

        let currentRadio = NSButton(radioButtonWithTitle: SZL10n.string("app.settings.currentFolder"), target: self, action: #selector(workDirModeChanged(_:)))
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
