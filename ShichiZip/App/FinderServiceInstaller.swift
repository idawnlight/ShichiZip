import AppKit
import ShichiZipQuickActionCore

@MainActor
final class FinderServiceInstaller {
    static let actions: [ShichiZipQuickAction] = [.showInFileManager, .openInShichiZip, .compress, .smartQuickExtract]

    private let hostBundle: Bundle
    private let servicesDirectory: URL
    private let fileManager: FileManager
    private let updateServices: () -> Void

    init(hostBundle: Bundle = .main,
         servicesDirectory: URL? = nil,
         fileManager: FileManager = .default,
         updateServices: @escaping () -> Void = NSUpdateDynamicServices)
    {
        self.hostBundle = hostBundle
        self.fileManager = fileManager
        self.servicesDirectory = servicesDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services", isDirectory: true)
        self.updateServices = updateServices
    }

    func isEnabled(_ action: ShichiZipQuickAction) -> Bool {
        guard let installed = try? installedURL(for: action),
              let data = try? Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return info["CFBundleIdentifier"] as? String == serviceIdentifier(for: action)
    }

    func setEnabled(_ enabled: Bool, for action: ShichiZipQuickAction) throws {
        let destination = try installedURL(for: action)
        let exists = fileManager.fileExists(atPath: destination.path)
        if exists, !isEnabled(action) {
            throw CocoaError(.fileWriteFileExists)
        }
        guard enabled != exists else { return }

        if enabled {
            let source = try templateURL(for: action)
            try fileManager.createDirectory(at: servicesDirectory, withIntermediateDirectories: true)
            let staging = try fileManager.url(for: .itemReplacementDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: servicesDirectory,
                                              create: true)
            defer { try? fileManager.removeItem(at: staging) }
            let package = staging.appendingPathComponent(destination.lastPathComponent)
            try fileManager.copyItem(at: source, to: package)
            try fileManager.moveItem(at: package, to: destination)
        } else {
            try fileManager.removeItem(at: destination)
        }
        updateServices()
    }

    private func serviceIdentifier(for action: ShichiZipQuickAction) -> String {
        "\(hostBundle.bundleIdentifier ?? "").FinderService.\(action.rawValue)"
    }

    private func installedURL(for action: ShichiZipQuickAction) throws -> URL {
        guard hostBundle.bundleIdentifier != nil else { throw CocoaError(.fileReadCorruptFile) }
        return servicesDirectory.appendingPathComponent(serviceIdentifier(for: action) + ".service", isDirectory: true)
    }

    private func templateURL(for action: ShichiZipQuickAction) throws -> URL {
        guard let templates = hostBundle.object(forInfoDictionaryKey: "ShichiZipFinderServices") as? [String: String],
              let name = templates[action.rawValue],
              let url = hostBundle.url(forResource: name, withExtension: "bundle", subdirectory: "FinderServices"),
              Bundle(url: url)?.bundleIdentifier == serviceIdentifier(for: action)
        else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return url
    }
}
