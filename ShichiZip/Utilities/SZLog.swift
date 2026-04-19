import Foundation
import OSLog

enum SZLog {
    static func debug(_ prefix: String, _ message: @autoclosure () -> String) {
        #if DEBUG
            let resolvedMessage = message()
            writeToUnifiedLog(prefix, resolvedMessage, level: .debug, includePrivateData: false)
            NSLog("[%@] %@", prefix, resolvedMessage)
        #endif
    }

    static func info(_ prefix: String, _ message: @autoclosure () -> String) {
        write(prefix, message(), releaseType: .info)
    }

    static func error(_ prefix: String, _ message: @autoclosure () -> String) {
        write(prefix, message(), releaseType: .error)
    }

    private static func write(_ prefix: String, _ message: String, releaseType: OSLogType) {
        #if DEBUG
            writeToUnifiedLog(prefix, message, level: releaseType, includePrivateData: false)
            NSLog("[%@] %@", prefix, message)
        #else
            writeToUnifiedLog(prefix, message, level: releaseType, includePrivateData: true)
        #endif
    }

    private static func writeToUnifiedLog(_ prefix: String,
                                          _ message: String,
                                          level: OSLogType,
                                          includePrivateData: Bool)
    {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ShichiZip", category: prefix)

        switch level {
        case .debug:
            if includePrivateData {
                logger.debug("\(message, privacy: .private)")
            } else {
                logger.debug("\(message, privacy: .public)")
            }
        case .error, .fault:
            if includePrivateData {
                logger.error("\(message, privacy: .private)")
            } else {
                logger.error("\(message, privacy: .public)")
            }
        default:
            if includePrivateData {
                logger.info("\(message, privacy: .private)")
            } else {
                logger.info("\(message, privacy: .public)")
            }
        }
    }
}
