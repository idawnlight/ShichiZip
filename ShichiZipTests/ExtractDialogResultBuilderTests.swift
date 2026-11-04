#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class ExtractDialogResultBuilderTests: XCTestCase {
    func testOnlyEmptyPasswordIsMissingAndWhitespaceIsPreserved() throws {
        let tempRoot = try makeTemporaryDirectory(named: "extract-dialog-password")
        let builder = ExtractDialogResultBuilder(baseDirectory: tempRoot)
        var state = makeState(destinationPath: tempRoot.path)

        XCTAssertNil(try builder.buildResult(from: state).result.password)
        for password in ["  secret \n", " \t\n"] {
            state.password = password
            XCTAssertEqual(try builder.buildResult(from: state).result.password, password)
        }
    }

    func testRelativeDestinationResolvesUnderBaseDirectoryWithoutCreatingDirectory() throws {
        let tempRoot = try makeTemporaryDirectory(named: "extract-dialog-relative-destination")
        let builder = ExtractDialogResultBuilder(baseDirectory: tempRoot)

        let resolved = try builder.buildResult(from: makeState(destinationPath: "Nested/Output"))
        let expectedURL = tempRoot.appendingPathComponent("Nested/Output").standardizedFileURL

        XCTAssertEqual(resolved.baseDestinationURL.path, expectedURL.path)
        XCTAssertEqual(resolved.result.destinationURL.path, expectedURL.path)
        XCTAssertFalse(directoryExists(at: expectedURL))
    }

    func testExistingFileDestinationIsRejected() throws {
        let tempRoot = try makeTemporaryDirectory(named: "extract-dialog-file-destination")
        let fileURL = tempRoot.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: fileURL)
        let builder = ExtractDialogResultBuilder(baseDirectory: tempRoot)

        XCTAssertThrowsError(try builder.buildResult(from: makeState(destinationPath: fileURL.path))) { error in
            let cocoaError = error as NSError
            XCTAssertEqual(cocoaError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(cocoaError.code, NSFileWriteInvalidFileNameError)
        }
    }

    func testSplitDestinationAppendsTrimmedFolderName() throws {
        let tempRoot = try makeTemporaryDirectory(named: "extract-dialog-split-destination")
        let builder = ExtractDialogResultBuilder(baseDirectory: tempRoot)

        let resolved = try builder.buildResult(from: makeState(destinationPath: tempRoot.path,
                                                               splitDestination: true,
                                                               splitName: "  Archive Output  "))

        XCTAssertEqual(resolved.baseDestinationURL, tempRoot.standardizedFileURL)
        XCTAssertEqual(resolved.result.destinationURL,
                       tempRoot.appendingPathComponent("Archive Output", isDirectory: true).standardizedFileURL)
        XCTAssertFalse(directoryExists(at: resolved.result.destinationURL))
    }

    func testEmptySplitDestinationNameIsRejected() throws {
        let tempRoot = try makeTemporaryDirectory(named: "extract-dialog-empty-split-name")
        let builder = ExtractDialogResultBuilder(baseDirectory: tempRoot)

        XCTAssertThrowsError(try builder.buildResult(from: makeState(destinationPath: tempRoot.path,
                                                                     splitDestination: true,
                                                                     splitName: " \t\n")))
        { error in
            let cocoaError = error as NSError
            XCTAssertEqual(cocoaError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(cocoaError.code, NSFileWriteInvalidFileNameError)
        }
    }

    func testRevealAfterExtractInFileManagerChoiceIsReturned() throws {
        let tempRoot = try makeTemporaryDirectory(named: "extract-dialog-reveal-in-finder")
        let builder = ExtractDialogResultBuilder(baseDirectory: tempRoot)
        var state = makeState(destinationPath: tempRoot.path)
        state.revealAfterExtractInFileManager = true

        let resolved = try builder.buildResult(from: state)

        XCTAssertTrue(resolved.result.revealAfterExtractInFileManager)
    }

    func testSplitDestinationRejectsPathComponentsAndFilesButAllowsExistingDirectories() throws {
        let tempRoot = try makeTemporaryDirectory(named: "extract-dialog-invalid-split-name")
        let builder = ExtractDialogResultBuilder(baseDirectory: tempRoot)
        for name in [".", "..", "Nested/Output"] {
            XCTAssertThrowsError(try builder.buildResult(from: makeState(destinationPath: tempRoot.path,
                                                                         splitDestination: true,
                                                                         splitName: name)))
        }

        let outputURL = tempRoot.appendingPathComponent("Output")
        try Data("payload".utf8).write(to: outputURL)
        let state = makeState(destinationPath: tempRoot.path, splitDestination: true, splitName: "Output")
        XCTAssertThrowsError(try builder.buildResult(from: state))
        try FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: false)
        XCTAssertEqual(try builder.buildResult(from: state).result.destinationURL, outputURL.standardizedFileURL)
    }

    private func makeState(destinationPath: String,
                           splitDestination: Bool = false,
                           splitName: String = "Archive") -> ExtractDialogState
    {
        ExtractDialogState(destinationPath: destinationPath,
                           pathMode: .fullPaths,
                           overwriteMode: .ask,
                           password: "",
                           preserveNtSecurityInfo: false,
                           eliminateDuplicates: true,
                           destinationFolder: ExtractDestinationFolder(isEnabled: splitDestination, name: splitName),
                           showPassword: false,
                           moveArchiveToTrashAfterExtraction: false,
                           inheritDownloadedFileQuarantine: false,
                           revealAfterExtractInFileManager: false)
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
