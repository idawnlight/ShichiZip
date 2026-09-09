import Cocoa

struct ExtractDialogResult {
    let destinationURL: URL
    let overwriteMode: SZOverwriteMode
    let pathMode: SZPathMode
    let password: String?
    let preserveNtSecurityInfo: Bool
    let eliminateDuplicates: Bool
    let moveArchiveToTrashAfterExtraction: Bool
    let inheritDownloadedFileQuarantine: Bool
    let revealAfterExtractInFileManager: Bool
}

struct ExtractQuickActionDefaults {
    let overwriteMode: SZOverwriteMode
    let preserveNtSecurityInfo: Bool
    let eliminateDuplicates: Bool
    let moveArchiveToTrashAfterExtraction: Bool
    let inheritDownloadedFileQuarantine: Bool
}

@MainActor
private final class ExtractDialogValidationContext {
    var resolvedResult: ExtractDialogResolvedResult?
}

@MainActor
final class ExtractDialogController: NSObject {
    private enum DestinationHistory {
        private static var defaults: UserDefaults {
            SZSharedUserDefaults.defaults
        }

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
                updatedEntries.removeSubrange(maxEntries ..< updatedEntries.count)
            }
            defaults.set(updatedEntries, forKey: entriesKey)
        }
    }

    private enum DialogPreferences {
        private static var defaults: UserDefaults {
            SZSharedUserDefaults.defaults
        }

        private static let pathModeKey = "FileManager.ExtractPathMode"
        private static let overwriteModeKey = "FileManager.ExtractOverwriteMode"
        private static let preserveNtSecurityKey = "FileManager.ExtractPreserveNtSecurity"
        private static let eliminateDuplicatesKey = "FileManager.ExtractEliminateDuplicates"
        private static let splitDestinationKey = "FileManager.ExtractSplitDestination"
        private static let showPasswordKey = "FileManager.ExtractShowPassword"

        static func pathMode(defaultValue: SZPathMode,
                             allowedValues: [SZPathMode]) -> SZPathMode
        {
            guard let rawValue = defaults.object(forKey: pathModeKey) as? Int,
                  let value = SZPathMode(rawValue: rawValue),
                  allowedValues.contains(value)
            else {
                return defaultValue
            }
            return value
        }

        static func overwriteMode(defaultValue: SZOverwriteMode) -> SZOverwriteMode {
            guard let rawValue = defaults.object(forKey: overwriteModeKey) as? Int,
                  let value = SZOverwriteMode(rawValue: rawValue)
            else {
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
                           showPassword: Bool)
        {
            defaults.set(pathMode.rawValue, forKey: pathModeKey)
            defaults.set(overwriteMode.rawValue, forKey: overwriteModeKey)
            defaults.set(preserveNtSecurityInfo, forKey: preserveNtSecurityKey)
            defaults.set(eliminateDuplicates, forKey: eliminateDuplicatesKey)
            defaults.set(splitDestination, forKey: splitDestinationKey)
            defaults.set(showPassword, forKey: showPasswordKey)
        }
    }

    private let suggestedDestinationURL: URL
    private let baseDirectory: URL
    private let messageText: String?
    private let defaultPathMode: SZPathMode
    private let showsCurrentPathsOption: Bool
    private let suggestedSplitDestinationName: String?
    private let sourceArchiveAvailableForMoveToTrash: Bool
    private let sourceArchiveAvailableForQuarantineInheritance: Bool

    init(suggestedDestinationURL: URL,
         baseDirectory: URL,
         message: String?,
         defaultPathMode: SZPathMode,
         showsCurrentPathsOption: Bool,
         suggestedSplitDestinationName: String? = nil,
         sourceArchiveAvailableForMoveToTrash: Bool = true,
         sourceArchiveAvailableForQuarantineInheritance: Bool = true)
    {
        self.suggestedDestinationURL = suggestedDestinationURL.standardizedFileURL
        self.baseDirectory = baseDirectory.standardizedFileURL
        messageText = message
        self.defaultPathMode = defaultPathMode
        self.showsCurrentPathsOption = showsCurrentPathsOption
        self.suggestedSplitDestinationName = suggestedSplitDestinationName
        self.sourceArchiveAvailableForMoveToTrash = sourceArchiveAvailableForMoveToTrash
        self.sourceArchiveAvailableForQuarantineInheritance = sourceArchiveAvailableForQuarantineInheritance
    }

    func runModal(for parentWindow: NSWindow?) async -> ExtractDialogResult? {
        let pathModeOptions = makePathModeOptions()
        let overwriteModeOptions = makeOverwriteModeOptions()
        let initialState = ExtractDialogState(destinationPath: suggestedDestinationURL.path,
                                              pathMode: DialogPreferences.pathMode(defaultValue: defaultPathMode,
                                                                                   allowedValues: pathModeOptions.map(\.value)),
                                              overwriteMode: DialogPreferences.overwriteMode(defaultValue: .ask),
                                              password: "",
                                              preserveNtSecurityInfo: DialogPreferences.preserveNtSecurityInfo(),
                                              eliminateDuplicates: DialogPreferences.eliminateDuplicates(),
                                              splitDestination: DialogPreferences.splitDestination(),
                                              splitName: suggestedSplitDestinationName ?? "",
                                              showPassword: DialogPreferences.showPassword(),
                                              moveArchiveToTrashAfterExtraction: SZSettings.bool(.moveArchiveToTrashAfterExtraction),
                                              inheritDownloadedFileQuarantine: SZSettings.bool(.inheritDownloadedFileQuarantine),
                                              revealAfterExtractInFileManager: SZSettings.revealAfterExtractInFileManager)
        let contentController = ExtractDialogContentController(state: initialState,
                                                               pathModeOptions: pathModeOptions,
                                                               overwriteModeOptions: overwriteModeOptions,
                                                               destinationHistoryEntries: DestinationHistory.entries(),
                                                               baseDirectory: baseDirectory,
                                                               sourceArchiveAvailableForMoveToTrash: sourceArchiveAvailableForMoveToTrash,
                                                               sourceArchiveAvailableForQuarantineInheritance: sourceArchiveAvailableForQuarantineInheritance)
        let controller = SZModalDialogController(style: .informational,
                                                 title: SZL10n.string("extract.title"),
                                                 message: messageText,
                                                 actions: [
                                                     SZDialogAction(title: SZL10n.string("common.cancel"),
                                                                    roles: .cancel),
                                                     SZDialogAction(title: SZL10n.string("extract.title"),
                                                                    roles: .default),
                                                 ],
                                                 accessoryView: contentController.view,
                                                 preferredFirstResponder: contentController.preferredFirstResponder)
        contentController.attach(to: controller.window)

        let resultBuilder = ExtractDialogResultBuilder(baseDirectory: baseDirectory)
        let validationContext = ExtractDialogValidationContext()
        controller.shouldFinishHandler = { buttonIndex in
            guard buttonIndex == 1 else {
                return true
            }

            contentController.updateStateFromControls()
            do {
                validationContext.resolvedResult = try resultBuilder.buildResult(from: contentController.state)
                return true
            } catch {
                szPresentError(error, for: controller.window)
                return false
            }
        }

        let buttonIndex = await controller.modalResult(for: parentWindow)
        controller.shouldFinishHandler = nil

        guard buttonIndex == 1,
              let resolvedResult = validationContext.resolvedResult
        else {
            return nil
        }

        let state = contentController.state
        DestinationHistory.record(resolvedResult.baseDestinationURL.path)
        DialogPreferences.record(pathMode: state.pathMode,
                                 overwriteMode: state.overwriteMode,
                                 preserveNtSecurityInfo: state.preserveNtSecurityInfo,
                                 eliminateDuplicates: state.eliminateDuplicates,
                                 splitDestination: state.splitDestination,
                                 showPassword: state.showPassword)
        SZSettings.set(state.moveArchiveToTrashAfterExtraction, for: .moveArchiveToTrashAfterExtraction)
        SZSettings.set(state.inheritDownloadedFileQuarantine, for: .inheritDownloadedFileQuarantine)
        SZSettings.revealAfterExtractInFileManager = state.revealAfterExtractInFileManager
        return resolvedResult.result
    }

    private func makePathModeOptions() -> [ExtractDialogOption<SZPathMode>] {
        var options: [ExtractDialogOption<SZPathMode>] = []
        if showsCurrentPathsOption {
            options.append(ExtractDialogOption(title: SZL10n.string("app.extract.currentPaths"), value: .currentPaths))
        }
        options.append(ExtractDialogOption(title: SZL10n.string("extract.fullPathnames"), value: .fullPaths))
        options.append(ExtractDialogOption(title: SZL10n.string("extract.noPathnames"), value: .noPaths))
        options.append(ExtractDialogOption(title: SZL10n.string("extract.absolutePathnames"), value: .absolutePaths))
        return options
    }

    private func makeOverwriteModeOptions() -> [ExtractDialogOption<SZOverwriteMode>] {
        [
            ExtractDialogOption(title: SZL10n.string("extract.askBeforeOverwrite"), value: .ask),
            ExtractDialogOption(title: SZL10n.string("extract.overwriteWithoutPrompt"), value: .overwrite),
            ExtractDialogOption(title: SZL10n.string("extract.skipExisting"), value: .skip),
            ExtractDialogOption(title: SZL10n.string("extract.autoRename"), value: .rename),
            ExtractDialogOption(title: SZL10n.string("extract.autoRenameExisting"), value: .renameExisting),
        ]
    }

    nonisolated static func normalizedPassword(from rawValue: String) -> String? {
        ExtractDialogResultBuilder.normalizedPassword(from: rawValue)
    }
}

extension ExtractDialogController {
    static func quickActionDefaults() -> ExtractQuickActionDefaults {
        ExtractQuickActionDefaults(overwriteMode: DialogPreferences.overwriteMode(defaultValue: .ask),
                                   preserveNtSecurityInfo: DialogPreferences.preserveNtSecurityInfo(),
                                   eliminateDuplicates: DialogPreferences.eliminateDuplicates(),
                                   moveArchiveToTrashAfterExtraction: SZSettings.bool(.moveArchiveToTrashAfterExtraction),
                                   inheritDownloadedFileQuarantine: SZSettings.bool(.inheritDownloadedFileQuarantine))
    }
}
