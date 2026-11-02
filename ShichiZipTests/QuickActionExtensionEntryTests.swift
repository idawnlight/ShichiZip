import Darwin
import Foundation
@testable import ShichiZipQuickActionCore
import XCTest

final class QuickActionExtensionEntryTests: XCTestCase {
    @MainActor
    func testDataInputRejectsTextAndAcceptsFileReferences() async throws {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        for (data, expected) in try [(Data("hello world".utf8), nil), (Data(url.path.utf8), url.path), (url.bookmarkData(), url.path)] {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: "public.data", visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            let item = NSExtensionItem()
            item.attachments = [provider]
            let context = RecordingExtensionContext(expectation: XCTestExpectation())
            context.items = [item]
            let urls = try? await ShichiZipQuickActionInputLoader.fileURLs(from: context, action: .showInFileManager)
            XCTAssertEqual(urls?.first?.path, expected)
        }
    }

    func testQuickActionAppexEntryPointsAcceptBackgroundQueueRequests() throws {
        for appexName in Self.quickActionAppexNames {
            let handler = try loadQuickActionHandler(from: appexName)
            let context = RecordingExtensionContext(expectation: expectation(description: "\(appexName) request finished"))
            let invocation = UncheckedSendableBox<QuickActionHandlerInvocation>()
            invocation.value = QuickActionHandlerInvocation(handler: handler,
                                                            context: context)

            DispatchQueue(label: "QuickActionExtensionEntryTests.\(appexName)").async {
                guard let invocation = invocation.value else {
                    return
                }

                invocation.handler.beginRequest(with: invocation.context)
            }

            wait(for: [context.finishedExpectation], timeout: 5)
            XCTAssertFalse(context.didComplete, "Empty Quick Action requests should be cancelled, not completed.")
            XCTAssertNotNil(context.cancellationError)
        }
    }

    private func loadQuickActionHandler(from appexName: String) throws -> NSExtensionRequestHandling {
        let appexBundle = try loadQuickActionBundle(named: appexName)
        let extensionInfo = try XCTUnwrap(appexBundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
        let principalClassName = try XCTUnwrap(extensionInfo["NSExtensionPrincipalClass"] as? String)
        let principalClass = try XCTUnwrap(NSClassFromString(principalClassName) as? NSObject.Type)
        let handler = principalClass.init()

        return try XCTUnwrap(handler as? NSExtensionRequestHandling)
    }

    private func loadQuickActionBundle(named appexName: String) throws -> Bundle {
        let plugInsURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let appexURL = plugInsURL.appendingPathComponent("\(appexName).appex", isDirectory: true)
        let appexBundle = try XCTUnwrap(Bundle(url: appexURL))

        if appexBundle.load() || loadDebugDylib(for: appexBundle, at: appexURL) {
            return appexBundle
        }

        let loadError = dlerror().map { String(cString: $0) } ?? "Unknown bundle load error."
        XCTFail("Failed to load \(appexName).appex: \(loadError)")
        return appexBundle
    }

    private func loadDebugDylib(for appexBundle: Bundle, at appexURL: URL) -> Bool {
        guard let executableName = appexBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String else {
            return false
        }

        let debugDylibURL = appexURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("\(executableName).debug.dylib")
        guard FileManager.default.fileExists(atPath: debugDylibURL.path) else {
            return false
        }

        return dlopen(debugDylibURL.path, RTLD_NOW | RTLD_LOCAL) != nil
    }

    private static var quickActionAppexNames: [String] {
        #if SHICHIZIP_ZS_VARIANT
            [
                "ShichiZipZSRevealInFileManagerAction",
                "ShichiZipZSOpenInShichiZipAction",
                "ShichiZipZSCompressAction",
                "ShichiZipZSSmartQuickExtractAction",
            ]
        #else
            [
                "ShichiZipRevealInFileManagerAction",
                "ShichiZipOpenInShichiZipAction",
                "ShichiZipCompressAction",
                "ShichiZipSmartQuickExtractAction",
            ]
        #endif
    }
}

private struct QuickActionHandlerInvocation {
    let handler: NSExtensionRequestHandling
    let context: NSExtensionContext
}

private final class RecordingExtensionContext: NSExtensionContext {
    let finishedExpectation: XCTestExpectation
    var items: [Any] = []

    private let stateLock = NSLock()
    private var completed = false
    private var error: Error?

    init(expectation: XCTestExpectation) {
        finishedExpectation = expectation
        super.init()
    }

    override var inputItems: [Any] {
        items
    }

    var didComplete: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return completed
    }

    var cancellationError: Error? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return error
    }

    override func completeRequest(returningItems _: [Any]?, completionHandler: ((Bool) -> Void)? = nil) {
        stateLock.lock()
        completed = true
        stateLock.unlock()

        completionHandler?(true)
        finishedExpectation.fulfill()
    }

    override func cancelRequest(withError error: Error) {
        stateLock.lock()
        self.error = error
        stateLock.unlock()

        finishedExpectation.fulfill()
    }
}
