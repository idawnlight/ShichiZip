import Foundation
import os

/// Timestamp preferences and formatter prototypes shared by the app and Quick Look.
enum FileManagerTimestampPreferences {
    enum DisplayLevel: Int, CaseIterable {
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

        /// Match Finder's medium date and relative days when following the region.
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

    static let utcKey = "FileManager.TimestampUTC"
    static let displayLevelKey = "FileManager.TimestampLevel"
    static let systemFormatKey = "FileManager.TimestampSystemFormat"

    private static let fixedFormatFormatterCache = OSAllocatedUnfairLock(initialState: [String: DateFormatter]())
    private static let styleFormatterCache = OSAllocatedUnfairLock(initialState: [String: DateFormatter]())

    static func usesUTCTimestamps(defaults: UserDefaults = SZSharedUserDefaults.defaults) -> Bool {
        defaults.bool(forKey: utcKey)
    }

    static func usesSystemTimestampFormat(defaults: UserDefaults = SZSharedUserDefaults.defaults) -> Bool {
        defaults.object(forKey: systemFormatKey) == nil || defaults.bool(forKey: systemFormatKey)
    }

    static func displayLevel(defaults: UserDefaults = SZSharedUserDefaults.defaults) -> DisplayLevel {
        guard defaults.object(forKey: displayLevelKey) != nil else { return .minute }
        return DisplayLevel(rawValue: defaults.integer(forKey: displayLevelKey)) ?? .minute
    }

    static func makeListDateFormatter(defaults: UserDefaults = SZSharedUserDefaults.defaults) -> DateFormatter {
        makeFormatter(for: displayLevel(defaults: defaults),
                      allowsRelativeDates: true,
                      defaults: defaults)
    }

    static func timeMenuPreviewTitle(for level: DisplayLevel,
                                     referenceDate: Date = Date(),
                                     defaults: UserDefaults = SZSharedUserDefaults.defaults) -> String
    {
        // A relative "Today" would hide the format that the menu is advertising.
        makeFormatter(for: level, allowsRelativeDates: false, defaults: defaults).string(from: referenceDate)
    }

    static func makeDateFormatter(dateStyle: DateFormatter.Style,
                                  timeStyle: DateFormatter.Style,
                                  defaults: UserDefaults = SZSharedUserDefaults.defaults) -> DateFormatter
    {
        let usesUTC = usesUTCTimestamps(defaults: defaults)
        let cacheKey = "\(dateStyle.rawValue)|\(timeStyle.rawValue)|\(usesUTC ? 1 : 0)"
        return cachedFormatter(forKey: cacheKey, in: styleFormatterCache) {
            let formatter = DateFormatter()
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
            formatter.timeZone = usesUTC ? TimeZone(secondsFromGMT: 0) : .current
            return formatter
        }
    }

    static func fractionalPattern(from pattern: String, digits: Int) -> String {
        pattern.replacingOccurrences(of: "ss",
                                     with: "ss." + String(repeating: "S", count: digits))
    }

    static func resetFormatterCaches() {
        fixedFormatFormatterCache.withLock { $0.removeAll() }
        styleFormatterCache.withLock { $0.removeAll() }
    }

    private static func makeFormatter(for level: DisplayLevel,
                                      allowsRelativeDates: Bool,
                                      defaults: UserDefaults) -> DateFormatter
    {
        let usesUTC = usesUTCTimestamps(defaults: defaults)
        return usesSystemTimestampFormat(defaults: defaults)
            ? makeLocalizedFormatter(for: level, allowsRelativeDates: allowsRelativeDates, usesUTC: usesUTC)
            : makeFixedFormatFormatter(format: level.dateFormat, usesUTC: usesUTC)
    }

    private static func makeFixedFormatFormatter(format: String, usesUTC: Bool) -> DateFormatter {
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

    private static func makeLocalizedFormatter(for level: DisplayLevel,
                                               allowsRelativeDates: Bool,
                                               usesUTC: Bool) -> DateFormatter
    {
        let locale = Locale.current
        // The hour cycle can change independently of the locale identifier.
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
                // Assigning a pattern clears styles and therefore relative days.
                formatter.dateFormat = fractionalPattern(from: formatter.dateFormat,
                                                         digits: level.systemFractionalDigits)
            } else {
                formatter.doesRelativeDateFormatting = allowsRelativeDates
            }
            formatter.timeZone = usesUTC ? TimeZone(secondsFromGMT: 0) : .current
            return formatter
        }
    }

    private static func cachedFormatter(forKey key: String,
                                        in cache: OSAllocatedUnfairLock<[String: DateFormatter]>,
                                        builder: @Sendable () -> DateFormatter) -> DateFormatter
    {
        // Callers can mutate a formatter without changing the cached prototype.
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
