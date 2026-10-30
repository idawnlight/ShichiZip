import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class SharedArchivePreferencesTests: XCTestCase {
    func testAppAndPreviewFormattersDoNotShareMutableInstances() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(false, forKey: "FileManager.TimestampSystemFormat")
        defaults.set(4, forKey: "FileManager.TimestampLevel")
        defaults.set(true, forKey: "FileManager.TimestampUTC")

        let appFormatter = FileManagerViewPreferences.makeListDateFormatter(defaults: defaults)
        let previewFormatter = ArchivePreviewPreferences.makeListDateFormatter(defaults: defaults)
        XCTAssertEqual(appFormatter.dateFormat, "yyyy-MM-dd HH:mm:ss.SSSSSSSSS")
        XCTAssertEqual(previewFormatter.dateFormat, "yyyy-MM-dd HH:mm:ss.SSSSSSSSS")
        XCTAssertEqual(previewFormatter.timeZone, TimeZone(secondsFromGMT: 0))

        previewFormatter.dateFormat = "yyyy"

        XCTAssertEqual(appFormatter.dateFormat, "yyyy-MM-dd HH:mm:ss.SSSSSSSSS")
        XCTAssertEqual(ArchivePreviewPreferences.makeListDateFormatter(defaults: defaults).dateFormat,
                       "yyyy-MM-dd HH:mm:ss.SSSSSSSSS")
    }

    func testNewPreviewFormatterReadsChangedTimestampPreferences() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(false, forKey: "FileManager.TimestampSystemFormat")
        defaults.set(0, forKey: "FileManager.TimestampLevel")
        let first = ArchivePreviewPreferences.makeListDateFormatter(defaults: defaults)
        XCTAssertEqual(first.dateFormat, "yyyy-MM-dd")

        defaults.set(2, forKey: "FileManager.TimestampLevel")
        defaults.set(true, forKey: "FileManager.TimestampUTC")
        let second = ArchivePreviewPreferences.makeListDateFormatter(defaults: defaults)

        XCTAssertEqual(second.dateFormat, "yyyy-MM-dd HH:mm:ss")
        XCTAssertEqual(second.timeZone, TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(first.dateFormat, "yyyy-MM-dd")
    }

    func testReloadBundleRefreshesLanguageForAnotherPreview() throws {
        let defaults = try makeIsolatedDefaults()
        defer { SZL10n.reloadBundle() }

        defaults.set("en", forKey: "LanguageOverride")
        SZL10n.reloadBundle(defaults: defaults)
        XCTAssertEqual(SZL10n.string("app.fileManager.statusFiles"), "files")

        defaults.set("zh-Hans", forKey: "LanguageOverride")
        SZL10n.reloadBundle(defaults: defaults)
        XCTAssertEqual(SZL10n.string("app.fileManager.statusFiles"), "个文件")

        defaults.set("en", forKey: "LanguageOverride")
        SZL10n.reloadBundle(defaults: defaults)
        XCTAssertEqual(SZL10n.string("app.fileManager.statusFiles"), "files")
    }

    func testBundleReloadKeepsInjectedSuitesIsolatedAndClearsInvalidOverrides() throws {
        let english = try makeIsolatedDefaults()
        let chinese = try makeIsolatedDefaults()
        let fallback = try makeIsolatedDefaults()
        defer { SZL10n.reloadBundle() }

        SZL10n.reloadBundle(defaults: fallback)
        let baseBundle = SZL10n.bundle
        english.set("en", forKey: "LanguageOverride")
        chinese.set("zh-Hans", forKey: "LanguageOverride")

        for defaults in [english, chinese, english] {
            SZL10n.reloadBundle(defaults: defaults)
            let expected = defaults === chinese ? "个文件" : "files"
            XCTAssertEqual(SZL10n.string("app.fileManager.statusFiles"), expected)
        }

        chinese.set("missing-language", forKey: "LanguageOverride")
        SZL10n.reloadBundle(defaults: chinese)
        XCTAssertTrue(SZL10n.bundle === baseBundle)

        english.removeObject(forKey: "LanguageOverride")
        SZL10n.reloadBundle(defaults: english)
        XCTAssertTrue(SZL10n.bundle === baseBundle)
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "SharedArchivePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
