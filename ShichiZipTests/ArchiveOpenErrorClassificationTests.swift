import XCTest

@testable import ShichiZip

final class ArchiveOpenErrorClassificationTests: XCTestCase {
    func testCorruptedEncryptedArchiveWithPasswordIsNotMisclassifiedAsWrongPassword() throws {
        let tempRoot = try makeTemporaryDirectory(named: "corrupted-encrypted")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let payloadURL = tempRoot.appendingPathComponent("payload.txt")
        let archiveURL = tempRoot.appendingPathComponent("payload.7z")
        let corruptedArchiveURL = tempRoot.appendingPathComponent("payload-corrupted.7z")

        try "secret payload".write(to: payloadURL, atomically: true, encoding: .utf8)
        try createEncryptedArchive(at: archiveURL, payloadURL: payloadURL)
        try FileManager.default.copyItem(at: archiveURL, to: corruptedArchiveURL)
        try corruptArchive(at: corruptedArchiveURL)

        let archive = SZArchive()
        let error = captureOpenError(from: archive, path: corruptedArchiveURL.path, password: "wrong-password")

        XCTAssertEqual(error.domain, SZArchiveErrorDomain)
        XCTAssertEqual(error.code, -14)
        XCTAssertNotEqual(error.code, -12)
        XCTAssertEqual(error.localizedDescription, "Cannot open archive")
    }

    private func createEncryptedArchive(at archiveURL: URL, payloadURL: URL) throws {
        let settings = SZCompressionSettings()
        settings.pathMode = .relativePaths
        settings.password = "correct-password"
        settings.encryptFileNames = true

        try SZArchive.create(
            atPath: archiveURL.path,
            fromPaths: [payloadURL.path],
            settings: settings,
            session: nil)
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
                                  password: String) -> NSError
    {
        do {
            try archive.open(atPath: path, password: password, session: nil)
            XCTFail("Expected archive open to fail")
            return NSError(domain: "ArchiveOpenErrorClassificationTests",
                           code: 0)
        } catch {
            return error as NSError
        }
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ShichiZipArchiveOpenTests-\(name)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
