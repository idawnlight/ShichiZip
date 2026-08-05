import Foundation
@testable import ShichiZipQuickActionCore
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
        setenv("SHICHIZIP_DISABLE_SMART_QUICK_EXTRACT_REVEAL", "1", 1)
        requestDirectoryURL = try? makeTemporaryDirectory(named: #function,
                                                          prefix: "ShichiZipQuickActionRequests")
        if let requestDirectoryURL {
            setenv("SHICHIZIP_QUICK_ACTION_REQUEST_DIRECTORY", requestDirectoryURL.path, 1)
        }
    }

    override func tearDown() {
        unsetenv("SHICHIZIP_QUICK_ACTION_REQUEST_DIRECTORY")
        requestDirectoryURL = nil
        unsetenv("SHICHIZIP_DISABLE_SMART_QUICK_EXTRACT_REVEAL")
        super.tearDown()
    }

    func testInfoPlistRegistersAdditionalArchiveAndDiskImageFileTypes() throws {
        let infoPlist = try loadSourceInfoPlist()
        let documentTypes = try XCTUnwrap(infoPlist["CFBundleDocumentTypes"] as? [[String: Any]])
        let importedTypes = try XCTUnwrap(infoPlist["UTImportedTypeDeclarations"] as? [[String: Any]])
        let importedTypeIdentifiers = importedTypes.compactMap { $0["UTTypeIdentifier"] as? String }
        XCTAssertEqual(importedTypeIdentifiers.count, Set(importedTypeIdentifiers).count)

        var importedTypesByIdentifier: [String: [String: Any]] = [:]
        for importedType in importedTypes {
            guard let identifier = importedType["UTTypeIdentifier"] as? String else {
                continue
            }

            importedTypesByIdentifier[identifier] = importedType
        }

        let knownSystemContentTypes: Set<String> = [
            "com.android.package-archive",
            "com.apple.archive",
            "com.apple.bom-compressed-cpio",
            "com.apple.disk-image",
            "com.apple.disk-image-smi",
            "com.apple.disk-image-udif",
            "com.apple.encrypted-archive",
            "com.apple.iTunes.ipa",
            "com.apple.xar-archive",
            "com.microsoft.windows-executable",
            "com.sun.java-archive",
            "org.gnu.gnu-zip-archive",
            "public.bzip2-archive",
            "public.cpio-archive",
            "public.iso-image",
            "public.tar-archive",
            "public.zip-archive",
        ]
        let referencedContentTypes = Set(documentTypes.flatMap { documentType in
            documentType["LSItemContentTypes"] as? [String] ?? []
        })
        let danglingContentTypes = referencedContentTypes.filter { contentType in
            !knownSystemContentTypes.contains(contentType) && importedTypesByIdentifier[contentType] == nil
        }.sorted()
        XCTAssertTrue(danglingContentTypes.isEmpty,
                      "Dangling LSItemContentTypes: \(danglingContentTypes.joined(separator: ", "))")

        for expectation in DocumentTypeExpectation.registeredArchiveAndDiskImageTypes {
            let matchingDocumentTypes = documentTypes.filter { documentType in
                let extensions = documentType["CFBundleTypeExtensions"] as? [String] ?? []
                return extensions.contains(expectation.fileExtension)
            }
            XCTAssertEqual(matchingDocumentTypes.count,
                           1,
                           "Expected exactly one document type for .\(expectation.fileExtension)")

            let documentType = try XCTUnwrap(matchingDocumentTypes.first)
            XCTAssertEqual(documentType["CFBundleTypeIconFile"] as? String, expectation.iconFile)
            XCTAssertEqual(documentType["NSDocumentClass"] as? String, "$(PRODUCT_MODULE_NAME).ArchiveDocument")
            XCTAssertEqual(documentType["CFBundleTypeRole"] as? String, "Viewer")
            XCTAssertEqual(documentType["LSHandlerRank"] as? String, "Alternate")

            let contentTypes = try XCTUnwrap(documentType["LSItemContentTypes"] as? [String])
            XCTAssertEqual(contentTypes, expectation.contentTypes)
            XCTAssertFalse(contentTypes.isEmpty)

            for contentType in contentTypes where !knownSystemContentTypes.contains(contentType) {
                XCTAssertNotNil(importedTypesByIdentifier[contentType],
                                "\(contentType) must be declared in UTImportedTypeDeclarations")
            }
        }

        for expectation in ImportedTypeExpectation.additionalArchiveAndDiskImageTypes {
            let importedType = try XCTUnwrap(importedTypesByIdentifier[expectation.identifier])
            XCTAssertEqual(importedType["UTTypeDescription"] as? String, expectation.typeDescription)

            let conformsTo = try XCTUnwrap(importedType["UTTypeConformsTo"] as? [String])
            XCTAssertEqual(Set(conformsTo), Set(expectation.conformsTo))

            let tagSpecification = try XCTUnwrap(importedType["UTTypeTagSpecification"] as? [String: Any])
            XCTAssertEqual(tagSpecification["public.filename-extension"] as? [String],
                           [expectation.fileExtension])
        }
    }

    @MainActor
    func testDeliveredQuickActionLaunchDoesNotKeepProcessAliveWhenLaunchNotificationArrivesLater() {
        let coordinator = LaunchOpenCoordinator()

        coordinator.noteLaunchOpenDelivered()
        coordinator.noteLaunchExpectsExternalOpen()

        XCTAssertTrue(coordinator.shouldSuppressInitialFileManager)
        XCTAssertFalse(coordinator.shouldKeepProcessAlive)
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

    func testCompressLaunchURLRoundTripsMultipleSelectedItems() throws {
        let sourceURLs = [
            URL(fileURLWithPath: "/tmp/../tmp/source.txt"),
            URL(fileURLWithPath: "/tmp/folder"),
        ]
        let request = ShichiZipQuickActionRequest(action: .compress,
                                                  fileURLs: sourceURLs)

        let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)
        let consumedRequest = try ShichiZipQuickActionTransport.consumeRequest(from: launchURL)

        XCTAssertEqual(consumedRequest.action, .compress)
        XCTAssertEqual(consumedRequest.fileURLs, sourceURLs.map(\.standardizedFileURL))
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

    @MainActor
    func testSmartQuickExtractContainsLeadingDotRootInsideArchiveDirectory() throws {
        let tempRoot = try makeTemporaryDirectory(named: #function,
                                                  prefix: "ShichiZipQuickActionTests")
        let archiveDirectory = tempRoot.appendingPathComponent("input", isDirectory: true)
        let sourceDirectory = tempRoot.appendingPathComponent("source", isDirectory: true)
        let payloadURL = sourceDirectory.appendingPathComponent("usr/bin/payload.txt")
        let archiveURL = archiveDirectory.appendingPathComponent("leading-dot.cpio")

        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "leading dot payload".write(to: payloadURL, atomically: true, encoding: .utf8)
        try createCpioFixture(at: archiveURL,
                              currentDirectory: sourceDirectory,
                              entryPaths: ["./usr/bin/payload.txt"])
        try FileManager.default.removeItem(at: sourceDirectory)

        let request = ShichiZipQuickActionRequest(action: .smartQuickExtract,
                                                  fileURLs: [archiveURL])
        let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)

        appDelegate.application(NSApp, open: [launchURL])

        let extractedURL = archiveDirectory.appendingPathComponent("leading-dot/usr/bin/payload.txt")
        waitForFile(at: extractedURL)

        XCTAssertEqual(try String(contentsOf: extractedURL, encoding: .utf8),
                       "leading dot payload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("input 1").path),
                       "A leading-dot root must not rename the archive's containing directory")
    }

    @MainActor
    func testSmartQuickExtractContainsParentTraversalRootInsideArchiveDirectory() throws {
        let tempRoot = try makeTemporaryDirectory(named: #function,
                                                  prefix: "ShichiZipQuickActionTests")
        let outerDirectory = tempRoot.appendingPathComponent("outer", isDirectory: true)
        let archiveDirectory = outerDirectory.appendingPathComponent("input", isDirectory: true)
        let payloadURL = outerDirectory.appendingPathComponent("payload.txt")
        let archiveURL = archiveDirectory.appendingPathComponent("parent-root.zip")

        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        try "parent root payload".write(to: payloadURL, atomically: true, encoding: .utf8)
        try createZipFixture(at: archiveURL,
                             currentDirectory: archiveDirectory,
                             entryPaths: ["../payload.txt"])
        try FileManager.default.removeItem(at: payloadURL)

        let request = ShichiZipQuickActionRequest(action: .smartQuickExtract,
                                                  fileURLs: [archiveURL])
        let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)

        appDelegate.application(NSApp, open: [launchURL])

        let extractedURL = archiveDirectory.appendingPathComponent("parent-root/payload.txt")
        waitForFile(at: extractedURL)

        XCTAssertEqual(try String(contentsOf: extractedURL, encoding: .utf8),
                       "parent root payload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("outer 1").path),
                       "A parent traversal root must not select a destination above the archive directory")
    }

    @MainActor
    func testSmartQuickExtractViaURLSchemeRenamesConflictingSingleFile() throws {
        let tempRoot = try makeTemporaryDirectory(named: #function,
                                                  prefix: "ShichiZipQuickActionTests")
        let archiveURL = tempRoot.appendingPathComponent("single-file.7z")
        let sourceDirectory = tempRoot.appendingPathComponent("single-source", isDirectory: true)
        let payloadURL = sourceDirectory.appendingPathComponent("payload.txt")

        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "new payload".write(to: payloadURL, atomically: true, encoding: .utf8)
        try createArchive(at: archiveURL,
                          from: [payloadURL],
                          pathMode: .relativePaths)
        try FileManager.default.removeItem(at: sourceDirectory)
        try "existing payload".write(to: tempRoot.appendingPathComponent("payload.txt"),
                                     atomically: true,
                                     encoding: .utf8)

        let request = ShichiZipQuickActionRequest(action: .smartQuickExtract,
                                                  fileURLs: [archiveURL])
        let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)

        appDelegate.application(NSApp, open: [launchURL])

        let renamedPayloadURL = tempRoot.appendingPathComponent("payload 1.txt")
        waitForFile(at: renamedPayloadURL)

        XCTAssertEqual(try String(contentsOf: renamedPayloadURL, encoding: .utf8),
                       "new payload")
        XCTAssertEqual(try String(contentsOf: tempRoot.appendingPathComponent("payload.txt"), encoding: .utf8),
                       "existing payload")
    }

    @MainActor
    func testSmartQuickExtractViaURLSchemeRenamesConflictingSingleDirectoryRoot() throws {
        let tempRoot = try makeTemporaryDirectory(named: #function,
                                                  prefix: "ShichiZipQuickActionTests")
        let bundleName = "Payload.app"
        let archiveURL = tempRoot.appendingPathComponent("bundle.7z")
        let bundleRoot = tempRoot.appendingPathComponent(bundleName, isDirectory: true)
        let contentsRoot = bundleRoot.appendingPathComponent("Contents", isDirectory: true)

        try FileManager.default.createDirectory(at: contentsRoot, withIntermediateDirectories: true)
        try "new payload".write(to: contentsRoot.appendingPathComponent("payload.txt"),
                                atomically: true,
                                encoding: .utf8)
        try createZipFixture(at: archiveURL,
                             currentDirectory: tempRoot,
                             entryPaths: [bundleName],
                             recursive: true)
        try FileManager.default.removeItem(at: bundleRoot)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        try "existing payload".write(to: bundleRoot.appendingPathComponent("existing.txt"),
                                     atomically: true,
                                     encoding: .utf8)

        let request = ShichiZipQuickActionRequest(action: .smartQuickExtract,
                                                  fileURLs: [archiveURL])
        let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)

        appDelegate.application(NSApp, open: [launchURL])

        let renamedBundleURL = tempRoot.appendingPathComponent("Payload 1.app", isDirectory: true)
        let renamedPayloadURL = renamedBundleURL.appendingPathComponent("Contents/payload.txt")
        waitForFile(at: renamedPayloadURL)

        XCTAssertEqual(try String(contentsOf: renamedPayloadURL, encoding: .utf8),
                       "new payload")
        XCTAssertEqual(try String(contentsOf: bundleRoot.appendingPathComponent("existing.txt"), encoding: .utf8),
                       "existing payload")
    }

    @MainActor
    func testSmartQuickExtractViaURLSchemeRenamesConflictingMultiRootDestination() throws {
        let tempRoot = try makeTemporaryDirectory(named: #function,
                                                  prefix: "ShichiZipQuickActionTests")
        let archiveURL = tempRoot.appendingPathComponent("multi-file.7z")
        let sourceDirectory = tempRoot.appendingPathComponent("multi-source", isDirectory: true)
        let firstPayloadURL = sourceDirectory.appendingPathComponent("first.txt")
        let secondPayloadURL = sourceDirectory.appendingPathComponent("second.txt")
        let existingDestinationURL = tempRoot.appendingPathComponent("multi-file", isDirectory: true)

        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "first payload".write(to: firstPayloadURL, atomically: true, encoding: .utf8)
        try "second payload".write(to: secondPayloadURL, atomically: true, encoding: .utf8)
        try createArchive(at: archiveURL,
                          from: [firstPayloadURL, secondPayloadURL],
                          pathMode: .relativePaths)
        try FileManager.default.removeItem(at: sourceDirectory)
        try FileManager.default.createDirectory(at: existingDestinationURL, withIntermediateDirectories: true)
        try "existing payload".write(to: existingDestinationURL.appendingPathComponent("existing.txt"),
                                     atomically: true,
                                     encoding: .utf8)

        let request = ShichiZipQuickActionRequest(action: .smartQuickExtract,
                                                  fileURLs: [archiveURL])
        let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)

        appDelegate.application(NSApp, open: [launchURL])

        let renamedDestinationURL = tempRoot.appendingPathComponent("multi-file 1", isDirectory: true)
        let firstExtractedURL = renamedDestinationURL.appendingPathComponent("first.txt")
        let secondExtractedURL = renamedDestinationURL.appendingPathComponent("second.txt")
        waitForFile(at: firstExtractedURL)
        waitForFile(at: secondExtractedURL)

        XCTAssertEqual(try String(contentsOf: firstExtractedURL, encoding: .utf8),
                       "first payload")
        XCTAssertEqual(try String(contentsOf: secondExtractedURL, encoding: .utf8),
                       "second payload")
        XCTAssertEqual(try String(contentsOf: existingDestinationURL.appendingPathComponent("existing.txt"), encoding: .utf8),
                       "existing payload")
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

    private func createCpioFixture(at archiveURL: URL,
                                   currentDirectory: URL,
                                   entryPaths: [String]) throws
    {
        FileManager.default.createFile(atPath: archiveURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: archiveURL)
        defer { try? outputHandle.close() }

        let inputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/cpio")
        process.arguments = ["-o", "-H", "newc"]
        process.currentDirectoryURL = currentDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        try process.run()

        let input = Data((entryPaths.joined(separator: "\n") + "\n").utf8)
        try inputPipe.fileHandleForWriting.write(contentsOf: input)
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [
                              NSLocalizedDescriptionKey: "/usr/bin/cpio failed to create fixture at \(archiveURL.path)",
                          ])
        }
    }

    private func stagedPayloadURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: requestDirectoryURL,
                                                      includingPropertiesForKeys: nil,
                                                      options: [])) ?? []
    }

    private func loadSourceInfoPlist() throws -> [String: Any] {
        let infoPlistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ShichiZip/Resources/Info.plist")
        let infoPlistData = try Data(contentsOf: infoPlistURL)
        let propertyList = try PropertyListSerialization.propertyList(from: infoPlistData,
                                                                      options: [],
                                                                      format: nil)
        return try XCTUnwrap(propertyList as? [String: Any])
    }

    private struct DocumentTypeExpectation {
        let fileExtension: String
        let iconFile: String
        let contentTypes: [String]

        static let registeredArchiveAndDiskImageTypes = [
            DocumentTypeExpectation(fileExtension: "iso",
                                    iconFile: "diskimg",
                                    contentTypes: ["public.iso-image"]),
            DocumentTypeExpectation(fileExtension: "udif",
                                    iconFile: "diskimg",
                                    contentTypes: ["com.apple.disk-image-udif"]),
            DocumentTypeExpectation(fileExtension: "deb",
                                    iconFile: "archive",
                                    contentTypes: ["org.debian.deb-archive"]),
            DocumentTypeExpectation(fileExtension: "chm",
                                    iconFile: "archive",
                                    contentTypes: ["com.microsoft.chm"]),
        ]
    }

    private struct ImportedTypeExpectation {
        let identifier: String
        let typeDescription: String
        let fileExtension: String
        let conformsTo: [String]

        static let additionalArchiveAndDiskImageTypes = [
            ImportedTypeExpectation(identifier: "org.debian.deb-archive",
                                    typeDescription: "Debian Package Archive",
                                    fileExtension: "deb",
                                    conformsTo: ["public.data", "public.archive"]),
            ImportedTypeExpectation(identifier: "com.microsoft.chm",
                                    typeDescription: "Compiled HTML Help",
                                    fileExtension: "chm",
                                    conformsTo: ["public.data", "public.archive"]),
        ]
    }
}
