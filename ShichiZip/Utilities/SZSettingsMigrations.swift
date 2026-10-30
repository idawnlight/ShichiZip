import Foundation

enum SZSettingsMigrations {
    private static let preferencesPrepared: Void = {
        SZSharedUserDefaults.migrateStandardDefaultsIfNeeded()
        run(defaults: SZSharedUserDefaults.defaults)
    }()

    static var defaults: UserDefaults {
        preparePreferences()
        return SZSharedUserDefaults.defaults
    }

    /// Runs once per launch, including when settings are accessed before app startup.
    static func preparePreferences() {
        _ = preferencesPrepared
    }

    /// Append adjacent migrations in order: A -> B, then B -> C.
    /// Keep historical names as string literals here, not cases in SZSettingsKey.
    /// Removing a link ends support for that upgrade path: if the current key cannot
    /// be reached, it stays absent and SZSettings supplies its normal default.
    static func run(defaults: UserDefaults) {
        let migrator = SZPreferenceMigrator(defaults: defaults)
        migrator.migrate(newKeys: [
            SZSettingsKey.revealAfterExtractInFileManager.rawValue,
            SZSettingsKey.revealAfterTransfer.rawValue,
            SZSettingsKey.launchOpenRevealAfterExtract.rawValue,
        ],
        oldKey: "RevealAfterExtract")
    }
}

struct SZPreferenceMigrator {
    let defaults: UserDefaults

    /// Copies the old value into missing destination keys, then removes the old key.
    /// Existing destination values are preserved.
    func migrate(newKeys: [String], oldKey: String) {
        guard !newKeys.isEmpty,
              !newKeys.contains(oldKey),
              let oldValue = defaults.object(forKey: oldKey)
        else {
            return
        }

        let missingKeys = newKeys.filter { defaults.object(forKey: $0) == nil }
        for key in missingKeys {
            defaults.set(oldValue, forKey: key)
        }
        defaults.removeObject(forKey: oldKey)
    }
}
