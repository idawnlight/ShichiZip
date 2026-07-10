import AppKit
import Foundation

@MainActor
protocol ShichiZipQuickActionLaunching {
    func open(_ url: URL) -> Bool
}

struct ShichiZipWorkspaceQuickActionLauncher: ShichiZipQuickActionLaunching {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
struct ShichiZipQuickActionRequestPipeline {
    private let policy: ShichiZipQuickActionRequestPolicy
    private let launcher: any ShichiZipQuickActionLaunching
    private let logger: ShichiZipQuickActionLogger

    init(policy: ShichiZipQuickActionRequestPolicy,
         launcher: any ShichiZipQuickActionLaunching = ShichiZipWorkspaceQuickActionLauncher())
    {
        self.policy = policy
        self.launcher = launcher
        logger = ShichiZipQuickActionLogger(action: policy.action)
    }

    func handle(_ context: NSExtensionContext) async {
        do {
            let fileURLs = try await ShichiZipQuickActionInputLoader.fileURLs(from: context,
                                                                              action: policy.action)
            logger.log("resolved fileURLCount=\(fileURLs.count)")
            let request = try policy.makeRequest(from: fileURLs)
            let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)
            let didLaunch = launcher.open(launchURL)

            logger.log("workspace open success=\(didLaunch) url=\(launchURL.absoluteString)")

            if didLaunch {
                complete(context)
            } else {
                ShichiZipQuickActionTransport.releasePayload(for: launchURL)
                cancel(context, error: ShichiZipQuickActionError.launchFailed)
            }
        } catch ShichiZipQuickActionInputError.emptyExtensionContext {
            logger.log("completing host request with an empty extension context")
            complete(context)
        } catch {
            logger.log("canceling with error=\(String(describing: error))")
            cancel(context, error: error)
        }
    }

    private func complete(_ context: NSExtensionContext) {
        context.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func cancel(_ context: NSExtensionContext, error: Error) {
        context.cancelRequest(withError: error)
    }
}
