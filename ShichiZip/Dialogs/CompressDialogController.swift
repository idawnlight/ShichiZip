import Cocoa

struct CompressDialogResult {
    let settings: SZCompressionSettings
    let archiveURL: URL
}

final class CompressDialogController: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {

    private struct Option<Value: Equatable>: Equatable {
        let title: String
        let value: Value
    }

    private struct MethodOption: Equatable {
        let title: String
        let enumValue: SZCompressionMethod?
        let methodName: String
        let dictionaryLabel: String
        let dictionaryOptions: [Option<UInt64>]
        let wordLabel: String
        let wordOptions: [Option<UInt32>]
    }

    private struct FormatOption: Equatable {
        let title: String
        let codecName: String
        let format: SZArchiveFormat
        let defaultExtension: String
        let levelOptions: [Option<SZCompressionLevel>]
        let methods: [MethodOption]
        let supportsSolid: Bool
        let supportsThreads: Bool
        let encryptionOptions: [Option<SZEncryptionMethod>]
        let supportsEncryptFileNames: Bool
        let keepsName: Bool
    }

    private struct AdvancedBoolPairState: Equatable {
        var isSet: Bool
        var value: Bool
    }

    private struct AdvancedTimePrecisionState: Equatable {
        var isSet: Bool
        var value: SZCompressionTimePrecision
    }

    private struct AdvancedOptionsState: Equatable {
        var storeSymbolicLinks: Bool
        var storeHardLinks: Bool
        var storeAlternateDataStreams: Bool
        var storeFileSecurity: Bool
        var preserveSourceAccessTime: Bool
        var storeModificationTime: AdvancedBoolPairState
        var storeCreationTime: AdvancedBoolPairState
        var storeAccessTime: AdvancedBoolPairState
        var setArchiveTimeToLatestFile: AdvancedBoolPairState
        var timePrecision: AdvancedTimePrecisionState
    }

    private struct AdvancedOptionsCapabilities {
        var supportsSymbolicLinks: Bool
        var supportsHardLinks: Bool
        var supportsAlternateDataStreams: Bool
        var supportsFileSecurity: Bool
        var supportsModificationTime: Bool
        var supportsCreationTime: Bool
        var supportsAccessTime: Bool
        var defaultModificationTime: Bool
        var defaultCreationTime: Bool
        var defaultAccessTime: Bool
        var keepsName: Bool
        var supportedTimePrecisions: [SZCompressionTimePrecision]
        var defaultTimePrecision: SZCompressionTimePrecision

        var hasMetadataControls: Bool {
            supportsSymbolicLinks || supportsHardLinks || supportsAlternateDataStreams || supportsFileSecurity
        }
    }

    private struct CompressionResourceEstimate {
        let compressionMemory: UInt64?
        let decompressionMemory: UInt64?
        let memoryUsageLimit: UInt64?
        let resolvedDictionarySize: UInt64?
        let resolvedWordSize: UInt32?
        let resolvedNumThreads: UInt32?
    }

    private enum MemoryUsageSelection: Equatable {
        case auto
        case percent(UInt64)
        case bytes(UInt64)
    }

    private enum ArchivePathHistory {
        private static let defaults = UserDefaults.standard
        private static let entriesKey = "FileManager.CompressArchivePathHistory"
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
                           allowedValues: [String]) -> String {
            guard let value = defaults.string(forKey: formatKey),
                  allowedValues.contains(value) else {
                return defaultValue
            }
            return value
        }

        static func updateMode(defaultValue: SZCompressionUpdateMode) -> SZCompressionUpdateMode {
            guard let rawValue = defaults.object(forKey: updateModeKey) as? Int,
                  let value = SZCompressionUpdateMode(rawValue: rawValue) else {
                return defaultValue
            }
            return value
        }

        static func pathMode(defaultValue: SZCompressionPathMode) -> SZCompressionPathMode {
            guard let rawValue = defaults.object(forKey: pathModeKey) as? Int,
                  let value = SZCompressionPathMode(rawValue: rawValue) else {
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
                                 defaultValue: Bool) -> Bool {
            guard defaults.object(forKey: key) != nil else {
                return defaultValue
            }
            return defaults.bool(forKey: key)
        }

        private static func advancedBoolPairState(valueKey: String,
                                                  setKey: String,
                                                  defaultValue: Bool) -> AdvancedBoolPairState {
            let storedValueExists = defaults.object(forKey: valueKey) != nil
            let value = bool(forKey: valueKey, defaultValue: defaultValue)

            let isSet: Bool
            if defaults.object(forKey: setKey) != nil {
                isSet = defaults.bool(forKey: setKey)
            } else if storedValueExists {
                isSet = (value != defaultValue)
            } else {
                isSet = false
            }

            return AdvancedBoolPairState(isSet: isSet,
                                         value: isSet ? value : defaultValue)
        }

        private static func advancedTimePrecisionState(defaults fallbackState: AdvancedTimePrecisionState) -> AdvancedTimePrecisionState {
            let rawTimePrecision = defaults.object(forKey: timePrecisionKey) as? Int
            let value = rawTimePrecision
                .flatMap(SZCompressionTimePrecision.init(rawValue:))
                ?? fallbackState.value

            let isSet: Bool
            if defaults.object(forKey: timePrecisionSetKey) != nil {
                isSet = defaults.bool(forKey: timePrecisionSetKey)
            } else if rawTimePrecision != nil {
                isSet = (value.rawValue != fallbackState.value.rawValue)
            } else {
                isSet = false
            }

            return AdvancedTimePrecisionState(isSet: isSet,
                                              value: isSet ? value : fallbackState.value)
        }

        static func advancedOptions(defaults fallbackState: AdvancedOptionsState) -> AdvancedOptionsState {
            return AdvancedOptionsState(
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
                timePrecision: advancedTimePrecisionState(defaults: fallbackState.timePrecision)
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
                           memoryUsage: String) {
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

    private final class ArchivePathPicker: NSObject {
        private weak var ownerWindow: NSWindow?
        private weak var pathField: NSComboBox?
        private let baseDirectory: URL
        private let defaultFileNameProvider: () -> String

        init(ownerWindow: NSWindow?,
             pathField: NSComboBox,
             baseDirectory: URL,
             defaultFileNameProvider: @escaping () -> String) {
            self.ownerWindow = ownerWindow
            self.pathField = pathField
            self.baseDirectory = baseDirectory.standardizedFileURL
            self.defaultFileNameProvider = defaultFileNameProvider
        }

        @objc func browse(_ sender: Any?) {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.directoryURL = suggestedDirectoryURL()
            panel.nameFieldStringValue = suggestedFileName()

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

    private final class ActionHandler: NSObject {
        private let handler: () -> Void

        init(handler: @escaping () -> Void) {
            self.handler = handler
        }

        @objc func invoke(_ sender: Any?) {
            handler()
        }
    }

    private static let knownArchiveExtensions: Set<String> = ["7z", "zip", "tar", "gz", "gzip", "bz2", "bzip2", "xz", "wim", "zst", "zstd", "exe"]
    private static let defaultMemoryUsagePercent: UInt64 = 80
    private static let knownTimePrecisionValues: [SZCompressionTimePrecision] = [
        SZCompressionTimePrecision(rawValue: 0)!,
        SZCompressionTimePrecision(rawValue: 1)!,
        SZCompressionTimePrecision(rawValue: 2)!,
        SZCompressionTimePrecision(rawValue: 3)!,
    ]
    private static let formLabelWidth: CGFloat = 126
    private static let leftColumnWidth: CGFloat = 320
    private static let rightColumnWidth: CGFloat = 364
    private static let columnSpacing: CGFloat = 20

    private static let levelOptions: [Option<SZCompressionLevel>] = [
        Option(title: "Store", value: .store),
        Option(title: "Fastest", value: .fastest),
        Option(title: "Fast", value: .fast),
        Option(title: "Normal", value: .normal),
        Option(title: "Maximum", value: .maximum),
        Option(title: "Ultra", value: .ultra),
    ]

    private static let storeOnlyLevelOptions: [Option<SZCompressionLevel>] = [
        Option(title: "Store", value: .store)
    ]

    private static let standardDictionaryOptions: [Option<UInt64>] = [
        Option(title: "Auto", value: 0),
        Option(title: "64 KB", value: 64 * 1024),
        Option(title: "256 KB", value: 256 * 1024),
        Option(title: "1 MB", value: 1 << 20),
        Option(title: "4 MB", value: 4 << 20),
        Option(title: "8 MB", value: 8 << 20),
        Option(title: "16 MB", value: 16 << 20),
        Option(title: "32 MB", value: 32 << 20),
        Option(title: "64 MB", value: 64 << 20),
        Option(title: "128 MB", value: 128 << 20),
        Option(title: "256 MB", value: 256 << 20),
    ]

    private static let ppmdDictionaryOptions: [Option<UInt64>] = [
        Option(title: "Auto", value: 0),
        Option(title: "1 MB", value: 1 << 20),
        Option(title: "2 MB", value: 2 << 20),
        Option(title: "4 MB", value: 4 << 20),
        Option(title: "8 MB", value: 8 << 20),
        Option(title: "16 MB", value: 16 << 20),
        Option(title: "32 MB", value: 32 << 20),
        Option(title: "64 MB", value: 64 << 20),
        Option(title: "128 MB", value: 128 << 20),
        Option(title: "256 MB", value: 256 << 20),
    ]

    private static let standardWordOptions: [Option<UInt32>] = [
        Option(title: "Auto", value: 0),
        Option(title: "8", value: 8),
        Option(title: "12", value: 12),
        Option(title: "16", value: 16),
        Option(title: "24", value: 24),
        Option(title: "32", value: 32),
        Option(title: "48", value: 48),
        Option(title: "64", value: 64),
        Option(title: "96", value: 96),
        Option(title: "128", value: 128),
        Option(title: "192", value: 192),
        Option(title: "256", value: 256),
        Option(title: "273", value: 273),
    ]

    private static let orderOptions: [Option<UInt32>] =
        [Option(title: "Auto", value: 0)] + (2...32).map { Option(title: "\($0)", value: UInt32($0)) }

    private static let updateModeOptions: [Option<SZCompressionUpdateMode>] = [
        Option(title: "Add and replace files", value: .add),
        Option(title: "Update and add files", value: .update),
        Option(title: "Freshen existing files", value: .fresh),
        Option(title: "Synchronize files", value: .sync),
    ]

    private static let pathModeOptions: [Option<SZCompressionPathMode>] = [
        Option(title: "Relative paths", value: .relativePaths),
        Option(title: "Full paths", value: .fullPaths),
        Option(title: "Absolute paths", value: .absolutePaths),
    ]

    private static let solidOptions: [Option<Bool>] = [
        Option(title: "Non-solid", value: false),
        Option(title: "Solid", value: true),
    ]

    private static let splitVolumePresets = [
        "10M",
        "100M",
        "1000M",
        "650M - CD",
        "700M - CD",
        "4092M - FAT",
        "4480M - DVD",
        "8128M - DVD DL",
        "23040M - BD",
    ]

    private static let sevenZipMethods: [MethodOption] = [
        MethodOption(title: "LZMA2", enumValue: .LZMA2, methodName: "LZMA2", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: standardWordOptions),
        MethodOption(title: "LZMA", enumValue: .LZMA, methodName: "LZMA", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: standardWordOptions),
        MethodOption(title: "PPMd", enumValue: .ppMd, methodName: "PPMd", dictionaryLabel: "Memory usage:", dictionaryOptions: ppmdDictionaryOptions, wordLabel: "Order:", wordOptions: orderOptions),
        MethodOption(title: "BZip2", enumValue: .bZip2, methodName: "BZip2", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: standardWordOptions),
        MethodOption(title: "Deflate", enumValue: .deflate, methodName: "Deflate", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: standardWordOptions),
        MethodOption(title: "Deflate64", enumValue: .deflate64, methodName: "Deflate64", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: standardWordOptions),
        MethodOption(title: "Copy", enumValue: .copy, methodName: "Copy", dictionaryLabel: "Dictionary size:", dictionaryOptions: [], wordLabel: "Word size:", wordOptions: []),
    ]

    private static let zipMethods: [MethodOption] = [
        MethodOption(title: "Deflate", enumValue: .deflate, methodName: "Deflate", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: standardWordOptions),
        MethodOption(title: "Deflate64", enumValue: .deflate64, methodName: "Deflate64", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: standardWordOptions),
        MethodOption(title: "BZip2", enumValue: .bZip2, methodName: "BZip2", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: standardWordOptions),
        MethodOption(title: "LZMA", enumValue: .LZMA, methodName: "LZMA", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: standardWordOptions),
        MethodOption(title: "PPMd", enumValue: .ppMd, methodName: "PPMd", dictionaryLabel: "Memory usage:", dictionaryOptions: ppmdDictionaryOptions, wordLabel: "Order:", wordOptions: orderOptions),
    ]

    private static let gzipMethods: [MethodOption] = [
        MethodOption(title: "Deflate", enumValue: .deflate, methodName: "Deflate", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: standardWordOptions),
    ]

    private static let bzip2Methods: [MethodOption] = [
        MethodOption(title: "BZip2", enumValue: .bZip2, methodName: "BZip2", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: standardWordOptions),
    ]

    private static let xzMethods: [MethodOption] = [
        MethodOption(title: "LZMA2", enumValue: .LZMA2, methodName: "LZMA2", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: standardWordOptions),
    ]

    private static let tarMethods: [MethodOption] = [
        MethodOption(title: "GNU", enumValue: nil, methodName: "GNU", dictionaryLabel: "Dictionary size:", dictionaryOptions: [], wordLabel: "Word size:", wordOptions: []),
        MethodOption(title: "POSIX", enumValue: nil, methodName: "POSIX", dictionaryLabel: "Dictionary size:", dictionaryOptions: [], wordLabel: "Word size:", wordOptions: []),
    ]

    private static let zstdMethods: [MethodOption] = [
        MethodOption(title: "ZSTD", enumValue: nil, methodName: "ZSTD", dictionaryLabel: "Dictionary size:", dictionaryOptions: standardDictionaryOptions, wordLabel: "Word size:", wordOptions: []),
    ]

    private static let formatCatalog: [FormatOption] = [
        FormatOption(title: "7z", codecName: "7z", format: .format7z, defaultExtension: "7z", levelOptions: levelOptions, methods: sevenZipMethods, supportsSolid: true, supportsThreads: true, encryptionOptions: [Option(title: "AES-256", value: .AES256)], supportsEncryptFileNames: true, keepsName: false),
        FormatOption(title: "zip", codecName: "zip", format: .formatZip, defaultExtension: "zip", levelOptions: levelOptions, methods: zipMethods, supportsSolid: false, supportsThreads: true, encryptionOptions: [Option(title: "ZipCrypto", value: .zipCrypto), Option(title: "AES-256", value: .AES256)], supportsEncryptFileNames: false, keepsName: false),
        FormatOption(title: "tar", codecName: "tar", format: .formatTar, defaultExtension: "tar", levelOptions: storeOnlyLevelOptions, methods: tarMethods, supportsSolid: false, supportsThreads: false, encryptionOptions: [], supportsEncryptFileNames: false, keepsName: false),
        FormatOption(title: "gzip", codecName: "gzip", format: .formatGZip, defaultExtension: "gz", levelOptions: levelOptions, methods: gzipMethods, supportsSolid: false, supportsThreads: false, encryptionOptions: [], supportsEncryptFileNames: false, keepsName: true),
        FormatOption(title: "bzip2", codecName: "bzip2", format: .formatBZip2, defaultExtension: "bz2", levelOptions: levelOptions, methods: bzip2Methods, supportsSolid: false, supportsThreads: true, encryptionOptions: [], supportsEncryptFileNames: false, keepsName: true),
        FormatOption(title: "xz", codecName: "xz", format: .formatXz, defaultExtension: "xz", levelOptions: levelOptions, methods: xzMethods, supportsSolid: true, supportsThreads: true, encryptionOptions: [], supportsEncryptFileNames: false, keepsName: true),
        FormatOption(title: "wim", codecName: "wim", format: .formatWim, defaultExtension: "wim", levelOptions: storeOnlyLevelOptions, methods: [], supportsSolid: false, supportsThreads: false, encryptionOptions: [], supportsEncryptFileNames: false, keepsName: false),
        FormatOption(title: "zstd", codecName: "zstd", format: .formatZstd, defaultExtension: "zst", levelOptions: levelOptions, methods: zstdMethods, supportsSolid: false, supportsThreads: true, encryptionOptions: [], supportsEncryptFileNames: false, keepsName: true),
    ]

    private let sourceURLs: [URL]
    private let baseDirectory: URL
    private let messageText: String?
    private let suggestedBaseName: String
    private let supportedFormatInfoByName: [String: SZFormatInfo]
    private let availableFormats: [FormatOption]
    private let hasStoredAdvancedPreferences: Bool

    private var archivePathPicker: ArchivePathPicker?
    private weak var currentDialogWindow: NSWindow?
    private weak var archivePathField: NSComboBox?
    private weak var formatPopup: NSPopUpButton?
    private weak var levelPopup: NSPopUpButton?
    private weak var methodPopup: NSPopUpButton?
    private weak var dictionaryPopup: NSPopUpButton?
    private weak var wordPopup: NSPopUpButton?
    private weak var solidPopup: NSPopUpButton?
    private weak var threadField: NSComboBox?
    private weak var memoryUsagePopup: NSPopUpButton?
    private weak var splitVolumesField: NSComboBox?
    private weak var parametersField: NSTextField?
    private weak var updateModePopup: NSPopUpButton?
    private weak var pathModePopup: NSPopUpButton?
    private weak var encryptionPopup: NSPopUpButton?
    private weak var encryptNamesCheckbox: NSButton?
    private weak var createSFXCheckbox: NSButton?
    private weak var excludeMacResourceFilesCheckbox: NSButton?
    private weak var openSharedCheckbox: NSButton?
    private weak var deleteAfterCheckbox: NSButton?
    private weak var dictionaryLabel: NSTextField?
    private weak var wordLabel: NSTextField?
    private weak var threadInfoLabel: NSTextField?
    private weak var compressionMemoryLabel: NSTextField?
    private weak var decompressionMemoryLabel: NSTextField?
    private weak var memoryUsageRow: NSView?
    private weak var compressionMemoryRow: NSView?
    private weak var decompressionMemoryRow: NSView?
    private weak var securePasswordField: NSSecureTextField?
    private weak var plainPasswordField: NSTextField?
    private weak var secureConfirmPasswordField: NSSecureTextField?
    private weak var plainConfirmPasswordField: NSTextField?
    private weak var showPasswordCheckbox: NSButton?
    private weak var advancedOptionsSummaryLabel: NSTextField?
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

    init(sourceURLs: [URL],
         baseDirectory: URL? = nil,
         message: String? = nil) {
        let normalizedSourceURLs = sourceURLs.map { $0.standardizedFileURL }
        let resolvedBaseDirectory = (baseDirectory ?? Self.suggestedBaseDirectory(for: normalizedSourceURLs)).standardizedFileURL
        let supportedFormatInfoByName = Self.makeSupportedFormatInfoByName()

        self.sourceURLs = normalizedSourceURLs
        self.baseDirectory = resolvedBaseDirectory
        self.suggestedBaseName = Self.suggestedArchiveBaseName(for: normalizedSourceURLs,
                                                               baseDirectory: resolvedBaseDirectory)
        self.supportedFormatInfoByName = supportedFormatInfoByName
        self.availableFormats = Self.makeAvailableFormats(supportedFormatInfoByName: supportedFormatInfoByName,
                                  sourceURLs: normalizedSourceURLs)
        self.hasStoredAdvancedPreferences = DialogPreferences.hasStoredAdvancedOptions()
        self.messageText = message ?? Self.defaultMessage(for: normalizedSourceURLs,
                                                          baseDirectory: resolvedBaseDirectory)

        super.init()
    }

    func runModal(for parentWindow: NSWindow?) -> CompressDialogResult? {
        guard !availableFormats.isEmpty else {
            szPresentMessage(title: "No Archive Formats Available",
                             message: "7-Zip did not report any writable archive formats.",
                             style: .warning,
                             for: parentWindow)
            return nil
        }

        let allowedFormats = availableFormats.map(\.codecName)
        var selectedFormatName = DialogPreferences.format(defaultValue: availableFormats[0].codecName,
                                                          allowedValues: allowedFormats)
        var selectedUpdateMode = DialogPreferences.updateMode(defaultValue: .add)
        var selectedPathMode = DialogPreferences.pathMode(defaultValue: .relativePaths)
        var openSharedFiles = DialogPreferences.openSharedFiles()
        var deleteAfterCompression = DialogPreferences.deleteAfterCompression()
        var encryptNames = DialogPreferences.encryptNames()
        var showPassword = DialogPreferences.showPassword()
        var selectedArchivePath = defaultArchiveURL(for: selectedFormatName).path
        var selectedLevel = defaultLevel(for: selectedFormatName)
        var selectedMethodName = defaultMethodName(for: selectedFormatName)
        var selectedDictionarySize: UInt64 = 0
        var selectedWordSize: UInt32 = 0
        var selectedSolidMode = true
        var selectedThreadText = "Auto"
        var selectedMemoryUsageSpec = DialogPreferences.memoryUsage()
        var selectedSplitVolumes = ""
        var selectedParameters = ""
        var selectedPassword = ""
        var selectedConfirmation = ""
        var selectedEncryption = defaultEncryption(for: selectedFormatName)
        var createSFX = false
        var excludeMacResourceFiles = SZSettings.bool(.excludeMacResourceFilesByDefault)
        var advancedOptions = DialogPreferences.advancedOptions(
            defaults: defaultAdvancedOptionsState(for: formatOption(named: selectedFormatName) ?? availableFormats[0],
                                                 methodName: selectedMethodName)
        )
        var advancedOptionsCustomized = hasStoredAdvancedPreferences

        while true {
            let archivePathField = NSComboBox(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
            archivePathField.usesDataSource = false
            archivePathField.completes = false
            archivePathField.isEditable = true
            archivePathField.addItems(withObjectValues: ArchivePathHistory.entries())
            archivePathField.stringValue = selectedArchivePath
            archivePathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

            let browseButton = NSButton(title: "Browse...", target: nil, action: nil)
            browseButton.bezelStyle = .rounded

            let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            availableFormats.forEach { formatPopup.addItem(withTitle: $0.title) }
            if let selectedIndex = availableFormats.firstIndex(where: { $0.codecName == selectedFormatName }) {
                formatPopup.selectItem(at: selectedIndex)
            }
            formatPopup.target = self
            formatPopup.action = #selector(formatChanged(_:))

            let levelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            levelPopup.target = self
            levelPopup.action = #selector(compressionSettingsChanged(_:))
            let methodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            methodPopup.target = self
            methodPopup.action = #selector(methodChanged(_:))
            let dictionaryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            dictionaryPopup.target = self
            dictionaryPopup.action = #selector(compressionSettingsChanged(_:))
            let wordPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            wordPopup.target = self
            wordPopup.action = #selector(compressionSettingsChanged(_:))

            let solidPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            Self.solidOptions.forEach { solidPopup.addItem(withTitle: $0.title) }
            solidPopup.target = self
            solidPopup.action = #selector(compressionSettingsChanged(_:))

            let threadField = NSComboBox(frame: NSRect(x: 0, y: 0, width: 140, height: 26))
            threadField.usesDataSource = false
            threadField.completes = false
            threadField.isEditable = true
            threadField.addItems(withObjectValues: ["Auto"] + Self.threadChoices())
            threadField.stringValue = selectedThreadText
            threadField.target = self
            threadField.action = #selector(compressionSettingsChanged(_:))
            threadField.delegate = self

            let threadInfoLabel = makeInfoLabel(minWidth: 52)
            let threadControl = NSStackView(views: [threadField, threadInfoLabel])
            threadControl.orientation = .horizontal
            threadControl.alignment = .centerY
            threadControl.spacing = 6

            let memoryUsageOptions = Self.makeMemoryUsageOptions(preferredSpec: selectedMemoryUsageSpec)
            let memoryUsagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            Self.populateMemoryUsagePopup(memoryUsagePopup,
                                          with: memoryUsageOptions,
                                          selectedSpec: selectedMemoryUsageSpec)
            memoryUsagePopup.target = self
            memoryUsagePopup.action = #selector(compressionSettingsChanged(_:))
            memoryUsagePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

            let memoryUsageRow = makeFormRow(label: "Memory usage:",
                                             control: memoryUsagePopup,
                                             labelWidth: 152)

            let compressionMemoryLabel = makeInfoLabel(minWidth: 132)
            let decompressionMemoryLabel = makeInfoLabel(minWidth: 132)
            let compressionMemoryRow = makeFormRow(label: "Compressing memory:",
                                                   control: compressionMemoryLabel,
                                                   labelWidth: 152)
            let decompressionMemoryRow = makeFormRow(label: "Decompressing memory:",
                                                     control: decompressionMemoryLabel,
                                                     labelWidth: 152)

            let splitVolumesField = NSComboBox(frame: NSRect(x: 0, y: 0, width: 180, height: 26))
            splitVolumesField.usesDataSource = false
            splitVolumesField.completes = false
            splitVolumesField.isEditable = true
            splitVolumesField.addItems(withObjectValues: Self.splitVolumePresets)
            splitVolumesField.stringValue = selectedSplitVolumes

            let parametersField = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
            parametersField.stringValue = selectedParameters
            parametersField.placeholderString = "e.g. d=64m fb=273"

            let updateModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            Self.updateModeOptions.forEach { updateModePopup.addItem(withTitle: $0.title) }
            if let selectedIndex = Self.updateModeOptions.firstIndex(where: { $0.value == selectedUpdateMode }) {
                updateModePopup.selectItem(at: selectedIndex)
            }

            let pathModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            Self.pathModeOptions.forEach { pathModePopup.addItem(withTitle: $0.title) }
            if let selectedIndex = Self.pathModeOptions.firstIndex(where: { $0.value == selectedPathMode }) {
                pathModePopup.selectItem(at: selectedIndex)
            }

            let openSharedCheckbox = NSButton(checkboxWithTitle: "Compress shared files", target: nil, action: nil)
            openSharedCheckbox.state = openSharedFiles ? .on : .off
            let deleteAfterCheckbox = NSButton(checkboxWithTitle: "Delete files after compression", target: nil, action: nil)
            deleteAfterCheckbox.state = deleteAfterCompression ? .on : .off
            let createSFXCheckbox = NSButton(checkboxWithTitle: "Create Windows SFX archive",
                                             target: self,
                                             action: #selector(createSFXToggled(_:)))
            createSFXCheckbox.state = createSFX ? .on : .off
            let excludeMacResourceFilesCheckbox = NSButton(checkboxWithTitle: "Exclude macOS resource files",
                                                           target: nil,
                                                           action: nil)
            excludeMacResourceFilesCheckbox.state = excludeMacResourceFiles ? .on : .off

            let advancedOptionsButton = NSButton(title: "Options",
                                                 target: self,
                                                 action: #selector(showAdvancedOptions(_:)))
            advancedOptionsButton.bezelStyle = .rounded
            advancedOptionsButton.setContentHuggingPriority(.required, for: .horizontal)
            advancedOptionsButton.setContentCompressionResistancePriority(.required, for: .horizontal)

            let advancedOptionsSummaryLabel = NSTextField(labelWithString: "")
            advancedOptionsSummaryLabel.font = .systemFont(ofSize: 11)
            advancedOptionsSummaryLabel.textColor = .secondaryLabelColor
            advancedOptionsSummaryLabel.lineBreakMode = .byTruncatingTail
            advancedOptionsSummaryLabel.cell?.wraps = false
            advancedOptionsSummaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            advancedOptionsSummaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let advancedOptionsRow = NSStackView(views: [advancedOptionsButton, advancedOptionsSummaryLabel])
            advancedOptionsRow.orientation = .horizontal
            advancedOptionsRow.alignment = .centerY
            advancedOptionsRow.spacing = 8
            advancedOptionsRow.distribution = .fill

            let encryptionPopup = NSPopUpButton(frame: .zero, pullsDown: false)

            let securePasswordField = NSSecureTextField(frame: .zero)
            securePasswordField.stringValue = selectedPassword
            securePasswordField.placeholderString = "Optional"
            securePasswordField.delegate = self

            let plainPasswordField = NSTextField(frame: .zero)
            plainPasswordField.stringValue = selectedPassword
            plainPasswordField.placeholderString = "Optional"
            plainPasswordField.delegate = self

            let secureConfirmPasswordField = NSSecureTextField(frame: .zero)
            secureConfirmPasswordField.stringValue = selectedConfirmation
            secureConfirmPasswordField.placeholderString = "Retype password"
            secureConfirmPasswordField.delegate = self

            let plainConfirmPasswordField = NSTextField(frame: .zero)
            plainConfirmPasswordField.stringValue = selectedConfirmation
            plainConfirmPasswordField.placeholderString = "Retype password"
            plainConfirmPasswordField.delegate = self

            let passwordContainer = makePasswordContainer(secureField: securePasswordField,
                                                          plainField: plainPasswordField)
            let confirmPasswordContainer = makePasswordContainer(secureField: secureConfirmPasswordField,
                                                                 plainField: plainConfirmPasswordField)

            let showPasswordCheckbox = NSButton(checkboxWithTitle: "Show password",
                                                target: self,
                                                action: #selector(showPasswordToggled(_:)))
            showPasswordCheckbox.state = showPassword ? .on : .off

            let encryptNamesCheckbox = NSButton(checkboxWithTitle: "Encrypt file names",
                                                target: nil,
                                                action: nil)
            encryptNamesCheckbox.state = encryptNames ? .on : .off

            let dictionaryLabel = NSTextField(labelWithString: "Dictionary size:")
            let wordLabel = NSTextField(labelWithString: "Word size:")

            let archivePathRow = makePathRow(label: "Archive:",
                                             pathField: archivePathField,
                                             browseButton: browseButton)

            let leftColumn = makeColumn(rows: [
                makeFormRow(label: "Archive format:", control: formatPopup),
                makeFormRow(label: "Compression level:", control: levelPopup),
                makeFormRow(label: "Compression method:", control: methodPopup),
                makeFormRow(labelField: dictionaryLabel, control: dictionaryPopup),
                makeFormRow(labelField: wordLabel, control: wordPopup),
                makeFormRow(label: "Solid block size:", control: solidPopup),
                makeFormRow(label: "CPU threads:", control: threadControl),
                memoryUsageRow,
                compressionMemoryRow,
                decompressionMemoryRow,
                makeFormRow(label: "Split to volumes:", control: splitVolumesField),
                makeFormRow(label: "Parameters:", control: parametersField),
            ])

            let optionsColumn = makeTitledSection(title: "Options", rows: [
                createSFXCheckbox,
                excludeMacResourceFilesCheckbox,
                openSharedCheckbox,
                deleteAfterCheckbox,
                advancedOptionsRow,
            ])

            let encryptionColumn = makeTitledSection(title: "Encryption", rows: [
                makeFormRow(label: "Password:", control: passwordContainer),
                makeFormRow(label: "Retype password:", control: confirmPasswordContainer),
                showPasswordCheckbox,
                makeFormRow(label: "Encryption method:", control: encryptionPopup),
                encryptNamesCheckbox,
            ])

            let rightColumn = makeColumn(rows: [
                makeFormRow(label: "Update mode:", control: updateModePopup),
                makeFormRow(label: "Path mode:", control: pathModePopup),
                optionsColumn,
                encryptionColumn,
            ])

            leftColumn.widthAnchor.constraint(equalToConstant: Self.leftColumnWidth).isActive = true
            rightColumn.widthAnchor.constraint(equalToConstant: Self.rightColumnWidth).isActive = true
            optionsColumn.widthAnchor.constraint(equalTo: rightColumn.widthAnchor).isActive = true
            encryptionColumn.widthAnchor.constraint(equalTo: rightColumn.widthAnchor).isActive = true

            let columns = NSStackView(views: [leftColumn, rightColumn])
            columns.orientation = .horizontal
            columns.alignment = .top
            columns.distribution = .fill
            columns.spacing = Self.columnSpacing
            columns.widthAnchor.constraint(equalToConstant: Self.leftColumnWidth + Self.rightColumnWidth + Self.columnSpacing).isActive = true

            let accessoryView = NSStackView(views: [archivePathRow, columns])
            accessoryView.orientation = .vertical
            accessoryView.alignment = .leading
            accessoryView.spacing = 16
            accessoryView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

            let controller = SZModalDialogController(style: .informational,
                                                     title: "Add to Archive",
                                                     message: messageText,
                                                     buttonTitles: ["Cancel", "OK"],
                                                     accessoryView: accessoryView,
                                                     preferredFirstResponder: archivePathField,
                                                     cancelButtonIndex: 0)
            currentDialogWindow = controller.window
            self.archivePathField = archivePathField
            self.formatPopup = formatPopup
            self.levelPopup = levelPopup
            self.methodPopup = methodPopup
            self.dictionaryPopup = dictionaryPopup
            self.wordPopup = wordPopup
            self.solidPopup = solidPopup
            self.threadField = threadField
            self.memoryUsagePopup = memoryUsagePopup
            self.splitVolumesField = splitVolumesField
            self.parametersField = parametersField
            self.updateModePopup = updateModePopup
            self.pathModePopup = pathModePopup
            self.encryptionPopup = encryptionPopup
            self.encryptNamesCheckbox = encryptNamesCheckbox
            self.createSFXCheckbox = createSFXCheckbox
            self.excludeMacResourceFilesCheckbox = excludeMacResourceFilesCheckbox
            self.openSharedCheckbox = openSharedCheckbox
            self.deleteAfterCheckbox = deleteAfterCheckbox
            self.dictionaryLabel = dictionaryLabel
            self.wordLabel = wordLabel
            self.threadInfoLabel = threadInfoLabel
            self.memoryUsageRow = memoryUsageRow
            self.compressionMemoryLabel = compressionMemoryLabel
            self.decompressionMemoryLabel = decompressionMemoryLabel
            self.compressionMemoryRow = compressionMemoryRow
            self.decompressionMemoryRow = decompressionMemoryRow
            self.securePasswordField = securePasswordField
            self.plainPasswordField = plainPasswordField
            self.secureConfirmPasswordField = secureConfirmPasswordField
            self.plainConfirmPasswordField = plainConfirmPasswordField
            self.showPasswordCheckbox = showPasswordCheckbox
            self.advancedOptionsSummaryLabel = advancedOptionsSummaryLabel
            self.advancedOptionsState = advancedOptions
            self.advancedOptionsWereCustomized = advancedOptionsCustomized

            reloadFormatDependentControls(preferredLevel: selectedLevel,
                                          preferredMethodName: selectedMethodName,
                                          preferredDictionarySize: selectedDictionarySize,
                                          preferredWordSize: selectedWordSize,
                                          preferredEncryption: selectedEncryption)
            selectOption(Self.solidOptions, selectedValue: selectedSolidMode, on: solidPopup)
            updatePasswordVisibilityUI(moveFocus: false)
            refreshOptionAvailability()

            let picker = ArchivePathPicker(ownerWindow: controller.window,
                                           pathField: archivePathField,
                                           baseDirectory: baseDirectory) { [weak self] in
                self?.suggestedArchiveFileName() ?? "Archive.7z"
            }
            archivePathPicker = picker
            browseButton.target = picker
            browseButton.action = #selector(ArchivePathPicker.browse(_:))

            defer {
                archivePathPicker = nil
                currentDialogWindow = nil
                self.archivePathField = nil
                self.formatPopup = nil
                self.levelPopup = nil
                self.methodPopup = nil
                self.dictionaryPopup = nil
                self.wordPopup = nil
                self.solidPopup = nil
                self.threadField = nil
                self.memoryUsagePopup = nil
                self.splitVolumesField = nil
                self.parametersField = nil
                self.updateModePopup = nil
                self.pathModePopup = nil
                self.encryptionPopup = nil
                self.encryptNamesCheckbox = nil
                self.createSFXCheckbox = nil
                self.excludeMacResourceFilesCheckbox = nil
                self.openSharedCheckbox = nil
                self.deleteAfterCheckbox = nil
                self.dictionaryLabel = nil
                self.wordLabel = nil
                self.threadInfoLabel = nil
                self.memoryUsageRow = nil
                self.compressionMemoryLabel = nil
                self.decompressionMemoryLabel = nil
                self.compressionMemoryRow = nil
                self.decompressionMemoryRow = nil
                self.securePasswordField = nil
                self.plainPasswordField = nil
                self.secureConfirmPasswordField = nil
                self.plainConfirmPasswordField = nil
                self.showPasswordCheckbox = nil
                self.advancedOptionsSummaryLabel = nil
            }

            guard controller.runModal() == 1 else {
                return nil
            }

            syncPasswordFields()
            selectedArchivePath = archivePathField.stringValue
            selectedFormatName = selectedFormatOption()?.codecName ?? selectedFormatName
            selectedLevel = selectedLevelOption()?.value ?? selectedLevel
            selectedMethodName = selectedMethodOption()?.methodName ?? ""
            selectedDictionarySize = selectedDictionaryOption()?.value ?? 0
            selectedWordSize = selectedWordOption()?.value ?? 0
            selectedSolidMode = selectedSolidOption()?.value ?? selectedSolidMode
            selectedThreadText = Self.normalizedThreadText(threadField.stringValue)
            selectedMemoryUsageSpec = selectedMemoryUsageSpecValue()
            selectedSplitVolumes = splitVolumesField.stringValue
            selectedParameters = parametersField.stringValue
            selectedPassword = currentPasswordValue()
            selectedConfirmation = currentConfirmationValue()
            showPassword = showPasswordCheckbox.state == .on
            selectedUpdateMode = selectedUpdateModeOption()?.value ?? selectedUpdateMode
            selectedPathMode = selectedPathModeOption()?.value ?? selectedPathMode
            selectedEncryption = selectedEncryptionOption()?.value ?? .none
            encryptNames = encryptNamesCheckbox.state == .on
            createSFX = createSFXCheckbox.state == .on
            excludeMacResourceFiles = excludeMacResourceFilesCheckbox.state == .on
            openSharedFiles = openSharedCheckbox.state == .on
            deleteAfterCompression = deleteAfterCheckbox.state == .on
            advancedOptions = advancedOptionsState
            advancedOptionsCustomized = advancedOptionsWereCustomized

            do {
                let result = try buildResult(archivePath: selectedArchivePath,
                                             format: selectedFormatOption() ?? availableFormats[0],
                                             level: selectedLevel,
                                             method: selectedMethodOption(),
                                             dictionarySize: selectedDictionarySize,
                                             wordSize: selectedWordSize,
                                             solidMode: selectedSolidMode,
                                             threadText: selectedThreadText,
                                             splitVolumes: selectedSplitVolumes,
                                             parameters: selectedParameters,
                                             updateMode: selectedUpdateMode,
                                             pathMode: selectedPathMode,
                                             encryption: selectedEncryption,
                                             password: selectedPassword,
                                             confirmation: selectedConfirmation,
                                             encryptNames: encryptNames,
                                             createSFX: createSFX,
                                             excludeMacResourceFiles: excludeMacResourceFiles,
                                             memoryUsageSpec: selectedMemoryUsageSpec,
                                             openSharedFiles: openSharedFiles,
                                             deleteAfterCompression: deleteAfterCompression,
                                             advancedOptions: advancedOptions)
                ArchivePathHistory.record(result.archiveURL.path)
                DialogPreferences.record(format: selectedFormatName,
                                         updateMode: selectedUpdateMode,
                                         pathMode: selectedPathMode,
                                         openSharedFiles: openSharedFiles,
                                         deleteAfterCompression: deleteAfterCompression,
                                         encryptNames: encryptNames,
                                         showPassword: showPassword,
                                         memoryUsage: selectedMemoryUsageSpec)
                DialogPreferences.recordAdvancedOptions(advancedOptions)
                return result
            } catch {
                szPresentError(error, for: parentWindow)
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if let comboBox = obj.object as? NSComboBox,
           comboBox === threadField {
            refreshOptionAvailability()
            return
        }

        guard let field = obj.object as? NSTextField else { return }

        if field === securePasswordField || field === plainPasswordField {
            securePasswordField?.stringValue = field.stringValue
            plainPasswordField?.stringValue = field.stringValue
        } else if field === secureConfirmPasswordField || field === plainConfirmPasswordField {
            secureConfirmPasswordField?.stringValue = field.stringValue
            plainConfirmPasswordField?.stringValue = field.stringValue
        }

        refreshOptionAvailability()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let comboBox = notification.object as? NSComboBox else {
            return
        }

        if comboBox === threadField {
            refreshOptionAvailability()
        }
    }

    @objc private func formatChanged(_ sender: Any?) {
        updateArchivePathExtension()
        reloadFormatDependentControls(preferredLevel: nil,
                                      preferredMethodName: nil,
                                      preferredDictionarySize: nil,
                                      preferredWordSize: nil,
                                      preferredEncryption: nil)
        parametersField?.stringValue = defaultParameters(for: selectedFormatOption())

        if !advancedOptionsWereCustomized,
           !hasStoredAdvancedPreferences,
           let format = selectedFormatOption() {
            advancedOptionsState = defaultAdvancedOptionsState(for: format,
                                                              methodName: selectedMethodOption()?.methodName)
            refreshAdvancedOptionsSummary()
        }
    }

    @objc private func methodChanged(_ sender: Any?) {
        let preferredDictionarySize = selectedDictionaryOption()?.value
        let preferredWordSize = selectedWordOption()?.value
        reloadMethodDependentControls(preferredDictionarySize: preferredDictionarySize,
                                      preferredWordSize: preferredWordSize)

        if !advancedOptionsWereCustomized,
           !hasStoredAdvancedPreferences,
           let format = selectedFormatOption() {
            advancedOptionsState = defaultAdvancedOptionsState(for: format,
                                                              methodName: selectedMethodOption()?.methodName)
            refreshAdvancedOptionsSummary()
        }
    }

    @objc private func showPasswordToggled(_ sender: Any?) {
        syncPasswordFields()
        updatePasswordVisibilityUI(moveFocus: true)
        refreshOptionAvailability()
    }

    @objc private func compressionSettingsChanged(_ sender: Any?) {
        refreshOptionAvailability()
    }

    @objc private func createSFXToggled(_ sender: Any?) {
        updateArchivePathExtension()
        refreshOptionAvailability()
    }

    @objc private func showAdvancedOptions(_ sender: Any?) {
        guard let format = selectedFormatOption() else {
            return
        }

        let initialState = effectiveAdvancedOptions(for: format,
                                                    method: selectedMethodOption(),
                                                    baseState: advancedOptionsState).state
        guard let updatedState = runAdvancedOptionsModal(for: format,
                                                         method: selectedMethodOption(),
                                                         initialState: initialState) else {
            return
        }

        advancedOptionsState = updatedState
        advancedOptionsWereCustomized = true
        refreshAdvancedOptionsSummary()
    }

    private func runAdvancedOptionsModal(for format: FormatOption,
                                         method: MethodOption?,
                                         initialState: AdvancedOptionsState) -> AdvancedOptionsState? {
        let baseCapabilities = baseAdvancedOptionsCapabilities(for: format,
                                                               methodName: method?.methodName)
        let effectiveInitialState = effectiveAdvancedOptions(for: format,
                                                             method: method,
                                                             baseState: initialState).state
        let timePrecisionOptions = makeTimePrecisionOptions(for: baseCapabilities)

        let setColumnWidth: CGFloat = 34

        func makeSetCheckbox() -> NSButton {
            let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            checkbox.setContentHuggingPriority(.required, for: .horizontal)
            checkbox.setContentCompressionResistancePriority(.required, for: .horizontal)
            checkbox.controlSize = .small
            return checkbox
        }

        func makeColonLabel() -> NSTextField {
            let label = NSTextField(labelWithString: ":")
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.widthAnchor.constraint(equalToConstant: 6).isActive = true
            return label
        }

        func makeSetColumn(setCheckbox: NSButton,
                           colonLabel: NSTextField) -> NSStackView {
            let column = NSStackView(views: [setCheckbox, colonLabel])
            column.orientation = .horizontal
            column.alignment = .centerY
            column.spacing = 4
            column.widthAnchor.constraint(equalToConstant: setColumnWidth).isActive = true
            return column
        }

        func makeBoolPairRow(title: String,
                             state: AdvancedBoolPairState) -> (setCheckbox: NSButton, colonLabel: NSTextField, setColumn: NSStackView, valueCheckbox: NSButton, row: NSStackView) {
            let setCheckbox = makeSetCheckbox()
            setCheckbox.state = state.isSet ? .on : .off

            let colonLabel = makeColonLabel()
            let setColumn = makeSetColumn(setCheckbox: setCheckbox,
                                          colonLabel: colonLabel)

            let valueCheckbox = NSButton(checkboxWithTitle: title,
                                         target: nil,
                                         action: nil)
            valueCheckbox.state = state.value ? .on : .off

            let row = NSStackView(views: [setColumn, valueCheckbox])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            return (setCheckbox, colonLabel, setColumn, valueCheckbox, row)
        }

        func selectTimePrecision(_ precision: SZCompressionTimePrecision) {
            if let selectedIndex = timePrecisionOptions.firstIndex(where: { $0.value.rawValue == precision.rawValue }) {
                timePrecisionPopup.selectItem(at: selectedIndex)
            } else if !timePrecisionOptions.isEmpty {
                timePrecisionPopup.selectItem(at: 0)
            }
        }

        func currentSelectedTimePrecision() -> SZCompressionTimePrecision {
            guard !timePrecisionOptions.isEmpty else {
                return baseCapabilities.defaultTimePrecision
            }

            let selectedIndex = max(0, timePrecisionPopup.indexOfSelectedItem)
            guard timePrecisionOptions.indices.contains(selectedIndex) else {
                return timePrecisionOptions[0].value
            }
            return timePrecisionOptions[selectedIndex].value
        }

        let symbolicLinksCheckbox = NSButton(checkboxWithTitle: "Store symbolic links",
                                             target: nil,
                                             action: nil)
        symbolicLinksCheckbox.state = effectiveInitialState.storeSymbolicLinks ? .on : .off

        let hardLinksCheckbox = NSButton(checkboxWithTitle: "Store hard links",
                                         target: nil,
                                         action: nil)
        hardLinksCheckbox.state = effectiveInitialState.storeHardLinks ? .on : .off

        let alternateDataStreamsCheckbox = NSButton(checkboxWithTitle: "Store alternate data streams",
                                                    target: nil,
                                                    action: nil)
        alternateDataStreamsCheckbox.state = effectiveInitialState.storeAlternateDataStreams ? .on : .off

        let fileSecurityCheckbox = NSButton(checkboxWithTitle: "Store file security",
                                            target: nil,
                                            action: nil)
        fileSecurityCheckbox.state = effectiveInitialState.storeFileSecurity ? .on : .off

        let preserveAccessTimeCheckbox = NSButton(checkboxWithTitle: "Do not change source files last access time",
                                                  target: nil,
                                                  action: nil)
        preserveAccessTimeCheckbox.state = effectiveInitialState.preserveSourceAccessTime ? .on : .off

        let timePrecisionSetCheckbox = makeSetCheckbox()
        timePrecisionSetCheckbox.state = effectiveInitialState.timePrecision.isSet ? .on : .off
        let timePrecisionColonLabel = makeColonLabel()
        let timePrecisionSetColumn = makeSetColumn(setCheckbox: timePrecisionSetCheckbox,
                               colonLabel: timePrecisionColonLabel)

        let timePrecisionLabel = NSTextField(labelWithString: "Timestamp precision:")
        timePrecisionLabel.textColor = .labelColor

        let timePrecisionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        populate(timePrecisionPopup, with: timePrecisionOptions.map(\.title))
        selectTimePrecision(effectiveInitialState.timePrecision.value)
        timePrecisionPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let timePrecisionContent = NSStackView(views: [timePrecisionLabel, timePrecisionPopup])
        timePrecisionContent.orientation = .horizontal
        timePrecisionContent.alignment = .centerY
        timePrecisionContent.spacing = 8

        let timePrecisionRow = NSStackView(views: [timePrecisionSetColumn, timePrecisionContent])
        timePrecisionRow.orientation = .horizontal
        timePrecisionRow.alignment = .centerY
        timePrecisionRow.spacing = 6

        let modificationTimeRow = makeBoolPairRow(title: "Store modification time",
                                                  state: effectiveInitialState.storeModificationTime)
        let creationTimeRow = makeBoolPairRow(title: "Store creation time",
                                              state: effectiveInitialState.storeCreationTime)
        let accessTimeRow = makeBoolPairRow(title: "Store last access time",
                                            state: effectiveInitialState.storeAccessTime)
        let archiveTimeRow = makeBoolPairRow(title: "Set archive time to latest file time",
                                             state: effectiveInitialState.setArchiveTimeToLatestFile)

        let typeLabel = NSTextField(labelWithString: optionsTypeDescription(for: format,
                                                                            method: method))
        typeLabel.font = .systemFont(ofSize: 12)
        typeLabel.textColor = .secondaryLabelColor

        let metadataSection = makeTitledSection(title: "NTFS", rows: [
            symbolicLinksCheckbox,
            hardLinksCheckbox,
            alternateDataStreamsCheckbox,
            fileSecurityCheckbox,
        ])

        let timeSection = makeTitledSection(title: "Time", rows: [
            timePrecisionRow,
            modificationTimeRow.row,
            creationTimeRow.row,
            accessTimeRow.row,
            archiveTimeRow.row,
            preserveAccessTimeCheckbox,
        ])

        let contentStack = NSStackView(views: [typeLabel, metadataSection, timeSection])
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

        func configureSimpleCheckbox(_ checkbox: NSButton,
                                     supported: Bool) {
            checkbox.isHidden = !supported
            checkbox.isEnabled = supported
        }

        func configureBoolPairRow(_ row: (setCheckbox: NSButton, colonLabel: NSTextField, setColumn: NSStackView, valueCheckbox: NSButton, row: NSStackView),
                                  supported: Bool,
                                  defaultValue: Bool,
                                  showSetCheckbox: Bool) {
            row.row.isHidden = !supported
            row.valueCheckbox.isHidden = !supported
            row.setCheckbox.isHidden = !supported || !showSetCheckbox
            row.colonLabel.isHidden = row.setCheckbox.isHidden

            guard supported else {
                return
            }

            if row.setCheckbox.state != .on {
                row.valueCheckbox.state = defaultValue ? .on : .off
            }
            row.valueCheckbox.isEnabled = (row.setCheckbox.state == .on)
        }

        let refreshControls = {
            if !timePrecisionOptions.isEmpty,
               timePrecisionSetCheckbox.state != .on {
                selectTimePrecision(baseCapabilities.defaultTimePrecision)
            }

            let selectedTimePrecision = currentSelectedTimePrecision()
            let capabilities = self.adjustedAdvancedOptionsCapabilities(baseCapabilities,
                                                                        timePrecision: selectedTimePrecision,
                                                                        format: format,
                                                                        methodName: method?.methodName)

            configureSimpleCheckbox(symbolicLinksCheckbox,
                                    supported: capabilities.supportsSymbolicLinks)
            configureSimpleCheckbox(hardLinksCheckbox,
                                    supported: capabilities.supportsHardLinks)
            configureSimpleCheckbox(alternateDataStreamsCheckbox,
                                    supported: capabilities.supportsAlternateDataStreams)
            configureSimpleCheckbox(fileSecurityCheckbox,
                                    supported: capabilities.supportsFileSecurity)

            metadataSection.isHidden = !capabilities.hasMetadataControls

            let showPrecisionRow = !timePrecisionOptions.isEmpty
            timePrecisionRow.isHidden = !showPrecisionRow
            let showPrecisionSetCheckbox = timePrecisionSetCheckbox.state == .on || timePrecisionOptions.count > 1
            timePrecisionSetCheckbox.isHidden = !showPrecisionSetCheckbox
            timePrecisionColonLabel.isHidden = timePrecisionSetCheckbox.isHidden
            timePrecisionSetCheckbox.isEnabled = timePrecisionOptions.count > 1 || timePrecisionSetCheckbox.state == .on
            timePrecisionPopup.isEnabled = timePrecisionSetCheckbox.state == .on && timePrecisionOptions.count > 1

            configureBoolPairRow(modificationTimeRow,
                                 supported: capabilities.supportsModificationTime,
                                 defaultValue: capabilities.defaultModificationTime,
                                 showSetCheckbox: capabilities.keepsName || modificationTimeRow.setCheckbox.state == .on)
            configureBoolPairRow(creationTimeRow,
                                 supported: capabilities.supportsCreationTime,
                                 defaultValue: capabilities.defaultCreationTime,
                                 showSetCheckbox: true)
            configureBoolPairRow(accessTimeRow,
                                 supported: capabilities.supportsAccessTime,
                                 defaultValue: capabilities.defaultAccessTime,
                                 showSetCheckbox: true)
            configureBoolPairRow(archiveTimeRow,
                                 supported: true,
                                 defaultValue: false,
                                 showSetCheckbox: true)
        }

        let refreshHandler = ActionHandler(handler: refreshControls)
        let refreshControlsList: [NSControl] = [
            timePrecisionSetCheckbox,
            modificationTimeRow.setCheckbox,
            creationTimeRow.setCheckbox,
            accessTimeRow.setCheckbox,
            archiveTimeRow.setCheckbox,
        ]
        refreshControlsList.forEach {
            $0.target = refreshHandler
            $0.action = #selector(ActionHandler.invoke(_:))
        }
        timePrecisionPopup.target = refreshHandler
        timePrecisionPopup.action = #selector(ActionHandler.invoke(_:))
        refreshControls()

        let controller = SZModalDialogController(style: .informational,
                                                 title: "Options",
                                                 message: nil,
                                                 buttonTitles: ["Cancel", "OK"],
                                                 accessoryView: wrapper,
                                                 preferredFirstResponder: nil,
                                                 cancelButtonIndex: 0)
        guard controller.runModal() == 1 else {
            return nil
        }

        let updatedState = AdvancedOptionsState(
            storeSymbolicLinks: symbolicLinksCheckbox.state == .on,
            storeHardLinks: hardLinksCheckbox.state == .on,
            storeAlternateDataStreams: alternateDataStreamsCheckbox.state == .on,
            storeFileSecurity: fileSecurityCheckbox.state == .on,
            preserveSourceAccessTime: preserveAccessTimeCheckbox.state == .on,
            storeModificationTime: AdvancedBoolPairState(isSet: modificationTimeRow.setCheckbox.state == .on,
                                                         value: modificationTimeRow.valueCheckbox.state == .on),
            storeCreationTime: AdvancedBoolPairState(isSet: creationTimeRow.setCheckbox.state == .on,
                                                     value: creationTimeRow.valueCheckbox.state == .on),
            storeAccessTime: AdvancedBoolPairState(isSet: accessTimeRow.setCheckbox.state == .on,
                                                   value: accessTimeRow.valueCheckbox.state == .on),
            setArchiveTimeToLatestFile: AdvancedBoolPairState(isSet: archiveTimeRow.setCheckbox.state == .on,
                                                              value: archiveTimeRow.valueCheckbox.state == .on),
            timePrecision: AdvancedTimePrecisionState(isSet: timePrecisionSetCheckbox.state == .on,
                                                      value: currentSelectedTimePrecision())
        )
        return effectiveAdvancedOptions(for: format,
                                        method: method,
                                        baseState: updatedState).state
    }

    private func reloadFormatDependentControls(preferredLevel: SZCompressionLevel?,
                                               preferredMethodName: String?,
                                               preferredDictionarySize: UInt64?,
                                               preferredWordSize: UInt32?,
                                               preferredEncryption: SZEncryptionMethod?) {
        guard let format = selectedFormatOption() else { return }

        populate(levelPopup, with: format.levelOptions.map(\.title))
        if let preferredLevel,
           let selectedIndex = format.levelOptions.firstIndex(where: { $0.value == preferredLevel }) {
            levelPopup?.selectItem(at: selectedIndex)
        } else {
            levelPopup?.selectItem(at: defaultLevelIndex(for: format))
        }

        if format.methods.isEmpty {
            populate(methodPopup, with: ["Default"])
            methodPopup?.selectItem(at: 0)
        } else {
            populate(methodPopup, with: format.methods.map(\.title))
            if let preferredMethodName,
               let selectedIndex = format.methods.firstIndex(where: { $0.methodName == preferredMethodName }) {
                methodPopup?.selectItem(at: selectedIndex)
            } else {
                methodPopup?.selectItem(at: 0)
            }
        }

        if format.encryptionOptions.isEmpty {
            populate(encryptionPopup, with: ["Not available"])
            encryptionPopup?.selectItem(at: 0)
        } else {
            populate(encryptionPopup, with: format.encryptionOptions.map(\.title))
            if let preferredEncryption,
               let selectedIndex = format.encryptionOptions.firstIndex(where: { $0.value == preferredEncryption }) {
                encryptionPopup?.selectItem(at: selectedIndex)
            } else {
                encryptionPopup?.selectItem(at: 0)
            }
        }

        reloadMethodDependentControls(preferredDictionarySize: preferredDictionarySize,
                                      preferredWordSize: preferredWordSize)
        refreshOptionAvailability()
    }

    private func reloadMethodDependentControls(preferredDictionarySize: UInt64?,
                                               preferredWordSize: UInt32?) {
        let method = selectedMethodOption()
        dictionaryLabel?.stringValue = method?.dictionaryLabel ?? "Dictionary size:"
        wordLabel?.stringValue = method?.wordLabel ?? "Word size:"

        let dictionaryOptions = method?.dictionaryOptions ?? []
        if dictionaryOptions.isEmpty {
            populate(dictionaryPopup, with: ["Auto"])
            dictionaryPopup?.selectItem(at: 0)
        } else {
            populate(dictionaryPopup, with: dictionaryOptions.map(\.title))
            if let preferredDictionarySize,
               let selectedIndex = dictionaryOptions.firstIndex(where: { $0.value == preferredDictionarySize }) {
                dictionaryPopup?.selectItem(at: selectedIndex)
            } else {
                dictionaryPopup?.selectItem(at: 0)
            }
        }

        let wordOptions = method?.wordOptions ?? []
        if wordOptions.isEmpty {
            populate(wordPopup, with: ["Auto"])
            wordPopup?.selectItem(at: 0)
        } else {
            populate(wordPopup, with: wordOptions.map(\.title))
            if let preferredWordSize,
               let selectedIndex = wordOptions.firstIndex(where: { $0.value == preferredWordSize }) {
                wordPopup?.selectItem(at: selectedIndex)
            } else {
                wordPopup?.selectItem(at: 0)
            }
        }

        refreshOptionAvailability()
    }

    private func refreshOptionAvailability() {
        guard let format = selectedFormatOption() else { return }

        let method = selectedMethodOption()
        let level = selectedLevelOption()?.value ?? defaultLevel(for: format.codecName)
        let selectedDictionarySize = selectedDictionaryOption()?.value ?? 0
        let selectedWordSize = selectedWordOption()?.value ?? 0
        let currentThreadText = threadField?.stringValue ?? "Auto"
        let memoryUsageSpec = selectedMemoryUsageSpecValue()
        let estimate = compressionResourceEstimate(for: format,
                                                   method: method,
                                                   level: level,
                                                   dictionarySize: selectedDictionarySize,
                                                   threadText: currentThreadText,
                                                   memoryUsageSpec: memoryUsageSpec)

        refreshDynamicCompressionControlTitles(for: format,
                                              method: method,
                                              selectedDictionarySize: selectedDictionarySize,
                                              selectedWordSize: selectedWordSize,
                                              currentThreadText: currentThreadText,
                                              estimate: estimate)

        levelPopup?.isEnabled = format.levelOptions.count > 1
        methodPopup?.isEnabled = !format.methods.isEmpty
        dictionaryPopup?.isEnabled = !(method?.dictionaryOptions.isEmpty ?? true)
        wordPopup?.isEnabled = !(method?.wordOptions.isEmpty ?? true)
        solidPopup?.isEnabled = format.supportsSolid
        threadField?.isEnabled = format.supportsThreads

        if !format.supportsSolid {
            solidPopup?.selectItem(at: 0)
        }
        if !format.supportsThreads {
            threadField?.stringValue = "Auto"
        }

        let createSFXWasEnabled = createSFXCheckbox?.state == .on
        let canCreateSFX = supportsSFX(for: format,
                                       method: method)
        createSFXCheckbox?.isEnabled = canCreateSFX
        if !canCreateSFX {
            createSFXCheckbox?.state = .off
        }

        let createSFX = effectiveCreateSFXState(for: format,
                                                method: method)
        splitVolumesField?.isEnabled = !createSFX
        if createSFX {
            splitVolumesField?.stringValue = ""
        }

        if createSFXWasEnabled != createSFX {
            updateArchivePathExtension()
        }

        let encryptionAvailable = !format.encryptionOptions.isEmpty
        encryptionPopup?.isEnabled = encryptionAvailable && format.encryptionOptions.count > 1
        securePasswordField?.isEnabled = encryptionAvailable
        plainPasswordField?.isEnabled = encryptionAvailable
        secureConfirmPasswordField?.isEnabled = encryptionAvailable
        plainConfirmPasswordField?.isEnabled = encryptionAvailable
        showPasswordCheckbox?.isEnabled = encryptionAvailable

        let canEncryptNames = encryptionAvailable && format.supportsEncryptFileNames && !currentPasswordValue().isEmpty
        encryptNamesCheckbox?.isEnabled = canEncryptNames
        if !canEncryptNames {
            encryptNamesCheckbox?.state = .off
        }

        refreshCompressionResourceSummary(for: format, estimate: estimate)
        refreshAdvancedOptionsSummary()
    }

    private func refreshCompressionResourceSummary(for format: FormatOption,
                                                   estimate: CompressionResourceEstimate) {
        threadInfoLabel?.stringValue = Self.cpuThreadSummary(forThreadedFormat: format.supportsThreads)
        threadInfoLabel?.isHidden = !format.supportsThreads
        let showsMemoryUsageControl = estimate.memoryUsageLimit != nil
        memoryUsageRow?.isHidden = !showsMemoryUsageControl
        memoryUsagePopup?.isEnabled = showsMemoryUsageControl && (memoryUsagePopup?.numberOfItems ?? 0) > 1

        let showsMemoryUsage = estimate.compressionMemory != nil || estimate.decompressionMemory != nil
        compressionMemoryRow?.isHidden = !showsMemoryUsage
        decompressionMemoryRow?.isHidden = !showsMemoryUsage
        compressionMemoryLabel?.stringValue = estimate.compressionMemory.map(Self.memoryUsageText(for:)) ?? "?"
        decompressionMemoryLabel?.stringValue = estimate.decompressionMemory.map(Self.memoryUsageText(for:)) ?? "?"

        let exceedsMemoryLimit = {
            guard let compressionMemory = estimate.compressionMemory,
                  let memoryUsageLimit = estimate.memoryUsageLimit else {
                return false
            }
            return compressionMemory > memoryUsageLimit
        }()
        compressionMemoryLabel?.textColor = exceedsMemoryLimit ? .systemRed : .secondaryLabelColor
        decompressionMemoryLabel?.textColor = .secondaryLabelColor
    }

    private func buildResult(archivePath: String,
                             format: FormatOption,
                             level: SZCompressionLevel,
                             method: MethodOption?,
                             dictionarySize: UInt64,
                             wordSize: UInt32,
                             solidMode: Bool,
                             threadText: String,
                             splitVolumes: String,
                             parameters: String,
                             updateMode: SZCompressionUpdateMode,
                             pathMode: SZCompressionPathMode,
                             encryption: SZEncryptionMethod,
                             password: String,
                             confirmation: String,
                             encryptNames: Bool,
                             createSFX: Bool,
                             excludeMacResourceFiles: Bool,
                             memoryUsageSpec: String,
                             openSharedFiles: Bool,
                             deleteAfterCompression: Bool,
                             advancedOptions: AdvancedOptionsState) throws -> CompressDialogResult {
        let effectiveCreateSFX = createSFX && supportsSFX(for: format, method: method)
        if createSFX && !effectiveCreateSFX {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSUserCancelledError,
                          userInfo: [NSLocalizedDescriptionKey: "Windows SFX is only available for 7z archives using Copy, LZMA, LZMA2, or PPMd, and requires the bundled 7z.sfx module."])
        }

        let trimmedSplitVolumes = splitVolumes.trimmingCharacters(in: .whitespacesAndNewlines)
        if effectiveCreateSFX && !trimmedSplitVolumes.isEmpty {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSUserCancelledError,
                          userInfo: [NSLocalizedDescriptionKey: "Windows SFX archives cannot be split into volumes."])
        }

        let normalizedMemoryUsageSpec = memoryUsageSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        let archiveURL = try resolveArchiveURL(from: archivePath,
                                               format: format,
                                               createSFX: effectiveCreateSFX)
        let threadCount = try parseThreadCount(threadText)
        let normalizedPassword = try validatePassword(password,
                                                      confirmation: confirmation,
                                                      for: format,
                                                      encryption: encryption)
        let settings = SZCompressionSettings()
        settings.format = format.format
        settings.level = level
        settings.method = method?.enumValue ?? .LZMA2
        settings.methodName = method?.methodName
        settings.updateMode = updateMode
        settings.pathMode = pathMode
        settings.encryption = normalizedPassword == nil ? .none : encryption
        settings.password = normalizedPassword
        settings.encryptFileNames = normalizedPassword != nil && format.supportsEncryptFileNames && encryptNames
        settings.createSFX = effectiveCreateSFX
        settings.excludeMacResourceFiles = excludeMacResourceFiles
        settings.solidMode = format.supportsSolid && solidMode
        settings.dictionarySize = dictionarySize
        settings.wordSize = wordSize
        settings.numThreads = threadCount
        settings.splitVolumes = trimmedSplitVolumes.isEmpty ? nil : trimmedSplitVolumes
        settings.memoryUsage = normalizedMemoryUsageSpec.isEmpty ? nil : normalizedMemoryUsageSpec

        let trimmedParameters = parameters.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.parameters = trimmedParameters.isEmpty ? nil : trimmedParameters

        settings.openSharedFiles = openSharedFiles
        settings.deleteAfterCompression = deleteAfterCompression

        let effectiveAdvancedOptions = effectiveAdvancedOptions(for: format,
                                                                method: method,
                                                                baseState: advancedOptions)
        applyAdvancedOptions(effectiveAdvancedOptions.state,
                             capabilities: effectiveAdvancedOptions.capabilities,
                             to: settings)

        let estimate = compressionResourceEstimate(for: format,
                                                   method: method,
                                                   level: level,
                                                   dictionarySize: dictionarySize,
                                                   threadText: threadText,
                                                   memoryUsageSpec: normalizedMemoryUsageSpec)
        if let compressionMemory = estimate.compressionMemory,
           let memoryUsageLimit = estimate.memoryUsageLimit,
           compressionMemory > memoryUsageLimit {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSUserCancelledError,
                          userInfo: [NSLocalizedDescriptionKey: "Compression requires \(Self.memoryUsageText(for: compressionMemory)), which exceeds the selected memory usage limit of \(Self.memoryUsageText(for: memoryUsageLimit))."])
        }

        return CompressDialogResult(settings: settings, archiveURL: archiveURL)
    }

    private func validatePassword(_ password: String,
                                  confirmation: String,
                                  for format: FormatOption,
                                  encryption: SZEncryptionMethod) throws -> String? {
        guard !password.isEmpty || !confirmation.isEmpty else {
            return nil
        }

        guard password == confirmation else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSUserCancelledError,
                          userInfo: [NSLocalizedDescriptionKey: "Passwords do not match."])
        }

        if format.codecName == "zip" {
            guard password.canBeConverted(to: .ascii) else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSUserCancelledError,
                              userInfo: [NSLocalizedDescriptionKey: "ZIP passwords must use ASCII characters."])
            }

            if encryption == .AES256 && password.utf8.count > 99 {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSUserCancelledError,
                              userInfo: [NSLocalizedDescriptionKey: "ZIP AES passwords must be 99 bytes or fewer."])
            }
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
                                   createSFX: Bool) throws -> URL {
        let trimmedPath = archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = normalizedArchivePath(from: trimmedPath,
                                                   format: format,
                                                   createSFX: createSFX)
        let expandedPath = NSString(string: normalizedPath).expandingTildeInPath
        let archiveURL: URL
        if NSString(string: expandedPath).isAbsolutePath {
            archiveURL = URL(fileURLWithPath: expandedPath)
        } else {
            archiveURL = URL(fileURLWithPath: expandedPath, relativeTo: baseDirectory)
        }

        let standardizedURL = archiveURL.standardizedFileURL
        guard !standardizedURL.lastPathComponent.isEmpty else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSUserCancelledError,
                          userInfo: [NSLocalizedDescriptionKey: "Enter an archive path."])
        }

        let parentDirectory = standardizedURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSUserCancelledError,
                          userInfo: [NSLocalizedDescriptionKey: "The destination folder does not exist."])
        }

        if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSUserCancelledError,
                          userInfo: [NSLocalizedDescriptionKey: "The archive path points to an existing folder."])
        }

        return standardizedURL
    }

    private func normalizedArchivePath(from archivePath: String,
                                       format: FormatOption,
                                       createSFX: Bool) -> String {
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
        guard let archivePathField,
              let format = selectedFormatOption() else {
            return
        }

        archivePathField.stringValue = normalizedArchivePath(from: archivePathField.stringValue,
                                                             format: format,
                                                             createSFX: effectiveCreateSFXState(for: format,
                                                                                                method: selectedMethodOption()))
    }

    private func updatePasswordVisibilityUI(moveFocus: Bool) {
        let showsPassword = showPasswordCheckbox?.state == .on
        securePasswordField?.isHidden = showsPassword
        secureConfirmPasswordField?.isHidden = showsPassword
        plainPasswordField?.isHidden = !showsPassword
        plainConfirmPasswordField?.isHidden = !showsPassword

        guard moveFocus,
              let window = currentDialogWindow,
              let textView = window.firstResponder as? NSTextView,
              let owner = textView.delegate as? NSView else {
            return
        }

        let replacementResponder: NSView?
        switch owner {
        case securePasswordField, plainPasswordField:
            replacementResponder = showsPassword ? plainPasswordField : securePasswordField
        case secureConfirmPasswordField, plainConfirmPasswordField:
            replacementResponder = showsPassword ? plainConfirmPasswordField : secureConfirmPasswordField
        default:
            replacementResponder = nil
        }

        if let replacementResponder {
            window.makeFirstResponder(replacementResponder)
        }
    }

    private func syncPasswordFields() {
        let password = currentPasswordValue()
        securePasswordField?.stringValue = password
        plainPasswordField?.stringValue = password

        let confirmation = currentConfirmationValue()
        secureConfirmPasswordField?.stringValue = confirmation
        plainConfirmPasswordField?.stringValue = confirmation
    }

    private func currentPasswordValue() -> String {
        if showPasswordCheckbox?.state == .on {
            return plainPasswordField?.stringValue ?? securePasswordField?.stringValue ?? ""
        }
        return securePasswordField?.stringValue ?? plainPasswordField?.stringValue ?? ""
    }

    private func currentConfirmationValue() -> String {
        if showPasswordCheckbox?.state == .on {
            return plainConfirmPasswordField?.stringValue ?? secureConfirmPasswordField?.stringValue ?? ""
        }
        return secureConfirmPasswordField?.stringValue ?? plainConfirmPasswordField?.stringValue ?? ""
    }

    private func selectedFormatOption() -> FormatOption? {
        guard let formatPopup else { return nil }
        let index = formatPopup.indexOfSelectedItem
        guard availableFormats.indices.contains(index) else { return availableFormats.first }
        return availableFormats[index]
    }

    private func selectedLevelOption() -> Option<SZCompressionLevel>? {
        guard let format = selectedFormatOption(),
              let levelPopup else {
            return nil
        }
        let index = levelPopup.indexOfSelectedItem
        guard format.levelOptions.indices.contains(index) else {
            return format.levelOptions.first
        }
        return format.levelOptions[index]
    }

    private func selectedMethodOption() -> MethodOption? {
        guard let format = selectedFormatOption(),
              let methodPopup,
              !format.methods.isEmpty else {
            return nil
        }
        let index = methodPopup.indexOfSelectedItem
        guard format.methods.indices.contains(index) else {
            return format.methods.first
        }
        return format.methods[index]
    }

    private func selectedDictionaryOption() -> Option<UInt64>? {
        guard let method = selectedMethodOption(),
              let dictionaryPopup,
              !method.dictionaryOptions.isEmpty else {
            return nil
        }
        let index = dictionaryPopup.indexOfSelectedItem
        guard method.dictionaryOptions.indices.contains(index) else {
            return method.dictionaryOptions.first
        }
        return method.dictionaryOptions[index]
    }

    private func selectedWordOption() -> Option<UInt32>? {
        guard let method = selectedMethodOption(),
              let wordPopup,
              !method.wordOptions.isEmpty else {
            return nil
        }
        let index = wordPopup.indexOfSelectedItem
        guard method.wordOptions.indices.contains(index) else {
            return method.wordOptions.first
        }
        return method.wordOptions[index]
    }

    private func selectedSolidOption() -> Option<Bool>? {
        guard let solidPopup else { return nil }
        let index = solidPopup.indexOfSelectedItem
        guard Self.solidOptions.indices.contains(index) else { return Self.solidOptions.first }
        return Self.solidOptions[index]
    }

    private func selectedUpdateModeOption() -> Option<SZCompressionUpdateMode>? {
        guard let updateModePopup else { return nil }
        let index = updateModePopup.indexOfSelectedItem
        guard Self.updateModeOptions.indices.contains(index) else { return Self.updateModeOptions.first }
        return Self.updateModeOptions[index]
    }

    private func selectedPathModeOption() -> Option<SZCompressionPathMode>? {
        guard let pathModePopup else { return nil }
        let index = pathModePopup.indexOfSelectedItem
        guard Self.pathModeOptions.indices.contains(index) else { return Self.pathModeOptions.first }
        return Self.pathModeOptions[index]
    }

    private func selectedEncryptionOption() -> Option<SZEncryptionMethod>? {
        guard let format = selectedFormatOption(),
              !format.encryptionOptions.isEmpty,
              let encryptionPopup else {
            return nil
        }
        let index = encryptionPopup.indexOfSelectedItem
        guard format.encryptionOptions.indices.contains(index) else { return format.encryptionOptions.first }
        return format.encryptionOptions[index]
    }

    private func selectedMemoryUsageSpecValue() -> String {
        guard let selectedItem = memoryUsagePopup?.selectedItem,
              let spec = selectedItem.representedObject as? String else {
            return ""
        }
        return Self.normalizedMemoryUsageSpec(spec)
    }

    private func supportsSFX(for format: FormatOption?,
                             method: MethodOption?) -> Bool {
        guard let format else {
            return false
        }
        guard format.codecName.caseInsensitiveCompare("7z") == .orderedSame,
              Self.hasBundledWindowsSfxModule() else {
            return false
        }

        guard let method else {
            return true
        }

        switch method.enumValue {
        case .copy?, .LZMA?, .LZMA2?, .ppMd?:
            return true
        default:
            return false
        }
    }

    private func effectiveCreateSFXState(for format: FormatOption? = nil,
                                         method: MethodOption? = nil) -> Bool {
        guard createSFXCheckbox?.state == .on else {
            return false
        }
        return supportsSFX(for: format ?? selectedFormatOption(),
                           method: method ?? selectedMethodOption())
    }

    private func archiveExtension(for format: FormatOption,
                                  createSFX: Bool) -> String {
        createSFX ? "exe" : format.defaultExtension
    }

    private func defaultArchiveURL(for formatName: String,
                                   createSFX: Bool = false) -> URL {
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

    private func defaultLevel(for formatName: String) -> SZCompressionLevel {
        let format = formatOption(named: formatName) ?? availableFormats[0]
        return format.levelOptions[defaultLevelIndex(for: format)].value
    }

    private func defaultLevelIndex(for format: FormatOption) -> Int {
        if let normalIndex = format.levelOptions.firstIndex(where: { $0.value == .normal }) {
            return normalIndex
        }
        return 0
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

    private func populate(_ popup: NSPopUpButton?, with titles: [String]) {
        popup?.removeAllItems()
        popup?.addItems(withTitles: titles)
    }

    private static func populateMemoryUsagePopup(_ popup: NSPopUpButton,
                                                 with options: [Option<String>],
                                                 selectedSpec: String) {
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

    private static func makeMemoryUsageOptions(preferredSpec: String) -> [Option<String>] {
        let normalizedPreferredSpec = normalizedMemoryUsageSpec(preferredSpec)
        let preferredSelection = parseMemoryUsageSelection(normalizedPreferredSpec)

        var options: [Option<String>] = [
            Option(title: memoryUsageOptionTitle(for: .auto), value: "")
        ]

        let percentChoices = stride(from: 10, through: 100, by: 10).map(UInt64.init)
        if case let .percent(preferredPercent) = preferredSelection {
            var insertedPreferred = false
            for percent in percentChoices {
                if !insertedPreferred && preferredPercent <= percent {
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
            percentChoices.forEach {
                options.append(Option(title: memoryUsageOptionTitle(for: .percent($0)),
                                      value: "\($0)%"))
            }
        }

        let byteChoices = standardMemoryUsageByteChoices()
        if case let .bytes(preferredBytes) = preferredSelection {
            var insertedPreferred = false
            for bytes in byteChoices {
                if !insertedPreferred && preferredBytes <= bytes {
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
            byteChoices.forEach {
                options.append(Option(title: memoryUsageOptionTitle(for: .bytes($0)),
                                      value: normalizedMemoryUsageSpec(forBytes: $0)))
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

    private static func normalizedMemoryUsageSpec(_ spec: String) -> String {
        switch parseMemoryUsageSelection(spec) {
        case .auto:
            return ""
        case let .percent(percent):
            return "\(percent)%"
        case let .bytes(bytes):
            return normalizedMemoryUsageSpec(forBytes: bytes)
        case nil:
            return ""
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
            return "Auto: \(defaultMemoryUsagePercent)%"
        case let .percent(percent):
            return "\(percent)%"
        case let .bytes(bytes):
            return memoryUsageText(for: bytes)
        }
    }

    private static func standardMemoryUsageByteChoices() -> [UInt64] {
        let maxIndex = (20 + MemoryLayout<Int>.size * 3 - 1) * 2
        var choices: [UInt64] = []
        choices.reserveCapacity(max(0, maxIndex - (27 * 2) + 1))

        for index in (27 * 2)...maxIndex {
            let base = UInt64(2 + (index & 1))
            let shift = index / 2
            choices.append(base << shift)
        }
        return choices
    }

    private static func hasBundledWindowsSfxModule() -> Bool {
        Bundle.main.url(forResource: "7z", withExtension: "sfx") != nil
    }

    private func selectOption<Value>(_ options: [Option<Value>],
                                     selectedValue: Value,
                                     on popup: NSPopUpButton) where Value: Equatable {
        if let selectedIndex = options.firstIndex(where: { $0.value == selectedValue }) {
            popup.selectItem(at: selectedIndex)
        } else {
            popup.selectItem(at: 0)
        }
    }

    private func makePathRow(label: String,
                             pathField: NSComboBox,
                             browseButton: NSButton) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.font = .systemFont(ofSize: 12)
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let stack = NSStackView(views: [labelField, pathField, browseButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func makeFormRow(label: String,
                             control: NSView) -> NSView {
        makeFormRow(labelField: NSTextField(labelWithString: label),
                    control: control,
                    labelWidth: Self.formLabelWidth)
    }

    private func makeFormRow(label: String,
                             control: NSView,
                             labelWidth: CGFloat) -> NSView {
        makeFormRow(labelField: NSTextField(labelWithString: label),
                    control: control,
                    labelWidth: labelWidth)
    }

    private func makeFormRow(labelField: NSTextField,
                             control: NSView) -> NSView {
        makeFormRow(labelField: labelField,
                    control: control,
                    labelWidth: Self.formLabelWidth)
    }

    private func makeFormRow(labelField: NSTextField,
                             control: NSView,
                             labelWidth: CGFloat) -> NSView {
        labelField.alignment = .right
        labelField.font = .systemFont(ofSize: 12)
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        let stack = NSStackView(views: [labelField, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func makeInfoLabel(minWidth: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        return label
    }

    private func makeColumn(rows: [NSView]) -> NSStackView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func makeTitledSection(title: String,
                                   rows: [NSView]) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let content = NSStackView(views: rows)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8

        let panel = NSView(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 8
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        panel.addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
        ])

        let section = NSStackView(views: [titleLabel, panel])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        return section
    }

    private func refreshAdvancedOptionsSummary() {
        guard let summaryLabel = advancedOptionsSummaryLabel,
              let format = selectedFormatOption() else {
            advancedOptionsSummaryLabel?.stringValue = ""
            return
        }

        let effectiveOptions = effectiveAdvancedOptions(for: format,
                                                        method: selectedMethodOption(),
                                                        baseState: advancedOptionsState)
        summaryLabel.stringValue = advancedOptionsSummary(for: effectiveOptions.state,
                                                          capabilities: effectiveOptions.capabilities)
    }

    private func advancedOptionsSummary(for state: AdvancedOptionsState,
                                        capabilities: AdvancedOptionsCapabilities) -> String {
        var parts: [String] = []

        if state.timePrecision.isSet {
            parts.append("tp\(state.timePrecision.value.rawValue)")
        }

        appendBoolPairSummary("tm",
                              state: state.storeModificationTime,
                              to: &parts)
        appendBoolPairSummary("tc",
                              state: state.storeCreationTime,
                              to: &parts)
        appendBoolPairSummary("ta",
                              state: state.storeAccessTime,
                              to: &parts)
        appendBoolPairSummary("-stl",
                              state: state.setArchiveTimeToLatestFile,
                              to: &parts)

        if capabilities.supportsSymbolicLinks && state.storeSymbolicLinks {
            parts.append("SL")
        }
        if capabilities.supportsHardLinks && state.storeHardLinks {
            parts.append("HL")
        }
        if capabilities.supportsAlternateDataStreams && state.storeAlternateDataStreams {
            parts.append("AS")
        }
        if capabilities.supportsFileSecurity && state.storeFileSecurity {
            parts.append("Sec")
        }

        return parts.joined(separator: " ")
    }

    private func appendBoolPairSummary(_ name: String,
                                       state: AdvancedBoolPairState,
                                       to parts: inout [String]) {
        guard state.isSet else {
            return
        }
        parts.append(state.value ? name : "\(name)-")
    }

    private func defaultAdvancedOptionsState(for format: FormatOption,
                                             methodName: String?) -> AdvancedOptionsState {
        let capabilities = baseAdvancedOptionsCapabilities(for: format,
                                                           methodName: methodName)
        return AdvancedOptionsState(storeSymbolicLinks: false,
                                    storeHardLinks: false,
                                    storeAlternateDataStreams: false,
                                    storeFileSecurity: false,
                                    preserveSourceAccessTime: false,
                                    storeModificationTime: AdvancedBoolPairState(isSet: false,
                                                                                 value: capabilities.supportsModificationTime && capabilities.defaultModificationTime),
                                    storeCreationTime: AdvancedBoolPairState(isSet: false,
                                                                             value: capabilities.supportsCreationTime && capabilities.defaultCreationTime),
                                    storeAccessTime: AdvancedBoolPairState(isSet: false,
                                                                           value: capabilities.supportsAccessTime && capabilities.defaultAccessTime),
                                    setArchiveTimeToLatestFile: AdvancedBoolPairState(isSet: false,
                                                                                      value: false),
                                    timePrecision: AdvancedTimePrecisionState(isSet: false,
                                                                              value: capabilities.defaultTimePrecision))
    }

    private func baseAdvancedOptionsCapabilities(for format: FormatOption,
                                                 methodName: String?) -> AdvancedOptionsCapabilities {
        let info = supportedFormatInfoByName[format.codecName.lowercased()]
                let supportedTimePrecisions = Self.knownTimePrecisionValues.filter { value in
            guard let info,
                  value.rawValue >= 0 else {
                return false
            }
            let bit = UInt32(value.rawValue)
            return (info.supportedTimePrecisionMask & (UInt32(1) << bit)) != 0
        }

        var defaultTimePrecision = info?.defaultTimePrecision ?? SZCompressionTimePrecision(rawValue: -1)!
        if (defaultTimePrecision.rawValue < 0
            || !supportedTimePrecisions.contains(where: { $0.rawValue == defaultTimePrecision.rawValue })),
           let firstSupportedTimePrecision = supportedTimePrecisions.first {
            defaultTimePrecision = firstSupportedTimePrecision
        }

        var capabilities = AdvancedOptionsCapabilities(
            supportsSymbolicLinks: info?.supportsSymbolicLinks ?? false,
            supportsHardLinks: info?.supportsHardLinks ?? false,
            supportsAlternateDataStreams: info?.supportsAlternateDataStreams ?? false,
            supportsFileSecurity: info?.supportsFileSecurity ?? false,
            supportsModificationTime: info?.supportsModificationTime ?? true,
            supportsCreationTime: info?.supportsCreationTime ?? false,
            supportsAccessTime: info?.supportsAccessTime ?? false,
            defaultModificationTime: info?.defaultsModificationTime ?? true,
            defaultCreationTime: info?.defaultsCreationTime ?? false,
            defaultAccessTime: info?.defaultsAccessTime ?? false,
            keepsName: info?.keepsName ?? false,
            supportedTimePrecisions: supportedTimePrecisions,
            defaultTimePrecision: defaultTimePrecision
        )

        if format.codecName.caseInsensitiveCompare("tar") == .orderedSame {
            capabilities.supportsCreationTime = false
            capabilities.defaultCreationTime = false
            let isPosix = methodName?.caseInsensitiveCompare("POSIX") == .orderedSame
            capabilities.supportsAccessTime = capabilities.supportsAccessTime && isPosix
            capabilities.defaultAccessTime = capabilities.defaultAccessTime && isPosix
        }

        return capabilities
    }

    private func adjustedAdvancedOptionsCapabilities(_ capabilities: AdvancedOptionsCapabilities,
                                                     timePrecision: SZCompressionTimePrecision,
                                                     format: FormatOption,
                                                     methodName: String?) -> AdvancedOptionsCapabilities {
        var adjustedCapabilities = capabilities
        let effectiveTimePrecision = timePrecision.rawValue < 0 ? capabilities.defaultTimePrecision : timePrecision

        if format.codecName.caseInsensitiveCompare("zip") == .orderedSame,
           effectiveTimePrecision.rawValue != 0 {
            adjustedCapabilities.supportsCreationTime = false
            adjustedCapabilities.defaultCreationTime = false
            adjustedCapabilities.supportsAccessTime = false
            adjustedCapabilities.defaultAccessTime = false
        }

        if format.codecName.caseInsensitiveCompare("tar") == .orderedSame {
            adjustedCapabilities.supportsCreationTime = false
            adjustedCapabilities.defaultCreationTime = false
            let isPosix = methodName?.caseInsensitiveCompare("POSIX") == .orderedSame
            adjustedCapabilities.supportsAccessTime = adjustedCapabilities.supportsAccessTime && isPosix
            adjustedCapabilities.defaultAccessTime = adjustedCapabilities.defaultAccessTime && isPosix
        }

        return adjustedCapabilities
    }

    private func effectiveAdvancedOptions(for format: FormatOption,
                                          method: MethodOption?,
                                          baseState: AdvancedOptionsState) -> (state: AdvancedOptionsState, capabilities: AdvancedOptionsCapabilities) {
        let baseCapabilities = baseAdvancedOptionsCapabilities(for: format,
                                                               methodName: method?.methodName)
        var state = baseState
        if baseCapabilities.supportedTimePrecisions.isEmpty {
            state.timePrecision = AdvancedTimePrecisionState(isSet: false,
                                                             value: SZCompressionTimePrecision(rawValue: -1)!)
        } else if !baseCapabilities.supportedTimePrecisions.contains(where: { $0.rawValue == state.timePrecision.value.rawValue }) {
            state.timePrecision = AdvancedTimePrecisionState(isSet: false,
                                                             value: baseCapabilities.defaultTimePrecision)
        }

        let capabilities = adjustedAdvancedOptionsCapabilities(baseCapabilities,
                                                               timePrecision: state.timePrecision.value,
                                                               format: format,
                                                               methodName: method?.methodName)

        return (state, capabilities)
    }

    private func makeTimePrecisionOptions(for capabilities: AdvancedOptionsCapabilities) -> [Option<SZCompressionTimePrecision>] {
        capabilities.supportedTimePrecisions.map {
            Option(title: timePrecisionTitle(for: $0), value: $0)
        }
    }

    private func timePrecisionTitle(for precision: SZCompressionTimePrecision) -> String {
        switch precision.rawValue {
        case 0:
            return "100 ns : Windows"
        case 1:
            return "1 sec : Unix"
        case 2:
            return "2 sec : DOS"
        case 3:
            return "1 ns : Linux"
        default:
            return "Automatic"
        }
    }

    private func optionsTypeDescription(for format: FormatOption,
                                        method: MethodOption?) -> String {
        var description = "Type: \(format.title)"
        if format.codecName.caseInsensitiveCompare("tar") == .orderedSame,
           let methodName = method?.methodName,
           !methodName.isEmpty {
            description += ": \(methodName)"
        }
        return description
    }

    private func compressionBool1Setting(for value: Bool,
                                         supported: Bool) -> SZCompressionBoolSetting {
        guard supported, value else {
            return SZCompressionBoolSetting(rawValue: -1)!
        }
        return SZCompressionBoolSetting(rawValue: 1)!
    }

    private func compressionBoolPairSetting(for state: AdvancedBoolPairState,
                                            supported: Bool) -> SZCompressionBoolSetting {
        guard supported, state.isSet else {
            return SZCompressionBoolSetting(rawValue: -1)!
        }
        return SZCompressionBoolSetting(rawValue: state.value ? 1 : 0)!
    }

    private func applyAdvancedOptions(_ state: AdvancedOptionsState,
                                      capabilities: AdvancedOptionsCapabilities,
                                      to settings: SZCompressionSettings) {
        settings.storeSymbolicLinks = compressionBool1Setting(for: state.storeSymbolicLinks,
                                                              supported: capabilities.supportsSymbolicLinks)
        settings.storeHardLinks = compressionBool1Setting(for: state.storeHardLinks,
                                                          supported: capabilities.supportsHardLinks)
        settings.storeAlternateDataStreams = compressionBool1Setting(for: state.storeAlternateDataStreams,
                                                                     supported: capabilities.supportsAlternateDataStreams)
        settings.storeFileSecurity = compressionBool1Setting(for: state.storeFileSecurity,
                                                             supported: capabilities.supportsFileSecurity)
        settings.preserveSourceAccessTime = compressionBool1Setting(for: state.preserveSourceAccessTime,
                                                                    supported: true)
        settings.storeModificationTime = compressionBoolPairSetting(for: state.storeModificationTime,
                                                                    supported: capabilities.supportsModificationTime)
        settings.storeCreationTime = compressionBoolPairSetting(for: state.storeCreationTime,
                                                                supported: capabilities.supportsCreationTime)
        settings.storeAccessTime = compressionBoolPairSetting(for: state.storeAccessTime,
                                                              supported: capabilities.supportsAccessTime)
        settings.setArchiveTimeToLatestFile = compressionBoolPairSetting(for: state.setArchiveTimeToLatestFile,
                                                                         supported: true)
        settings.timePrecision = capabilities.supportedTimePrecisions.isEmpty || !state.timePrecision.isSet
            ? SZCompressionTimePrecision(rawValue: -1)!
            : state.timePrecision.value
    }

    private func compressionResourceEstimate(for format: FormatOption,
                                             method: MethodOption?,
                                             level: SZCompressionLevel,
                                             dictionarySize: UInt64,
                                             threadText: String?,
                                             memoryUsageSpec: String) -> CompressionResourceEstimate {
        let settings = SZCompressionSettings()
        settings.format = format.format
        settings.level = level
        settings.method = method?.enumValue ?? .LZMA2
        settings.methodName = method?.methodName
        settings.dictionarySize = dictionarySize
        settings.memoryUsage = memoryUsageSpec.isEmpty ? nil : Self.normalizedMemoryUsageSpec(memoryUsageSpec)

        if let threadText,
           let explicitThreadCount = try? parseThreadCount(threadText),
           explicitThreadCount > 0 {
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
            resolvedNumThreads: estimate.resolvedNumThreadsIsDefined ? estimate.resolvedNumThreads : nil
        )
    }

    private static func cpuThreadCounts() -> (available: Int, total: Int) {
        let processInfo = ProcessInfo.processInfo
        return (available: max(1, processInfo.activeProcessorCount),
                total: max(1, processInfo.processorCount))
    }

    private static func cpuThreadSummary(forThreadedFormat isThreaded: Bool) -> String {
        guard isThreaded else {
            return ""
        }

        let counts = cpuThreadCounts()
        if counts.available == counts.total {
            return "/ \(counts.total)"
        }
        return "/ \(counts.available) / \(counts.total)"
    }

    private static func memoryUsageText(for bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
                                  countStyle: .memory)
    }

    private func refreshDynamicCompressionControlTitles(for format: FormatOption,
                                                        method: MethodOption?,
                                                        selectedDictionarySize: UInt64,
                                                        selectedWordSize: UInt32,
                                                        currentThreadText: String,
                                                        estimate: CompressionResourceEstimate) {
        if let dictionaryPopup {
            if let method, !method.dictionaryOptions.isEmpty {
                let titles = method.dictionaryOptions.enumerated().map { index, option in
                    if index == 0 {
                        return Self.autoDictionaryTitle(for: estimate.resolvedDictionarySize,
                                                        fallback: option.title)
                    }
                    return option.title
                }
                updatePopupTitlesIfNeeded(dictionaryPopup, titles: titles)
                selectOption(method.dictionaryOptions,
                             selectedValue: selectedDictionarySize,
                             on: dictionaryPopup)
            } else {
                updatePopupTitlesIfNeeded(dictionaryPopup, titles: ["Auto"])
                dictionaryPopup.selectItem(at: 0)
            }
        }

        if let wordPopup {
            if let method, !method.wordOptions.isEmpty {
                let titles = method.wordOptions.enumerated().map { index, option in
                    if index == 0 {
                        return Self.autoWordTitle(for: estimate.resolvedWordSize,
                                                  fallback: option.title)
                    }
                    return option.title
                }
                updatePopupTitlesIfNeeded(wordPopup, titles: titles)
                selectOption(method.wordOptions,
                             selectedValue: selectedWordSize,
                             on: wordPopup)
            } else {
                updatePopupTitlesIfNeeded(wordPopup, titles: ["Auto"])
                wordPopup.selectItem(at: 0)
            }
        }

        guard format.supportsThreads,
              let threadField else {
            return
        }

        let items = [Self.autoThreadTitle(for: estimate.resolvedNumThreads)] + Self.threadChoices()
        updateComboBoxItemsIfNeeded(threadField, items: items)

        let normalizedThreadText = Self.normalizedThreadText(currentThreadText)
        if Self.isAutomaticThreadText(normalizedThreadText) {
            if threadField.indexOfSelectedItem != 0 {
                threadField.selectItem(at: 0)
            }
            let autoTitle = items[0]
            if threadField.stringValue != autoTitle {
                threadField.stringValue = autoTitle
            }
        } else if let itemIndex = items.firstIndex(of: normalizedThreadText) {
            if threadField.indexOfSelectedItem != itemIndex {
                threadField.selectItem(at: itemIndex)
            }
            if threadField.stringValue != normalizedThreadText {
                threadField.stringValue = normalizedThreadText
            }
        } else if threadField.stringValue != normalizedThreadText {
            threadField.stringValue = normalizedThreadText
        }
    }

    private func updatePopupTitlesIfNeeded(_ popup: NSPopUpButton,
                                           titles: [String]) {
        if popup.itemTitles != titles {
            populate(popup, with: titles)
        }
    }

    private func updateComboBoxItemsIfNeeded(_ comboBox: NSComboBox,
                                             items: [String]) {
        if Self.comboBoxItems(from: comboBox) != items {
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: items)
        }
    }

    private static func comboBoxItems(from comboBox: NSComboBox) -> [String] {
        (0..<comboBox.numberOfItems).compactMap { comboBox.itemObjectValue(at: $0) as? String }
    }

    private static func isAutomaticThreadText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return true
        }
        return normalized.lowercased().hasPrefix("auto")
    }

    private static func normalizedThreadText(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isAutomaticThreadText(normalized) ? "Auto" : normalized
    }

    private static func autoDictionaryTitle(for bytes: UInt64?,
                                            fallback: String) -> String {
        guard let bytes, bytes > 0 else {
            return fallback
        }
        return "Auto: \(memoryUsageText(for: bytes))"
    }

    private static func autoWordTitle(for value: UInt32?,
                                      fallback: String) -> String {
        guard let value, value > 0 else {
            return fallback
        }
        return "Auto: \(value)"
    }

    private static func autoThreadTitle(for value: UInt32?) -> String {
        guard let value, value > 0 else {
            return "Auto"
        }
        return "Auto: \(value)"
    }

    private func makePasswordContainer(secureField: NSSecureTextField,
                                       plainField: NSTextField) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        container.translatesAutoresizingMaskIntoConstraints = false
        secureField.translatesAutoresizingMaskIntoConstraints = false
        plainField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(secureField)
        container.addSubview(plainField)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 220),
            container.heightAnchor.constraint(equalToConstant: 24),
            secureField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            secureField.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            secureField.topAnchor.constraint(equalTo: container.topAnchor),
            secureField.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            plainField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            plainField.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            plainField.topAnchor.constraint(equalTo: container.topAnchor),
            plainField.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private static func makeSupportedFormatInfoByName() -> [String: SZFormatInfo] {
        SZArchive.supportedFormats().reduce(into: [:]) { partialResult, info in
            partialResult[info.name.lowercased()] = info
        }
    }

    private static func makeAvailableFormats(supportedFormatInfoByName: [String: SZFormatInfo],
                                             sourceURLs: [URL]) -> [FormatOption] {
        let isSingleFile = isSingleFileSource(sourceURLs)
        let supportedNames = Set(
            supportedFormatInfoByName.values
                .filter(\.canWrite)
                .map { $0.name.lowercased() }
        )
        let filteredFormats = formatCatalog.filter {
            guard supportedNames.isEmpty || supportedNames.contains($0.codecName.lowercased()) else {
                return false
            }

            let keepsName = supportedFormatInfoByName[$0.codecName.lowercased()]?.keepsName ?? $0.keepsName
            return isSingleFile || !keepsName
        }
        if !filteredFormats.isEmpty {
            return filteredFormats
        }

        return formatCatalog.filter { isSingleFile || !$0.keepsName }
    }

    private static func isSingleFileSource(_ sourceURLs: [URL]) -> Bool {
        guard sourceURLs.count == 1,
              let sourceURL = sourceURLs.first else {
            return false
        }

        let resourceValues = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        return resourceValues?.isDirectory == false
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
                                                 baseDirectory: URL) -> String {
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
                   fileName[fileName.index(after: dotIndex)...].contains(".") == false {
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
                                                 sourceURLs: [URL]) -> String {
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
                                       baseDirectory: URL) -> String? {
        if sourceURLs.count == 1 {
            return baseDirectory.path
        }
        return "Source folder: \(baseDirectory.path)"
    }

    private static func threadChoices() -> [String] {
        let processorCount = max(1, ProcessInfo.processInfo.processorCount)
        let upperBound = min(max(processorCount * 2, 16), 1 << 14)
        return (1...upperBound).map(String.init)
    }
}
