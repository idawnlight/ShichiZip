import Cocoa

struct ExtractDialogResult {
    let destinationURL: URL
    let overwriteMode: SZOverwriteMode
    let pathMode: SZPathMode
    let password: String?
    let preserveNtSecurityInfo: Bool
    let eliminateDuplicates: Bool
}

struct ExtractQuickActionDefaults {
    let overwriteMode: SZOverwriteMode
    let preserveNtSecurityInfo: Bool
    let eliminateDuplicates: Bool
}

final class ExtractDialogController: NSObject {

    private struct ModeOption<Value: Equatable> {
        let title: String
        let value: Value
    }

    private enum DestinationHistory {
        private static let defaults = UserDefaults.standard
        private static let entriesKey = "FileManager.ExtractDestinationHistory"
        private static let maxEntries = 20

        static func entries() -> [String] {
            defaults.stringArray(forKey: entriesKey) ?? []
        }

        static func record(_ path: String) {
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            var updatedEntries = entries().filter { $0 != normalizedPath }
            updatedEntries.insert(normalizedPath, at: 0)
            if updatedEntries.count > maxEntries {
                updatedEntries.removeSubrange(maxEntries..<updatedEntries.count)
            }
            defaults.set(updatedEntries, forKey: entriesKey)
        }
    }

    private enum DialogPreferences {
        private static let defaults = UserDefaults.standard
        private static let pathModeKey = "FileManager.ExtractPathMode"
        private static let overwriteModeKey = "FileManager.ExtractOverwriteMode"
        private static let preserveNtSecurityKey = "FileManager.ExtractPreserveNtSecurity"
        private static let eliminateDuplicatesKey = "FileManager.ExtractEliminateDuplicates"
        private static let splitDestinationKey = "FileManager.ExtractSplitDestination"
        private static let showPasswordKey = "FileManager.ExtractShowPassword"

        static func pathMode(defaultValue: SZPathMode,
                             allowedValues: [SZPathMode]) -> SZPathMode {
            guard let rawValue = defaults.object(forKey: pathModeKey) as? Int,
                  let value = SZPathMode(rawValue: rawValue),
                  allowedValues.contains(value) else {
                return defaultValue
            }
            return value
        }

        static func overwriteMode(defaultValue: SZOverwriteMode) -> SZOverwriteMode {
            guard let rawValue = defaults.object(forKey: overwriteModeKey) as? Int,
                  let value = SZOverwriteMode(rawValue: rawValue) else {
                return defaultValue
            }
            return value
        }

        static func preserveNtSecurityInfo() -> Bool {
            guard defaults.object(forKey: preserveNtSecurityKey) != nil else {
                return false
            }
            return defaults.bool(forKey: preserveNtSecurityKey)
        }

        static func eliminateDuplicates() -> Bool {
            guard defaults.object(forKey: eliminateDuplicatesKey) != nil else {
                return true
            }
            return defaults.bool(forKey: eliminateDuplicatesKey)
        }

        static func splitDestination() -> Bool {
            guard defaults.object(forKey: splitDestinationKey) != nil else {
                return true
            }
            return defaults.bool(forKey: splitDestinationKey)
        }

        static func showPassword() -> Bool {
            guard defaults.object(forKey: showPasswordKey) != nil else {
                return false
            }
            return defaults.bool(forKey: showPasswordKey)
        }

        static func record(pathMode: SZPathMode,
                           overwriteMode: SZOverwriteMode,
                           preserveNtSecurityInfo: Bool,
                           eliminateDuplicates: Bool,
                           splitDestination: Bool,
                           showPassword: Bool) {
            defaults.set(pathMode.rawValue, forKey: pathModeKey)
            defaults.set(overwriteMode.rawValue, forKey: overwriteModeKey)
            defaults.set(preserveNtSecurityInfo, forKey: preserveNtSecurityKey)
            defaults.set(eliminateDuplicates, forKey: eliminateDuplicatesKey)
            defaults.set(splitDestination, forKey: splitDestinationKey)
            defaults.set(showPassword, forKey: showPasswordKey)
        }
    }

    private final class DestinationPicker: NSObject {
        private weak var ownerWindow: NSWindow?
        private weak var pathField: NSComboBox?
        private let baseDirectory: URL

        init(ownerWindow: NSWindow?,
             pathField: NSComboBox,
             baseDirectory: URL) {
            self.ownerWindow = ownerWindow
            self.pathField = pathField
            self.baseDirectory = baseDirectory.standardizedFileURL
        }

        @objc func browse(_ sender: Any?) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Choose"
            panel.message = "Choose destination folder:"
            panel.directoryURL = suggestedDirectoryURL()

            if let ownerWindow {
                panel.beginSheetModal(for: ownerWindow) { [weak self] response in
                    guard response == .OK, let url = panel.url else { return }
                    self?.pathField?.stringValue = url.standardizedFileURL.path
                }
                return
            }

            guard panel.runModal() == .OK, let url = panel.url else { return }
            pathField?.stringValue = url.standardizedFileURL.path
        }

        private func suggestedDirectoryURL() -> URL {
            guard let pathField else {
                return baseDirectory
            }

            let currentValue = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !currentValue.isEmpty else {
                return baseDirectory
            }

            let expandedPath = NSString(string: currentValue).expandingTildeInPath
            let candidateURL: URL
            if NSString(string: expandedPath).isAbsolutePath {
                candidateURL = URL(fileURLWithPath: expandedPath)
            } else {
                candidateURL = URL(fileURLWithPath: expandedPath, relativeTo: baseDirectory)
            }

            let standardizedURL = candidateURL.standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? standardizedURL : standardizedURL.deletingLastPathComponent()
            }

            return standardizedURL.deletingLastPathComponent()
        }
    }

    private let suggestedDestinationURL: URL
    private let baseDirectory: URL
    private let messageText: String?
    private let defaultPathMode: SZPathMode
    private let showsCurrentPathsOption: Bool
    private let suggestedSplitDestinationName: String?
    private var destinationPicker: DestinationPicker?
    private weak var splitNameField: NSTextField?
    private weak var splitNameRow: NSView?
    private weak var splitDestinationCheckbox: NSButton?
    private weak var securePasswordField: NSSecureTextField?
    private weak var plainPasswordField: NSTextField?
    private weak var showPasswordCheckbox: NSButton?
    private weak var passwordContainerView: NSView?
    private weak var currentDialogWindow: NSWindow?

    init(suggestedDestinationURL: URL,
         baseDirectory: URL,
         message: String?,
         defaultPathMode: SZPathMode,
         showsCurrentPathsOption: Bool,
         suggestedSplitDestinationName: String? = nil) {
        self.suggestedDestinationURL = suggestedDestinationURL.standardizedFileURL
        self.baseDirectory = baseDirectory.standardizedFileURL
        self.messageText = message
        self.defaultPathMode = defaultPathMode
        self.showsCurrentPathsOption = showsCurrentPathsOption
        self.suggestedSplitDestinationName = suggestedSplitDestinationName
    }

    func runModal(for parentWindow: NSWindow?) -> ExtractDialogResult? {
        let pathModeOptions = makePathModeOptions()
        let overwriteModeOptions = makeOverwriteModeOptions()
        var selectedPath = suggestedDestinationURL.path
        var selectedPathMode = DialogPreferences.pathMode(defaultValue: defaultPathMode,
                                                         allowedValues: pathModeOptions.map(\ .value))
        var selectedOverwriteMode = DialogPreferences.overwriteMode(defaultValue: .ask)
        var enteredPassword = ""
        var preserveNtSecurityInfo = DialogPreferences.preserveNtSecurityInfo()
        var eliminateDuplicates = DialogPreferences.eliminateDuplicates()
        var splitDestination = DialogPreferences.splitDestination()
        var splitName = suggestedSplitDestinationName ?? ""
        var showPassword = DialogPreferences.showPassword()

        while true {
            let historyEntries = DestinationHistory.entries()
            let pathField = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
            pathField.isEditable = true
            pathField.usesDataSource = false
            pathField.completes = false
            pathField.addItems(withObjectValues: historyEntries)
            pathField.stringValue = selectedPath
            pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

            let browseButton = NSButton(title: "Browse...", target: nil, action: nil)
            browseButton.bezelStyle = .rounded
            browseButton.setContentHuggingPriority(.required, for: .horizontal)
            browseButton.setContentCompressionResistancePriority(.required, for: .horizontal)

            let pathRow = NSStackView(views: [pathField, browseButton])
            pathRow.orientation = .horizontal
            pathRow.alignment = .centerY
            pathRow.spacing = 8
            pathRow.distribution = .fill

            let pathModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            pathModeOptions.forEach { pathModePopup.addItem(withTitle: $0.title) }
            if let selectedIndex = pathModeOptions.firstIndex(where: { $0.value == selectedPathMode }) {
                pathModePopup.selectItem(at: selectedIndex)
            }
            pathModePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

            let overwriteModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            overwriteModeOptions.forEach { overwriteModePopup.addItem(withTitle: $0.title) }
            if let selectedIndex = overwriteModeOptions.firstIndex(where: { $0.value == selectedOverwriteMode }) {
                overwriteModePopup.selectItem(at: selectedIndex)
            }
            overwriteModePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

            let splitDestinationCheckbox = NSButton(checkboxWithTitle: "",
                                                    target: self,
                                                    action: #selector(splitDestinationToggled(_:)))
            splitDestinationCheckbox.state = splitDestination ? .on : .off
            splitDestinationCheckbox.toolTip = "Create a separate destination folder"
            splitDestinationCheckbox.setAccessibilityLabel("Create a separate destination folder")

            let splitNameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            splitNameField.placeholderString = "Archive"
            splitNameField.stringValue = splitName
            splitNameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

            let splitRow = NSStackView(views: [splitDestinationCheckbox, splitNameField])
            splitRow.orientation = .horizontal
            splitRow.alignment = .centerY
            splitRow.spacing = 8
            splitRow.distribution = .fill

            let securePasswordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            securePasswordField.placeholderString = "Optional"
            securePasswordField.stringValue = enteredPassword
            securePasswordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

            let plainPasswordField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            plainPasswordField.placeholderString = "Optional"
            plainPasswordField.stringValue = enteredPassword
            plainPasswordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

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

            let showPasswordCheckbox = NSButton(checkboxWithTitle: "Show password",
                                                target: self,
                                                action: #selector(showPasswordToggled(_:)))
            showPasswordCheckbox.state = showPassword ? .on : .off

            let ntSecurityCheckbox = NSButton(checkboxWithTitle: "NT security information",
                                              target: nil,
                                              action: nil)
            ntSecurityCheckbox.state = preserveNtSecurityInfo ? .on : .off

            let eliminateDuplicatesCheckbox = NSButton(checkboxWithTitle: "Eliminate duplicate root folder",
                                                       target: nil,
                                                       action: nil)
            eliminateDuplicatesCheckbox.state = eliminateDuplicates ? .on : .off

            let accessoryView = makeAccessoryView(pathRow: pathRow,
                                                  splitRow: splitRow,
                                                  pathModePopup: pathModePopup,
                                                  overwriteModePopup: overwriteModePopup,
                                                  passwordContainer: passwordContainer,
                                                  showPasswordCheckbox: showPasswordCheckbox,
                                                  ntSecurityCheckbox: ntSecurityCheckbox,
                                                  eliminateDuplicatesCheckbox: eliminateDuplicatesCheckbox)

            let controller = SZModalDialogController(style: .informational,
                                                     title: "Extract",
                                                     message: messageText,
                                                     buttonTitles: ["Cancel", "Extract"],
                                                     accessoryView: accessoryView,
                                                     preferredFirstResponder: pathField,
                                                     cancelButtonIndex: 0)
            currentDialogWindow = controller.window
            self.splitNameField = splitNameField
            self.splitNameRow = splitRow
            self.splitDestinationCheckbox = splitDestinationCheckbox
            self.securePasswordField = securePasswordField
            self.plainPasswordField = plainPasswordField
            self.showPasswordCheckbox = showPasswordCheckbox
            self.passwordContainerView = passwordContainer
            updateSplitDestinationUI()
            updatePasswordVisibilityUI(moveFocus: false)

            let picker = DestinationPicker(ownerWindow: controller.window,
                                           pathField: pathField,
                                           baseDirectory: baseDirectory)
            destinationPicker = picker
            browseButton.target = picker
            browseButton.action = #selector(DestinationPicker.browse(_:))

            defer {
                destinationPicker = nil
                currentDialogWindow = nil
                self.splitNameField = nil
                self.splitNameRow = nil
                self.splitDestinationCheckbox = nil
                self.securePasswordField = nil
                self.plainPasswordField = nil
                self.showPasswordCheckbox = nil
                self.passwordContainerView = nil
            }

            guard controller.runModal() == 1 else {
                return nil
            }

            selectedPath = pathField.stringValue
            splitDestination = splitDestinationCheckbox.state == .on
            splitName = splitNameField.stringValue
            enteredPassword = visiblePasswordValue()
            showPassword = showPasswordCheckbox.state == .on
            selectedPathMode = pathModeOptions[pathModePopup.indexOfSelectedItem].value
            selectedOverwriteMode = overwriteModeOptions[overwriteModePopup.indexOfSelectedItem].value
            preserveNtSecurityInfo = ntSecurityCheckbox.state == .on
            eliminateDuplicates = eliminateDuplicatesCheckbox.state == .on

            do {
                let baseDestinationURL = try resolveDestinationDirectoryURL(from: selectedPath)
                let destinationURL = try resolveFinalDestinationURL(baseDestinationURL: baseDestinationURL,
                                                                    splitDestination: splitDestination,
                                                                    splitName: splitName)
                let password = normalizedPassword(from: enteredPassword)
                DestinationHistory.record(baseDestinationURL.path)
                DialogPreferences.record(pathMode: selectedPathMode,
                                         overwriteMode: selectedOverwriteMode,
                                         preserveNtSecurityInfo: preserveNtSecurityInfo,
                                         eliminateDuplicates: eliminateDuplicates,
                                         splitDestination: splitDestination,
                                         showPassword: showPassword)
                return ExtractDialogResult(destinationURL: destinationURL,
                                           overwriteMode: selectedOverwriteMode,
                                           pathMode: selectedPathMode,
                                           password: password,
                                           preserveNtSecurityInfo: preserveNtSecurityInfo,
                                           eliminateDuplicates: eliminateDuplicates)
            } catch {
                szPresentError(error, for: parentWindow)
            }
        }
    }

    private func makePathModeOptions() -> [ModeOption<SZPathMode>] {
        var options: [ModeOption<SZPathMode>] = []
        if showsCurrentPathsOption {
            options.append(ModeOption(title: "Current Paths", value: .currentPaths))
        }
        options.append(ModeOption(title: "Full Paths", value: .fullPaths))
        options.append(ModeOption(title: "No Paths", value: .noPaths))
        options.append(ModeOption(title: "Absolute Paths", value: .absolutePaths))
        return options
    }

    private func makeOverwriteModeOptions() -> [ModeOption<SZOverwriteMode>] {
        [
            ModeOption(title: "Ask", value: .ask),
            ModeOption(title: "Overwrite", value: .overwrite),
            ModeOption(title: "Skip Existing", value: .skip),
            ModeOption(title: "Rename", value: .rename),
            ModeOption(title: "Rename Existing", value: .renameExisting),
        ]
    }

    private func makeAccessoryView(pathRow: NSView,
                                   splitRow: NSView,
                                   pathModePopup: NSPopUpButton,
                                   overwriteModePopup: NSPopUpButton,
                                   passwordContainer: NSView,
                                   showPasswordCheckbox: NSButton,
                                   ntSecurityCheckbox: NSButton,
                                   eliminateDuplicatesCheckbox: NSButton) -> NSView {
        let formStack = NSStackView(views: [
            makeFormRow(label: "Extract to:", control: pathRow),
            makeFormRow(label: "Separate folder:", control: splitRow),
            makeFormRow(label: "Path mode:", control: pathModePopup),
            makeFormRow(label: "Overwrite mode:", control: overwriteModePopup),
            makeFormRow(label: "Password:", control: passwordContainer),
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

        let optionsLabel = NSTextField(labelWithString: "Options")
        optionsLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let optionsStack = NSStackView(views: [ntSecurityCheckbox, eliminateDuplicatesCheckbox])
        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 8

        let contentStack = NSStackView(views: [formStack, optionsLabel, optionsStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
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

    private func resolveDestinationDirectoryURL(from enteredPath: String) throws -> URL {
        let trimmedPath = enteredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileNoSuchFileError,
                          userInfo: [NSLocalizedDescriptionKey: "Enter a destination folder."])
        }

        let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
        let candidateURL: URL
        if NSString(string: expandedPath).isAbsolutePath {
            candidateURL = URL(fileURLWithPath: expandedPath)
        } else {
            candidateURL = URL(fileURLWithPath: expandedPath, relativeTo: baseDirectory)
        }

        let standardizedURL = candidateURL.standardizedFileURL
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteInvalidFileNameError,
                              userInfo: [
                                  NSFilePathErrorKey: standardizedURL.path,
                                  NSLocalizedDescriptionKey: "The destination path must be a folder."
                              ])
            }
            return standardizedURL
        }

        try FileManager.default.createDirectory(at: standardizedURL, withIntermediateDirectories: true)
        return standardizedURL
    }

    private func resolveFinalDestinationURL(baseDestinationURL: URL,
                                            splitDestination: Bool,
                                            splitName: String) throws -> URL {
        guard splitDestination else {
            return baseDestinationURL
        }

        let trimmedName = splitName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileWriteInvalidFileNameError,
                          userInfo: [NSLocalizedDescriptionKey: "Enter a destination folder name."])
        }

        return baseDestinationURL.appendingPathComponent(trimmedName, isDirectory: true).standardizedFileURL
    }

    private func normalizedPassword(from rawValue: String) -> String? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func visiblePasswordValue() -> String {
        if showPasswordCheckbox?.state == .on {
            return plainPasswordField?.stringValue ?? securePasswordField?.stringValue ?? ""
        }
        return securePasswordField?.stringValue ?? plainPasswordField?.stringValue ?? ""
    }

    @objc private func splitDestinationToggled(_ sender: Any?) {
        updateSplitDestinationUI()
    }

    @objc private func showPasswordToggled(_ sender: Any?) {
        updatePasswordVisibilityUI(moveFocus: true)
    }

    private func updateSplitDestinationUI() {
        let enabled = splitDestinationCheckbox?.state == .on
        splitNameField?.isEnabled = enabled
        splitNameField?.alphaValue = enabled ? 1.0 : 0.55
    }

    private func updatePasswordVisibilityUI(moveFocus: Bool) {
        let showPassword = showPasswordCheckbox?.state == .on
        let currentValue = visiblePasswordValue()

        securePasswordField?.stringValue = currentValue
        plainPasswordField?.stringValue = currentValue
        securePasswordField?.isHidden = showPassword
        securePasswordField?.isEnabled = !showPassword
        plainPasswordField?.isHidden = !showPassword
        plainPasswordField?.isEnabled = showPassword

        guard moveFocus, let currentDialogWindow else {
            return
        }

        if showPassword, let plainPasswordField {
            currentDialogWindow.makeFirstResponder(plainPasswordField)
        } else if let securePasswordField {
            currentDialogWindow.makeFirstResponder(securePasswordField)
        }
    }

    private func makeLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        return label
    }
}

extension ExtractDialogController {
    static func quickActionDefaults() -> ExtractQuickActionDefaults {
        ExtractQuickActionDefaults(overwriteMode: DialogPreferences.overwriteMode(defaultValue: .ask),
                                   preserveNtSecurityInfo: DialogPreferences.preserveNtSecurityInfo(),
                                   eliminateDuplicates: DialogPreferences.eliminateDuplicates())
    }
}