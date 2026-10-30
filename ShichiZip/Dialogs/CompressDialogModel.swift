import Cocoa

@MainActor
extension CompressDialogController {
    struct CompressDialogState {
        var archivePath: String
        var format: FormatOption
        var level: Int
        var method: MethodOption?
        var dictionarySize: UInt64
        var wordSize: UInt32
        var solidMode: Bool
        var threadText: String
        var splitVolumes: String
        var parameters: String
        var updateMode: SZCompressionUpdateMode
        var pathMode: SZCompressionPathMode
        var encryption: SZEncryptionMethod
        var password: String
        var confirmation: String
        var encryptNames: Bool
        var createSFX: Bool
        var excludeMacResourceFiles: Bool
        var excludeOfficeLockFiles: Bool
        var memoryUsageSpec: String
        var openSharedFiles: Bool
        var deleteAfterCompression: Bool
        var advancedOptions: AdvancedOptionsState
        var showPassword: Bool

        var formatName: String {
            format.codecName
        }
    }

    @MainActor
    struct CompressDialogResultBuilder {
        let supportsSFX: (FormatOption, MethodOption?) -> Bool
        let resolveArchiveURL: (String, FormatOption, Bool) throws -> URL
        let parseThreadCount: (String) throws -> UInt32
        let validatePassword: (String, String, FormatOption, SZEncryptionMethod) throws -> String?
        let effectiveAdvancedOptions: (FormatOption, MethodOption?, AdvancedOptionsState) -> (state: AdvancedOptionsState, capabilities: AdvancedOptionsCapabilities)
        let applyAdvancedOptions: (AdvancedOptionsState, AdvancedOptionsCapabilities, SZCompressionSettings) -> Void

        func build(from state: CompressDialogState) throws -> CompressDialogResult {
            let effectiveCreateSFX = state.createSFX && supportsSFX(state.format, state.method)
            if state.createSFX && !effectiveCreateSFX {
                let sfxSupportDescription: String
                #if SHICHIZIP_ZS_VARIANT
                    sfxSupportDescription = "Windows SFX is only available for 7z archives using Copy, LZMA, LZMA2, PPMd, FLZMA2, or ZSTD, and requires the bundled 7z.sfx module."
                #else
                    sfxSupportDescription = "Windows SFX is only available for 7z archives using Copy, LZMA, LZMA2, or PPMd, and requires the bundled 7z.sfx module."
                #endif
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSUserCancelledError,
                              userInfo: [NSLocalizedDescriptionKey: sfxSupportDescription])
            }

            let trimmedSplitVolumes = state.splitVolumes.trimmingCharacters(in: .whitespacesAndNewlines)
            if effectiveCreateSFX && !trimmedSplitVolumes.isEmpty {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSUserCancelledError,
                              userInfo: [NSLocalizedDescriptionKey: SZL10n.string("app.archive.error.sfxCannotSplitVolumes")])
            }

            let normalizedMemoryUsageSpec = state.memoryUsageSpec.trimmingCharacters(in: .whitespacesAndNewlines)
            let archiveURL = try resolveArchiveURL(state.archivePath,
                                                   state.format,
                                                   effectiveCreateSFX)
            let threadCount = try parseThreadCount(state.threadText)
            let normalizedPassword = try validatePassword(state.password,
                                                          state.confirmation,
                                                          state.format,
                                                          state.encryption)
            let settings = SZCompressionSettings()
            settings.format = state.format.format
            settings.levelValue = state.level
            settings.method = state.method?.enumValue ?? .LZMA2
            settings.methodName = state.method?.methodName
            settings.updateMode = state.updateMode
            settings.pathMode = state.pathMode
            settings.encryption = normalizedPassword == nil ? .none : state.encryption
            settings.password = normalizedPassword
            settings.encryptFileNames = normalizedPassword != nil && state.format.supportsEncryptFileNames && state.encryptNames
            settings.createSFX = effectiveCreateSFX
            settings.excludeMacResourceFiles = state.excludeMacResourceFiles
            settings.excludeOfficeLockFiles = state.excludeOfficeLockFiles
            settings.solidMode = state.format.supportsSolid && state.solidMode
            settings.dictionarySize = state.dictionarySize
            settings.wordSize = state.wordSize
            settings.numThreads = threadCount
            settings.splitVolumes = trimmedSplitVolumes.isEmpty ? nil : trimmedSplitVolumes
            settings.memoryUsage = normalizedMemoryUsageSpec.isEmpty ? nil : normalizedMemoryUsageSpec

            let trimmedParameters = state.parameters.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.parameters = trimmedParameters.isEmpty ? nil : trimmedParameters

            settings.openSharedFiles = state.openSharedFiles
            settings.deleteAfterCompression = state.deleteAfterCompression

            let effectiveAdvancedOptions = effectiveAdvancedOptions(state.format,
                                                                    state.method,
                                                                    state.advancedOptions)
            applyAdvancedOptions(effectiveAdvancedOptions.state,
                                 effectiveAdvancedOptions.capabilities,
                                 settings)

            return CompressDialogResult(settings: settings, archiveURL: archiveURL)
        }
    }

    private static let defaultMemoryUsagePercent: UInt64 = 80

    static func populateMemoryUsagePopup(_ popup: NSPopUpButton,
                                         with options: [Option<String>],
                                         selectedSpec: String)
    {
        popup.removeAllItems()

        let normalizedSelectedSpec = normalizedMemoryUsageSpec(selectedSpec)
        for option in options {
            popup.addItem(withTitle: option.title)
            popup.lastItem?.representedObject = option.value
        }

        if let selectedIndex = options.firstIndex(where: { $0.value == normalizedSelectedSpec }) {
            popup.selectItem(at: selectedIndex)
        } else {
            popup.selectItem(at: 0)
        }
    }

    static func makeMemoryUsageOptions(preferredSpec: String) -> [Option<String>] {
        let normalizedPreferredSpec = normalizedMemoryUsageSpec(preferredSpec)
        let preferredSelection = parseMemoryUsageSelection(normalizedPreferredSpec)

        var options: [Option<String>] = [
            Option(title: memoryUsageOptionTitle(for: .auto), value: ""),
        ]

        let percentChoices = stride(from: 10, through: 100, by: 10).map(UInt64.init)
        if case let .percent(preferredPercent) = preferredSelection {
            var insertedPreferred = false
            for percent in percentChoices {
                if !insertedPreferred, preferredPercent <= percent {
                    if preferredPercent != percent {
                        options.append(Option(title: memoryUsageOptionTitle(for: .percent(preferredPercent)),
                                              value: normalizedPreferredSpec))
                    }
                    insertedPreferred = true
                }
                options.append(Option(title: memoryUsageOptionTitle(for: .percent(percent)),
                                      value: "\(percent)%"))
            }
            if !insertedPreferred {
                options.append(Option(title: memoryUsageOptionTitle(for: .percent(preferredPercent)),
                                      value: normalizedPreferredSpec))
            }
        } else {
            for percentChoice in percentChoices {
                options.append(Option(title: memoryUsageOptionTitle(for: .percent(percentChoice)),
                                      value: "\(percentChoice)%"))
            }
        }

        let byteChoices = standardMemoryUsageByteChoices()
        if case let .bytes(preferredBytes) = preferredSelection {
            var insertedPreferred = false
            for bytes in byteChoices {
                if !insertedPreferred, preferredBytes <= bytes {
                    if preferredBytes != bytes {
                        options.append(Option(title: memoryUsageOptionTitle(for: .bytes(preferredBytes)),
                                              value: normalizedPreferredSpec))
                    }
                    insertedPreferred = true
                }
                options.append(Option(title: memoryUsageOptionTitle(for: .bytes(bytes)),
                                      value: normalizedMemoryUsageSpec(forBytes: bytes)))
            }
            if !insertedPreferred {
                options.append(Option(title: memoryUsageOptionTitle(for: .bytes(preferredBytes)),
                                      value: normalizedPreferredSpec))
            }
        } else {
            for byteChoice in byteChoices {
                options.append(Option(title: memoryUsageOptionTitle(for: .bytes(byteChoice)),
                                      value: normalizedMemoryUsageSpec(forBytes: byteChoice)))
            }
        }

        return options
    }

    private static func parseMemoryUsageSelection(_ spec: String) -> MemoryUsageSelection? {
        let normalizedSpec = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedSpec.isEmpty {
            return .auto
        }

        if normalizedSpec.hasSuffix("%") {
            let valueText = String(normalizedSpec.dropLast())
            guard let percent = UInt64(valueText) else {
                return nil
            }
            return .percent(percent)
        }

        var valueText = normalizedSpec
        if valueText.hasSuffix("b") {
            valueText.removeLast()
        }

        var shift = 0
        if let suffix = valueText.last {
            switch suffix {
            case "k":
                shift = 10
                valueText.removeLast()
            case "m":
                shift = 20
                valueText.removeLast()
            case "g":
                shift = 30
                valueText.removeLast()
            case "t":
                shift = 40
                valueText.removeLast()
            default:
                break
            }
        }

        guard let baseValue = UInt64(valueText) else {
            return nil
        }
        return .bytes(baseValue << shift)
    }

    static func normalizedMemoryUsageSpec(_ spec: String) -> String {
        switch parseMemoryUsageSelection(spec) {
        case .auto:
            ""
        case let .percent(percent):
            "\(percent)%"
        case let .bytes(bytes):
            normalizedMemoryUsageSpec(forBytes: bytes)
        case nil:
            ""
        }
    }

    private static func normalizedMemoryUsageSpec(forBytes bytes: UInt64) -> String {
        let units: [(suffix: String, shift: UInt64)] = [
            ("t", 40),
            ("g", 30),
            ("m", 20),
            ("k", 10),
        ]

        for unit in units {
            let divisor = UInt64(1) << unit.shift
            if bytes.isMultiple(of: divisor) {
                return "\(bytes / divisor)\(unit.suffix)"
            }
        }

        return "\(bytes)"
    }

    private static func memoryUsageOptionTitle(for selection: MemoryUsageSelection) -> String {
        switch selection {
        case .auto:
            "Auto: \(defaultMemoryUsagePercent)%"
        case let .percent(percent):
            "\(percent)%"
        case let .bytes(bytes):
            memoryUsageText(for: bytes)
        }
    }

    private static func standardMemoryUsageByteChoices() -> [UInt64] {
        let maxIndex = (20 + MemoryLayout<Int>.size * 3 - 1) * 2
        var choices: [UInt64] = []
        choices.reserveCapacity(max(0, maxIndex - (27 * 2) + 1))

        for index in (27 * 2) ... maxIndex {
            let base = UInt64(2 + (index & 1))
            let shift = index / 2
            choices.append(base << shift)
        }
        return choices
    }

    static func memoryUsageText(for bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
                                  countStyle: .memory)
    }

    @MainActor
    enum ArchivePathHistory {
        private static let store = PathHistoryStore(entriesKey: "FileManager.CompressArchivePathHistory")

        static func entries() -> [String] {
            store.entries()
        }

        static func record(_ path: String) {
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            store.record(normalizedPath)
        }
    }

    enum DialogPreferences {
        private static var defaults: UserDefaults {
            SZSharedUserDefaults.defaults
        }

        private static let formatKey = "FileManager.CompressFormat"
        private static let updateModeKey = "FileManager.CompressUpdateMode"
        private static let pathModeKey = "FileManager.CompressPathMode"
        private static let openSharedKey = "FileManager.CompressOpenSharedFiles"
        private static let deleteAfterKey = "FileManager.CompressDeleteAfter"
        private static let encryptNamesKey = "FileManager.CompressEncryptNames"
        private static let showPasswordKey = "FileManager.CompressShowPassword"
        private static let memoryUsageKey = "FileManager.CompressMemoryUsage"
        private static let storeSymbolicLinksKey = "FileManager.CompressStoreSymbolicLinks"
        private static let storeHardLinksKey = "FileManager.CompressStoreHardLinks"
        private static let storeAlternateDataStreamsKey = "FileManager.CompressStoreAlternateDataStreams"
        private static let storeFileSecurityKey = "FileManager.CompressStoreFileSecurity"
        private static let preserveSourceAccessTimeKey = "FileManager.CompressPreserveSourceAccessTime"
        private static let storeModificationTimeKey = "FileManager.CompressStoreModificationTime"
        private static let storeModificationTimeSetKey = "FileManager.CompressStoreModificationTimeSet"
        private static let storeCreationTimeKey = "FileManager.CompressStoreCreationTime"
        private static let storeCreationTimeSetKey = "FileManager.CompressStoreCreationTimeSet"
        private static let storeAccessTimeKey = "FileManager.CompressStoreAccessTime"
        private static let storeAccessTimeSetKey = "FileManager.CompressStoreAccessTimeSet"
        private static let setArchiveTimeToLatestFileKey = "FileManager.CompressSetArchiveTimeToLatestFile"
        private static let setArchiveTimeToLatestFileSetKey = "FileManager.CompressSetArchiveTimeToLatestFileSet"
        private static let timePrecisionKey = "FileManager.CompressTimePrecision"
        private static let timePrecisionSetKey = "FileManager.CompressTimePrecisionSet"

        static func format(defaultValue: String,
                           allowedValues: [String]) -> String
        {
            guard let value = defaults.string(forKey: formatKey),
                  allowedValues.contains(value)
            else {
                return defaultValue
            }
            return value
        }

        static func updateMode(defaultValue: SZCompressionUpdateMode) -> SZCompressionUpdateMode {
            guard let rawValue = defaults.object(forKey: updateModeKey) as? Int,
                  let value = SZCompressionUpdateMode(rawValue: rawValue)
            else {
                return defaultValue
            }
            return value
        }

        static func pathMode(defaultValue: SZCompressionPathMode) -> SZCompressionPathMode {
            guard let rawValue = defaults.object(forKey: pathModeKey) as? Int,
                  let value = SZCompressionPathMode(rawValue: rawValue)
            else {
                return defaultValue
            }
            return value
        }

        static func openSharedFiles() -> Bool {
            defaults.bool(forKey: openSharedKey)
        }

        static func deleteAfterCompression() -> Bool {
            defaults.bool(forKey: deleteAfterKey)
        }

        static func encryptNames() -> Bool {
            defaults.bool(forKey: encryptNamesKey)
        }

        static func showPassword() -> Bool {
            defaults.bool(forKey: showPasswordKey)
        }

        static func memoryUsage() -> String {
            defaults.string(forKey: memoryUsageKey) ?? ""
        }

        static func hasStoredAdvancedOptions() -> Bool {
            let keys = [
                storeSymbolicLinksKey,
                storeHardLinksKey,
                storeAlternateDataStreamsKey,
                storeFileSecurityKey,
                preserveSourceAccessTimeKey,
                storeModificationTimeKey,
                storeModificationTimeSetKey,
                storeCreationTimeKey,
                storeCreationTimeSetKey,
                storeAccessTimeKey,
                storeAccessTimeSetKey,
                setArchiveTimeToLatestFileKey,
                setArchiveTimeToLatestFileSetKey,
                timePrecisionKey,
                timePrecisionSetKey,
            ]
            return keys.contains { defaults.object(forKey: $0) != nil }
        }

        private static func bool(forKey key: String,
                                 defaultValue: Bool) -> Bool
        {
            guard defaults.object(forKey: key) != nil else {
                return defaultValue
            }
            return defaults.bool(forKey: key)
        }

        private static func advancedBoolPairState(valueKey: String,
                                                  setKey: String,
                                                  defaultValue: Bool) -> AdvancedBoolPairState
        {
            let storedValueExists = defaults.object(forKey: valueKey) != nil
            let value = bool(forKey: valueKey, defaultValue: defaultValue)

            let isSet: Bool = if defaults.object(forKey: setKey) != nil {
                defaults.bool(forKey: setKey)
            } else if storedValueExists {
                value != defaultValue
            } else {
                false
            }

            return AdvancedBoolPairState(isSet: isSet,
                                         value: isSet ? value : defaultValue)
        }

        private static func advancedTimePrecisionState(defaults fallbackState: AdvancedTimePrecisionState) -> AdvancedTimePrecisionState {
            let rawTimePrecision = defaults.object(forKey: timePrecisionKey) as? Int
            let value = rawTimePrecision
                .flatMap(SZCompressionTimePrecision.init(rawValue:))
                ?? fallbackState.value

            let isSet: Bool = if defaults.object(forKey: timePrecisionSetKey) != nil {
                defaults.bool(forKey: timePrecisionSetKey)
            } else if rawTimePrecision != nil {
                value.rawValue != fallbackState.value.rawValue
            } else {
                false
            }

            return AdvancedTimePrecisionState(isSet: isSet,
                                              value: isSet ? value : fallbackState.value)
        }

        static func advancedOptions(defaults fallbackState: AdvancedOptionsState) -> AdvancedOptionsState {
            AdvancedOptionsState(
                storeSymbolicLinks: bool(forKey: storeSymbolicLinksKey,
                                         defaultValue: fallbackState.storeSymbolicLinks),
                storeHardLinks: bool(forKey: storeHardLinksKey,
                                     defaultValue: fallbackState.storeHardLinks),
                storeAlternateDataStreams: bool(forKey: storeAlternateDataStreamsKey,
                                                defaultValue: fallbackState.storeAlternateDataStreams),
                storeFileSecurity: bool(forKey: storeFileSecurityKey,
                                        defaultValue: fallbackState.storeFileSecurity),
                preserveSourceAccessTime: bool(forKey: preserveSourceAccessTimeKey,
                                               defaultValue: fallbackState.preserveSourceAccessTime),
                storeModificationTime: advancedBoolPairState(valueKey: storeModificationTimeKey,
                                                             setKey: storeModificationTimeSetKey,
                                                             defaultValue: fallbackState.storeModificationTime.value),
                storeCreationTime: advancedBoolPairState(valueKey: storeCreationTimeKey,
                                                         setKey: storeCreationTimeSetKey,
                                                         defaultValue: fallbackState.storeCreationTime.value),
                storeAccessTime: advancedBoolPairState(valueKey: storeAccessTimeKey,
                                                       setKey: storeAccessTimeSetKey,
                                                       defaultValue: fallbackState.storeAccessTime.value),
                setArchiveTimeToLatestFile: advancedBoolPairState(valueKey: setArchiveTimeToLatestFileKey,
                                                                  setKey: setArchiveTimeToLatestFileSetKey,
                                                                  defaultValue: fallbackState.setArchiveTimeToLatestFile.value),
                timePrecision: advancedTimePrecisionState(defaults: fallbackState.timePrecision),
            )
        }

        static func recordAdvancedOptions(_ state: AdvancedOptionsState) {
            defaults.set(state.storeSymbolicLinks, forKey: storeSymbolicLinksKey)
            defaults.set(state.storeHardLinks, forKey: storeHardLinksKey)
            defaults.set(state.storeAlternateDataStreams, forKey: storeAlternateDataStreamsKey)
            defaults.set(state.storeFileSecurity, forKey: storeFileSecurityKey)
            defaults.set(state.preserveSourceAccessTime, forKey: preserveSourceAccessTimeKey)
            defaults.set(state.storeModificationTime.value, forKey: storeModificationTimeKey)
            defaults.set(state.storeModificationTime.isSet, forKey: storeModificationTimeSetKey)
            defaults.set(state.storeCreationTime.value, forKey: storeCreationTimeKey)
            defaults.set(state.storeCreationTime.isSet, forKey: storeCreationTimeSetKey)
            defaults.set(state.storeAccessTime.value, forKey: storeAccessTimeKey)
            defaults.set(state.storeAccessTime.isSet, forKey: storeAccessTimeSetKey)
            defaults.set(state.setArchiveTimeToLatestFile.value, forKey: setArchiveTimeToLatestFileKey)
            defaults.set(state.setArchiveTimeToLatestFile.isSet, forKey: setArchiveTimeToLatestFileSetKey)
            defaults.set(state.timePrecision.value.rawValue, forKey: timePrecisionKey)
            defaults.set(state.timePrecision.isSet, forKey: timePrecisionSetKey)
        }

        static func record(format: String,
                           updateMode: SZCompressionUpdateMode,
                           pathMode: SZCompressionPathMode,
                           openSharedFiles: Bool,
                           deleteAfterCompression: Bool,
                           encryptNames: Bool,
                           showPassword: Bool,
                           memoryUsage: String)
        {
            defaults.set(format, forKey: formatKey)
            defaults.set(updateMode.rawValue, forKey: updateModeKey)
            defaults.set(pathMode.rawValue, forKey: pathModeKey)
            defaults.set(openSharedFiles, forKey: openSharedKey)
            defaults.set(deleteAfterCompression, forKey: deleteAfterKey)
            defaults.set(encryptNames, forKey: encryptNamesKey)
            defaults.set(showPassword, forKey: showPasswordKey)
            defaults.set(memoryUsage, forKey: memoryUsageKey)
        }
    }
}
