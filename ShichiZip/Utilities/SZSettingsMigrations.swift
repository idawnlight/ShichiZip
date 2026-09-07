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
        // Compatibility with the interim RevealAfterExtract key. The b60c261
        // baseline has neither key, so its users get the new setting's default.
        migrator.migrate(newKey: SZSettingsKey.revealAfterExtractInFileManager.rawValue,
                         oldKey: "RevealAfterExtract")
    }
}

struct SZPreferenceMigrator {
    let defaults: UserDefaults

    /// Copies by default. A transform must return a UserDefaults-compatible value,
    /// or nil to leave the old value untouched when conversion is not possible.
    /// Existing destination values win; successful migrations remove the old key.
    func migrate(newKey: String, oldKey: String, transform: (Any) -> Any? = { $0 }) {
        guard newKey != oldKey,
              let oldValue = defaults.object(forKey: oldKey) else {
            return
        }

        if defaults.object(forKey: newKey) == nil {
            guard let newValue = transform(oldValue) else { return }
            defaults.set(newValue, forKey: newKey)
        }
        defaults.removeObject(forKey: oldKey)
    }
}
