import Foundation
import os.log

enum ShichiZipQuickActionTransport {
    private static let launchHost = "quick-action"
    private static let launchPath = "/finder"
    private static let requestQueryItemName = "request"
    private static let defaultURLScheme = "shichizip"
    private static let appGroupIdentifierInfoKey = "ShichiZipQuickActionAppGroupIdentifier"
    private static let urlSchemeInfoKey = "ShichiZipQuickActionURLScheme"
    private static let requestDirectoryName = "QuickActionRequests"
    private static let staleRequestLifetime: TimeInterval = 24 * 60 * 60

    nonisolated(unsafe) static var testingRequestDirectoryURLOverride: URL?

    private static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "<unknown>"
    }

    static var urlScheme: String {
        infoString(forKey: urlSchemeInfoKey) ?? defaultURLScheme
    }

    private static var appGroupIdentifier: String? {
        infoString(forKey: appGroupIdentifierInfoKey)
    }

    static func canHandle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else {
            return false
        }

        return scheme == urlScheme && host == launchHost && url.path == launchPath
    }

    static func launchURL(for request: ShichiZipQuickActionRequest) throws -> URL {
        cleanupStalePayloads()
        let requestIdentifier = try store(request)
        let launchURL = try makeLaunchURL(forRequestIdentifier: requestIdentifier)
        log("staged request action=\(request.action.rawValue) bundle=\(bundleIdentifier) appGroupIdentifier=\(appGroupIdentifier ?? "<missing>") launchURL=\(launchURL.absoluteString)")
        return launchURL
    }

    static func consumeRequest(from launchURL: URL) throws -> ShichiZipQuickActionRequest {
        let requestFileURL = try requestFileURL(from: launchURL)
        log("consuming request bundle=\(bundleIdentifier) appGroupIdentifier=\(appGroupIdentifier ?? "<missing>") requestFile=\(requestFileURL.path) launchURL=\(launchURL.absoluteString)")
        defer { removeRequestFile(at: requestFileURL, reason: "consumed") }

        let data: Data
        do {
            data = try Data(contentsOf: requestFileURL)
        } catch {
            throw ShichiZipQuickActionError.missingPayload
        }

        let request = try JSONDecoder().decode(ShichiZipQuickActionRequest.self, from: data)
        guard request.version == ShichiZipQuickActionRequest.currentVersion else {
            throw ShichiZipQuickActionError.invalidPayload
        }

        log("consumed request action=\(request.action.rawValue) requestFile=\(requestFileURL.path)")
        return request
    }

    static func releasePayload(for launchURL: URL) {
        guard let requestFileURL = try? requestFileURL(from: launchURL) else {
            log("release skipped for invalid launchURL=\(launchURL.absoluteString)")
            return
        }

        removeRequestFile(at: requestFileURL, reason: "released")
    }

    static func cleanupStalePayloads(now: Date = Date()) {
        guard let requestDirectoryURL = try? requestDirectoryURL(),
              let requestFileURLs = try? FileManager.default.contentsOfDirectory(at: requestDirectoryURL,
                                                                                 includingPropertiesForKeys: [.isRegularFileKey,
                                                                                                              .contentModificationDateKey,
                                                                                                              .creationDateKey],
                                                                                 options: [.skipsHiddenFiles])
        else {
            log("stale cleanup skipped bundle=\(bundleIdentifier) appGroupIdentifier=\(appGroupIdentifier ?? "<missing>")")
            return
        }

        var removedCount = 0
        for requestFileURL in requestFileURLs where requestFileURL.pathExtension == "json" {
            guard let resourceValues = try? requestFileURL.resourceValues(forKeys: [.isRegularFileKey,
                                                                                    .contentModificationDateKey,
                                                                                    .creationDateKey]),
                resourceValues.isRegularFile != false,
                let fileDate = resourceValues.contentModificationDate ?? resourceValues.creationDate,
                now.timeIntervalSince(fileDate) >= staleRequestLifetime
            else {
                continue
            }

            if removeRequestFile(at: requestFileURL, reason: "stale-cleanup") {
                removedCount += 1
            }
        }

        log("stale cleanup bundle=\(bundleIdentifier) appGroupIdentifier=\(appGroupIdentifier ?? "<missing>") requestDirectory=\(requestDirectoryURL.path) scanned=\(requestFileURLs.count) removed=\(removedCount)")
    }

    private static func store(_ request: ShichiZipQuickActionRequest) throws -> String {
        let requestIdentifier = UUID().uuidString.lowercased()
        let requestFileURL = try requestFileURL(for: requestIdentifier)
        let data = try JSONEncoder().encode(request)

        do {
            try FileManager.default.createDirectory(at: requestFileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: requestFileURL, options: .atomic)
        } catch {
            log("failed to stage request action=\(request.action.rawValue) bundle=\(bundleIdentifier) appGroupIdentifier=\(appGroupIdentifier ?? "<missing>") requestFile=\(requestFileURL.path) error=\(String(describing: error))")
            throw ShichiZipQuickActionError.transportUnavailable
        }

        log("wrote request payload action=\(request.action.rawValue) bundle=\(bundleIdentifier) appGroupIdentifier=\(appGroupIdentifier ?? "<missing>") requestFile=\(requestFileURL.path)")
        return requestIdentifier
    }

    private static func makeLaunchURL(forRequestIdentifier requestIdentifier: String) throws -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = launchHost
        components.path = launchPath
        components.queryItems = [URLQueryItem(name: requestQueryItemName, value: requestIdentifier)]

        guard let launchURL = components.url else {
            throw ShichiZipQuickActionError.invalidLaunchURL
        }

        return launchURL
    }

    private static func requestFileURL(from launchURL: URL) throws -> URL {
        guard let requestIdentifier = requestIdentifier(from: launchURL) else {
            throw ShichiZipQuickActionError.invalidLaunchURL
        }

        return try requestFileURL(for: requestIdentifier)
    }

    private static func requestFileURL(for requestIdentifier: String) throws -> URL {
        guard let requestUUID = UUID(uuidString: requestIdentifier) else {
            throw ShichiZipQuickActionError.invalidLaunchURL
        }

        return try requestDirectoryURL()
            .appendingPathComponent(requestUUID.uuidString.lowercased())
            .appendingPathExtension("json")
    }

    private static func requestIdentifier(from launchURL: URL) -> String? {
        guard canHandle(launchURL),
              let components = URLComponents(url: launchURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        return components.queryItems?.first(where: { $0.name == requestQueryItemName })?.value
    }

    private static func requestDirectoryURL() throws -> URL {
        if let testingRequestDirectoryURLOverride {
            log("using test request directory bundle=\(bundleIdentifier) requestDirectory=\(testingRequestDirectoryURLOverride.path)")
            return testingRequestDirectoryURLOverride
        }

        guard let appGroupIdentifier else {
            log("transport unavailable missing app group identifier bundle=\(bundleIdentifier) infoKey=\(appGroupIdentifierInfoKey)")
            throw ShichiZipQuickActionError.transportUnavailable
        }

        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            log("transport unavailable unresolved app group container bundle=\(bundleIdentifier) appGroupIdentifier=\(appGroupIdentifier)")
            throw ShichiZipQuickActionError.transportUnavailable
        }

        let requestDirectoryURL = containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(requestDirectoryName, isDirectory: true)

        log("resolved app group container bundle=\(bundleIdentifier) appGroupIdentifier=\(appGroupIdentifier) container=\(containerURL.path) requestDirectory=\(requestDirectoryURL.path)")
        return requestDirectoryURL
    }

    @discardableResult
    private static func removeRequestFile(at requestFileURL: URL, reason: String) -> Bool {
        do {
            try FileManager.default.removeItem(at: requestFileURL)
            log("removed request file reason=\(reason) requestFile=\(requestFileURL.path)")
            return true
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.fileNoSuchFile.rawValue
            {
                return false
            }

            log("failed to remove request file reason=\(reason) requestFile=\(requestFileURL.path) error=\(String(describing: error))")
            return false
        }
    }

    private static func infoString(forKey key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func log(_ message: String) {
        #if DEBUG
            NSLog("[QuickActionTransport] %@", message)
        #else
            os_log(.info, "[QuickActionTransport] %{private}@",
                   message)
        #endif
    }
}
