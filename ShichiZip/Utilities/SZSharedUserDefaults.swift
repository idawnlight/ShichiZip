import Foundation
import Security

enum SZSharedUserDefaults {
    static let appGroupIdentifierInfoKey = "ShichiZipQuickActionAppGroupIdentifier"
    private static let applicationGroupsEntitlementKey = "com.apple.security.application-groups"

    private static let migrationVersionKey = "ShichiZip.SharedUserDefaultsMigrationVersion"
    private static let currentMigrationVersion = 1

    static var defaults: UserDefaults {
        sharedDefaults ?? .standard
    }

    /// macOS only persists App Group preference suites and containers when the
    /// binary is signed with a real Team Identifier matching `<TeamID>.<GroupName>`.
    static let appGroupIdentifier: String? = resolveCurrentProcessAppGroupIdentifier()

    /// Foundation documents UserDefaults as thread-safe, but does not declare it Sendable.
    nonisolated(unsafe) static let sharedDefaults: UserDefaults? = {
        guard let appGroupIdentifier else {
            return nil
        }

        return UserDefaults(suiteName: appGroupIdentifier)
    }()

    static func resolveEntitledAppGroupIdentifier(configuredIdentifier: String?,
                                                  signingIdentifier: String?,
                                                  signatureFlags: UInt32,
                                                  entitledGroups: [Any]?) -> String?
    {
        guard let identifier = configuredIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              let dotIndex = identifier.firstIndex(of: "."),
              dotIndex > identifier.startIndex,
              identifier.index(after: dotIndex) < identifier.endIndex,
              let signingIdentifier,
              !signingIdentifier.isEmpty,
              !SecCodeSignatureFlags(rawValue: signatureFlags).contains(.adhoc)
        else {
            return nil
        }

        let groups = entitledGroups?.compactMap { $0 as? String } ?? []
        return groups.contains(identifier) ? identifier : nil
    }

    private static func resolveCurrentProcessAppGroupIdentifier() -> String? {
        guard let rawIdentifier = Bundle.main.object(forInfoDictionaryKey: appGroupIdentifierInfoKey) as? String else {
            return nil
        }

        let configuredIdentifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredIdentifier.isEmpty, !configuredIdentifier.hasPrefix(".") else {
            return nil
        }

        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }

        var signingInfoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &signingInfoRef) == errSecSuccess,
              let signingInfo = signingInfoRef as? [String: Any],
              let signatureFlags = (signingInfo[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
        else {
            return nil
        }

        let signingIdentifier = signingInfo[kSecCodeInfoIdentifier as String] as? String
        let entitlements = signingInfo[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let entitledGroups = entitlements?[applicationGroupsEntitlementKey] as? [Any]
        return resolveEntitledAppGroupIdentifier(configuredIdentifier: configuredIdentifier,
                                                 signingIdentifier: signingIdentifier,
                                                 signatureFlags: signatureFlags,
                                                 entitledGroups: entitledGroups)
    }

    static func migrateStandardDefaultsIfNeeded() {
        _ = migrateStandardDefaultsIfNeeded(appGroupIdentifier: appGroupIdentifier,
                                            sharedDefaults: sharedDefaults,
                                            standardDefaults: .standard,
                                            appDefaultsDomainName: Bundle.main.bundleIdentifier)
    }

    @discardableResult
    static func migrateStandardDefaultsIfNeeded(appGroupIdentifier: String?,
                                                sharedDefaults: UserDefaults?,
                                                standardDefaults: UserDefaults,
                                                appDefaultsDomainName: String?) -> Bool
    {
        guard let appGroupIdentifier,
              let sharedDefaults,
              let appDefaultsDomainName,
              sharedDefaults.integer(forKey: migrationVersionKey) < currentMigrationVersion
        else {
            return false
        }

        migrateDefaultsDomain(named: appDefaultsDomainName,
                              from: standardDefaults,
                              to: sharedDefaults,
                              destinationDomainName: appGroupIdentifier,
                              removesSourceDomain: true)
        sharedDefaults.set(currentMigrationVersion, forKey: migrationVersionKey)
        return true
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
        let rawValue: Int? = switch object(forKey: key) {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): number as? Int
        case let string as String: Int(string)
        default: nil
        }
        guard let rawValue else { return defaultValue }
        return Value(rawValue: rawValue) ?? defaultValue
    }

    func enumValue<Value: RawRepresentable>(forKey key: String, default defaultValue: Value) -> Value
        where Value.RawValue == String
    {
        guard let rawValue = string(forKey: key) else { return defaultValue }
        return Value(rawValue: rawValue) ?? defaultValue
    }
}
