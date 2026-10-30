import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class SharedUserDefaultsTests: XCTestCase {
    private let revealPreferenceKeys: [SZSettingsKey] = [
        .revealAfterExtractInFileManager,
        .revealAfterTransfer,
        .launchOpenRevealAfterExtract,
    ]

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
        // Foundation may retain an empty domain after removing all its values.
        XCTAssertTrue(source.defaults.persistentDomain(forName: source.suiteName)?.isEmpty ?? true,
                      "Migration must remove every value from the source domain.")
    }

    func testSettingsMigrationPreservesBothBooleanValues() throws {
        for value in [false, true] {
            let defaults = try makeIsolatedDefaults().defaults
            defaults.set(value, forKey: "RevealAfterExtract")

            SZSettingsMigrations.run(defaults: defaults)

            for key in revealPreferenceKeys {
                XCTAssertEqual(defaults.object(forKey: key.rawValue) as? Bool,
                               value,
                               key.rawValue)
            }
            XCTAssertNil(defaults.object(forKey: "RevealAfterExtract"))
        }
    }

    func testSettingsMigrationPreservesNewValueAndRemovesObsoleteKey() throws {
        for preservedKey in revealPreferenceKeys {
            let defaults = try makeIsolatedDefaults().defaults
            defaults.set(true, forKey: "RevealAfterExtract")
            defaults.set(false, forKey: preservedKey.rawValue)

            SZSettingsMigrations.run(defaults: defaults)
            SZSettingsMigrations.run(defaults: defaults)

            for key in revealPreferenceKeys {
                XCTAssertEqual(defaults.object(forKey: key.rawValue) as? Bool,
                               key != preservedKey,
                               key.rawValue)
            }
            XCTAssertNil(defaults.object(forKey: "RevealAfterExtract"))
        }
    }

    func testSettingsMigrationDoesNotCreateValuesOnFreshInstall() throws {
        let defaults = try makeIsolatedDefaults().defaults

        SZSettingsMigrations.run(defaults: defaults)

        for key in revealPreferenceKeys {
            XCTAssertNil(defaults.object(forKey: key.rawValue))
        }
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
