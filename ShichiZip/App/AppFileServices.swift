import AppKit
import ShichiZipQuickActionCore

@MainActor
final class AppFileServicesProvider: NSObject {
    private let handleRequest: (ShichiZipQuickActionRequest) throws -> Void

    init(handleRequest: @escaping (ShichiZipQuickActionRequest) throws -> Void) {
        self.handleRequest = handleRequest
    }

    @objc func performFileAction(_ pasteboard: NSPasteboard,
                                userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>)
    {
        do {
            guard let userData, let action = ShichiZipQuickAction(rawValue: userData) else {
                throw ShichiZipQuickActionError.invalidPayload
            }
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                   options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty
            else {
                throw CocoaError(.fileReadInvalidFileName)
            }

            try handleRequest(ShichiZipQuickActionRequest(action: action, fileURLs: urls))
        } catch let failure {
            error.pointee = failure.localizedDescription as NSString
        }
    }
}
