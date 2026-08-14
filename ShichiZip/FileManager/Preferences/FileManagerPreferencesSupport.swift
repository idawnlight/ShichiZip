import AppKit
import os

extension Notification.Name {
    static let fileManagerViewPreferencesDidChange = Notification.Name("FileManagerViewPreferencesDidChange")
}

enum FileManagerPreferenceStore {
    static var defaults: UserDefaults {
        SZSharedUserDefaults.defaults
    }

    static func bool(forKey key: String,
                     defaultValue: Bool,
                     defaults: UserDefaults = FileManagerPreferenceStore.defaults) -> Bool
    {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    static func integer(forKey key: String, defaultValue: Int) -> Int {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.integer(forKey: key)
    }

    static func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    static func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    static func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    static func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

enum FileManagerPanePreferences {
    private static let dualPaneKey = "FileManager.IsDualPane"

    static var showsDualPane: Bool {
        FileManagerPreferenceStore.bool(forKey: dualPaneKey, defaultValue: false)
    }

    static func setShowsDualPane(_ value: Bool) {
        FileManagerPreferenceStore.set(value, forKey: dualPaneKey)
    }
}

enum FileManagerWindowPreferences {
    static let defaultContentRect = NSRect(x: 0, y: 0, width: 1000, height: 650)
    static let minimumSize = NSSize(width: 600, height: 400)

    private static let rememberWindowFrameKey = "FileManager.RememberWindowFrame"
    private static let savedWindowFrameKey = "FileManager.WindowFrame"

    static var remembersWindowFrame: Bool {
        remembersWindowFrame()
    }

    static func remembersWindowFrame(defaults: UserDefaults = FileManagerPreferenceStore.defaults) -> Bool {
        FileManagerPreferenceStore.bool(forKey: rememberWindowFrameKey,
                                        defaultValue: false,
                                        defaults: defaults)
    }

    static func setRemembersWindowFrame(_ value: Bool,
                                        defaults: UserDefaults = FileManagerPreferenceStore.defaults)
    {
        defaults.set(value, forKey: rememberWindowFrameKey)
    }

    static func savedWindowFrame(defaults: UserDefaults = FileManagerPreferenceStore.defaults) -> NSRect? {
        guard let storedFrame = defaults.string(forKey: savedWindowFrameKey) else { return nil }
        let frame = NSRectFromString(storedFrame)
        guard isValidWindowFrame(frame) else { return nil }
        return frame
    }

    static func setSavedWindowFrame(_ frame: NSRect,
                                    defaults: UserDefaults = FileManagerPreferenceStore.defaults)
    {
        guard isValidWindowFrame(frame) else { return }
        defaults.set(NSStringFromRect(frame), forKey: savedWindowFrameKey)
    }

    static func resetSavedWindowFrame(defaults: UserDefaults = FileManagerPreferenceStore.defaults) {
        defaults.removeObject(forKey: savedWindowFrameKey)
    }

    @discardableResult
    @MainActor
    static func applySavedWindowFrameIfNeeded(to window: NSWindow,
                                              defaults: UserDefaults = FileManagerPreferenceStore.defaults) -> Bool
    {
        guard remembersWindowFrame(defaults: defaults),
              let savedFrame = savedWindowFrame(defaults: defaults)
        else {
            return false
        }

        window.setFrame(constrainedWindowFrame(savedFrame, for: window), display: false)
        return true
    }

    private static func isValidWindowFrame(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    @MainActor
    private static func constrainedWindowFrame(_ frame: NSRect,
                                               for window: NSWindow) -> NSRect
    {
        let minimumSize = window.minSize
        var constrainedFrame = frame
        constrainedFrame.size.width = max(constrainedFrame.width, minimumSize.width)
        constrainedFrame.size.height = max(constrainedFrame.height, minimumSize.height)

        guard let visibleFrame = screen(for: constrainedFrame)?.visibleFrame else {
            return constrainedFrame
        }

        constrainedFrame.size.width = min(constrainedFrame.width,
                                          max(visibleFrame.width, minimumSize.width))
        constrainedFrame.size.height = min(constrainedFrame.height,
                                           max(visibleFrame.height, minimumSize.height))

        if constrainedFrame.maxX > visibleFrame.maxX {
            constrainedFrame.origin.x = visibleFrame.maxX - constrainedFrame.width
        }
        if constrainedFrame.minX < visibleFrame.minX {
            constrainedFrame.origin.x = visibleFrame.minX
        }
        if constrainedFrame.maxY > visibleFrame.maxY {
            constrainedFrame.origin.y = visibleFrame.maxY - constrainedFrame.height
        }
        if constrainedFrame.minY < visibleFrame.minY {
            constrainedFrame.origin.y = visibleFrame.minY
        }

        return constrainedFrame
    }

    @MainActor
    private static func screen(for frame: NSRect) -> NSScreen? {
        let frameCenter = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { screen in
            screen.frame.contains(frameCenter)
        } ?? NSScreen.screens.first { screen in
            screen.frame.intersects(frame)
        } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

enum FileManagerToolbarPreferences {
    enum Style: String {
        case expanded
        case unified

        var toolbarStyle: NSWindow.ToolbarStyle {
            switch self {
            case .expanded:
                .expanded
            case .unified:
                .unified
            }
        }
    }

    private static let archiveToolbarKey = "FileManager.ShowArchiveToolbar"
    private static let standardToolbarKey = "FileManager.ShowStandardToolbar"
    private static let showTextKey = "FileManager.ToolbarShowButtonText"
    private static let styleKey = "FileManager.ToolbarStyle"

    static var showsArchiveToolbar: Bool {
        FileManagerPreferenceStore.bool(forKey: archiveToolbarKey, defaultValue: true)
    }

    static var showsStandardToolbar: Bool {
        FileManagerPreferenceStore.bool(forKey: standardToolbarKey, defaultValue: true)
    }

    static var showsButtonText: Bool {
        FileManagerPreferenceStore.bool(forKey: showTextKey, defaultValue: true)
    }

    static var style: Style {
        guard let rawValue = FileManagerPreferenceStore.string(forKey: styleKey),
              let style = Style(rawValue: rawValue)
        else {
            return .expanded
        }
        return style
    }

    static func setShowsArchiveToolbar(_ value: Bool) {
        FileManagerPreferenceStore.set(value, forKey: archiveToolbarKey)
    }

    static func setShowsStandardToolbar(_ value: Bool) {
        FileManagerPreferenceStore.set(value, forKey: standardToolbarKey)
    }

    static func setShowsButtonText(_ value: Bool) {
        FileManagerPreferenceStore.set(value, forKey: showTextKey)
    }

    static func setStyle(_ style: Style) {
        FileManagerPreferenceStore.set(style.rawValue, forKey: styleKey)
    }
}

enum FileManagerViewPreferences {
    private static let fixedFormatFormatterCache = OSAllocatedUnfairLock(initialState: [String: DateFormatter]())
    private static let styleFormatterCache = OSAllocatedUnfairLock(initialState: [String: DateFormatter]())

    enum TimestampDisplayLevel: Int, CaseIterable {
        case day
        case minute
        case second
        case ntfs
        case nanoseconds

        fileprivate var dateFormat: String {
            switch self {
            case .day:
                "yyyy-MM-dd"
            case .minute:
                "yyyy-MM-dd HH:mm"
            case .second:
                "yyyy-MM-dd HH:mm:ss"
            case .ntfs:
                "yyyy-MM-dd HH:mm:ss.SSSSSSS"
            case .nanoseconds:
                "yyyy-MM-dd HH:mm:ss.SSSSSSSSS"
            }
        }

        /// Styles used when the list follows the system region. Finder renders its
        /// date columns with a medium date and relative days, so the system option
        /// matches that rather than a numeric skeleton.
        fileprivate var systemTimeStyle: DateFormatter.Style {
            switch self {
            case .day:
                .none
            case .minute:
                .short
            case .second, .ntfs, .nanoseconds:
                .medium
            }
        }

        fileprivate var systemFractionalDigits: Int {
            switch self {
            case .ntfs:
                7
            case .nanoseconds:
                9
            default:
                0
            }
        }
    }

    private static let timestampUTCKey = "FileManager.TimestampUTC"
    private static let timestampLevelKey = "FileManager.TimestampLevel"
    private static let timestampSystemFormatKey = "FileManager.TimestampSystemFormat"
    private static let autoRefreshKey = "FileManager.AutoRefresh"

    static var usesUTCTimestamps: Bool {
        FileManagerPreferenceStore.bool(forKey: timestampUTCKey, defaultValue: false)
    }

    static var usesSystemTimestampFormat: Bool {
        FileManagerPreferenceStore.bool(forKey: timestampSystemFormatKey, defaultValue: true)
    }

    static var timestampDisplayLevel: TimestampDisplayLevel {
        TimestampDisplayLevel(rawValue: FileManagerPreferenceStore.integer(forKey: timestampLevelKey,
                                                                           defaultValue: TimestampDisplayLevel.minute.rawValue)) ?? .minute
    }

    static var autoRefreshEnabled: Bool {
        FileManagerPreferenceStore.bool(forKey: autoRefreshKey, defaultValue: false)
    }

    static func setUsesUTCTimestamps(_ value: Bool) {
        set(value, forKey: timestampUTCKey)
    }

    static func setUsesSystemTimestampFormat(_ value: Bool) {
        set(value, forKey: timestampSystemFormatKey)
    }

    static func setTimestampDisplayLevel(_ value: TimestampDisplayLevel) {
        set(value.rawValue, forKey: timestampLevelKey)
    }

    static func setAutoRefreshEnabled(_ value: Bool) {
        set(value, forKey: autoRefreshKey)
    }

    static func timeMenuPreviewTitle(for level: TimestampDisplayLevel, referenceDate: Date = Date()) -> String {
        // The menu samples advertise the format itself, so relative days are
        // suppressed there: a lone "Today" says nothing about the pattern.
        makeFormatter(for: level, allowsRelativeDates: false).string(from: referenceDate)
    }

    static func makeListDateFormatter() -> DateFormatter {
        makeFormatter(for: timestampDisplayLevel, allowsRelativeDates: true)
    }

    private static func makeFormatter(for level: TimestampDisplayLevel,
                                      allowsRelativeDates: Bool) -> DateFormatter
    {
        usesSystemTimestampFormat
            ? makeLocalizedFormatter(for: level, allowsRelativeDates: allowsRelativeDates)
            : makeFixedFormatFormatter(format: level.dateFormat)
    }

    static func makeDateFormatter(dateStyle: DateFormatter.Style,
                                  timeStyle: DateFormatter.Style) -> DateFormatter
    {
        let usesUTC = usesUTCTimestamps
        let cacheKey = "\(dateStyle.rawValue)|\(timeStyle.rawValue)|\(usesUTC ? 1 : 0)"
        return cachedFormatter(forKey: cacheKey, in: styleFormatterCache) {
            let formatter = DateFormatter()
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
            formatter.timeZone = usesUTC ? TimeZone(secondsFromGMT: 0) : .current
            return formatter
        }
    }

    private static func set(_ value: Bool, forKey key: String) {
        FileManagerPreferenceStore.set(value, forKey: key)
        resetFormatterCaches()
        NotificationCenter.default.post(name: .fileManagerViewPreferencesDidChange, object: nil)
    }

    private static func set(_ value: Int, forKey key: String) {
        FileManagerPreferenceStore.set(value, forKey: key)
        resetFormatterCaches()
        NotificationCenter.default.post(name: .fileManagerViewPreferencesDidChange, object: nil)
    }

    private static func makeFixedFormatFormatter(format: String) -> DateFormatter {
        let usesUTC = usesUTCTimestamps
        let cacheKey = "\(format)|\(usesUTC ? 1 : 0)"
        return cachedFormatter(forKey: cacheKey, in: fixedFormatFormatterCache) {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            formatter.timeZone = usesUTC ? TimeZone(secondsFromGMT: 0) : .current
            return formatter
        }
    }

    private static func makeLocalizedFormatter(for level: TimestampDisplayLevel,
                                               allowsRelativeDates: Bool) -> DateFormatter
    {
        let locale = Locale.current
        let usesUTC = usesUTCTimestamps
        // The hour cycle is part of the key because the 24-Hour Time setting can
        // change it without changing the locale identifier.
        let cacheKey = [
            "system",
            String(level.rawValue),
            locale.identifier,
            "\(locale.calendar.identifier)",
            "\(String(describing: locale.hourCycle))",
            allowsRelativeDates ? "rel" : "abs",
            usesUTC ? "1" : "0",
        ].joined(separator: "|")

        return cachedFormatter(forKey: cacheKey, in: fixedFormatFormatterCache) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .medium
            formatter.timeStyle = level.systemTimeStyle
            if level.systemFractionalDigits > 0 {
                // Assigning a pattern clears the styles, so the sub-second levels
                // opt out of relative days by construction.
                formatter.dateFormat = Self.fractionalPattern(from: formatter.dateFormat,
                                                              digits: level.systemFractionalDigits)
            } else {
                formatter.doesRelativeDateFormatting = allowsRelativeDates
            }
            formatter.timeZone = usesUTC ? TimeZone(secondsFromGMT: 0) : .current
            return formatter
        }
    }

    static func fractionalPattern(from pattern: String, digits: Int) -> String {
        pattern.replacingOccurrences(of: "ss",
                                     with: "ss." + String(repeating: "S", count: digits))
    }

    private static func resetFormatterCaches() {
        fixedFormatFormatterCache.withLock { $0.removeAll() }
        styleFormatterCache.withLock { $0.removeAll() }
    }

    private static func cachedFormatter(forKey key: String,
                                        in cache: OSAllocatedUnfairLock<[String: DateFormatter]>,
                                        builder: @Sendable () -> DateFormatter) -> DateFormatter
    {
        // DateFormatter is mutable and not thread-safe, so the cache stores
        // prototypes and each caller gets an independent copy.
        cache.withLock { store in
            let formatter: DateFormatter
            if let cached = store[key] {
                formatter = cached
            } else {
                let created = builder()
                store[key] = created
                formatter = created
            }
            return formatter.copy() as! DateFormatter
        }
    }
}
