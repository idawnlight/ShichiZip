import AppKit
import ShichiZipQuickActionCore
import XCTest

#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

@MainActor
final class AppFileServicesTests: XCTestCase {
    func testRoutesEachServiceWithTheSelectedFileURLs() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/tmp/測試 folder/one.zip"),
                    URL(fileURLWithPath: "/tmp/another file.7z")]
        XCTAssertTrue(pasteboard.writeObjects(urls as [NSURL]))
        var requests: [ShichiZipQuickActionRequest] = []
        let provider = AppFileServicesProvider { requests.append($0) }
        let actions: [ShichiZipQuickAction] = [.showInFileManager, .openInShichiZip, .compress, .smartQuickExtract]

        for action in actions {
            var error: NSString?
            provider.performFileAction(pasteboard, userData: action.rawValue, error: &error)
            XCTAssertNil(error)
        }

        XCTAssertEqual(requests.map(\.action), actions)
        XCTAssertEqual(requests.map(\.fileURLs), Array(repeating: urls, count: actions.count))
    }

    func testRejectsNonFileURLsAndEmptySelections() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var didOpen = false
        let provider = AppFileServicesProvider { _ in didOpen = true }
        XCTAssertTrue(pasteboard.writeObjects([NSURL(string: "https://example.com/archive.zip")!]))
        var error: NSString?

        provider.performFileAction(pasteboard, userData: "compress", error: &error)
        XCTAssertNotNil(error)
        XCTAssertFalse(didOpen)

        pasteboard.clearContents()
        error = nil
        provider.performFileAction(pasteboard, userData: "compress", error: &error)
        XCTAssertNotNil(error)
        XCTAssertFalse(didOpen)
    }

    func testRejectsMissingOrUnknownActions() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/archive.zip")]))
        var didOpen = false
        let provider = AppFileServicesProvider { _ in didOpen = true }

        for action in [nil, "unknown"] as [String?] {
            var error: NSString?
            provider.performFileAction(pasteboard, userData: action, error: &error)
            XCTAssertNotNil(error)
        }
        XCTAssertFalse(didOpen)
    }

    func testReportsExistingActionValidationErrorsToServices() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/archive.zip")]))
        let expected = ShichiZipQuickActionError.unsupportedSelection("Select a single archive to extract.")
        let provider = AppFileServicesProvider { _ in throw expected }
        var error: NSString?

        provider.performFileAction(pasteboard, userData: "smart-quick-extract", error: &error)

        XCTAssertEqual(error as String?, expected.localizedDescription)
    }
}
