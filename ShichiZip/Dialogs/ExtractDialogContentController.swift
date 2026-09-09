import Cocoa

struct ExtractDialogOption<Value: Equatable> {
    let title: String
    let value: Value
}

struct ExtractDialogState: Equatable {
    var destinationPath: String
    var pathMode: SZPathMode
    var overwriteMode: SZOverwriteMode
    var password: String
    var preserveNtSecurityInfo: Bool
    var eliminateDuplicates: Bool
    var splitDestination: Bool
    var splitName: String
    var showPassword: Bool
    var moveArchiveToTrashAfterExtraction: Bool
    var inheritDownloadedFileQuarantine: Bool
    var revealAfterExtractInFileManager: Bool
}

struct ExtractDialogResolvedResult {
    let baseDestinationURL: URL
    let result: ExtractDialogResult
}

struct ExtractDialogResultBuilder {
    let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory.standardizedFileURL
    }

    func buildResult(from state: ExtractDialogState) throws -> ExtractDialogResolvedResult {
        let baseDestinationURL = try resolveDestinationDirectoryURL(from: state.destinationPath)
        let destinationURL = try resolveFinalDestinationURL(baseDestinationURL: baseDestinationURL,
                                                            splitDestination: state.splitDestination,
                                                            splitName: state.splitName)
        let result = ExtractDialogResult(destinationURL: destinationURL,
                                         overwriteMode: state.overwriteMode,
                                         pathMode: state.pathMode,
                                         password: Self.normalizedPassword(from: state.password),
                                         preserveNtSecurityInfo: state.preserveNtSecurityInfo,
                                         eliminateDuplicates: state.eliminateDuplicates,
                                         moveArchiveToTrashAfterExtraction: state.moveArchiveToTrashAfterExtraction,
                                         inheritDownloadedFileQuarantine: state.inheritDownloadedFileQuarantine,
                                         revealAfterExtractInFileManager: state.revealAfterExtractInFileManager)
        return ExtractDialogResolvedResult(baseDestinationURL: baseDestinationURL,
                                           result: result)
    }

    static func normalizedPassword(from rawValue: String) -> String? {
        rawValue.isEmpty ? nil : rawValue
    }

    private func resolveDestinationDirectoryURL(from enteredPath: String) throws -> URL {
        let trimmedPath = enteredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileNoSuchFileError,
                          userInfo: [NSLocalizedDescriptionKey: SZL10n.string("fileop.selectDestination")])
        }

        let standardizedURL = szStandardizedFileURL(fromUserPath: trimmedPath,
                                                    relativeTo: baseDirectory)
        if let itemKind = FileManager.default.szExistingItemKind(at: standardizedURL) {
            guard itemKind == .directory else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteInvalidFileNameError,
                              userInfo: [
                                  NSFilePathErrorKey: standardizedURL.path,
                                  NSLocalizedDescriptionKey: "The destination path must be a folder.",
                              ])
            }
            return standardizedURL
        }

        return standardizedURL
    }

    private func resolveFinalDestinationURL(baseDestinationURL: URL,
                                            splitDestination: Bool,
                                            splitName: String) throws -> URL
    {
        guard splitDestination else {
            return baseDestinationURL
        }

        let trimmedName = splitName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileWriteInvalidFileNameError,
                          userInfo: [NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.enterFolderName")])
        }

        return baseDestinationURL.appendingPathComponent(trimmedName, isDirectory: true).standardizedFileURL
    }
}

@MainActor
final class ExtractDialogContentController: NSObject {
    @MainActor
    private final class DestinationPicker: NSObject {
        private weak var ownerWindow: NSWindow?
        private weak var pathField: NSComboBox?
        private let baseDirectory: URL

        init(ownerWindow: NSWindow?,
             pathField: NSComboBox,
             baseDirectory: URL)
        {
            self.ownerWindow = ownerWindow
            self.pathField = pathField
            self.baseDirectory = baseDirectory.standardizedFileURL
        }

        @objc func browse(_: Any?) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = SZL10n.string("app.choose")
            panel.message = SZL10n.string("app.chooseDestination")
            panel.directoryURL = suggestedDirectoryURL()

            panel.szBeginSheetOrRunModal(for: ownerWindow) { [weak self] response in
                guard response == .OK, let url = panel.url else {
                    return
                }
                self?.pathField?.stringValue = url.standardizedFileURL.path
            }
        }

        private func suggestedDirectoryURL() -> URL {
            guard let pathField else {
                return baseDirectory
            }

            let currentValue = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !currentValue.isEmpty else {
                return baseDirectory
            }

            let standardizedURL = szStandardizedFileURL(fromUserPath: currentValue,
                                                        relativeTo: baseDirectory)
            if let itemKind = FileManager.default.szExistingItemKind(at: standardizedURL) {
                return itemKind == .directory ? standardizedURL : standardizedURL.deletingLastPathComponent()
            }

            return standardizedURL.deletingLastPathComponent()
        }
    }

    private let baseDirectory: URL
    private let pathModeOptions: [ExtractDialogOption<SZPathMode>]
    private let overwriteModeOptions: [ExtractDialogOption<SZOverwriteMode>]
    private let sourceArchiveAvailableForMoveToTrash: Bool
    private let sourceArchiveAvailableForQuarantineInheritance: Bool
    private let pathField = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
    private let browseButton = NSButton(title: SZL10n.string("compress.browse"), target: nil, action: nil)
    private let pathModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let overwriteModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let splitDestinationCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let splitNameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    private let securePasswordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    private let plainPasswordField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    private let showPasswordCheckbox = NSButton(checkboxWithTitle: SZL10n.string("password.showPassword"), target: nil, action: nil)
    private let ntSecurityCheckbox = NSButton(checkboxWithTitle: SZL10n.string("extract.restoreSecurity"), target: nil, action: nil)
    private let eliminateDuplicatesCheckbox = NSButton(checkboxWithTitle: SZL10n.string("extract.eliminateDuplication"), target: nil, action: nil)
    private let moveArchiveToTrashCheckbox = NSButton(checkboxWithTitle: SZL10n.string("app.extract.moveToTrash"), target: nil, action: nil)
    private let inheritDownloadedFileQuarantineCheckbox = NSButton(checkboxWithTitle: SZL10n.string("app.extract.inheritQuarantine"), target: nil, action: nil)
    private let revealAfterExtractInFileManagerCheckbox = NSButton(checkboxWithTitle: SZL10n.string("app.fileManager.revealAfterExtract"), target: nil, action: nil)
    private var destinationPicker: DestinationPicker?

    private(set) var view = NSView()
    private(set) var state: ExtractDialogState

    var preferredFirstResponder: NSView {
        pathField
    }

    init(state: ExtractDialogState,
         pathModeOptions: [ExtractDialogOption<SZPathMode>],
         overwriteModeOptions: [ExtractDialogOption<SZOverwriteMode>],
         destinationHistoryEntries: [String],
         baseDirectory: URL,
         sourceArchiveAvailableForMoveToTrash: Bool,
         sourceArchiveAvailableForQuarantineInheritance: Bool)
    {
        self.state = state
        self.pathModeOptions = pathModeOptions
        self.overwriteModeOptions = overwriteModeOptions
        self.baseDirectory = baseDirectory.standardizedFileURL
        self.sourceArchiveAvailableForMoveToTrash = sourceArchiveAvailableForMoveToTrash
        self.sourceArchiveAvailableForQuarantineInheritance = sourceArchiveAvailableForQuarantineInheritance

        super.init()

        configureControls(destinationHistoryEntries: destinationHistoryEntries)
        view = makeAccessoryView()
        updateSplitDestinationUI()
        updatePasswordVisibilityUI(moveFocus: false)
    }

    func attach(to ownerWindow: NSWindow?) {
        let picker = DestinationPicker(ownerWindow: ownerWindow,
                                       pathField: pathField,
                                       baseDirectory: baseDirectory)
        destinationPicker = picker
        browseButton.target = picker
        browseButton.action = #selector(DestinationPicker.browse(_:))
    }

    func updateStateFromControls() {
        state.destinationPath = pathField.stringValue
        state.splitDestination = splitDestinationCheckbox.state == .on
        state.splitName = splitNameField.stringValue
        state.password = visiblePasswordValue()
        state.showPassword = showPasswordCheckbox.state == .on
        state.pathMode = selectedValue(from: pathModeOptions,
                                       popup: pathModePopup,
                                       fallback: state.pathMode)
        state.overwriteMode = selectedValue(from: overwriteModeOptions,
                                            popup: overwriteModePopup,
                                            fallback: state.overwriteMode)
        state.preserveNtSecurityInfo = ntSecurityCheckbox.state == .on
        state.eliminateDuplicates = eliminateDuplicatesCheckbox.state == .on
        state.moveArchiveToTrashAfterExtraction = moveArchiveToTrashCheckbox.state == .on
        state.inheritDownloadedFileQuarantine = inheritDownloadedFileQuarantineCheckbox.state == .on
        state.revealAfterExtractInFileManager = revealAfterExtractInFileManagerCheckbox.state == .on
    }

    private func configureControls(destinationHistoryEntries: [String]) {
        pathField.isEditable = true
        pathField.usesDataSource = false
        pathField.completes = false
        pathField.addItems(withObjectValues: destinationHistoryEntries)
        pathField.stringValue = state.destinationPath
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        pathField.setAccessibilityIdentifier("extract.destinationPath")

        browseButton.bezelStyle = .rounded
        browseButton.setContentHuggingPriority(.required, for: .horizontal)
        browseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        browseButton.setAccessibilityIdentifier("extract.browseButton")

        pathModeOptions.forEach { pathModePopup.addItem(withTitle: $0.title) }
        select(state.pathMode, in: pathModePopup, options: pathModeOptions)
        pathModePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        pathModePopup.setAccessibilityIdentifier("extract.pathMode")

        overwriteModeOptions.forEach { overwriteModePopup.addItem(withTitle: $0.title) }
        select(state.overwriteMode, in: overwriteModePopup, options: overwriteModeOptions)
        overwriteModePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        overwriteModePopup.setAccessibilityIdentifier("extract.overwriteMode")

        splitDestinationCheckbox.target = self
        splitDestinationCheckbox.action = #selector(splitDestinationToggled(_:))
        splitDestinationCheckbox.state = state.splitDestination ? .on : .off
        splitDestinationCheckbox.toolTip = SZL10n.string("app.extract.createSeparateFolder")
        splitDestinationCheckbox.setAccessibilityLabel(SZL10n.string("app.extract.createSeparateFolder"))
        splitDestinationCheckbox.setAccessibilityIdentifier("extract.splitDestination")

        splitNameField.placeholderString = "Archive"
        splitNameField.stringValue = state.splitName
        splitNameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        splitNameField.setAccessibilityIdentifier("extract.splitName")

        securePasswordField.placeholderString = SZL10n.string("app.optional")
        securePasswordField.stringValue = state.password
        securePasswordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        securePasswordField.setAccessibilityIdentifier("extract.password")

        plainPasswordField.placeholderString = SZL10n.string("app.optional")
        plainPasswordField.stringValue = state.password
        plainPasswordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        plainPasswordField.setAccessibilityIdentifier("extract.passwordPlain")

        showPasswordCheckbox.target = self
        showPasswordCheckbox.action = #selector(showPasswordToggled(_:))
        showPasswordCheckbox.state = state.showPassword ? .on : .off
        showPasswordCheckbox.setAccessibilityIdentifier("extract.showPassword")

        ntSecurityCheckbox.state = state.preserveNtSecurityInfo ? .on : .off
        ntSecurityCheckbox.setAccessibilityIdentifier("extract.ntSecurity")

        eliminateDuplicatesCheckbox.state = state.eliminateDuplicates ? .on : .off
        eliminateDuplicatesCheckbox.setAccessibilityIdentifier("extract.eliminateDuplicates")

        moveArchiveToTrashCheckbox.state = state.moveArchiveToTrashAfterExtraction ? .on : .off
        moveArchiveToTrashCheckbox.isEnabled = sourceArchiveAvailableForMoveToTrash
        moveArchiveToTrashCheckbox.alphaValue = sourceArchiveAvailableForMoveToTrash ? 1.0 : 0.55
        moveArchiveToTrashCheckbox.setAccessibilityIdentifier("extract.moveToTrash")

        inheritDownloadedFileQuarantineCheckbox.state = state.inheritDownloadedFileQuarantine ? .on : .off
        inheritDownloadedFileQuarantineCheckbox.isEnabled = sourceArchiveAvailableForQuarantineInheritance
        inheritDownloadedFileQuarantineCheckbox.alphaValue = sourceArchiveAvailableForQuarantineInheritance ? 1.0 : 0.55
        inheritDownloadedFileQuarantineCheckbox.setAccessibilityIdentifier("extract.inheritQuarantine")

        revealAfterExtractInFileManagerCheckbox.state = state.revealAfterExtractInFileManager ? .on : .off
        revealAfterExtractInFileManagerCheckbox.setAccessibilityIdentifier("extract.revealInFinder")
    }

    private func makeAccessoryView() -> NSView {
        let pathRow = NSStackView(views: [pathField, browseButton])
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 8
        pathRow.distribution = .fill

        let splitRow = NSStackView(views: [splitDestinationCheckbox, splitNameField])
        splitRow.orientation = .horizontal
        splitRow.alignment = .centerY
        splitRow.spacing = 8
        splitRow.distribution = .fill

        let passwordContainer = makePasswordContainer()
        let formStack = NSStackView(views: [
            makeFormRow(label: SZL10n.string("extract.extractTo"), control: pathRow),
            makeFormRow(label: SZL10n.string("app.extract.separateFolder"), control: splitRow),
            makeFormRow(label: SZL10n.string("extract.pathMode"), control: pathModePopup),
            makeFormRow(label: SZL10n.string("extract.overwriteMode"), control: overwriteModePopup),
            makeFormRow(label: SZL10n.string("password.password") + ":", control: passwordContainer),
        ])
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 10

        let passwordOptionsRow = NSStackView(views: [NSView(), showPasswordCheckbox])
        passwordOptionsRow.orientation = .horizontal
        passwordOptionsRow.alignment = .centerY
        passwordOptionsRow.spacing = 12
        passwordOptionsRow.distribution = .fill
        passwordOptionsRow.views.first?.widthAnchor.constraint(equalToConstant: 128).isActive = true
        formStack.addArrangedSubview(passwordOptionsRow)

        let optionsLabel = NSTextField(labelWithString: SZL10n.string("compress.options"))
        optionsLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let optionsStack = NSStackView(views: [
            revealAfterExtractInFileManagerCheckbox,
            moveArchiveToTrashCheckbox,
            inheritDownloadedFileQuarantineCheckbox,
            ntSecurityCheckbox,
            eliminateDuplicatesCheckbox,
        ])
        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 8

        let contentStack = NSStackView(views: [formStack, optionsLabel, optionsStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(contentStack)

        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalToConstant: 520),
            contentStack.topAnchor.constraint(equalTo: wrapper.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])

        return wrapper
    }

    private func makePasswordContainer() -> NSView {
        let passwordContainer = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        passwordContainer.translatesAutoresizingMaskIntoConstraints = false
        passwordContainer.addSubview(securePasswordField)
        passwordContainer.addSubview(plainPasswordField)
        securePasswordField.translatesAutoresizingMaskIntoConstraints = false
        plainPasswordField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            passwordContainer.widthAnchor.constraint(equalToConstant: 300),
            passwordContainer.heightAnchor.constraint(equalToConstant: 24),
            securePasswordField.topAnchor.constraint(equalTo: passwordContainer.topAnchor),
            securePasswordField.leadingAnchor.constraint(equalTo: passwordContainer.leadingAnchor),
            securePasswordField.trailingAnchor.constraint(equalTo: passwordContainer.trailingAnchor),
            securePasswordField.bottomAnchor.constraint(equalTo: passwordContainer.bottomAnchor),
            plainPasswordField.topAnchor.constraint(equalTo: passwordContainer.topAnchor),
            plainPasswordField.leadingAnchor.constraint(equalTo: passwordContainer.leadingAnchor),
            plainPasswordField.trailingAnchor.constraint(equalTo: passwordContainer.trailingAnchor),
            plainPasswordField.bottomAnchor.constraint(equalTo: passwordContainer.bottomAnchor),
        ])
        return passwordContainer
    }

    private func makeFormRow(label title: String, control: NSView) -> NSView {
        let label = makeLabel(title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 128).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.distribution = .fill
        return row
    }

    private func makeLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        return label
    }

    private func select<Value>(_ value: Value,
                               in popup: NSPopUpButton,
                               options: [ExtractDialogOption<Value>])
    {
        if let selectedIndex = options.firstIndex(where: { $0.value == value }) {
            popup.selectItem(at: selectedIndex)
        }
    }

    private func selectedValue<Value>(from options: [ExtractDialogOption<Value>],
                                      popup: NSPopUpButton,
                                      fallback: Value) -> Value
    {
        let index = popup.indexOfSelectedItem
        guard options.indices.contains(index) else {
            return fallback
        }
        return options[index].value
    }

    private func visiblePasswordValue() -> String {
        if plainPasswordField.isEnabled, !plainPasswordField.isHidden {
            return plainPasswordField.stringValue
        }
        return securePasswordField.stringValue
    }

    @objc private func splitDestinationToggled(_: Any?) {
        updateSplitDestinationUI()
    }

    @objc private func showPasswordToggled(_: Any?) {
        updatePasswordVisibilityUI(moveFocus: true)
    }

    private func updateSplitDestinationUI() {
        let enabled = splitDestinationCheckbox.state == .on
        splitNameField.isEnabled = enabled
        splitNameField.alphaValue = enabled ? 1.0 : 0.55
    }

    private func updatePasswordVisibilityUI(moveFocus: Bool) {
        let currentValue = visiblePasswordValue()
        let showPassword = showPasswordCheckbox.state == .on

        securePasswordField.stringValue = currentValue
        plainPasswordField.stringValue = currentValue
        securePasswordField.isHidden = showPassword
        securePasswordField.isEnabled = !showPassword
        plainPasswordField.isHidden = !showPassword
        plainPasswordField.isEnabled = showPassword

        guard moveFocus,
              let currentDialogWindow = view.window
        else {
            return
        }

        if showPassword {
            currentDialogWindow.makeFirstResponder(plainPasswordField)
        } else {
            currentDialogWindow.makeFirstResponder(securePasswordField)
        }
    }
}
