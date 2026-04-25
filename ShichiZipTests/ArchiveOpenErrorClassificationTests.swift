import XCTest

final class ArchiveOpenErrorClassificationTests: XCTestCase {
    func testEncryptedHeaderArchiveWithWrongPasswordMatchesUpstreamClassification() throws {
        let archiveURL = try makeArchive(named: "encrypted-header-wrong-password",
                                         payloadFileName: "secret.txt",
                                         payloadContents: "secret payload",
                                         password: "correct-password",
                                         encryptFileNames: true)

        let archive = SZArchive()
        let error = try captureOpenError(from: archive,
                                         path: archiveURL.path,
                                         password: "wrong-password")

        XCTAssertWrongPassword(
            error,
            description: "Cannot open encrypted archive '\(archiveURL.path)'. Wrong password?",
        )
    }

    func testCorruptedEncryptedArchiveWithPasswordUsesUpstreamWrongPasswordClassification() throws {
        let tempRoot = try makeTemporaryDirectory(named: "corrupted-encrypted")

        let payloadURL = tempRoot.appendingPathComponent("payload.txt")
        let archiveURL = tempRoot.appendingPathComponent("payload.7z")
        let corruptedArchiveURL = tempRoot.appendingPathComponent("payload-corrupted.7z")

        try "secret payload".write(to: payloadURL, atomically: true, encoding: .utf8)
        try createArchive(at: archiveURL,
                          from: [payloadURL],
                          password: "correct-password",
                          encryptFileNames: true)
        try FileManager.default.copyItem(at: archiveURL, to: corruptedArchiveURL)
        try corruptArchive(at: corruptedArchiveURL)

        let archive = SZArchive()
        let error = try captureOpenError(from: archive, path: corruptedArchiveURL.path, password: "wrong-password")

        XCTAssertWrongPassword(
            error,
            description: "Cannot open encrypted archive '\(corruptedArchiveURL.path)'. Wrong password?",
        )
        XCTAssertTrue(error.localizedFailureReason?.contains("Headers Error") ?? false,
                      "upstream-compatible headline should still preserve header details: \(error)")
    }

    func testExtractingEncryptedPayloadWithWrongPasswordReportsWrongPassword() throws {
        let archiveURL = try makeArchive(named: "extract-wrong-password",
                                         payloadFileName: "secret.txt",
                                         payloadContents: "secret payload",
                                         password: "correct-password")

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        defer { archive.close() }

        let extractDir = try makeTemporaryDirectory(named: "extract-wrong-password-output")
        let settings = SZExtractionSettings()
        settings.password = "wrong-password"

        let error = try captureExtractError(from: archive,
                                            toPath: extractDir.path,
                                            settings: settings)

        XCTAssertWrongPassword(error, description: "Wrong password")
    }

    private func corruptArchive(at archiveURL: URL) throws {
        var data = try Data(contentsOf: archiveURL)
        XCTAssertGreaterThan(data.count, 64)

        let mutationRange = 32 ..< min(data.count, 96)
        for index in mutationRange {
            data[index] ^= 0xFF
        }

        try data.write(to: archiveURL, options: .atomic)
    }

    private func captureOpenError(from archive: SZArchive,
                                  path: String,
                                  password: String) throws -> NSError
    {
        do {
            try archive.open(atPath: path, password: password, session: nil)
        } catch {
            return error as NSError
        }
        // Unexpected success should fail the test instead of fabricating an error.
        struct UnexpectedOpenSuccess: Error, CustomStringConvertible {
            var description: String {
                "Expected archive open to fail, but it succeeded"
            }
        }
        throw UnexpectedOpenSuccess()
    }

    private func captureExtractError(from archive: SZArchive,
                                     toPath path: String,
                                     settings: SZExtractionSettings) throws -> NSError
    {
        do {
            try archive.extract(toPath: path,
                                settings: settings,
                                session: SZOperationSession())
        } catch {
            return error as NSError
        }

        struct UnexpectedExtractSuccess: Error, CustomStringConvertible {
            var description: String {
                "Expected archive extraction to fail, but it succeeded"
            }
        }
        throw UnexpectedExtractSuccess()
    }

    private func XCTAssertWrongPassword(_ error: NSError,
                                        description: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line)
    {
        XCTAssertEqual(error.domain, SZArchiveErrorDomain, file: file, line: line)
        XCTAssertEqual(error.code, -12, file: file, line: line)
        XCTAssertEqual(error.localizedDescription, description, file: file, line: line)
    }
}
