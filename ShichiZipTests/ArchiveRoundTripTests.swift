// ArchiveRoundTripTests.swift
//
// End-to-end coverage for the SZArchive bridge that was flagged in
// CODE_REVIEW §4.5 as missing: create → open → extract → verify
// bytes, including the positive-password path (only the negative
// password path had a test) and the encrypted-filenames listing
// path. Also covers cooperative cancellation on SZOperationSession,
// co-located with the 584bc90 throttling work.

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

    // MARK: - Positive-password open

    /// The suite currently only has a negative test (wrong password
    /// produces a classified error). Cover the positive branch too,
    /// which exercises the open-callback password plumbing that
    /// c76378c seeds during in-place updates and that 3fa762d keeps
    /// in sync with the update callback.
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

    /// When an archive is created with `encryptFileNames = true`, the
    /// entire central directory is AES-encrypted. Opening it requires
    /// the password *before* the entry list can be read — a different
    /// code path from `encryption: AES256` alone. CODE_REVIEW §4.5
    /// flagged this listing path as untested.
    func testEncryptedFileNamesListingRequiresPassword() throws {
        let archiveURL = try makeArchive(named: "enc-filenames",
                                         payloadFileName: "top-secret.txt",
                                         payloadContents: "classified",
                                         password: Self.password,
                                         encryptFileNames: true)

        // Listing without a password must fail. Use an explicit empty
        // SZOperationSession so the bridge does *not* fall back to
        // SZMakeDefaultOperationSession — the default session wires
        // SZDialogPresenter as the password handler, which would pop
        // a UI prompt and hang the test runner.
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

        // With the password, the listing path must work and report
        // the original file name. Still pass an empty session to keep
        // any stray re-prompts routed to E_ABORT instead of the UI.
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

    /// Cooperative cancellation is a co-located cousin of the 584bc90
    /// progress-throttling work (same SZOperationSession object). The
    /// atomic shouldCancel flag (12dc0fd) must go true the moment
    /// requestCancel is invoked, and stay true until clearCancellationRequest.
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

    /// Cancellation from a background thread must be observable by a
    /// concurrent shouldCancel caller (this is the property the
    /// atomic flag in 12dc0fd guarantees without taking the main
    /// queue). We spin a background writer and a concurrent reader
    /// and assert the reader sees the flag flip.
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
