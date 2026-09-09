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

    /// Copies by default. A transform must return a UserDefaults-compatible value,
    /// or nil to leave the old value untouched when conversion is not possible.
    /// Existing destination values win; successful migrations remove the old key.
    func migrate(newKey: String, oldKey: String, transform: (Any) -> Any? = { $0 }) {
        migrate(newKeys: [newKey], oldKey: oldKey, transform: transform)
    }

    func migrate(newKeys: [String], oldKey: String, transform: (Any) -> Any? = { $0 }) {
        guard !newKeys.isEmpty,
              !newKeys.contains(oldKey),
              let oldValue = defaults.object(forKey: oldKey)
        else {
            return
        }

        let missingKeys = newKeys.filter { defaults.object(forKey: $0) == nil }
        if !missingKeys.isEmpty {
            guard let newValue = transform(oldValue) else { return }
            for key in missingKeys {
                defaults.set(newValue, forKey: key)
            }
        }
        defaults.removeObject(forKey: oldKey)
    }
}
