import Foundation

extension Notification.Name {
    static let szSettingsDidChange = Notification.Name("SZSettingsDidChange")
    static let szLanguageDidChange = Notification.Name("SZLanguageDidChange")
}

// MARK: - Settings Keys (maps to Windows 7-Zip registry keys)

enum SZSettingsKey: String {
    // Settings page
    case showDots = "ShowDots"
    case showRealFileIcons = "ShowRealFileIcons"
    case showHiddenFiles = "ShowHiddenFiles"
    case showGridLines = "ShowGrid"
    case singleClickOpen = "SingleClick"
    case quitAfterLastWindowClosed = "QuitAfterLastWindowClosed"
    case excludeMacResourceFilesByDefault = "ExcludeMacResourceFilesByDefault"
    case moveArchiveToTrashAfterExtraction = "MoveArchiveToTrashAfterExtraction"
    case inheritDownloadedFileQuarantine = "InheritDownloadedFileQuarantine"
    case memLimitEnabled = "MemLimitEnabled"
    case memLimitGB = "MemLimitGB"

    // Shortcuts page
    case fileManagerShortcutPreset = "FileManagerShortcutPreset"
    case fileManagerCustomShortcuts = "FileManagerCustomShortcuts"

    // Folders page
    case workDirMode = "WorkDirMode" // 0=system temp, 1=current, 2=specified
    case workDirPath = "WorkDirPath"
    case workDirRemovableOnly = "WorkDirForRemovableOnly"

    /// Language
    case languageOverride = "LanguageOverride" // "" or locale code (e.g. "ja", "zh-Hans")
}

// MARK: - Settings Access

enum SZSettings {
    private static var defaults: UserDefaults {
        .standard
    }

    private static func defaultBool(for key: SZSettingsKey) -> Bool {
        switch key {
        case .showRealFileIcons, .workDirRemovableOnly, .inheritDownloadedFileQuarantine:
            true
        default:
            false
        }
    }

    private static func postChange(for key: SZSettingsKey) {
        NotificationCenter.default.post(name: .szSettingsDidChange,
                                        object: nil,
                                        userInfo: ["key": key.rawValue])
    }

    static func bool(_ key: SZSettingsKey) -> Bool {
        guard defaults.object(forKey: key.rawValue) != nil else {
            return defaultBool(for: key)
        }
        return defaults.bool(forKey: key.rawValue)
    }

    static func set(_ value: Bool, for key: SZSettingsKey) {
        defaults.set(value, forKey: key.rawValue)
        postChange(for: key)
    }

    static func string(_ key: SZSettingsKey) -> String {
        defaults.string(forKey: key.rawValue) ?? ""
    }

    static func set(_ value: String, for key: SZSettingsKey) {
        defaults.set(value, forKey: key.rawValue)
        postChange(for: key)
    }

    static func integer(_ key: SZSettingsKey) -> Int {
        defaults.integer(forKey: key.rawValue)
    }

    static func set(_ value: Int, for key: SZSettingsKey) {
        defaults.set(value, forKey: key.rawValue)
        postChange(for: key)
    }

    static var memLimitGB: Int {
        let v = defaults.integer(forKey: SZSettingsKey.memLimitGB.rawValue)
        return v > 0 ? v : 4
    }

    static var fileManagerShortcutPreset: FileManagerShortcutPreset {
        guard defaults.object(forKey: SZSettingsKey.fileManagerShortcutPreset.rawValue) != nil else {
            return .finder
        }

        let rawValue = defaults.integer(forKey: SZSettingsKey.fileManagerShortcutPreset.rawValue)
        return FileManagerShortcutPreset(rawValue: rawValue) ?? .finder
    }

    static func setFileManagerShortcutPreset(_ preset: FileManagerShortcutPreset) {
        set(preset.rawValue, for: .fileManagerShortcutPreset)
    }

    static var hasFileManagerCustomShortcutMap: Bool {
        defaults.object(forKey: SZSettingsKey.fileManagerCustomShortcuts.rawValue) != nil
    }

    static var fileManagerCustomShortcutMap: [FileManagerShortcutCommand: FileManagerShortcut] {
        guard let rawMap = defaults.dictionary(forKey: SZSettingsKey.fileManagerCustomShortcuts.rawValue) as? [String: [String: Any]] else {
            return [:]
        }

        var resolvedMap: [FileManagerShortcutCommand: FileManagerShortcut] = [:]
        for command in FileManagerShortcutCommand.allCases {
            guard let shortcutRepresentation = rawMap[command.rawValue],
                  let shortcut = FileManagerShortcut.fromSerializedRepresentation(shortcutRepresentation)
            else {
                continue
            }
            resolvedMap[command] = shortcut
        }
        return resolvedMap
    }

    static func setFileManagerCustomShortcutMap(_ map: [FileManagerShortcutCommand: FileManagerShortcut]) {
        let rawMap = Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value.serializedRepresentation) })
        defaults.set(rawMap, forKey: SZSettingsKey.fileManagerCustomShortcuts.rawValue)
        postChange(for: .fileManagerCustomShortcuts)
    }

    static var workDirMode: Int {
        defaults.integer(forKey: SZSettingsKey.workDirMode.rawValue)
    }

    private static func useConfiguredWorkDir(for currentDir: URL?) -> Bool {
        guard bool(.workDirRemovableOnly) else {
            return true
        }

        guard let currentDir else {
            return false
        }

        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey]
        let values = try? currentDir.resourceValues(forKeys: keys)
        return values?.volumeIsRemovable == true || values?.volumeIsEjectable == true
    }

    /// Resolve the working directory based on settings.
    /// If "Use for removable drives only" is enabled, non-removable volumes fall back to the current folder.
    static func resolvedWorkDir(currentDir: URL? = nil) -> URL {
        let fallbackCurrentDir = currentDir ?? FileManager.default.temporaryDirectory
        let effectiveMode: Int = if useConfiguredWorkDir(for: currentDir) {
            workDirMode
        } else {
            1
        }

        switch effectiveMode {
        case 1:
            return fallbackCurrentDir
        case 2:
            let path = string(.workDirPath)
            if !path.isEmpty { return URL(fileURLWithPath: path) }
            return FileManager.default.temporaryDirectory
        default:
            return FileManager.default.temporaryDirectory
        }
    }
}
