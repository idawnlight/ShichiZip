// ZipEncryptionPolicyTests.swift
//
// Covers the zip-specific encryption policy introduced by 50f3d01:
//
//   1. A password supplied to createAtPath: for the zip format with
//      encryption == SZEncryptionMethodNone must be *rejected* up
//      front with SZArchiveErrorCodeUnsupportedFormat or the generic
//      E_INVALIDARG path, never silently fall through to ZipCrypto
//      (7-Zip's implicit default for password-protected zips).
//
//   2. Explicit AES256 must produce an AES-256 zip that round-trips
//      with the supplied password.
//
//   3. Explicit ZipCrypto is honoured verbatim when the caller opts
//      in: the bridge does not force AES256 on zips that the user
//      deliberately requested ZipCrypto for.
//
// Non-zip formats (7z, tar, ...) are unaffected by the policy and are
// not covered here because the change is strictly within
// SZCompressionEncryptionProperty()'s format==zip branch.

import XCTest

final class ZipEncryptionPolicyTests: XCTestCase {
    // MARK: - Helpers

    private func makePayload(named name: String,
                             file: String = "payload.txt",
                             contents: String = "secret") throws -> (URL, URL)
    {
        let tempRoot = try makeTemporaryDirectory(named: name)
        let payload = tempRoot.appendingPathComponent(file)
        try contents.write(to: payload, atomically: true, encoding: .utf8)
        return (tempRoot, payload)
    }

    private func makeZipSettings(encryption: SZEncryptionMethod,
                                 password: String?) -> SZCompressionSettings
    {
        let settings = SZCompressionSettings()
        settings.format = .formatZip
        settings.method = .deflate
        settings.methodName = "Deflate"
        settings.encryption = encryption
        settings.password = password
        settings.pathMode = .relativePaths
        return settings
    }

    // MARK: - Case 1: password + none must be rejected

    func testCreatingZipWithPasswordAndNoneEncryptionIsRejected() throws {
        let (tempRoot, payload) = try makePayload(named: "zip-none-password")
        let archiveURL = tempRoot.appendingPathComponent("out.zip")

        let settings = makeZipSettings(encryption: .none, password: "hunter2")

        XCTAssertThrowsError(
            try SZArchive.create(atPath: archiveURL.path,
                                 fromPaths: [payload.path],
                                 settings: settings,
                                 session: nil),
            "zip + password + encryption==None must not silently fall back to ZipCrypto"
        ) { error in
            let nsError = error as NSError
            // Bridge uses SZArchiveErrorDomain with E_INVALIDARG for
            // this specific guard. Don't hard-code the integer code to
            // avoid tying the test to the Win32 HRESULT value, just
            // require the domain and reject a success path.
            XCTAssertEqual(nsError.domain, SZArchiveErrorDomain,
                           "error should come from the archive bridge, got: \(nsError)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path),
                       "rejected creation must not leave a partial zip on disk")
    }

    // MARK: - Case 2: explicit AES256 round-trips

    func testCreatingZipWithExplicitAES256RoundTrips() throws {
        let (tempRoot, payload) = try makePayload(named: "zip-aes256",
                                                  file: "secret.txt",
                                                  contents: "top-secret payload")
        let archiveURL = tempRoot.appendingPathComponent("out.zip")

        let settings = makeZipSettings(encryption: .AES256, password: "hunter2")
        try SZArchive.create(atPath: archiveURL.path,
                             fromPaths: [payload.path],
                             settings: settings,
                             session: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))

        // Extract with the correct password and verify the payload.
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path,
                         password: "hunter2",
                         session: nil)
        defer { archive.close() }

        // Confirm the entry is flagged as encrypted. AES256 zips must
        // report isEncrypted=true on every data entry.
        let entries = archive.entries()
        XCTAssertTrue(entries.contains { $0.path == "secret.txt" && $0.isEncrypted },
                      "secret.txt must be marked encrypted in an AES256 zip")

        let extractDir = tempRoot.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let extractSettings = SZExtractionSettings()
        extractSettings.pathMode = .fullPaths
        extractSettings.password = "hunter2"
        try archive.extract(toPath: extractDir.path,
                            settings: extractSettings,
                            session: nil)

        let extracted = try String(contentsOf: extractDir.appendingPathComponent("secret.txt"),
                                   encoding: .utf8)
        XCTAssertEqual(extracted, "top-secret payload")
    }

    // MARK: - Case 3: explicit ZipCrypto is honoured

    func testCreatingZipWithExplicitZipCryptoIsHonouredVerbatim() throws {
        let (tempRoot, payload) = try makePayload(named: "zip-zipcrypto",
                                                  file: "legacy.txt",
                                                  contents: "legacy payload")
        let archiveURL = tempRoot.appendingPathComponent("out.zip")

        let settings = makeZipSettings(encryption: .zipCrypto, password: "hunter2")
        try SZArchive.create(atPath: archiveURL.path,
                             fromPaths: [payload.path],
                             settings: settings,
                             session: nil)

        // ZipCrypto is cryptographically weak but 7-Zip will still
        // round-trip it when the user opted in.
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path,
                         password: "hunter2",
                         session: nil)
        defer { archive.close() }

        let entries = archive.entries()
        XCTAssertTrue(entries.contains { $0.path == "legacy.txt" && $0.isEncrypted },
                      "ZipCrypto-protected entries must be flagged isEncrypted")

        let extractDir = tempRoot.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let extractSettings = SZExtractionSettings()
        extractSettings.pathMode = .fullPaths
        extractSettings.password = "hunter2"
        try archive.extract(toPath: extractDir.path,
                            settings: extractSettings,
                            session: nil)

        let extracted = try String(contentsOf: extractDir.appendingPathComponent("legacy.txt"),
                                   encoding: .utf8)
        XCTAssertEqual(extracted, "legacy payload")
    }

    // MARK: - AES256 vs ZipCrypto produce distinct archives

    /// Defence-in-depth: the two explicit-encryption archives above
    /// must not be byte-identical. Without the em= property plumbing,
    /// both calls would go through the same code path and silently
    /// produce ZipCrypto, so comparing the two files is a coarse but
    /// cheap check that the em= distinction is actually reaching 7-Zip.
    func testAES256AndZipCryptoProduceDifferentArchives() throws {
        let (tempRoot, payload) = try makePayload(named: "zip-distinct",
                                                  file: "same.txt",
                                                  contents: "identical input")

        let aesURL = tempRoot.appendingPathComponent("aes.zip")
        let zcURL = tempRoot.appendingPathComponent("zc.zip")

        try SZArchive.create(atPath: aesURL.path,
                             fromPaths: [payload.path],
                             settings: makeZipSettings(encryption: .AES256,
                                                       password: "hunter2"),
                             session: nil)
        try SZArchive.create(atPath: zcURL.path,
                             fromPaths: [payload.path],
                             settings: makeZipSettings(encryption: .zipCrypto,
                                                       password: "hunter2"),
                             session: nil)

        let aesData = try Data(contentsOf: aesURL)
        let zcData = try Data(contentsOf: zcURL)
        XCTAssertNotEqual(aesData, zcData,
                          "AES256 and ZipCrypto must not produce byte-identical archives")
    }
}
