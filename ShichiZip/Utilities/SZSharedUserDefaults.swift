import Foundation

enum SZSharedUserDefaults {
    static let appGroupIdentifierInfoKey = "ShichiZipQuickActionAppGroupIdentifier"

    private static let migrationVersionKey = "ShichiZip.SharedUserDefaultsMigrationVersion"
    private static let currentMigrationVersion = 1

    static var defaults: UserDefaults {
        sharedDefaults ?? .standard
    }

    static let appGroupIdentifier: String? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: appGroupIdentifierInfoKey) as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }()

    /// Foundation documents UserDefaults as thread-safe, but does not declare it Sendable.
    nonisolated(unsafe) static let sharedDefaults: UserDefaults? = {
        guard let appGroupIdentifier else {
            return nil
        }

        return UserDefaults(suiteName: appGroupIdentifier)
    }()

    static func migrateStandardDefaultsIfNeeded() {
        guard let appGroupIdentifier,
              let sharedDefaults,
              let appDefaultsDomainName = Bundle.main.bundleIdentifier,
              sharedDefaults.integer(forKey: migrationVersionKey) < currentMigrationVersion
        else {
            return
        }

        migrateDefaultsDomain(named: appDefaultsDomainName,
                              from: .standard,
                              to: sharedDefaults,
                              destinationDomainName: appGroupIdentifier,
                              removesSourceDomain: true)
        sharedDefaults.set(currentMigrationVersion, forKey: migrationVersionKey)
    }

    @discardableResult
    static func migrateDefaultsDomain(named sourceDomainName: String,
                                      from source: UserDefaults,
                                      to destination: UserDefaults,
                                      destinationDomainName: String,
                                      removesSourceDomain: Bool) -> Int
    {
        guard let sourceDomain = source.persistentDomain(forName: sourceDomainName) else {
            return 0
        }

        let destinationDomain = destination.persistentDomain(forName: destinationDomainName) ?? [:]
        var migratedCount = 0
        for (key, value) in sourceDomain {
            guard destinationDomain[key] == nil else {
                continue
            }

            destination.set(value, forKey: key)
            migratedCount += 1
        }

        if removesSourceDomain {
            source.removePersistentDomain(forName: sourceDomainName)
        }

        return migratedCount
    }
}

extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) == nil ? defaultValue : bool(forKey: key)
    }

    func integer(forKey key: String, default defaultValue: Int) -> Int {
        object(forKey: key) == nil ? defaultValue : integer(forKey: key)
    }

    func double(forKey key: String, default defaultValue: Double) -> Double {
        object(forKey: key) == nil ? defaultValue : double(forKey: key)
    }

    func enumValue<Value: RawRepresentable>(forKey key: String, default defaultValue: Value) -> Value
        where Value.RawValue == Int
    {
        guard object(forKey: key) != nil else { return defaultValue }
        return Value(rawValue: integer(forKey: key)) ?? defaultValue
    }

    func enumValue<Value: RawRepresentable>(forKey key: String, default defaultValue: Value) -> Value
        where Value.RawValue == String
    {
        guard let rawValue = string(forKey: key) else { return defaultValue }
        return Value(rawValue: rawValue) ?? defaultValue
    }
}
