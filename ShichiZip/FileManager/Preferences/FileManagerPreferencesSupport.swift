import AppKit

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

extension FileManagerViewPreferences {
    typealias TimestampDisplayLevel = FileManagerTimestampPreferences.DisplayLevel

    private static let autoRefreshKey = "FileManager.AutoRefresh"

    static var usesUTCTimestamps: Bool {
        FileManagerTimestampPreferences.usesUTCTimestamps()
    }

    static var usesSystemTimestampFormat: Bool {
        FileManagerTimestampPreferences.usesSystemTimestampFormat()
    }

    static var timestampDisplayLevel: TimestampDisplayLevel {
        FileManagerTimestampPreferences.displayLevel()
    }

    static var autoRefreshEnabled: Bool {
        FileManagerPreferenceStore.bool(forKey: autoRefreshKey, defaultValue: false)
    }

    static func setUsesUTCTimestamps(_ value: Bool) {
        set(value, forKey: FileManagerTimestampPreferences.utcKey)
    }

    static func setUsesSystemTimestampFormat(_ value: Bool) {
        set(value, forKey: FileManagerTimestampPreferences.systemFormatKey)
    }

    static func setTimestampDisplayLevel(_ value: TimestampDisplayLevel) {
        set(value.rawValue, forKey: FileManagerTimestampPreferences.displayLevelKey)
    }

    static func setAutoRefreshEnabled(_ value: Bool) {
        set(value, forKey: autoRefreshKey)
    }

    static func timeMenuPreviewTitle(for level: TimestampDisplayLevel,
                                     referenceDate: Date = Date(),
                                     defaults: UserDefaults = FileManagerPreferenceStore.defaults) -> String
    {
        FileManagerTimestampPreferences.timeMenuPreviewTitle(for: level,
                                                              referenceDate: referenceDate,
                                                              defaults: defaults)
    }

    static func makeListDateFormatter(defaults: UserDefaults = FileManagerPreferenceStore.defaults) -> DateFormatter {
        FileManagerTimestampPreferences.makeListDateFormatter(defaults: defaults)
    }

    static func makeDateFormatter(dateStyle: DateFormatter.Style,
                                  timeStyle: DateFormatter.Style,
                                  defaults: UserDefaults = FileManagerPreferenceStore.defaults) -> DateFormatter
    {
        FileManagerTimestampPreferences.makeDateFormatter(dateStyle: dateStyle,
                                                           timeStyle: timeStyle,
                                                           defaults: defaults)
    }

    static func fractionalPattern(from pattern: String, digits: Int) -> String {
        FileManagerTimestampPreferences.fractionalPattern(from: pattern, digits: digits)
    }

    private static func set(_ value: Bool, forKey key: String) {
        FileManagerPreferenceStore.set(value, forKey: key)
        preferencesDidChange()
    }

    private static func set(_ value: Int, forKey key: String) {
        FileManagerPreferenceStore.set(value, forKey: key)
        preferencesDidChange()
    }

    private static func preferencesDidChange() {
        FileManagerTimestampPreferences.resetFormatterCaches()
        NotificationCenter.default.post(name: .fileManagerViewPreferencesDidChange, object: nil)
    }
}
