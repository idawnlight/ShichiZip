import XCTest

#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

final class MixedPasswordZipTests: XCTestCase {
    private static let payloadByteCount = UInt64(
        "public payload".utf8.count + "ZipCrypto payload".utf8.count + "AES payload".utf8.count,
    )

    private struct Member {
        let path: String
        let contents: String
        let encryption: SZEncryptionMethod
        let password: String?
    }

    /// Each write adds one new member and copies the existing ZIP records. This
    /// produces independent passwords without an external 7-Zip installation.
    private func makeMixedArchive(additionalMembers: [Member] = []) throws -> (SZArchive, URL) {
        let root = try makeTemporaryDirectory(named: "mixed-password-zip")
        let archiveURL = root.appendingPathComponent("mixed.zip")
        let members = [
            Member(path: "plain.txt", contents: "public payload", encryption: .none, password: nil),
            Member(path: "legacy.txt", contents: "ZipCrypto payload", encryption: .zipCrypto, password: "one"),
            Member(path: "secret.txt", contents: "AES payload", encryption: .AES256, password: "two"),
        ] + additionalMembers

        for member in members {
            let sourceURL = root.appendingPathComponent(member.path)
            try member.contents.write(to: sourceURL, atomically: true, encoding: .utf8)
            let settings = SZCompressionSettings()
            settings.format = .formatZip
            settings.pathMode = .relativePaths
            settings.method = .deflate
            settings.methodName = "Deflate"
            settings.encryption = member.encryption
            settings.password = member.password
            try SZArchive.create(atPath: archiveURL.path,
                                 fromPaths: [sourceURL.path],
                                 settings: settings,
                                 session: SZOperationSession())
        }

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        return (archive, root)
    }

    private final class PasswordPrompts {
        private let replies: [(entry: String, password: String?)]
        private(set) var requestedEntries: [String] = []

        init(_ replies: [(entry: String, password: String?)]) {
            self.replies = replies
        }

        func session(_ session: SZOperationSession = SZOperationSession()) -> SZOperationSession {
            session.passwordRequestHandler = { _, message, _, passwordPointer in
                guard self.requestedEntries.count < self.replies.count else {
                    XCTFail("Unexpected password prompt: \(message ?? "")")
                    return false
                }
                let reply = self.replies[self.requestedEntries.count]
                self.requestedEntries.append(reply.entry)
                XCTAssertTrue(message?.contains(reply.entry) == true,
                              "Password prompt must identify \(reply.entry): \(message ?? "")")
                guard let password = reply.password else { return false }
                passwordPointer?.pointee = password as NSString
                return true
            }
            return session
        }
    }

    /// Observe every public progress report synchronously: the UI snapshot
    /// handler deliberately coalesces updates and can hide a brief regression.
    private final class ProgressRecordingSession: SZOperationSession, @unchecked Sendable {
        private(set) var progressSnapshots: [SZOperationSnapshot] = []

        override func reportProgressFraction(_ fraction: Double) {
            super.reportProgressFraction(fraction)
            progressSnapshots.append(snapshot())
        }

        override func reportBytesCompleted(_ completed: UInt64, total: UInt64) {
            super.reportBytesCompleted(completed, total: total)
            progressSnapshots.append(snapshot())
        }

        override func reportFilesCompleted(_ count: UInt64) {
            super.reportFilesCompleted(count)
            progressSnapshots.append(snapshot())
        }
    }

    private func assertMonotonicProgress(_ session: ProgressRecordingSession,
                                         file: StaticString = #filePath,
                                         line: UInt = #line)
    {
        let snapshots = session.progressSnapshots
        XCTAssertTrue(snapshots.contains { $0.progressFraction > 0 && $0.progressFraction < 1 },
                      "Must observe progress between the initial and completed states", file: file, line: line)
        for (previous, current) in zip(snapshots, snapshots.dropFirst()) {
            XCTAssertGreaterThanOrEqual(current.bytesCompleted, previous.bytesCompleted, file: file, line: line)
            XCTAssertGreaterThanOrEqual(current.filesCompleted, previous.filesCompleted, file: file, line: line)
            XCTAssertGreaterThanOrEqual(current.progressFraction, previous.progressFraction, file: file, line: line)
            XCTAssertLessThanOrEqual(current.bytesCompleted, current.bytesTotal, file: file, line: line)
        }
        XCTAssertEqual(session.progressFraction, 1, accuracy: 0.0001, file: file, line: line)
    }

    private func extract(_ path: String,
                         from archive: SZArchive,
                         into destination: URL,
                         session: SZOperationSession) throws
    {
        let entry = try XCTUnwrap(archive.entries().first { $0.path == path })
        let settings = SZExtractionSettings()
        settings.pathMode = .fullPaths
        try archive.extractEntries([NSNumber(value: entry.index)],
                                   toPath: destination.path,
                                   settings: settings,
                                   session: session)
    }

    private func assertContents(_ expected: String,
                                at url: URL,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws
    {
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected, file: file, line: line)
    }

    func testBulkExtractionHandlesPlainZipCryptoAndAESWithDifferentPasswords() throws {
        let (archive, root) = try makeMixedArchive()
        defer { archive.close() }

        let entries = archive.entries()
        XCTAssertEqual(Set(entries.map(\.path)), ["plain.txt", "legacy.txt", "secret.txt"])
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.path == "plain.txt" }).isEncrypted)
        XCTAssertTrue(try XCTUnwrap(entries.first { $0.path == "legacy.txt" }).method?.contains("ZipCrypto") == true)
        XCTAssertTrue(try XCTUnwrap(entries.first { $0.path == "secret.txt" }).method?.contains("AES-256") == true)

        let destination = root.appendingPathComponent("extracted")
        let prompts = PasswordPrompts([("legacy.txt", "one"), ("secret.txt", "two")])
        let session = prompts.session()
        try archive.extract(toPath: destination.path,
                            settings: SZExtractionSettings(),
                            session: session)

        XCTAssertEqual(prompts.requestedEntries, ["legacy.txt", "secret.txt"])
        try assertContents("public payload", at: destination.appendingPathComponent("plain.txt"))
        try assertContents("ZipCrypto payload", at: destination.appendingPathComponent("legacy.txt"))
        try assertContents("AES payload", at: destination.appendingPathComponent("secret.txt"))
        XCTAssertEqual(session.filesCompleted, 3, "Password attempts must not count as extracted files")
        XCTAssertEqual(session.bytesCompleted, session.bytesTotal)
    }

    func testIntegrityTestLearnsEveryPasswordForLaterOperations() throws {
        let (archive, root) = try makeMixedArchive()
        defer { archive.close() }

        let prompts = PasswordPrompts([("legacy.txt", "one"), ("secret.txt", "two")])
        let testSession = ProgressRecordingSession()
        try archive.test(with: prompts.session(testSession))
        XCTAssertEqual(prompts.requestedEntries, ["legacy.txt", "secret.txt"])
        XCTAssertEqual(testSession.bytesTotal, Self.payloadByteCount,
                       "Integrity testing reads every payload once, including encrypted entries")
        XCTAssertEqual(testSession.bytesCompleted, Self.payloadByteCount)
        XCTAssertEqual(testSession.filesCompleted, 3)
        assertMonotonicProgress(testSession)

        // A new headless session cannot answer prompts. Both passwords must be
        // retained by the archive, including after the second password succeeds.
        let cachedTestSession = ProgressRecordingSession()
        try archive.test(with: cachedTestSession)
        XCTAssertEqual(cachedTestSession.bytesTotal, Self.payloadByteCount)
        XCTAssertEqual(cachedTestSession.bytesCompleted, Self.payloadByteCount)
        XCTAssertEqual(cachedTestSession.filesCompleted, 3)
        assertMonotonicProgress(cachedTestSession)
        let destination = root.appendingPathComponent("after-test")
        try archive.extract(toPath: destination.path,
                            settings: SZExtractionSettings(),
                            session: SZOperationSession())
        try assertContents("ZipCrypto payload", at: destination.appendingPathComponent("legacy.txt"))
        try assertContents("AES payload", at: destination.appendingPathComponent("secret.txt"))
    }

    func testExtractionProgressDoesNotMoveBackwardsWhenPasswordsAreRetried() throws {
        let (archive, root) = try makeMixedArchive()
        defer { archive.close() }

        let prompts = PasswordPrompts([("legacy.txt", "wrong"), ("legacy.txt", "one"), ("secret.txt", "two")])
        let session = ProgressRecordingSession()
        try archive.extract(toPath: root.appendingPathComponent("with-validation").path,
                            settings: SZExtractionSettings(),
                            session: prompts.session(session))

        // The first extraction reads encrypted payloads once for password
        // validation and once for output. Failed attempts do not add more work.
        let validationBytes = UInt64("ZipCrypto payload".utf8.count + "AES payload".utf8.count)
        XCTAssertEqual(session.bytesTotal, Self.payloadByteCount + validationBytes)
        XCTAssertEqual(session.bytesCompleted, session.bytesTotal)
        XCTAssertEqual(session.filesCompleted, 3)
        XCTAssertEqual(prompts.requestedEntries, ["legacy.txt", "legacy.txt", "secret.txt"])
        assertMonotonicProgress(session)

        // A later extraction uses the validated passwords and reports only
        // the payload bytes written to its destination.
        let cachedSession = ProgressRecordingSession()
        try archive.extract(toPath: root.appendingPathComponent("already-validated").path,
                            settings: SZExtractionSettings(),
                            session: cachedSession)
        XCTAssertEqual(cachedSession.bytesTotal, Self.payloadByteCount)
        XCTAssertEqual(cachedSession.bytesCompleted, Self.payloadByteCount)
        XCTAssertEqual(cachedSession.filesCompleted, 3)
        assertMonotonicProgress(cachedSession)
    }

    func testSelectedExtractionRemembersEachPasswordAcrossOperationSessions() throws {
        let (archive, root) = try makeMixedArchive()
        defer { archive.close() }

        let firstPrompts = PasswordPrompts([("legacy.txt", "one")])
        try extract("legacy.txt", from: archive,
                    into: root.appendingPathComponent("first"), session: firstPrompts.session())
        let secondPrompts = PasswordPrompts([("secret.txt", "two")])
        try extract("secret.txt", from: archive,
                    into: root.appendingPathComponent("second"), session: secondPrompts.session())

        let third = root.appendingPathComponent("third")
        try extract("legacy.txt", from: archive, into: third, session: SZOperationSession())
        XCTAssertEqual(firstPrompts.requestedEntries, ["legacy.txt"])
        XCTAssertEqual(secondPrompts.requestedEntries, ["secret.txt"])
        try assertContents("ZipCrypto payload", at: third.appendingPathComponent("legacy.txt"))
    }

    func testKnownPasswordIsTriedForUnreadEntriesWithAnotherEncryptionMethod() throws {
        let (archive, root) = try makeMixedArchive(additionalMembers: [
            Member(path: "peer.txt", contents: "same password, different encryption",
                   encryption: .AES256, password: "one"),
        ])
        defer { archive.close() }

        let prompts = PasswordPrompts([("legacy.txt", "one")])
        try extract("legacy.txt", from: archive,
                    into: root.appendingPathComponent("legacy"), session: prompts.session())
        let secondPrompts = PasswordPrompts([("secret.txt", "two")])
        try extract("secret.txt", from: archive,
                    into: root.appendingPathComponent("secret"), session: secondPrompts.session())

        let destination = root.appendingPathComponent("peer")
        try extract("peer.txt", from: archive, into: destination, session: SZOperationSession())
        XCTAssertEqual(prompts.requestedEntries, ["legacy.txt"])
        XCTAssertEqual(secondPrompts.requestedEntries, ["secret.txt"])
        try assertContents("same password, different encryption",
                           at: destination.appendingPathComponent("peer.txt"))
    }

    func testWrongPasswordRepromptsForSameEntryWithoutForgettingOtherPasswords() throws {
        let (archive, root) = try makeMixedArchive()
        defer { archive.close() }

        let legacyPrompts = PasswordPrompts([("legacy.txt", "one")])
        try extract("legacy.txt", from: archive,
                    into: root.appendingPathComponent("legacy"), session: legacyPrompts.session())

        let secretPrompts = PasswordPrompts([("secret.txt", "wrong"), ("secret.txt", "two")])
        let destination = root.appendingPathComponent("secret")
        try extract("secret.txt", from: archive, into: destination, session: secretPrompts.session())
        XCTAssertEqual(secretPrompts.requestedEntries, ["secret.txt", "secret.txt"])
        try assertContents("AES payload", at: destination.appendingPathComponent("secret.txt"))

        try extract("legacy.txt", from: archive,
                    into: root.appendingPathComponent("legacy-again"), session: SZOperationSession())
    }

    func testCancellingPasswordRetryLeavesNoFailedMemberOutput() throws {
        let (archive, root) = try makeMixedArchive()
        defer { archive.close() }

        let prompts = PasswordPrompts([("secret.txt", "wrong"), ("secret.txt", nil)])
        let destination = root.appendingPathComponent("cancelled")
        XCTAssertThrowsError(try extract("secret.txt", from: archive,
                                         into: destination, session: prompts.session()))
        { error in
            XCTAssertTrue(szIsUserCancellation(error), "Expected cancellation, got \(error)")
        }
        XCTAssertEqual(prompts.requestedEntries, ["secret.txt", "secret.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("secret.txt").path))

        let retryPrompts = PasswordPrompts([("secret.txt", "two")])
        try extract("secret.txt", from: archive, into: destination, session: retryPrompts.session())
        XCTAssertEqual(retryPrompts.requestedEntries, ["secret.txt"])
        try assertContents("AES payload", at: destination.appendingPathComponent("secret.txt"))
    }

    func testCancellingPasswordRetryPreservesExistingDestinationFile() throws {
        let (archive, root) = try makeMixedArchive()
        defer { archive.close() }

        let destination = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existingFile = destination.appendingPathComponent("secret.txt")
        try "existing contents".write(to: existingFile, atomically: true, encoding: .utf8)
        let secret = try XCTUnwrap(archive.entries().first { $0.path == "secret.txt" })
        let settings = SZExtractionSettings()
        settings.overwriteMode = .overwrite
        let prompts = PasswordPrompts([("secret.txt", "wrong"), ("secret.txt", nil)])

        XCTAssertThrowsError(try archive.extractEntries([NSNumber(value: secret.index)],
                                                        toPath: destination.path,
                                                        settings: settings,
                                                        session: prompts.session()))
        { error in
            XCTAssertTrue(szIsUserCancellation(error), "Expected cancellation, got \(error)")
        }
        XCTAssertEqual(prompts.requestedEntries, ["secret.txt", "secret.txt"])
        try assertContents("existing contents", at: existingFile)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["secret.txt"])
    }

    func testSkippingExistingEncryptedEntryStillUnlocksItAndPreservesDestination() throws {
        let (archive, root) = try makeMixedArchive()
        defer { archive.close() }

        let destination = root.appendingPathComponent("skip-existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existingFile = destination.appendingPathComponent("secret.txt")
        try "existing contents".write(to: existingFile, atomically: true, encoding: .utf8)
        let secret = try XCTUnwrap(archive.entries().first { $0.path == "secret.txt" })
        let settings = SZExtractionSettings()
        settings.overwriteMode = .skip
        let prompts = PasswordPrompts([("secret.txt", "two")])

        // Password validation precedes filesystem overwrite decisions for all
        // selected encrypted entries. Skip preserves output but still unlocks.
        try archive.extractEntries([NSNumber(value: secret.index)],
                                   toPath: destination.path,
                                   settings: settings,
                                   session: prompts.session())

        XCTAssertEqual(prompts.requestedEntries, ["secret.txt"])
        try assertContents("existing contents", at: existingFile)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["secret.txt"])
    }

    func testExplicitPasswordCanBeCombinedWithAnotherPromptedPassword() throws {
        let (archive, root) = try makeMixedArchive()
        defer { archive.close() }

        let settings = SZExtractionSettings()
        settings.password = "one"
        let prompts = PasswordPrompts([("secret.txt", "two")])
        let destination = root.appendingPathComponent("explicit-password")
        try archive.extract(toPath: destination.path, settings: settings, session: prompts.session())

        XCTAssertEqual(prompts.requestedEntries, ["secret.txt"])
        try assertContents("ZipCrypto payload", at: destination.appendingPathComponent("legacy.txt"))
        try assertContents("AES payload", at: destination.appendingPathComponent("secret.txt"))
        try archive.test(with: SZOperationSession())
    }

    func testClosingArchiveClearsRememberedPasswords() throws {
        let (archive, root) = try makeMixedArchive()
        defer { archive.close() }

        let firstPrompts = PasswordPrompts([("legacy.txt", "one")])
        try extract("legacy.txt", from: archive,
                    into: root.appendingPathComponent("before-close"), session: firstPrompts.session())
        archive.close()
        try archive.open(atPath: root.appendingPathComponent("mixed.zip").path, session: SZOperationSession())

        let reopenedPrompts = PasswordPrompts([("legacy.txt", "one")])
        try extract("legacy.txt", from: archive,
                    into: root.appendingPathComponent("after-close"), session: reopenedPrompts.session())
        XCTAssertEqual(reopenedPrompts.requestedEntries, ["legacy.txt"])
    }
}
