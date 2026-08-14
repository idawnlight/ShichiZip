import Foundation

/// Archive-preview defaults shared by the main app and the Quick Look extension.
///
/// The extension runs out of process and cannot see `SZSettings`, so the canonical
/// expansion-depth key and its default/clamp live here where both targets compile it.
enum ArchivePreviewPreferences {
    private enum TimestampDisplayLevel: Int {
        case day
        case minute
        case second
        case ntfs
        case nanoseconds

        var dateFormat: String {
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

        var systemTimeStyle: DateFormatter.Style {
            switch self {
            case .day:
                .none
            case .minute:
                .short
            case .second, .ntfs, .nanoseconds:
                .medium
            }
        }

        var systemFractionalDigits: Int {
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
        let rawLevel = defaults.object(forKey: timestampLevelKey) == nil
            ? TimestampDisplayLevel.minute.rawValue
            : defaults.integer(forKey: timestampLevelKey)
        let level = TimestampDisplayLevel(rawValue: rawLevel) ?? .minute
        let usesUTC = defaults.object(forKey: timestampUTCKey) != nil
            && defaults.bool(forKey: timestampUTCKey)
        let usesSystemFormat = defaults.object(forKey: timestampSystemFormatKey) == nil
            || defaults.bool(forKey: timestampSystemFormatKey)

        let formatter = DateFormatter()
        if usesSystemFormat {
            formatter.locale = .current
            formatter.dateStyle = .medium
            formatter.timeStyle = level.systemTimeStyle
            if level.systemFractionalDigits > 0 {
                formatter.dateFormat = formatter.dateFormat.replacingOccurrences(
                    of: "ss",
                    with: "ss." + String(repeating: "S", count: level.systemFractionalDigits),
                )
            } else {
                formatter.doesRelativeDateFormatting = true
            }
        } else {
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = level.dateFormat
        }
        formatter.timeZone = usesUTC ? TimeZone(secondsFromGMT: 0) : .current
        return formatter
    }
}
