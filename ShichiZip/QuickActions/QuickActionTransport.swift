import AppKit
import Foundation

enum ShichiZipQuickActionTransport {
    private static let launchHost = "quick-action"
    private static let launchPath = "/finder"
    private static let pasteboardQueryItemName = "pasteboard"
    private static let defaultPasteboardType = "ee.dawn.ShichiZip.quick-action-request"
    private static let defaultURLScheme = "shichizip"
    private static let pasteboardTypeInfoKey = "ShichiZipQuickActionPasteboardType"
    private static let urlSchemeInfoKey = "ShichiZipQuickActionURLScheme"

    static var urlScheme: String {
        infoString(forKey: urlSchemeInfoKey) ?? defaultURLScheme
    }

    private static var pasteboardType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(infoString(forKey: pasteboardTypeInfoKey) ?? defaultPasteboardType)
    }

    static func canHandle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }

        return scheme == urlScheme && host == launchHost && url.path == launchPath
    }

    static func launchURL(for request: ShichiZipQuickActionRequest) throws -> URL {
        let pasteboardName = try store(request)
        return try makeLaunchURL(forPasteboardName: pasteboardName)
    }

    static func consumeRequest(from launchURL: URL) throws -> ShichiZipQuickActionRequest {
        let pasteboard = try pasteboard(from: launchURL)
        defer { release(pasteboard) }

        guard let data = pasteboard.data(forType: pasteboardType) else {
            throw ShichiZipQuickActionError.missingPayload
        }

        let request = try JSONDecoder().decode(ShichiZipQuickActionRequest.self, from: data)
        guard request.version == ShichiZipQuickActionRequest.currentVersion else {
            throw ShichiZipQuickActionError.invalidPayload
        }

        return request
    }

    static func releasePayload(for launchURL: URL) {
        guard let pasteboardName = pasteboardName(from: launchURL) else {
            return
        }

        release(NSPasteboard(name: NSPasteboard.Name(pasteboardName)))
    }

    private static func store(_ request: ShichiZipQuickActionRequest) throws -> String {
        let pasteboard = NSPasteboard.withUniqueName()
        let data = try JSONEncoder().encode(request)

        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: pasteboardType) else {
            pasteboard.releaseGlobally()
            throw ShichiZipQuickActionError.invalidPayload
        }

        return pasteboard.name.rawValue
    }

    private static func makeLaunchURL(forPasteboardName pasteboardName: String) throws -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = launchHost
        components.path = launchPath
        components.queryItems = [URLQueryItem(name: pasteboardQueryItemName, value: pasteboardName)]

        guard let launchURL = components.url else {
            throw ShichiZipQuickActionError.invalidLaunchURL
        }

        return launchURL
    }

    private static func pasteboard(from launchURL: URL) throws -> NSPasteboard {
        guard let pasteboardName = pasteboardName(from: launchURL) else {
            throw ShichiZipQuickActionError.invalidLaunchURL
        }

        return NSPasteboard(name: NSPasteboard.Name(pasteboardName))
    }

    private static func pasteboardName(from launchURL: URL) -> String? {
        guard canHandle(launchURL),
              let components = URLComponents(url: launchURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        return components.queryItems?.first(where: { $0.name == pasteboardQueryItemName })?.value
    }

    private static func release(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.releaseGlobally()
    }

    private static func infoString(forKey key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}