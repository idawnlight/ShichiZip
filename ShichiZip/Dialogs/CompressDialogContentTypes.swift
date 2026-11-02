import Cocoa

@MainActor
extension CompressDialogController {
    struct Option<Value: Equatable & Sendable>: Equatable {
        let title: String
        let value: Value
    }

    struct LevelOption: Equatable {
        let title: String
        let levelValue: Int
        let isDefault: Bool
    }

    struct MethodOption: Equatable {
        let title: String
        let enumValue: SZCompressionMethod?
        let methodName: String
        let levelOptions: [LevelOption]?
        let dictionaryLabel: String
        let dictionaryOptions: [Option<UInt64>]
        let wordLabel: String
        let wordOptions: [Option<UInt32>]

        init(title: String,
             enumValue: SZCompressionMethod?,
             methodName: String,
             levelOptions: [LevelOption]? = nil,
             dictionaryLabel: String,
             dictionaryOptions: [Option<UInt64>],
             wordLabel: String,
             wordOptions: [Option<UInt32>])
        {
            self.title = title
            self.enumValue = enumValue
            self.methodName = methodName
            self.levelOptions = levelOptions
            self.dictionaryLabel = dictionaryLabel
            self.dictionaryOptions = dictionaryOptions
            self.wordLabel = wordLabel
            self.wordOptions = wordOptions
        }
    }

    struct FormatOption: Equatable {
        let title: String
        let codecName: String
        let format: SZArchiveFormat
        let defaultExtension: String
        let levelOptions: [LevelOption]
        let methods: [MethodOption]
        let supportsSolid: Bool
        let supportsThreads: Bool
        let encryptionOptions: [Option<SZEncryptionMethod>]
        let supportsEncryptFileNames: Bool
        let keepsName: Bool
    }

    struct AdvancedBoolPairState: Equatable {
        var isSet: Bool
        var value: Bool
    }

    struct AdvancedTimePrecisionState: Equatable {
        var isSet: Bool
        var value: SZCompressionTimePrecision
    }

    struct AdvancedOptionsState: Equatable {
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

    struct AdvancedOptionsCapabilities {
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

    struct CompressionResourceEstimate {
        let compressionMemory: UInt64?
        let decompressionMemory: UInt64?
        let memoryUsageLimit: UInt64?
        let resolvedDictionarySize: UInt64?
        let resolvedWordSize: UInt32?
        let resolvedNumThreads: UInt32?
    }

    enum MemoryUsageSelection: Equatable {
        case auto
        case percent(UInt64)
        case bytes(UInt64)
    }

    struct CompressDialogControls {
        let archivePathField: NSComboBox
        let browseButton: NSButton
        let formatPopup: NSPopUpButton
        let levelPopup: NSPopUpButton
        let methodPopup: NSPopUpButton
        let dictionaryPopup: NSPopUpButton
        let wordPopup: NSPopUpButton
        let solidPopup: NSPopUpButton
        let threadField: NSComboBox
        let memoryUsagePopup: NSPopUpButton
        let splitVolumesField: NSComboBox
        let parametersField: NSTextField
        let updateModePopup: NSPopUpButton
        let pathModePopup: NSPopUpButton
        let encryptionPopup: NSPopUpButton
        let encryptNamesCheckbox: NSButton
        let createSFXCheckbox: NSButton
        let excludeMacResourceFilesCheckbox: NSButton
        let excludeOfficeLockFilesCheckbox: NSButton
        let openSharedCheckbox: NSButton
        let deleteAfterCheckbox: NSButton
        let dictionaryLabel: NSTextField
        let wordLabel: NSTextField
        let threadInfoLabel: NSTextField
        let compressionMemoryLabel: NSTextField
        let decompressionMemoryLabel: NSTextField
        let memoryUsageRow: NSView
        let compressionMemoryRow: NSView
        let decompressionMemoryRow: NSView
        let passwordField: SZPasswordField
        let confirmationField: SZPasswordField
        let showPasswordCheckbox: NSButton
        let advancedOptionsSummaryLabel: NSTextField
    }

    struct CompressDialogContentRefreshDependencies {
        let levelOptions: (FormatOption, MethodOption?) -> [LevelOption]
        let defaultLevel: (String, String?) -> Int
        let defaultLevelIndex: (FormatOption, MethodOption?) -> Int
        let supportsSFX: (FormatOption?, MethodOption?) -> Bool
        let compressionResourceEstimate: (FormatOption, MethodOption?, Int, UInt64, String, String) -> CompressionResourceEstimate
        let refreshAdvancedOptionsSummary: () -> Void
    }
}
