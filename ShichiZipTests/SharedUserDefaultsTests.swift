import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class SharedUserDefaultsTests: XCTestCase {
    func testSharedDefaultsUsesConfiguredAppGroupWhenAvailable() throws {
        guard SZSharedUserDefaults.appGroupIdentifier != nil else {
            throw XCTSkip("App group identifier is not configured for this test host.")
        }

        XCTAssertNotNil(SZSharedUserDefaults.sharedDefaults)
    }

    func testMigrationCopiesAppDomainWithoutOverwritingSharedValuesAndRemovesSource() throws {
        let source = try makeIsolatedDefaults()
        let destination = try makeIsolatedDefaults()
        let preservedSharedValue = false

        source.defaults.set(true, forKey: "ShowHiddenFiles")
        source.defaults.set(true, forKey: "SZShowPasswordInPrompts")
        source.defaults.set(["/tmp/archive.zip"], forKey: "FileManager.CompressArchivePathHistory")
        source.defaults.set("domain-owned", forKey: "UnrelatedPreference")
        destination.defaults.set(preservedSharedValue, forKey: "ShowHiddenFiles")

        let migratedCount = SZSharedUserDefaults.migrateDefaultsDomain(named: source.suiteName,
                                                                       from: source.defaults,
                                                                       to: destination.defaults,
                                                                       destinationDomainName: destination.suiteName,
                                                                       removesSourceDomain: true)

        XCTAssertEqual(migratedCount, 3)
        XCTAssertEqual(destination.defaults.bool(forKey: "ShowHiddenFiles"),
                       preservedSharedValue)
        XCTAssertTrue(destination.defaults.bool(forKey: "SZShowPasswordInPrompts"))
        XCTAssertEqual(destination.defaults.stringArray(forKey: "FileManager.CompressArchivePathHistory"),
                       ["/tmp/archive.zip"])
        XCTAssertEqual(destination.defaults.string(forKey: "UnrelatedPreference"), "domain-owned")
        XCTAssertNil(source.defaults.persistentDomain(forName: source.suiteName))
    }

    func testSettingsMigrationPreservesBothBooleanValues() throws {
        for value in [false, true] {
            let defaults = try makeIsolatedDefaults().defaults
            defaults.set(value, forKey: "RevealAfterExtract")

            SZSettingsMigrations.run(defaults: defaults)

            XCTAssertEqual(defaults.object(forKey: SZSettingsKey.revealAfterExtractInFileManager.rawValue) as? Bool,
                           value)
            XCTAssertNil(defaults.object(forKey: "RevealAfterExtract"))
        }
    }

    func testSettingsMigrationPreservesNewValueAndRemovesObsoleteKey() throws {
        let defaults = try makeIsolatedDefaults().defaults
        defaults.set(true, forKey: "RevealAfterExtract")
        defaults.set(false, forKey: SZSettingsKey.revealAfterExtractInFileManager.rawValue)

        SZSettingsMigrations.run(defaults: defaults)
        SZSettingsMigrations.run(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: SZSettingsKey.revealAfterExtractInFileManager.rawValue))
        XCTAssertNil(defaults.object(forKey: "RevealAfterExtract"))
    }

    func testSettingsMigrationDoesNotCreateValuesOnFreshInstall() throws {
        let defaults = try makeIsolatedDefaults().defaults

        SZSettingsMigrations.run(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: SZSettingsKey.revealAfterExtractInFileManager.rawValue))
    }

    func testPreferenceMigrationTransformsAndChainsAcrossSkippedVersions() throws {
        let defaults = try makeIsolatedDefaults().defaults
        let migrator = SZPreferenceMigrator(defaults: defaults)
        defaults.set("42", forKey: "Original")

        migrator.migrate(newKey: "Intermediate", oldKey: "Original")
        migrator.migrate(newKey: "Current", oldKey: "Intermediate") { value in
            (value as? String).flatMap(Int.init)
        }

        XCTAssertEqual(defaults.integer(forKey: "Current"), 42)
        XCTAssertNil(defaults.object(forKey: "Original"))
        XCTAssertNil(defaults.object(forKey: "Intermediate"))

        defaults.set(99, forKey: "Current")
        migrator.migrate(newKey: "Current", oldKey: "Intermediate")
        XCTAssertEqual(defaults.integer(forKey: "Current"), 99)
    }

    func testPreferenceMigrationKeepsSourceWhenConversionFails() throws {
        let defaults = try makeIsolatedDefaults().defaults
        let migrator = SZPreferenceMigrator(defaults: defaults)
        defaults.set("invalid", forKey: "Old")

        migrator.migrate(newKey: "New", oldKey: "Old") { value in
            (value as? String).flatMap(Int.init)
        }

        XCTAssertEqual(defaults.string(forKey: "Old"), "invalid")
        XCTAssertNil(defaults.object(forKey: "New"))
    }

    func testBrokenMigrationChainLeavesCurrentSettingAtDefault() throws {
        let defaults = try makeIsolatedDefaults().defaults
        defaults.set(true, forKey: "Original")

        // The Original -> Intermediate migration has been removed.
        SZPreferenceMigrator(defaults: defaults).migrate(newKey: "Current", oldKey: "Intermediate")

        XCTAssertNil(defaults.object(forKey: "Current"))
        XCTAssertFalse(defaults.bool(forKey: "Current"))
    }

    func testBrokenMigrationChainPreservesExistingCurrentValue() throws {
        let defaults = try makeIsolatedDefaults().defaults
        defaults.set(false, forKey: "Original")
        defaults.set(true, forKey: "Current")

        SZPreferenceMigrator(defaults: defaults).migrate(newKey: "Current", oldKey: "Intermediate")

        XCTAssertTrue(defaults.bool(forKey: "Current"))
    }

    func testBaselineRevealPreferenceIsUnchanged() throws {
        let defaults = try makeIsolatedDefaults().defaults
        let baselineKey = SZSettingsKey.launchOpenRevealAfterExtract.rawValue
        defaults.set(true, forKey: baselineKey)

        SZSettingsMigrations.run(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: baselineKey))
        XCTAssertNil(defaults.object(forKey: SZSettingsKey.revealAfterExtractInFileManager.rawValue))
        XCTAssertNil(defaults.object(forKey: SZSettingsKey.revealAfterTransfer.rawValue))
    }

    func testPreferenceMigrationIgnoresIdenticalKeys() throws {
        let defaults = try makeIsolatedDefaults().defaults
        defaults.set("keep", forKey: "Same")

        SZPreferenceMigrator(defaults: defaults).migrate(newKey: "Same", oldKey: "Same")

        XCTAssertEqual(defaults.string(forKey: "Same"), "keep")
    }

    private func makeIsolatedDefaults() throws -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "SharedUserDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return (suiteName, defaults)
    }
}
