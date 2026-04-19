import Foundation

enum ShichiZipQuickActionAppInfo {
    private static let hostAppDisplayNameKey = "ShichiZipHostAppDisplayName"

    static var hostAppDisplayName: String {
        if let configuredName = (Bundle.main.object(forInfoDictionaryKey: hostAppDisplayNameKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configuredName.isEmpty
        {
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

    var unsupportedTemporaryRepresentationMessage: String {
        switch self {
        case .showInFileManager:
            "The selected item was only provided as a temporary copy, so it can't be revealed safely. Try selecting the original file or folder directly in Finder."
        case .openInShichiZip:
            "The selected item was only provided as a temporary copy, so it can't be opened safely in \(ShichiZipQuickActionAppInfo.hostAppDisplayName). Try selecting the original file or folder directly in Finder."
        case .smartQuickExtract:
            "The selected archive was only provided as a temporary copy, so it can't be extracted safely. Try selecting the original archive directly in Finder."
        }
    }
}

struct ShichiZipQuickActionRequest: Codable {
    static let currentVersion = 1

    let version: Int
    let action: ShichiZipQuickAction
    let paths: [String]

    init(action: ShichiZipQuickAction, fileURLs: [URL]) {
        version = Self.currentVersion
        self.action = action
        paths = fileURLs.map(\.standardizedFileURL.path)
    }

    var fileURLs: [URL] {
        paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }
}

enum ShichiZipQuickActionError: LocalizedError {
    case invalidLaunchURL
    case missingPayload
    case invalidPayload
    case transportUnavailable
    case launchFailed
    case temporaryRepresentationUnsupported(ShichiZipQuickAction)
    case unsupportedSelection(String)

    var errorDescription: String? {
        switch self {
        case .invalidLaunchURL:
            "The Quick Action launch URL is invalid."
        case .missingPayload:
            "The Quick Action request payload is missing."
        case .invalidPayload:
            "The Quick Action request payload is invalid."
        case .transportUnavailable:
            "The Quick Action shared container is unavailable."
        case .launchFailed:
            "\(ShichiZipQuickActionAppInfo.hostAppDisplayName) could not be launched from the Quick Action."
        case let .temporaryRepresentationUnsupported(action):
            action.unsupportedTemporaryRepresentationMessage
        case let .unsupportedSelection(message):
            message
        }
    }
}
