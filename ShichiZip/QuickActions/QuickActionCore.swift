import Foundation

enum ShichiZipQuickActionAppInfo {
    private static let hostAppDisplayNameKey = "ShichiZipHostAppDisplayName"

    static var hostAppDisplayName: String {
        if let configuredName = (Bundle.main.object(forInfoDictionaryKey: hostAppDisplayNameKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredName.isEmpty {
            return configuredName
        }

        let bundleIdentifier = (Bundle.main.bundleIdentifier ?? "").lowercased()
        if bundleIdentifier.contains("shichizipzs") {
            return "ShichiZip ZS"
        }

        return "ShichiZip"
    }
}

enum ShichiZipQuickAction: String, Codable {
    case showInFileManager = "show-in-file-manager"
    case openInShichiZip = "open-in-shichizip"
    case smartQuickExtract = "smart-quick-extract"
}

struct ShichiZipQuickActionRequest: Codable {
    static let currentVersion = 1

    let version: Int
    let action: ShichiZipQuickAction
    let paths: [String]

    init(action: ShichiZipQuickAction, fileURLs: [URL]) {
        self.version = Self.currentVersion
        self.action = action
        self.paths = fileURLs.map { $0.standardizedFileURL.path }
    }

    var fileURLs: [URL] {
        paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }
}

enum ShichiZipQuickActionError: LocalizedError {
    case invalidLaunchURL
    case missingPayload
    case invalidPayload
    case launchFailed
    case unsupportedSelection(String)

    var errorDescription: String? {
        switch self {
        case .invalidLaunchURL:
            return "The Quick Action launch URL is invalid."
        case .missingPayload:
            return "The Quick Action request payload is missing."
        case .invalidPayload:
            return "The Quick Action request payload is invalid."
        case .launchFailed:
            return "\(ShichiZipQuickActionAppInfo.hostAppDisplayName) could not be launched from the Quick Action."
        case let .unsupportedSelection(message):
            return message
        }
    }
}