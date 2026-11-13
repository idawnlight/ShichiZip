import Foundation
import ShichiZipQuickActionCore
import XCTest

#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

@MainActor
final class FinderServiceInstallerTests: XCTestCase {
    func testServiceTitleFollowsAppLanguageOverride() throws {
        let suite = "ShichiZip.ServiceLocalization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            SZL10n.reloadBundle()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let store = SettingsStore(notificationCenter: NotificationCenter())
        let appName = AppBuildInfo.appDisplayName()
        for (locale, expected) in [("en", "Open in \(appName)"),
                                   ("zh-Hans", "在 \(appName) 中打开"),
                                   ("zh-Hant", "在 \(appName) 中開啟")]
        {
            defaults.set(locale, forKey: "LanguageOverride")
            SZL10n.reloadBundle(defaults: defaults)
            XCTAssertEqual(store.finderServiceTitle(.openInShichiZip), expected, locale)
        }
    }

    func testServicesStartOffAndCanBeInstalledIndependently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeHostBundle(in: root)
        let directory = root.appendingPathComponent("Services")
        var updates = 0
        let installer = FinderServiceInstaller(hostBundle: bundle, servicesDirectory: directory) { updates += 1 }
        XCTAssertTrue(FinderServiceInstaller.actions.allSatisfy { !installer.isEnabled($0) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        try installer.setEnabled(true, for: .compress)
        XCTAssertTrue(installer.isEnabled(.compress))
        XCTAssertFalse(installer.isEnabled(.openInShichiZip))
        try installer.setEnabled(true, for: .openInShichiZip)
        try installer.setEnabled(true, for: .openInShichiZip)
        XCTAssertEqual(updates, 2)

        try installer.setEnabled(false, for: .compress)
        XCTAssertFalse(installer.isEnabled(.compress))
        XCTAssertTrue(installer.isEnabled(.openInShichiZip))
        XCTAssertEqual(updates, 3)
    }

    func testDoesNotRemoveAnUnrelatedBundleAtTheDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeHostBundle(in: root)
        let directory = root.appendingPathComponent("Services")
        let destination = directory.appendingPathComponent("test.ShichiZip.FinderService.compress.service/Contents")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let unrelated = ["CFBundleIdentifier": "test.Unrelated"]
        let data = try PropertyListSerialization.data(fromPropertyList: unrelated, format: .xml, options: 0)
        let plist = destination.appendingPathComponent("Info.plist")
        try data.write(to: plist)
        let installer = FinderServiceInstaller(hostBundle: bundle, servicesDirectory: directory, updateServices: {})

        XCTAssertThrowsError(try installer.setEnabled(false, for: .compress))
        XCTAssertEqual(try Data(contentsOf: plist), data)
    }

    func testMissingTemplateDoesNotEnableTheService() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeHostBundle(in: root)
        let directory = root.appendingPathComponent("Services")
        try FileManager.default.removeItem(at: bundle.bundleURL.appendingPathComponent("Contents/Resources/FinderServices/Compress.bundle"))
        var updates = 0
        let installer = FinderServiceInstaller(hostBundle: bundle, servicesDirectory: directory) { updates += 1 }

        XCTAssertThrowsError(try installer.setEnabled(true, for: .compress))
        XCTAssertFalse(installer.isEnabled(.compress))
        XCTAssertEqual(updates, 0)
    }

    private func makeHostBundle(in root: URL) throws -> Bundle {
        let host = root.appendingPathComponent("Host.app")
        let resources = host.appendingPathComponent("Contents/Resources/FinderServices")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var templates: [String: String] = [:]
        for (action, name) in [(ShichiZipQuickAction.showInFileManager, "Reveal"), (.openInShichiZip, "Open"), (.compress, "Compress"), (.smartQuickExtract, "Extract")] {
            templates[action.rawValue] = name
            let contents = resources.appendingPathComponent("\(name).bundle/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "test.ShichiZip.FinderService.\(action.rawValue)",
                                       "CFBundlePackageType": "APPL",
                                       "NSServices": [["NSMenuItem": ["default": name]]]]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let info: [String: Any] = ["CFBundleIdentifier": "test.ShichiZip", "ShichiZipFinderServices": templates]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: host.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(Bundle(url: host))
    }
}
