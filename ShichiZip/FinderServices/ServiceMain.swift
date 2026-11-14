import AppKit
import ShichiZipQuickActionCore

@main
struct FinderServiceMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let provider = AppFileServicesProvider { request in
            let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)
            guard NSWorkspace.shared.open(launchURL) else {
                ShichiZipQuickActionTransport.releasePayload(for: launchURL)
                throw ShichiZipQuickActionError.launchFailed
            }
        }
        app.servicesProvider = provider
        app.run()
    }
}
