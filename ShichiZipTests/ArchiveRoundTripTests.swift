// ArchiveRoundTripTests.swift
//
// End-to-end create/open/extract coverage, plus encrypted-listing and
// cancellation checks.

import XCTest

final class ArchiveRoundTripTests: XCTestCase {
    private static let password = "round-trip-pw"

    // MARK: - Helpers

    private func writePayloads(_ payloads: [String: String],
                               into root: URL) throws -> [URL]
    {
        var urls: [URL] = []
        for (relPath, contents) in payloads.sorted(by: { $0.key < $1.key }) {
            let fileURL = root.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            urls.append(fileURL)
        }
        return urls
    }

    // MARK: - Unencrypted round-trip

    func testUnencrypted7zRoundTripPreservesPayloadBytes() throws {
        let tempRoot = try makeTemporaryDirectory(named: "roundtrip-7z")
        // Build the source tree inside a single subdirectory so the
        // archive preserves the hierarchy under a stable root. Passing
        // individual files would flatten them under .relativePaths.
        let sourceRoot = tempRoot.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot,
                                                withIntermediateDirectories: true)
        let payloads = [
            "a.txt": "first payload",
            "nested/b.txt": "second payload — with unicode é 🔒",
        ]
        _ = try writePayloads(payloads, into: sourceRoot)
        let archiveURL = tempRoot.appendingPathComponent("out.7z")

        try createArchive(at: archiveURL, from: [sourceRoot])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let listedPaths = Set(archive.entries().map(\.path))
        let expected: Set = ["src/a.txt", "src/nested/b.txt"]
        XCTAssertTrue(listedPaths.isSuperset(of: expected),
                      "listing must contain every payload we wrote; got \(listedPaths)")

        let extractDir = tempRoot.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let settings = SZExtractionSettings()
        settings.pathMode = .fullPaths
        try archive.extract(toPath: extractDir.path,
                            settings: settings,
                            session: nil)

        for (relPath, contents) in payloads {
            let extractedURL = extractDir.appendingPathComponent("src")
                .appendingPathComponent(relPath)
            let roundTripped = try String(contentsOf: extractedURL, encoding: .utf8)
            XCTAssertEqual(roundTripped, contents,
                           "byte-for-byte mismatch on extracted src/\(relPath)")
        }
    }

    func testOpeningAndExtractingZipPreservesNonBMPFilenames() throws {
        let tempRoot = try makeTemporaryDirectory(named: "roundtrip-nonbmp-zip")
        let sourceRoot = tempRoot.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot,
                                                withIntermediateDirectories: true)
        let payloads = [
            "emoji-🔒.txt": "emoji filename payload",
            "nested/han-𠜎.txt": "han extension-b filename payload",
        ]
        _ = try writePayloads(payloads, into: sourceRoot)
        let archiveURL = tempRoot.appendingPathComponent("out.zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-X", "-r", archiveURL.path, "src"]
        process.currentDirectoryURL = tempRoot
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "/usr/bin/zip failed to create the test fixture")

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let listedPaths = Set(archive.entries().map(\.path))
        let expected: Set = ["src/emoji-🔒.txt", "src/nested/han-𠜎.txt"]
        XCTAssertTrue(listedPaths.isSuperset(of: expected),
                      "listing must preserve non-BMP file names; got \(listedPaths)")

        let extractDir = tempRoot.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let settings = SZExtractionSettings()
        settings.pathMode = .fullPaths
        try archive.extract(toPath: extractDir.path,
                            settings: settings,
                            session: nil)

        for (relPath, contents) in payloads {
            let extractedURL = extractDir.appendingPathComponent("src")
                .appendingPathComponent(relPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: extractedURL.path),
                          "expected extracted file at \(extractedURL.path)")
            let roundTripped = try String(contentsOf: extractedURL, encoding: .utf8)
            XCTAssertEqual(roundTripped, contents,
                           "byte-for-byte mismatch on extracted src/\(relPath)")
        }
    }

    // MARK: - Positive-password open

    /// Covers the positive password path, not just wrong-password errors.
    func testOpeningEncrypted7zWithCorrectPasswordSucceeds() throws {
        let archiveURL = try makeArchive(named: "pos-open",
                                         payloadFileName: "hello.txt",
                                         payloadContents: "hello world",
                                         password: Self.password)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path,
                         password: Self.password,
                         session: nil)
        defer { archive.close() }

        XCTAssertEqual(archive.entryCount, 1)
        let entries = archive.entries()
        XCTAssertEqual(entries.first?.path, "hello.txt")
        XCTAssertTrue(entries.first?.isEncrypted ?? false,
                      "payload in a password-protected 7z must be marked encrypted")
    }

    // MARK: - Encrypted-filenames listing

    /// `encryptFileNames` archives need a password before listing entries.
    func testEncryptedFileNamesListingRequiresPassword() throws {
        let archiveURL = try makeArchive(named: "enc-filenames",
                                         payloadFileName: "top-secret.txt",
                                         payloadContents: "classified",
                                         password: Self.password,
                                         encryptFileNames: true)

        // Use an empty session so the test never opens a UI prompt.
        do {
            let archive = SZArchive()
            let headlessSession = SZOperationSession()
            XCTAssertThrowsError(
                try archive.open(atPath: archiveURL.path,
                                 session: headlessSession),
                "opening an encryptFileNames=true archive without a password must error",
            )
            archive.close()
        }

        // Keep this headless too so any stray re-prompts fail instead of showing UI.
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path,
                         password: Self.password,
                         session: SZOperationSession())
        defer { archive.close() }

        let names = archive.entries().map(\.path)
        XCTAssertEqual(names, ["top-secret.txt"])
        XCTAssertTrue(archive.entries().allSatisfy(\.isEncrypted),
                      "every entry in an encryptFileNames archive must be marked encrypted")
    }

    // MARK: - Session cancellation

    /// requestCancel should flip the flag immediately and keep it set until cleared.
    func testSessionCancellationFlagIsSetSynchronouslyAndCleared() {
        let session = SZOperationSession()
        XCTAssertFalse(session.shouldCancel(),
                       "fresh session must not report cancellation")
        XCTAssertFalse(session.isCancellationRequested)

        session.requestCancel()
        XCTAssertTrue(session.shouldCancel(),
                      "shouldCancel must flip synchronously after requestCancel")
        XCTAssertTrue(session.isCancellationRequested)

        // requestCancel is idempotent and thread-safe.
        session.requestCancel()
        XCTAssertTrue(session.shouldCancel())

        session.clearCancellationRequest()
        XCTAssertFalse(session.shouldCancel(),
                       "clearCancellationRequest must reset shouldCancel")
        XCTAssertFalse(session.isCancellationRequested)
    }

    /// Cancellation should be visible across threads without a main-queue hop.
    func testSessionCancellationIsVisibleAcrossThreads() {
        let session = SZOperationSession()
        let observed = expectation(description: "reader saw cancellation")

        let reader = DispatchQueue.global(qos: .userInitiated)
        reader.async {
            // Spin for at most 2 seconds waiting for the flag.
            let deadline = Date(timeIntervalSinceNow: 2)
            while Date() < deadline {
                if session.shouldCancel() {
                    observed.fulfill()
                    return
                }
            }
        }

        // Give the reader a head start, then flip the flag from a
        // different queue.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.02) {
            session.requestCancel()
        }

        wait(for: [observed], timeout: 3.0)
    }
}
