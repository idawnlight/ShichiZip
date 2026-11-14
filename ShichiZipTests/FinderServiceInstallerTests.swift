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

    func testServiceStringsResolveInEverySupportedLanguage() throws {
        let suite = "ShichiZip.ServiceLocalization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            SZL10n.reloadBundle()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        SZL10n.reloadBundle(defaults: defaults)
        let resources = try XCTUnwrap(SZL10n.bundle.resourceURL)
        let keys = ["app.settings.finderServices", "app.settings.openKeyboardSettings",
                    "app.settings.servicesDescription", "app.settings.servicesNote",
                    "app.settings.servicesOpenErrorDetail", "app.settings.finderService.reveal",
                    "app.settings.finderService.open", "app.settings.finderService.compress",
                    "app.settings.finderService.extract"]
        for language in SZL10n.availableLanguages() {
            let locale = language.localeCode
            let source = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("\(locale).lproj")))
            defaults.set(locale, forKey: "LanguageOverride")
            SZL10n.reloadBundle(defaults: defaults)
            for key in keys {
                let expected = source.localizedString(forKey: key, value: nil, table: "App")
                XCTAssertNotEqual(expected, key, "Missing translation: \(locale) / \(key)")
                XCTAssertEqual(SZL10n.string(key), expected, "Wrong language: \(locale) / \(key)")
            }
        }
    }

    func testBundledServicesKeepExecutableAndSignatureAfterInstallation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Bundle.main
        let hostIdentifier = try XCTUnwrap(host.bundleIdentifier)
        let installer = FinderServiceInstaller(hostBundle: host, servicesDirectory: root, updateServices: {})
        for action in FinderServiceInstaller.actions {
            try installer.setEnabled(true, for: action)
            let installed = root.appendingPathComponent("\(hostIdentifier).FinderService.\(action.rawValue).service")
            let service = try XCTUnwrap(Bundle(url: installed))
            let name = try XCTUnwrap(service.object(forInfoDictionaryKey: "CFBundleExecutable") as? String)
            let executable = try XCTUnwrap(service.executableURL)
            XCTAssertEqual(executable, installed.appendingPathComponent("Contents/MacOS/\(name)"))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))

            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--verify", "--deep", "--strict", installed.path]
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(process.terminationStatus, 0, message)
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
