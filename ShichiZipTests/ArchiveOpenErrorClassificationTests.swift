import XCTest

final class ArchiveOpenErrorClassificationTests: XCTestCase {
    func testCorruptedEncryptedArchiveWithPasswordIsNotMisclassifiedAsWrongPassword() throws {
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

        XCTAssertEqual(error.domain, SZArchiveErrorDomain)
        XCTAssertEqual(error.code, -14)
        XCTAssertNotEqual(error.code, -12)
        XCTAssertEqual(error.localizedDescription, "Cannot open archive")
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
        // Reaching here means -open: unexpectedly succeeded. Throw so the
        // caller bails out instead of silently reporting a fabricated
        // error that would pass the domain/code assertions and hide the
        // regression.
        struct UnexpectedOpenSuccess: Error, CustomStringConvertible {
            var description: String {
                "Expected archive open to fail, but it succeeded"
            }
        }
        throw UnexpectedOpenSuccess()
    }
}
