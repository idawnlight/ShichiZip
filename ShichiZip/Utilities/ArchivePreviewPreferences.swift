import Foundation

/// Archive-preview defaults shared by the main app and the Quick Look extension.
///
/// The extension runs out of process and cannot see `SZSettings`, so the canonical
/// expansion-depth key and its default/clamp live here where both targets compile it.
enum ArchivePreviewPreferences {
    static let expansionDepthKey = "QuickLookPreviewExpansionDepth"
    static let defaultExpansionDepth = 3
    static let maximumExpansionDepth = 10

    static func expansionDepth(defaults: UserDefaults = SZSharedUserDefaults.defaults) -> Int {
        guard defaults.object(forKey: expansionDepthKey) != nil else {
            return defaultExpansionDepth
        }

        return normalizedExpansionDepth(defaults.integer(forKey: expansionDepthKey))
    }

    static func normalizedExpansionDepth(_ depth: Int) -> Int {
        min(max(0, depth), maximumExpansionDepth)
    }

    static func makeListDateFormatter(defaults: UserDefaults = SZSharedUserDefaults.defaults) -> DateFormatter {
        FileManagerTimestampPreferences.makeListDateFormatter(defaults: defaults)
    }
}
