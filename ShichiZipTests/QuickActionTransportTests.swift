import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class QuickActionTransportTests: XCTestCase {
    private var requestDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        // Use the test override instead of mutating process-wide environment state.
        AppDelegate.testingShouldRevealSmartQuickExtractDestinationOverride = false
        requestDirectoryURL = try? makeTemporaryDirectory(named: #function,
                                                          prefix: "ShichiZipQuickActionRequests")
        ShichiZipQuickActionTransport.testingRequestDirectoryURLOverride = requestDirectoryURL
    }

    override func tearDown() {
        ShichiZipQuickActionTransport.testingRequestDirectoryURLOverride = nil
        requestDirectoryURL = nil
        AppDelegate.testingShouldRevealSmartQuickExtractDestinationOverride = nil
        super.tearDown()
    }

    func testSmartQuickExtractLaunchURLRoundTripsRequest() throws {
        let archiveURL = URL(fileURLWithPath: "/tmp/../tmp/archive.7z")
        let request = ShichiZipQuickActionRequest(action: .smartQuickExtract,
                                                  fileURLs: [archiveURL])

        let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)
        let components = try XCTUnwrap(URLComponents(url: launchURL, resolvingAgainstBaseURL: false))
        let requestIdentifier = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "request" })?.value)
        let consumedRequest = try ShichiZipQuickActionTransport.consumeRequest(from: launchURL)

        XCTAssertEqual(launchURL.scheme?.lowercased(),
                       ShichiZipQuickActionTransport.urlScheme.lowercased())
        XCTAssertEqual(launchURL.host?.lowercased(), "quick-action")
        XCTAssertEqual(launchURL.path, "/finder")
        XCTAssertFalse(requestIdentifier.isEmpty)
        XCTAssertTrue(ShichiZipQuickActionTransport.canHandle(launchURL))
        XCTAssertEqual(consumedRequest.action, .smartQuickExtract)
        XCTAssertEqual(consumedRequest.fileURLs, [archiveURL.standardizedFileURL])
        XCTAssertEqual(stagedPayloadURLs().count, 0)
    }

    func testSmartQuickExtractLaunchURLRejectsDifferentScheme() throws {
        let request = ShichiZipQuickActionRequest(action: .smartQuickExtract,
                                                  fileURLs: [URL(fileURLWithPath: "/tmp/archive.7z")])
        let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)
        var components = try XCTUnwrap(URLComponents(url: launchURL, resolvingAgainstBaseURL: false))
        components.scheme = "invalid-\(ShichiZipQuickActionTransport.urlScheme)"
        let invalidURL = try XCTUnwrap(components.url)

        XCTAssertFalse(ShichiZipQuickActionTransport.canHandle(invalidURL))
        XCTAssertThrowsError(try ShichiZipQuickActionTransport.consumeRequest(from: invalidURL)) { error in
            guard case ShichiZipQuickActionError.invalidLaunchURL = error else {
                return XCTFail("Expected invalidLaunchURL, got \(error)")
            }
        }
        XCTAssertEqual(stagedPayloadURLs().count, 1)

        let consumedRequest = try ShichiZipQuickActionTransport.consumeRequest(from: launchURL)
        XCTAssertEqual(consumedRequest.action, .smartQuickExtract)
        XCTAssertEqual(stagedPayloadURLs().count, 0)
    }

    func testReleasePayloadRemovesStagedRequestFile() throws {
        let request = ShichiZipQuickActionRequest(action: .smartQuickExtract,
                                                  fileURLs: [URL(fileURLWithPath: "/tmp/archive.7z")])
        let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)

        XCTAssertEqual(stagedPayloadURLs().count, 1)

        ShichiZipQuickActionTransport.releasePayload(for: launchURL)

        XCTAssertEqual(stagedPayloadURLs().count, 0)
    }

    func testCleanupStalePayloadsRemovesOnlyExpiredFiles() throws {
        let expiredFileURL = requestDirectoryURL.appendingPathComponent("expired.json")
        let freshFileURL = requestDirectoryURL.appendingPathComponent("fresh.json")
        let markerDate = Date()

        try Data("expired".utf8).write(to: expiredFileURL)
        try Data("fresh".utf8).write(to: freshFileURL)

        try FileManager.default.setAttributes([.modificationDate: markerDate.addingTimeInterval(-(25 * 60 * 60))],
                                              ofItemAtPath: expiredFileURL.path)
        try FileManager.default.setAttributes([.modificationDate: markerDate],
                                              ofItemAtPath: freshFileURL.path)

        ShichiZipQuickActionTransport.cleanupStalePayloads(now: markerDate)

        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshFileURL.path))
    }

    @MainActor
    func testSmartQuickExtractViaURLSchemeExtractsSingleTopLevelArchiveIntoBaseDirectory() throws {
        let tempRoot = try makeTemporaryDirectory(named: #function,
                                                  prefix: "ShichiZipQuickActionTests")
        let archiveURL = tempRoot.appendingPathComponent("single-file.7z")
        let sourceDirectory = tempRoot.appendingPathComponent("single-source", isDirectory: true)
        let payloadURL = sourceDirectory.appendingPathComponent("payload.txt")

        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "single payload".write(to: payloadURL, atomically: true, encoding: .utf8)
        try createArchive(at: archiveURL,
                          from: [payloadURL],
                          pathMode: .relativePaths)
        try FileManager.default.removeItem(at: sourceDirectory)

        let request = ShichiZipQuickActionRequest(action: .smartQuickExtract,
                                                  fileURLs: [archiveURL])
        let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)

        appDelegate.application(NSApp, open: [launchURL])

        let extractedURL = tempRoot.appendingPathComponent("payload.txt")
        waitForFile(at: extractedURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("single-file").path),
                       "Single-top-level archives should extract directly into the base directory")
    }

    @MainActor
    func testSmartQuickExtractViaURLSchemeExtractsMultiTopLevelArchiveIntoArchiveNamedDirectory() throws {
        let tempRoot = try makeTemporaryDirectory(named: #function,
                                                  prefix: "ShichiZipQuickActionTests")
        let archiveURL = tempRoot.appendingPathComponent("multi-file.7z")
        let sourceDirectory = tempRoot.appendingPathComponent("multi-source", isDirectory: true)
        let firstPayloadURL = sourceDirectory.appendingPathComponent("first.txt")
        let secondPayloadURL = sourceDirectory.appendingPathComponent("second.txt")

        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "first payload".write(to: firstPayloadURL, atomically: true, encoding: .utf8)
        try "second payload".write(to: secondPayloadURL, atomically: true, encoding: .utf8)
        try createArchive(at: archiveURL,
                          from: [firstPayloadURL, secondPayloadURL],
                          pathMode: .relativePaths)
        try FileManager.default.removeItem(at: sourceDirectory)

        let request = ShichiZipQuickActionRequest(action: .smartQuickExtract,
                                                  fileURLs: [archiveURL])
        let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)

        appDelegate.application(NSApp, open: [launchURL])

        let extractedDirectoryURL = tempRoot.appendingPathComponent("multi-file", isDirectory: true)
        let firstExtractedURL = extractedDirectoryURL.appendingPathComponent("first.txt")
        let secondExtractedURL = extractedDirectoryURL.appendingPathComponent("second.txt")
        waitForFile(at: firstExtractedURL)
        waitForFile(at: secondExtractedURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedDirectoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstExtractedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondExtractedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("first.txt").path),
                       "Multi-top-level archives should extract into an archive-named directory")
    }

    private func waitForFile(at url: URL,
                             timeout: TimeInterval = 15,
                             pollInterval: TimeInterval = 0.05)
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }

            RunLoop.main.run(until: Date().addingTimeInterval(pollInterval))
        }

        XCTFail("Timed out waiting for file at \(url.path)")
    }

    private func stagedPayloadURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: requestDirectoryURL,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? []
    }
}
