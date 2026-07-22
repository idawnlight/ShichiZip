import Foundation
import os

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
    static let localizationBundleIdentifier = "ee.dawn.ShichiZip.Localization"

    /// The bundle used for string lookups. Points at the chosen
    /// `.lproj` inside `Resources/Localization` when an override
    /// is active, otherwise falls back to `.main`.
    ///
    /// Access is guarded by `bundleStorage` so lookups remain safe when
    /// called from background queues (e.g. error-message construction
    /// in FileManagerArchiveItemWorkflowService, or bridge callbacks).
    private static let bundleStorage = OSAllocatedUnfairLock(initialState: makeBundle())
    private static let fullWidthLabelColons: Set<Character> = ["：", "︓", "﹕"]

    static var bundle: Bundle {
        bundleStorage.withLock { $0 }
    }

    /// Reload the bundle after the language preference changes.
    static func reloadBundle() {
        let newBundle = makeBundle()
        bundleStorage.withLock { $0 = newBundle }
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
        if b !== baseBundle, let found = lookup(key, in: baseBundle) {
            return found
        }
        // Fall back to .main for unsigned/ad-hoc builds or older bundles.
        if b !== Bundle.main, let found = lookup(key, in: .main) {
            return found
        }
        return key
    }

    /// Look up a localized string with format arguments.
    static func string(_ key: String, _ args: any CVarArg...) -> String {
        String(format: string(key), arguments: args)
    }

    /// Joins an upstream label and its value without adding excess space after
    /// a full-width CJK colon. Upstream translations intentionally preserve
    /// locale-specific punctuation: English commonly ends labels in `:`, while
    /// Simplified Chinese and several other locales use `：`.
    static func labelValue(_ key: String, value: String) -> String {
        labelValue(label: string(key), value: value)
    }

    static func labelValue(label: String, value: String) -> String {
        var resolvedLabel = label
        while let finalCharacter = resolvedLabel.last,
              finalCharacter.unicodeScalars.allSatisfy({
                  CharacterSet.whitespacesAndNewlines.contains($0)
              })
        {
            resolvedLabel.removeLast()
        }
        guard let finalCharacter = resolvedLabel.last else { return value }
        let separator = fullWidthLabelColons.contains(finalCharacter) ? "" : " "
        return resolvedLabel + separator + value
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
    /// based on which `.lproj` folders exist in the localization bundle.
    static func availableLanguages() -> [Language] {
        var languages: [Language] = []
        let localeCodes = availableLocaleCodes(in: baseBundle)

        for code in localeCodes {
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

    private static var baseBundle: Bundle {
        localizationBundle() ?? .main
    }

    private static func localizationBundle() -> Bundle? {
        if let bundle = Bundle(identifier: localizationBundleIdentifier) {
            return bundle
        }

        let candidateURLs = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("ShichiZipLocalization.framework", isDirectory: true),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/ShichiZipLocalization.framework", isDirectory: true),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Frameworks/ShichiZipLocalization.framework", isDirectory: true),
        ]

        for url in candidateURLs.compactMap(\.self) {
            if let bundle = Bundle(url: url),
               bundle.bundleIdentifier == localizationBundleIdentifier
            {
                return bundle
            }
        }

        return nil
    }

    private static func availableLocaleCodes(in bundle: Bundle) -> Set<String> {
        var codes = Set(bundle.localizations)

        for path in bundle.paths(forResourcesOfType: "lproj", inDirectory: nil) {
            codes.insert(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        }

        return codes
    }

    private static func makeBundle() -> Bundle {
        let override = SZSettings.string(.languageOverride)
        let bundle = baseBundle
        guard !override.isEmpty else { return bundle }

        // Look for the lproj in the shared localization bundle's Resources
        if let path = bundle.path(forResource: override, ofType: "lproj"),
           let overrideBundle = Bundle(path: path)
        {
            return overrideBundle
        }

        return bundle
    }
}
