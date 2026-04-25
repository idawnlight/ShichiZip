import Darwin
@testable import ShichiZip
import XCTest

final class QuarantineRegressionTests: XCTestCase {
    private let quarantineAttributeName = "com.apple.quarantine"

    /// Verifies the volume backing the temporary directory actually
    /// supports extended attributes. CI machines occasionally run
    /// their tmp on filesystems (for example some tmpfs variants or
    /// remote mounts) that return EOPNOTSUPP for setxattr; the rest of
    /// the quarantine fixtures are meaningless on such volumes, so we
    /// skip instead of misreporting a failure. Call this from every
    /// xattr-dependent test.
    private func skipUnlessExtendedAttributesWork(at directory: URL) throws {
        let probeURL = directory.appendingPathComponent("xattr-probe-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: probeURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: probeURL) }

        let probeName = "com.shichizip.test.xattr-probe"
        let result = probeName.withCString { namePointer in
            probeURL.path.withCString { pathPointer in
                setxattr(pathPointer, namePointer, "1", 1, 0, XATTR_NOFOLLOW)
            }
        }
        if result != 0 {
            let code = errno
            try XCTSkipIf(code == ENOTSUP || code == EPERM || code == EACCES,
                          "Extended attributes not supported on this volume (errno=\(code)); skipping quarantine regression checks.")
            // Any other setxattr failure is genuinely unexpected and
            // should surface as a test error rather than a skip.
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    func testNormalExtractionShouldInheritSourceArchiveQuarantine() throws {
        let tempRoot = try makeTemporaryDirectory(named: "normal-extract")
        try skipUnlessExtendedAttributesWork(at: tempRoot)

        let payloadURL = tempRoot.appendingPathComponent("payload.txt")
        let archiveURL = tempRoot.appendingPathComponent("payload.7z")
        let destinationURL = tempRoot.appendingPathComponent("extract", isDirectory: true)

        try "payload".write(to: payloadURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: destinationURL, withIntermediateDirectories: true,
        )

        try createArchive(at: archiveURL, from: [payloadURL])

        let quarantineData = Data("0081;661aaff0;ShichiZipTests;".utf8)
        try setExtendedAttribute(quarantineAttributeName, data: quarantineData, on: archiveURL)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let extractionSettings = SZExtractionSettings()
        extractionSettings.pathMode = .fullPaths
        extractionSettings.sourceArchivePathForQuarantine = archiveURL.path
        try archive.extract(
            toPath: destinationURL.path,
            settings: extractionSettings,
            session: nil,
        )

        let extractedURL = destinationURL.appendingPathComponent("payload.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedURL.path))
        XCTAssertEqual(
            try extendedAttributeData(quarantineAttributeName, on: extractedURL), quarantineData,
        )
    }

    func testNormalExtractionShouldInheritSourceArchiveQuarantineForExtractedDirectories() throws {
        let tempRoot = try makeTemporaryDirectory(named: "normal-extract-directory")
        try skipUnlessExtendedAttributesWork(at: tempRoot)

        let payloadDirectoryURL = tempRoot.appendingPathComponent("payload-directory", isDirectory: true)
        let nestedPayloadURL = payloadDirectoryURL.appendingPathComponent("payload.txt")
        let archiveURL = tempRoot.appendingPathComponent("payload-directory.7z")
        let destinationURL = tempRoot.appendingPathComponent("extract", isDirectory: true)

        try FileManager.default.createDirectory(
            at: payloadDirectoryURL, withIntermediateDirectories: true,
        )
        try "payload".write(to: nestedPayloadURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: destinationURL, withIntermediateDirectories: true,
        )

        try createArchive(at: archiveURL, from: [payloadDirectoryURL])

        let quarantineData = Data("0081;661aaff0;ShichiZipTests;".utf8)
        try setExtendedAttribute(quarantineAttributeName, data: quarantineData, on: archiveURL)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let extractionSettings = SZExtractionSettings()
        extractionSettings.pathMode = .fullPaths
        extractionSettings.sourceArchivePathForQuarantine = archiveURL.path
        try archive.extract(
            toPath: destinationURL.path,
            settings: extractionSettings,
            session: nil,
        )

        let extractedDirectoryURL = destinationURL.appendingPathComponent(
            "payload-directory", isDirectory: true,
        )
        let extractedFileURL = extractedDirectoryURL.appendingPathComponent("payload.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedDirectoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedFileURL.path))
        XCTAssertEqual(
            try extendedAttributeData(quarantineAttributeName, on: extractedDirectoryURL),
            quarantineData,
        )
        XCTAssertEqual(
            try extendedAttributeData(quarantineAttributeName, on: extractedFileURL),
            quarantineData,
        )
    }

    func testStagedArchiveItemsShouldInheritSourceArchiveQuarantine() throws {
        let tempRoot = try makeTemporaryDirectory(named: "quarantine")
        try skipUnlessExtendedAttributesWork(at: tempRoot)

        let payloadURL = tempRoot.appendingPathComponent("payload.txt")
        let archiveURL = tempRoot.appendingPathComponent("payload.7z")
        let stagingFileManager = FileManager.default

        try "payload".write(to: payloadURL, atomically: true, encoding: .utf8)

        try createArchive(at: archiveURL, from: [payloadURL])

        let quarantineData = Data("0081;661aaff0;ShichiZipTests;".utf8)
        try setExtendedAttribute(quarantineAttributeName, data: quarantineData, on: archiveURL)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let archiveItems = archive.entries().map(ArchiveItem.init(from:))
        let payloadItem = try XCTUnwrap(archiveItems.first { !$0.isDirectory })
        let workflowService = FileManagerArchiveItemWorkflowService(
            fileManager: stagingFileManager,
            quarantineInheritanceEnabled: { true },
        )
        let context = FileManagerArchiveItemWorkflowContext(
            archive: archive,
            hostDirectory: tempRoot,
            displayPathPrefix: archiveURL.path,
            quarantineSourceArchivePath: archiveURL.path,
            mutationTarget: nil,
        )
        let preview = try workflowService.stageQuickLookItems(
            [payloadItem],
            context: context,
            session: nil,
        )
        defer { workflowService.cleanup(preview.temporaryDirectory) }

        let stagedURL = try XCTUnwrap(preview.fileURLs.first)
        XCTAssertTrue(stagingFileManager.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(
            try extendedAttributeData(quarantineAttributeName, on: stagedURL), quarantineData,
        )
    }

    func testStagedArchiveItemsShouldNotResolveTraversalEntryOutsideTemporaryDirectory() throws {
        let tempRoot = try makeTemporaryDirectory(named: "staged-traversal")
        let escapedLeafName = "staged-traversal-\(UUID().uuidString).txt"
        let archivePayload = "archive payload"
        let existingLocalPayload = "existing local file"

        let temporaryRoot = FileManagerTemporaryDirectorySupport.rootDirectory()
        let existingLocalURL = temporaryRoot.appendingPathComponent(escapedLeafName)
        try existingLocalPayload.write(to: existingLocalURL, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: existingLocalURL)
        }

        let archivePayloadURL = tempRoot.appendingPathComponent(escapedLeafName)
        try archivePayload.write(to: archivePayloadURL, atomically: true, encoding: .utf8)

        let zipRoot = tempRoot.appendingPathComponent("zip-root", isDirectory: true)
        try FileManager.default.createDirectory(at: zipRoot, withIntermediateDirectories: true)

        let archiveURL = tempRoot.appendingPathComponent("traversal.zip")
        try createZipFixture(at: archiveURL,
                             currentDirectory: zipRoot,
                             entryPaths: ["../\(escapedLeafName)"])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        defer { archive.close() }

        let archiveItems = archive.entries().map(ArchiveItem.init(from:))
        let traversalItem = try XCTUnwrap(archiveItems.first { $0.path == "../\(escapedLeafName)" },
                                          "fixture must preserve the traversal entry path; got \(archiveItems.map(\.path))")
        let workflowService = FileManagerArchiveItemWorkflowService(
            fileManager: .default,
            quarantineInheritanceEnabled: { false },
        )
        let context = FileManagerArchiveItemWorkflowContext(
            archive: archive,
            hostDirectory: tempRoot,
            displayPathPrefix: archiveURL.path,
            quarantineSourceArchivePath: nil,
            mutationTarget: nil,
        )

        let preview = try workflowService.stageQuickLookItems(
            [traversalItem],
            context: context,
            session: SZOperationSession(),
        )
        defer { workflowService.cleanup(preview.temporaryDirectory) }

        let stagedURL = try XCTUnwrap(preview.fileURLs.first)
        let stagedPath = stagedURL.standardizedFileURL.path
        let temporaryDirectoryPath = preview.temporaryDirectory.standardizedFileURL.path
        XCTAssertTrue(stagedPath.hasPrefix(temporaryDirectoryPath + "/"),
                      "staged URL must stay inside the staging directory; got \(stagedPath)")
        XCTAssertEqual(try String(contentsOf: stagedURL, encoding: .utf8), archivePayload)
    }

    func testNestedArchiveExtractionShouldInheritOriginalSourceArchiveQuarantine() throws {
        let tempRoot = try makeTemporaryDirectory(named: "nested-extract")
        try skipUnlessExtendedAttributesWork(at: tempRoot)

        let innerPayloadURL = tempRoot.appendingPathComponent("inner-payload.txt")
        let innerArchiveURL = tempRoot.appendingPathComponent("inner.7z")
        let outerArchiveURL = tempRoot.appendingPathComponent("outer.7z")
        let outerHostDirectory = tempRoot.appendingPathComponent("outer-host", isDirectory: true)
        let nestedExtractURL = tempRoot.appendingPathComponent(
            "nested-extract-output", isDirectory: true,
        )

        try "nested payload".write(to: innerPayloadURL, atomically: true, encoding: .utf8)

        try createArchive(at: innerArchiveURL, from: [innerPayloadURL])
        try createArchive(at: outerArchiveURL, from: [innerArchiveURL])

        let quarantineData = Data("0081;661aaff0;ShichiZipTests;".utf8)
        try setExtendedAttribute(quarantineAttributeName, data: quarantineData, on: outerArchiveURL)

        let outerArchive = SZArchive()
        try outerArchive.open(atPath: outerArchiveURL.path, session: nil)
        defer { outerArchive.close() }

        let outerItems = outerArchive.entries().map(ArchiveItem.init(from:))
        let nestedArchiveItem = try XCTUnwrap(outerItems.first { $0.name == "inner.7z" })
        let workflowService = FileManagerArchiveItemWorkflowService(
            fileManager: .default,
            quarantineInheritanceEnabled: { true },
        )
        let outerContext = FileManagerArchiveItemWorkflowContext(
            archive: outerArchive,
            hostDirectory: outerHostDirectory,
            displayPathPrefix: outerArchiveURL.path,
            quarantineSourceArchivePath: outerArchiveURL.path,
            mutationTarget: nil,
        )
        let stagedNestedArchive = try workflowService.stageQuickLookItems(
            [nestedArchiveItem],
            context: outerContext,
            session: nil,
        )
        defer { workflowService.cleanup(stagedNestedArchive.temporaryDirectory) }

        let stagedNestedArchiveURL = try XCTUnwrap(stagedNestedArchive.fileURLs.first)
        XCTAssertEqual(
            try extendedAttributeData(quarantineAttributeName, on: stagedNestedArchiveURL),
            quarantineData,
        )

        let innerArchive = SZArchive()
        try innerArchive.open(atPath: stagedNestedArchiveURL.path, session: nil)
        defer { innerArchive.close() }

        let extractionSettings = SZExtractionSettings()
        extractionSettings.pathMode = .fullPaths
        extractionSettings.sourceArchivePathForQuarantine = stagedNestedArchiveURL.path
        try FileManager.default.createDirectory(
            at: nestedExtractURL, withIntermediateDirectories: true,
        )
        try innerArchive.extract(
            toPath: nestedExtractURL.path,
            settings: extractionSettings,
            session: nil,
        )

        let extractedURL = nestedExtractURL.appendingPathComponent("inner-payload.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedURL.path))
        XCTAssertEqual(
            try extendedAttributeData(quarantineAttributeName, on: extractedURL), quarantineData,
        )
    }

    private func setExtendedAttribute(_ name: String, data: Data, on url: URL) throws {
        let result = data.withUnsafeBytes { buffer in
            url.path.withCString { pathPointer in
                name.withCString { namePointer in
                    setxattr(
                        pathPointer,
                        namePointer,
                        buffer.baseAddress,
                        buffer.count,
                        0,
                        XATTR_NOFOLLOW,
                    )
                }
            }
        }

        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func extendedAttributeData(_ name: String, on url: URL) throws -> Data? {
        let size = url.path.withCString { pathPointer in
            name.withCString { namePointer in
                getxattr(pathPointer, namePointer, nil, 0, 0, XATTR_NOFOLLOW)
            }
        }

        if size < 0 {
            if errno == ENOATTR || errno == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { buffer in
            url.path.withCString { pathPointer in
                name.withCString { namePointer in
                    getxattr(
                        pathPointer,
                        namePointer,
                        buffer.baseAddress,
                        buffer.count,
                        0,
                        XATTR_NOFOLLOW,
                    )
                }
            }
        }

        if result < 0 {
            if errno == ENOATTR || errno == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return data
    }
}
