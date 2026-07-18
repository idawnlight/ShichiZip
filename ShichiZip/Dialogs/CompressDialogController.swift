import Cocoa

struct CompressDialogResult {
    let settings: SZCompressionSettings
    let archiveURL: URL
}

@MainActor
private final class CompressDialogValidationContext {
    var result: CompressDialogResult?
}

@MainActor
final class CompressDialogController: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {
    @MainActor
    private final class ArchivePathPicker: NSObject {
        private weak var ownerWindow: NSWindow?
        private weak var pathField: NSComboBox?
        private let baseDirectory: URL
        private let defaultFileNameProvider: () -> String

        init(ownerWindow: NSWindow?,
             pathField: NSComboBox,
             baseDirectory: URL,
             defaultFileNameProvider: @escaping () -> String)
        {
            self.ownerWindow = ownerWindow
            self.pathField = pathField
            self.baseDirectory = baseDirectory.standardizedFileURL
            self.defaultFileNameProvider = defaultFileNameProvider
        }

        @objc func browse(_: Any?) {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.directoryURL = suggestedDirectoryURL()
            panel.nameFieldStringValue = suggestedFileName()

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

        private func suggestedFileName() -> String {
            guard let pathField else {
                return defaultFileNameProvider()
            }

            let currentValue = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !currentValue.isEmpty else {
                return defaultFileNameProvider()
            }

            let expandedPath = NSString(string: currentValue).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath).lastPathComponent
        }
    }

    private static let knownArchiveExtensions: Set<String> = ["7z", "zip", "tar", "gz", "gzip", "bz2", "bzip2", "xz", "wim", "zst", "zstd", "br", "brotli", "liz", "lz4", "lz5", "exe"]

    private let sourceURLs: [URL]
    private let baseDirectory: URL
    private let messageText: String?
    private let suggestedBaseName: String
    let supportedFormatInfoByName: [String: SZFormatInfo]
    private let availableFormats: [FormatOption]
    private let hasStoredAdvancedPreferences: Bool

    private var archivePathPicker: ArchivePathPicker?
    private weak var currentDialogWindow: NSWindow?
    private var contentController: CompressDialogContentController?

    private var advancedOptionsState = AdvancedOptionsState(storeSymbolicLinks: false,
                                                            storeHardLinks: false,
                                                            storeAlternateDataStreams: false,
                                                            storeFileSecurity: false,
                                                            preserveSourceAccessTime: false,
                                                            storeModificationTime: AdvancedBoolPairState(isSet: false,
                                                                                                         value: true),
                                                            storeCreationTime: AdvancedBoolPairState(isSet: false,
                                                                                                     value: false),
                                                            storeAccessTime: AdvancedBoolPairState(isSet: false,
                                                                                                   value: false),
                                                            setArchiveTimeToLatestFile: AdvancedBoolPairState(isSet: false,
                                                                                                              value: false),
                                                            timePrecision: AdvancedTimePrecisionState(isSet: false,
                                                                                                      value: SZCompressionTimePrecision(rawValue: -1)!))
    private var advancedOptionsWereCustomized = false
    private var isPresentingAdvancedOptions = false

    init(sourceURLs: [URL],
         baseDirectory: URL? = nil,
         message: String? = nil)
    {
        let normalizedSourceURLs = sourceURLs.map(\.standardizedFileURL)
        let resolvedBaseDirectory = (baseDirectory ?? Self.suggestedBaseDirectory(for: normalizedSourceURLs)).standardizedFileURL
        let supportedFormatInfoByName = Self.makeSupportedFormatInfoByName()

        self.sourceURLs = normalizedSourceURLs
        self.baseDirectory = resolvedBaseDirectory
        suggestedBaseName = Self.suggestedArchiveBaseName(for: normalizedSourceURLs,
                                                          baseDirectory: resolvedBaseDirectory)
        self.supportedFormatInfoByName = supportedFormatInfoByName
        availableFormats = Self.makeAvailableFormats(supportedFormatInfoByName: supportedFormatInfoByName,
                                                     sourceURLs: normalizedSourceURLs)
        hasStoredAdvancedPreferences = DialogPreferences.hasStoredAdvancedOptions()
        messageText = message ?? Self.defaultMessage(for: normalizedSourceURLs,
                                                     baseDirectory: resolvedBaseDirectory)

        super.init()
    }

    func runModal(for parentWindow: NSWindow?) async -> CompressDialogResult? {
        guard !availableFormats.isEmpty else {
            szPresentMessage(title: "No Archive Formats Available",
                             message: "7-Zip did not report any writable archive formats.",
                             style: .warning,
                             for: parentWindow)
            return nil
        }

        let initialState = makeInitialDialogState()
        let initialMethodName = initialState.method?.methodName ?? ""
        let advancedOptionsCustomized = hasStoredAdvancedPreferences
        let resultBuilder = makeResultBuilder()
        let validationContext = CompressDialogValidationContext()

        do {
            let contentController = CompressDialogContentController(owner: self,
                                                                    initialState: initialState,
                                                                    availableFormats: availableFormats)

            let controller = SZModalDialogController(style: .informational,
                                                     title: SZL10n.string("compress.title"),
                                                     message: messageText,
                                                     actions: [
                                                         SZDialogAction(title: SZL10n.string("common.cancel"),
                                                                        roles: .cancel),
                                                         SZDialogAction(title: SZL10n.string("common.ok"),
                                                                        roles: .default),
                                                     ],
                                                     accessoryView: contentController.accessoryView,
                                                     preferredFirstResponder: contentController.preferredFirstResponder)
            currentDialogWindow = controller.window
            self.contentController = contentController
            advancedOptionsState = initialState.advancedOptions
            advancedOptionsWereCustomized = advancedOptionsCustomized

            reloadFormatDependentControls(preferredLevel: initialState.level,
                                          preferredMethodName: initialMethodName,
                                          preferredDictionarySize: initialState.dictionarySize,
                                          preferredWordSize: initialState.wordSize,
                                          preferredEncryption: initialState.encryption)
            contentController.selectSolidMode(initialState.solidMode)
            updatePasswordVisibilityUI(moveFocus: false)
            refreshOptionAvailability()

            let picker = ArchivePathPicker(ownerWindow: controller.window,
                                           pathField: contentController.archivePathField,
                                           baseDirectory: baseDirectory)
            { [weak self] in
                self?.suggestedArchiveFileName() ?? "Archive.7z"
            }
            archivePathPicker = picker
            contentController.setBrowseButtonTarget(picker,
                                                    action: #selector(ArchivePathPicker.browse(_:)))

            controller.shouldFinishHandler = { [weak self] buttonIndex in
                guard buttonIndex == 1 else {
                    return true
                }

                guard let self else {
                    return false
                }

                contentController.updateStateFromControls(advancedOptions: advancedOptionsState)
                let state = contentController.state

                do {
                    let result = try resultBuilder.build(from: state)
                    ArchivePathHistory.record(result.archiveURL.path)
                    DialogPreferences.record(format: state.formatName,
                                             updateMode: state.updateMode,
                                             pathMode: state.pathMode,
                                             openSharedFiles: state.openSharedFiles,
                                             deleteAfterCompression: state.deleteAfterCompression,
                                             encryptNames: state.encryptNames,
                                             showPassword: state.showPassword,
                                             memoryUsage: state.memoryUsageSpec)
                    DialogPreferences.recordAdvancedOptions(state.advancedOptions)
                    validationContext.result = result
                    return true
                } catch {
                    szPresentError(error, for: controller.window)
                    return false
                }
            }

            defer {
                controller.shouldFinishHandler = nil
                archivePathPicker = nil
                currentDialogWindow = nil
                self.contentController = nil
            }

            guard await controller.modalResult(for: parentWindow) == 1 else {
                return nil
            }

            return validationContext.result
        }
    }

    private func makeResultBuilder() -> CompressDialogResultBuilder {
        CompressDialogResultBuilder(
            supportsSFX: { [self] format, method in
                supportsSFX(for: format, method: method)
            },
            resolveArchiveURL: { [self] archivePath, format, createSFX in
                try resolveArchiveURL(from: archivePath,
                                      format: format,
                                      createSFX: createSFX)
            },
            parseThreadCount: { [self] text in
                try parseThreadCount(text)
            },
            validatePassword: { [self] password, confirmation, format, encryption in
                try validatePassword(password,
                                     confirmation: confirmation,
                                     for: format,
                                     encryption: encryption)
            },
            effectiveAdvancedOptions: { [self] format, method, baseState in
                effectiveAdvancedOptions(for: format,
                                         method: method,
                                         baseState: baseState)
            },
            applyAdvancedOptions: { [self] state, capabilities, settings in
                applyAdvancedOptions(state,
                                     capabilities: capabilities,
                                     to: settings)
            },
        )
    }

    func controlTextDidChange(_ obj: Notification) {
        if contentController?.isThreadField(obj.object) == true {
            refreshCompressionEstimateSummary()
            return
        }

        guard let field = obj.object as? NSTextField else { return }
        contentController?.syncPasswordFields(changedField: field)

        refreshOptionAvailability()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let comboBox = notification.object as? NSComboBox else {
            return
        }

        if contentController?.isThreadField(comboBox) == true {
            refreshCompressionEstimateSummary()
            return
        }

        refreshOptionAvailability()
    }

    @objc func formatChanged(_: Any?) {
        updateArchivePathExtension()
        reloadFormatDependentControls(preferredLevel: nil,
                                      preferredMethodName: nil,
                                      preferredDictionarySize: nil,
                                      preferredWordSize: nil,
                                      preferredEncryption: nil)
        contentController?.setParameters(defaultParameters(for: selectedFormatOption()))

        if !advancedOptionsWereCustomized,
           !hasStoredAdvancedPreferences,
           let format = selectedFormatOption()
        {
            advancedOptionsState = defaultAdvancedOptionsState(for: format,
                                                               methodName: selectedMethodOption()?.methodName)
            refreshAdvancedOptionsSummary()
        }
    }

    @objc func methodChanged(_: Any?) {
        reloadFormatDependentControls(preferredLevel: nil,
                                      preferredMethodName: selectedMethodOption()?.methodName,
                                      preferredDictionarySize: selectedDictionaryOption()?.value,
                                      preferredWordSize: selectedWordOption()?.value,
                                      preferredEncryption: selectedEncryptionOption()?.value)

        if !advancedOptionsWereCustomized,
           !hasStoredAdvancedPreferences,
           let format = selectedFormatOption()
        {
            advancedOptionsState = defaultAdvancedOptionsState(for: format,
                                                               methodName: selectedMethodOption()?.methodName)
            refreshAdvancedOptionsSummary()
        }
    }

    @objc func showPasswordToggled(_: Any?) {
        syncPasswordFields()
        updatePasswordVisibilityUI(moveFocus: true)
        refreshOptionAvailability()
    }

    @objc func compressionSettingsChanged(_: Any?) {
        refreshOptionAvailability()
    }

    @objc func createSFXToggled(_: Any?) {
        updateArchivePathExtension()
        refreshOptionAvailability()
    }

    @objc func showAdvancedOptions(_: Any?) {
        Task { @MainActor [weak self] in
            guard let self,
                  !isPresentingAdvancedOptions,
                  let format = selectedFormatOption()
            else {
                return
            }

            isPresentingAdvancedOptions = true
            defer { isPresentingAdvancedOptions = false }

            let method = selectedMethodOption()
            let initialState = effectiveAdvancedOptions(for: format,
                                                        method: method,
                                                        baseState: advancedOptionsState).state
            let presenter = makeAdvancedOptionsPresenter()
            guard let updatedState = await presenter.run(for: format,
                                                         method: method,
                                                         initialState: initialState)
            else {
                return
            }

            advancedOptionsState = updatedState
            advancedOptionsWereCustomized = true
            refreshAdvancedOptionsSummary()
        }
    }

    private func makeAdvancedOptionsPresenter() -> CompressDialogAdvancedOptionsPresenter {
        CompressDialogAdvancedOptionsPresenter(
            parentWindow: currentDialogWindow,
            baseAdvancedOptionsCapabilities: { [self] format, methodName in
                baseAdvancedOptionsCapabilities(for: format,
                                                methodName: methodName)
            },
            adjustedAdvancedOptionsCapabilities: { [self] capabilities, timePrecision, format, methodName in
                adjustedAdvancedOptionsCapabilities(capabilities,
                                                    timePrecision: timePrecision,
                                                    format: format,
                                                    methodName: methodName)
            },
            effectiveAdvancedOptions: { [self] format, method, baseState in
                effectiveAdvancedOptions(for: format,
                                         method: method,
                                         baseState: baseState)
            },
            makeTimePrecisionOptions: { [self] capabilities in
                makeTimePrecisionOptions(for: capabilities)
            },
        )
    }

    private func makeContentRefreshDependencies() -> CompressDialogContentRefreshDependencies {
        CompressDialogContentRefreshDependencies(
            levelOptions: { [self] format, method in
                levelOptions(for: format, method: method)
            },
            defaultLevel: { [self] formatName, methodName in
                defaultLevel(for: formatName, methodName: methodName)
            },
            defaultLevelIndex: { [self] format, method in
                defaultLevelIndex(for: format, method: method)
            },
            supportsSFX: { [self] format, method in
                supportsSFX(for: format, method: method)
            },
            compressionResourceEstimate: { [self] format, method, level, dictionarySize, threadText, memoryUsageSpec in
                compressionResourceEstimate(for: format,
                                            method: method,
                                            level: level,
                                            dictionarySize: dictionarySize,
                                            threadText: threadText,
                                            memoryUsageSpec: memoryUsageSpec)
            },
            refreshAdvancedOptionsSummary: { [self] in
                refreshAdvancedOptionsSummary()
            },
        )
    }

    private func reloadFormatDependentControls(preferredLevel: Int?,
                                               preferredMethodName: String?,
                                               preferredDictionarySize: UInt64?,
                                               preferredWordSize: UInt32?,
                                               preferredEncryption: SZEncryptionMethod?)
    {
        guard let contentController else { return }
        if contentController.reloadFormatDependentControls(preferredLevel: preferredLevel,
                                                           preferredMethodName: preferredMethodName,
                                                           preferredDictionarySize: preferredDictionarySize,
                                                           preferredWordSize: preferredWordSize,
                                                           preferredEncryption: preferredEncryption,
                                                           dependencies: makeContentRefreshDependencies())
        {
            updateArchivePathExtension()
        }
    }

    private func reloadMethodDependentControls(preferredDictionarySize: UInt64?,
                                               preferredWordSize: UInt32?)
    {
        guard let contentController else { return }
        if contentController.reloadMethodDependentControls(preferredDictionarySize: preferredDictionarySize,
                                                           preferredWordSize: preferredWordSize,
                                                           dependencies: makeContentRefreshDependencies())
        {
            updateArchivePathExtension()
        }
    }

    private func refreshOptionAvailability() {
        guard let contentController else { return }
        if contentController.refreshOptionAvailability(dependencies: makeContentRefreshDependencies()) {
            updateArchivePathExtension()
        }
    }

    private func refreshCompressionEstimateSummary() {
        contentController?.refreshCompressionEstimateSummary(dependencies: makeContentRefreshDependencies())
    }

    private func makeInitialDialogState() -> CompressDialogState {
        let allowedFormats = availableFormats.map(\.codecName)
        let selectedFormatName = DialogPreferences.format(defaultValue: availableFormats[0].codecName,
                                                          allowedValues: allowedFormats)
        let format = formatOption(named: selectedFormatName) ?? availableFormats[0]
        let selectedMethodName = defaultMethodName(for: selectedFormatName)
        let method = format.methods.first { $0.methodName == selectedMethodName }
        let advancedOptions = DialogPreferences.advancedOptions(
            defaults: defaultAdvancedOptionsState(for: format,
                                                  methodName: selectedMethodName),
        )

        return CompressDialogState(archivePath: defaultArchiveURL(for: selectedFormatName).path,
                                   format: format,
                                   level: defaultLevel(for: selectedFormatName,
                                                       methodName: selectedMethodName),
                                   method: method,
                                   dictionarySize: 0,
                                   wordSize: 0,
                                   solidMode: true,
                                   threadText: "Auto",
                                   splitVolumes: "",
                                   parameters: "",
                                   updateMode: DialogPreferences.updateMode(defaultValue: .add),
                                   pathMode: DialogPreferences.pathMode(defaultValue: .relativePaths),
                                   encryption: defaultEncryption(for: selectedFormatName),
                                   password: "",
                                   confirmation: "",
                                   encryptNames: DialogPreferences.encryptNames(),
                                   createSFX: false,
                                   excludeMacResourceFiles: SZSettings.bool(.excludeMacResourceFilesByDefault),
                                   memoryUsageSpec: DialogPreferences.memoryUsage(),
                                   openSharedFiles: DialogPreferences.openSharedFiles(),
                                   deleteAfterCompression: DialogPreferences.deleteAfterCompression(),
                                   advancedOptions: advancedOptions,
                                   showPassword: DialogPreferences.showPassword())
    }

    private func validatePassword(_ password: String,
                                  confirmation: String,
                                  for format: FormatOption,
                                  encryption: SZEncryptionMethod) throws -> String?
    {
        guard !password.isEmpty || !confirmation.isEmpty else {
            return nil
        }

        if format.codecName == "zip" {
            guard password.canBeConverted(to: .ascii) else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSUserCancelledError,
                              userInfo: [NSLocalizedDescriptionKey: SZL10n.string("password.useAscii")])
            }

            if encryption == .AES256, password.utf8.count > 99 {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSUserCancelledError,
                              userInfo: [NSLocalizedDescriptionKey: SZL10n.string("password.tooLong")])
            }
        }

        guard password == confirmation else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSUserCancelledError,
                          userInfo: [NSLocalizedDescriptionKey: SZL10n.string("password.passwordsMismatch")])
        }

        return password
    }

    private func parseThreadCount(_ text: String) throws -> UInt32 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.isAutomaticThreadText(trimmed) else {
            return 0
        }

        guard let value = UInt32(trimmed), value > 0 else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSUserCancelledError,
                          userInfo: [NSLocalizedDescriptionKey: "Thread count must be a positive number or Auto."])
        }

        return value
    }

    private func resolveArchiveURL(from archivePath: String,
                                   format: FormatOption,
                                   createSFX: Bool) throws -> URL
    {
        let trimmedPath = archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = normalizedArchivePath(from: trimmedPath,
                                                   format: format,
                                                   createSFX: createSFX)
        let standardizedURL = szStandardizedFileURL(fromUserPath: normalizedPath,
                                                    relativeTo: baseDirectory)
        guard !standardizedURL.lastPathComponent.isEmpty else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSUserCancelledError,
                          userInfo: [NSLocalizedDescriptionKey: "Enter an archive path."])
        }

        let parentDirectory = standardizedURL.deletingLastPathComponent()
        guard FileManager.default.szDirectoryExists(at: parentDirectory) else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSUserCancelledError,
                          userInfo: [NSLocalizedDescriptionKey: "The destination folder does not exist."])
        }

        if FileManager.default.szDirectoryExists(at: standardizedURL) {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSUserCancelledError,
                          userInfo: [NSLocalizedDescriptionKey: "The archive path points to an existing folder."])
        }

        return standardizedURL
    }

    private func normalizedArchivePath(from archivePath: String,
                                       format: FormatOption,
                                       createSFX: Bool) -> String
    {
        let trimmedPath = archivePath.isEmpty
            ? defaultArchiveURL(for: format.codecName, createSFX: createSFX).path
            : archivePath
        let pathNSString = NSString(string: trimmedPath)
        let existingExtension = pathNSString.pathExtension.lowercased()
        let targetExtension = archiveExtension(for: format, createSFX: createSFX)

        if existingExtension.isEmpty {
            return trimmedPath + ".\(targetExtension)"
        }

        if existingExtension == targetExtension.lowercased() {
            return trimmedPath
        }

        if Self.knownArchiveExtensions.contains(existingExtension) {
            return pathNSString.deletingPathExtension + ".\(targetExtension)"
        }

        return trimmedPath + ".\(targetExtension)"
    }

    private func updateArchivePathExtension() {
        guard let contentController,
              let format = selectedFormatOption()
        else {
            return
        }

        contentController.setArchivePath(normalizedArchivePath(from: contentController.archivePath,
                                                               format: format,
                                                               createSFX: effectiveCreateSFXState(for: format,
                                                                                                  method: selectedMethodOption())))
    }

    private func updatePasswordVisibilityUI(moveFocus: Bool) {
        contentController?.updatePasswordVisibilityUI(moveFocus: moveFocus,
                                                      in: currentDialogWindow)
    }

    private func syncPasswordFields() {
        contentController?.syncPasswordFields()
    }

    private func selectedFormatOption() -> FormatOption? {
        contentController?.selectedFormatOption()
    }

    private func selectedMethodOption() -> MethodOption? {
        contentController?.selectedMethodOption()
    }

    private func selectedDictionaryOption() -> Option<UInt64>? {
        contentController?.selectedDictionaryOption()
    }

    private func selectedWordOption() -> Option<UInt32>? {
        contentController?.selectedWordOption()
    }

    private func selectedEncryptionOption() -> Option<SZEncryptionMethod>? {
        contentController?.selectedEncryptionOption()
    }

    private func supportsSFX(for format: FormatOption?,
                             method: MethodOption?) -> Bool
    {
        guard let format else {
            return false
        }
        guard format.codecName.caseInsensitiveCompare("7z") == .orderedSame,
              Self.hasBundledWindowsSfxModule()
        else {
            return false
        }

        guard let method else {
            return true
        }

        switch method.methodName.lowercased() {
        case "copy", "lzma", "lzma2", "ppmd":
            return true
        #if SHICHIZIP_ZS_VARIANT
            case "flzma2", "zstd":
                return true
        #endif
        default:
            return false
        }
    }

    private func effectiveCreateSFXState(for format: FormatOption? = nil,
                                         method: MethodOption? = nil) -> Bool
    {
        contentController?.effectiveCreateSFXState(for: format,
                                                   method: method,
                                                   supportsSFX: { [self] format, method in
                                                       supportsSFX(for: format, method: method)
                                                   }) ?? false
    }

    private func archiveExtension(for format: FormatOption,
                                  createSFX: Bool) -> String
    {
        createSFX ? "exe" : format.defaultExtension
    }

    private func defaultArchiveURL(for formatName: String,
                                   createSFX: Bool = false) -> URL
    {
        let format = formatOption(named: formatName) ?? availableFormats[0]
        let extensionName = archiveExtension(for: format, createSFX: createSFX)
        return baseDirectory.appendingPathComponent("\(suggestedBaseName).\(extensionName)")
    }

    private func suggestedArchiveFileName() -> String {
        let format = selectedFormatOption() ?? availableFormats[0]
        let extensionName = archiveExtension(for: format,
                                             createSFX: effectiveCreateSFXState(for: format,
                                                                                method: selectedMethodOption()))
        return "\(suggestedBaseName).\(extensionName)"
    }

    private func formatOption(named formatName: String) -> FormatOption? {
        availableFormats.first { $0.codecName == formatName }
    }

    private func levelOptions(for format: FormatOption,
                              method: MethodOption?) -> [LevelOption]
    {
        method?.levelOptions ?? format.levelOptions
    }

    private func defaultLevel(for formatName: String,
                              methodName: String? = nil) -> Int
    {
        let format = formatOption(named: formatName) ?? availableFormats[0]
        let method = methodName.flatMap { name in
            format.methods.first(where: { $0.methodName == name })
        } ?? format.methods.first
        let levelOptions = levelOptions(for: format,
                                        method: method)
        return levelOptions[defaultLevelIndex(for: format,
                                              method: method)].levelValue
    }

    private func defaultLevelIndex(for format: FormatOption,
                                   method: MethodOption? = nil) -> Int
    {
        let levelOptions = levelOptions(for: format,
                                        method: method)
        if let defaultIndex = levelOptions.firstIndex(where: { $0.isDefault }) {
            return defaultIndex
        }
        guard !levelOptions.isEmpty else { return 0 }
        return min(levelOptions.count / 2, levelOptions.count - 1)
    }

    private func defaultMethodName(for formatName: String) -> String {
        (formatOption(named: formatName) ?? availableFormats[0]).methods.first?.methodName ?? ""
    }

    private func defaultParameters(for format: FormatOption?) -> String {
        _ = format
        return ""
    }

    private func defaultEncryption(for formatName: String) -> SZEncryptionMethod {
        (formatOption(named: formatName) ?? availableFormats[0]).encryptionOptions.first?.value ?? .none
    }

    private static func hasBundledWindowsSfxModule() -> Bool {
        Bundle.main.url(forResource: "7z", withExtension: "sfx") != nil
    }

    private func refreshAdvancedOptionsSummary() {
        guard let contentController,
              let format = selectedFormatOption()
        else {
            contentController?.setAdvancedOptionsSummary("")
            return
        }

        let effectiveOptions = effectiveAdvancedOptions(for: format,
                                                        method: selectedMethodOption(),
                                                        baseState: advancedOptionsState)
        contentController.setAdvancedOptionsSummary(advancedOptionsSummary(for: effectiveOptions.state,
                                                                           capabilities: effectiveOptions.capabilities))
    }

    private func compressionResourceEstimate(for format: FormatOption,
                                             method: MethodOption?,
                                             level: Int,
                                             dictionarySize: UInt64,
                                             threadText: String?,
                                             memoryUsageSpec: String) -> CompressionResourceEstimate
    {
        let settings = SZCompressionSettings()
        settings.format = format.format
        settings.levelValue = level
        settings.method = method?.enumValue ?? .LZMA2
        settings.methodName = method?.methodName
        settings.dictionarySize = dictionarySize
        settings.memoryUsage = memoryUsageSpec.isEmpty ? nil : Self.normalizedMemoryUsageSpec(memoryUsageSpec)

        if let threadText,
           let explicitThreadCount = try? parseThreadCount(threadText),
           explicitThreadCount > 0
        {
            settings.numThreads = explicitThreadCount
        } else {
            settings.numThreads = 0
        }

        let estimate = SZArchive.compressionResourceEstimate(for: settings)
        return CompressionResourceEstimate(
            compressionMemory: estimate.compressionMemoryIsDefined ? estimate.compressionMemory : nil,
            decompressionMemory: estimate.decompressionMemoryIsDefined ? estimate.decompressionMemory : nil,
            memoryUsageLimit: estimate.memoryUsageLimitIsDefined ? estimate.memoryUsageLimit : nil,
            resolvedDictionarySize: estimate.resolvedDictionarySizeIsDefined ? estimate.resolvedDictionarySize : nil,
            resolvedWordSize: estimate.resolvedWordSizeIsDefined ? estimate.resolvedWordSize : nil,
            resolvedNumThreads: estimate.resolvedNumThreadsIsDefined ? estimate.resolvedNumThreads : nil,
        )
    }

    private static func isAutomaticThreadText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return true
        }
        return normalized.lowercased().hasPrefix("auto")
    }

    static func normalizedThreadText(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isAutomaticThreadText(normalized) ? "Auto" : normalized
    }

    private static func suggestedBaseDirectory(for sourceURLs: [URL]) -> URL {
        guard let firstURL = sourceURLs.first?.standardizedFileURL else {
            return FileManager.default.homeDirectoryForCurrentUser
        }

        var commonComponents = firstURL.deletingLastPathComponent().pathComponents
        for sourceURL in sourceURLs.dropFirst() {
            let components = sourceURL.standardizedFileURL.deletingLastPathComponent().pathComponents
            var updatedComponents: [String] = []
            for (lhs, rhs) in zip(commonComponents, components) where lhs == rhs {
                updatedComponents.append(lhs)
            }
            commonComponents = updatedComponents
        }

        guard !commonComponents.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser
        }

        return URL(fileURLWithPath: NSString.path(withComponents: commonComponents))
    }

    private static func suggestedArchiveBaseName(for sourceURLs: [URL],
                                                 baseDirectory: URL) -> String
    {
        guard let firstURL = sourceURLs.first?.standardizedFileURL else {
            return "Archive"
        }

        let baseName: String
        if sourceURLs.count == 1 {
            let resourceValues = try? firstURL.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = resourceValues?.isDirectory ?? false
            if isDirectory {
                baseName = firstURL.lastPathComponent
            } else {
                let fileName = firstURL.lastPathComponent
                if let dotIndex = fileName.firstIndex(of: "."),
                   fileName[fileName.index(after: dotIndex)...].contains(".") == false
                {
                    baseName = String(fileName[..<dotIndex])
                } else {
                    baseName = fileName
                }
            }
        } else {
            let folderName = baseDirectory.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            baseName = folderName.isEmpty ? "Archive" : folderName
        }

        let sanitizedBaseName = sanitizeFileName(baseName)
        return uniquedSuggestedBaseName(sanitizedBaseName, sourceURLs: sourceURLs)
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalidCharacters = CharacterSet(charactersIn: "/:")
        let sanitized = trimmed.unicodeScalars.map { invalidCharacters.contains($0) ? "_" : String($0) }.joined()
        return sanitized.isEmpty ? "Archive" : sanitized
    }

    private static func uniquedSuggestedBaseName(_ baseName: String,
                                                 sourceURLs: [URL]) -> String
    {
        let selectedArchiveBaseNames = Set(sourceURLs.compactMap { url -> String? in
            let fileName = url.standardizedFileURL.lastPathComponent
            let pathExtension = (fileName as NSString).pathExtension.lowercased()
            guard knownArchiveExtensions.contains(pathExtension) else {
                return nil
            }
            return (fileName as NSString).deletingPathExtension.lowercased()
        })

        guard selectedArchiveBaseNames.contains(baseName.lowercased()) else {
            return baseName
        }

        var suffix = 2
        while selectedArchiveBaseNames.contains("\(baseName)_\(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(baseName)_\(suffix)"
    }

    private static func defaultMessage(for sourceURLs: [URL],
                                       baseDirectory: URL) -> String?
    {
        if sourceURLs.count == 1 {
            return baseDirectory.path
        }
        return "Source folder: \(baseDirectory.path)"
    }

    static func threadChoices() -> [String] {
        let processorCount = max(1, ProcessInfo.processInfo.processorCount)
        let upperBound = min(max(processorCount * 2, 16), 1 << 14)
        return (1 ... upperBound).map(String.init)
    }
}
