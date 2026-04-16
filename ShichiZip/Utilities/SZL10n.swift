import Foundation

/// Centralized lookup for localized UI strings.
///
/// Strings sourced from the upstream 7-Zip translation project live in
/// `Upstream.strings`; app-specific strings that have no upstream
/// equivalent live in `App.strings`. `Upstream.strings` is generated,
/// while `App.strings` is maintained manually.
///
/// Lookup order: `App.strings` first, then `Upstream.strings`.
/// This lets `App.strings` override any upstream translation.
///
/// When the user selects a specific language in Settings, the override
/// bundle is used instead of `.main` so translations resolve to the
/// chosen locale regardless of the system language.
///
/// Usage:
/// ```swift
/// let title = SZL10n.string("extract.title")   // "Extract"
/// let label = SZL10n.string("app.extract.moveToTrash")
/// ```
enum SZL10n {
    /// The bundle used for string lookups. Points at the chosen
    /// `.lproj` inside `Resources/Localization` when an override
    /// is active, otherwise falls back to `.main`.
    ///
    /// Access is guarded by `bundleLock` so lookups remain safe when
    /// called from background queues (e.g. error-message construction
    /// in FileManagerArchiveItemWorkflowService, or bridge callbacks).
    nonisolated(unsafe) private static var _bundle: Bundle = makeBundle()
    private static let bundleLock = NSLock()

    static var bundle: Bundle {
        bundleLock.lock()
        defer { bundleLock.unlock() }
        return _bundle
    }

    /// Reload the bundle after the language preference changes.
    static func reloadBundle() {
        let newBundle = makeBundle()
        bundleLock.lock()
        _bundle = newBundle
        bundleLock.unlock()
    }

    /// Look up a localized string.  Checks `App.strings` first,
    /// then falls back to `Upstream.strings`.  This allows app-specific
    /// overrides of upstream translations.
    ///
    /// When a language override is active the override bundle is tried
    /// first, then `.main` is consulted as a fallback so that keys
    /// only present in `en.lproj` (e.g. app-specific strings) still
    /// resolve.
    static func string(_ key: String) -> String {
        let b = bundle
        if let found = lookup(key, in: b) {
            return found
        }
        // When an override bundle is active, fall back to .main
        if b !== Bundle.main, let found = lookup(key, in: .main) {
            return found
        }
        return key
    }

    /// Look up a localized string with format arguments.
    static func string(_ key: String, _ args: any CVarArg...) -> String {
        String(format: string(key), arguments: args)
    }

    /// Search a single bundle's App then Upstream tables.
    private static func lookup(_ key: String, in b: Bundle) -> String? {
        let appValue = b.localizedString(forKey: key, value: nil, table: "App")
        if appValue != key { return appValue }
        let upstreamValue = b.localizedString(forKey: key, value: nil, table: "Upstream")
        if upstreamValue != key { return upstreamValue }
        return nil
    }

    // MARK: - Available languages

    /// A single entry in the language picker.
    struct Language {
        let localeCode: String // e.g. "ja", "zh-Hans"
        let displayName: String // e.g. "日本語 – Japanese"
    }

    /// Returns all available languages sorted by display name,
    /// based on which `.lproj` folders exist in the app bundle's Resources.
    static func availableLanguages() -> [Language] {
        guard let resourceURL = Bundle.main.resourceURL,
              let contents = try? FileManager.default.contentsOfDirectory(at: resourceURL,
                                                                          includingPropertiesForKeys: nil)
        else {
            return []
        }

        var languages: [Language] = []
        for url in contents {
            guard url.pathExtension == "lproj" else { continue }
            let code = url.deletingPathExtension().lastPathComponent
            if code == "en" || code == "Base" { continue }

            let nativeLocale = Locale(identifier: code)
            let nativeName = nativeLocale.localizedString(forIdentifier: code) ?? code
            let englishLocale = Locale(identifier: "en")
            let englishName = englishLocale.localizedString(forIdentifier: code) ?? code

            let displayName = if nativeName.lowercased() == englishName.lowercased() {
                englishName
            } else {
                "\(nativeName) – \(englishName)"
            }

            languages.append(Language(localeCode: code, displayName: displayName))
        }

        languages.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        languages.insert(Language(localeCode: "en", displayName: "English"), at: 0)
        return languages
    }

    // MARK: - Private

    private static func makeBundle() -> Bundle {
        let override = SZSettings.string(.languageOverride)
        guard !override.isEmpty else { return .main }

        // Look for the lproj in the main bundle's Resources
        if let path = Bundle.main.path(forResource: override, ofType: "lproj"),
           let overrideBundle = Bundle(path: path)
        {
            return overrideBundle
        }

        return .main
    }
}
