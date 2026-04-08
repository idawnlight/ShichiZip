import Foundation

enum AppBuildInfo {
    private static let gitCommitCountKey = "ShichiZipGitCommitCount"
    private static let gitShortHashKey = "ShichiZipGitShortHash"
    private static let licenseResourceName = "7zip-license"

    static func displayVersion(bundle: Bundle = .main) -> String? {
        let shortVersion = infoString("CFBundleShortVersionString", bundle: bundle)
        let buildVersion = infoString(gitCommitCountKey, bundle: bundle)
            ?? infoString("CFBundleVersion", bundle: bundle)
        let gitHash = infoString(gitShortHashKey, bundle: bundle)

        switch (shortVersion, buildVersion, gitHash) {
        case let (.some(shortVersion), .some(buildVersion), .some(gitHash))
            where !shortVersion.isEmpty && !buildVersion.isEmpty && !gitHash.isEmpty:
            return "\(shortVersion) (\(buildVersion), \(gitHash))"
        case let (.some(shortVersion), .some(buildVersion), _)
            where !shortVersion.isEmpty && !buildVersion.isEmpty && shortVersion != buildVersion:
            return "\(shortVersion) (\(buildVersion))"
        case let (.some(shortVersion), _, _) where !shortVersion.isEmpty:
            return shortVersion
        case let (_, .some(buildVersion), _) where !buildVersion.isEmpty:
            return buildVersion
        default:
            return nil
        }
    }

    static func aboutSummary(bundle: Bundle = .main) -> String {
        let appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "ShichiZip"
        let bundleIdentifier = bundle.bundleIdentifier ?? ""
        let copyright = infoString("NSHumanReadableCopyright", bundle: bundle)

        var lines: [String] = []
        if let version = displayVersion(bundle: bundle) {
            lines.append("\(appName) \(version)")
        } else {
            lines.append(appName)
        }
        if !bundleIdentifier.isEmpty {
            lines.append(bundleIdentifier)
        }
        lines.append("7-Zip core \(SZArchive.sevenZipVersionString())")
        if let copyright, !copyright.isEmpty {
            lines.append(copyright)
        }
        lines.append("Included 7-Zip license information follows.")
        return lines.joined(separator: "\n")
    }

    static func bundled7ZipLicense(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: licenseResourceName, withExtension: "txt") else {
            return nil
        }

        return try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func infoString(_ key: String, bundle: Bundle) -> String? {
        (bundle.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
