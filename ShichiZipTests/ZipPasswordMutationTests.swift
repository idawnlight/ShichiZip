import XCTest

final class ZipPasswordMutationTests: XCTestCase {
    private struct Member {
        let path: String
        let contents: String
        let encryption: SZEncryptionMethod
        let password: String
    }

    private func makeArchive(_ members: [Member]) throws -> (SZArchive, URL) {
        let root = try makeTemporaryDirectory(named: "zip-password-mutation")
        let archiveURL = root.appendingPathComponent("archive.zip")
        for member in members {
            let source = root.appendingPathComponent(member.path)
            try member.contents.write(to: source, atomically: true, encoding: .utf8)
            let settings = SZCompressionSettings()
            settings.format = .formatZip
            settings.pathMode = .relativePaths
            settings.method = .deflate
            settings.methodName = "Deflate"
            settings.encryption = member.encryption
            settings.password = member.password
            try SZArchive.create(atPath: archiveURL.path,
                                 fromPaths: [source.path],
                                 settings: settings,
                                 session: SZOperationSession())
        }

        // ZIP listing does not prove a password: learn it from reading data.
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        return (archive, root)
    }

    private func makeMixedArchive() throws -> (SZArchive, URL) {
        try makeArchive([
            Member(path: "legacy.txt", contents: "legacy payload", encryption: .zipCrypto, password: "one"),
            Member(path: "secret.txt", contents: "secret payload", encryption: .AES256, password: "two"),
        ])
    }

    private final class PasswordPrompts {
        private let passwords: [String: String]
        private(set) var requestedPaths: [String] = []

        init(_ passwords: [String: String]) {
            self.passwords = passwords
        }

        func session() -> SZOperationSession {
            let session = SZOperationSession()
            session.passwordRequestHandler = { _, message, _, passwordPointer in
                guard let path = self.passwords.keys.first(where: { message?.contains($0) == true }),
                      let password = self.passwords[path],
                      !self.requestedPaths.contains(path)
                else {
                    XCTFail("Unexpected password prompt: \(message ?? "")")
                    return false
                }
                self.requestedPaths.append(path)
                passwordPointer?.pointee = password as NSString
                return true
            }
            return session
        }
    }

    private func verifyEncryptedPayloads(_ payloads: [String: String],
                                         at archiveURL: URL,
                                         password: String,
                                         destination: URL) throws
    {
        let reopened = SZArchive()
        try reopened.open(atPath: archiveURL.path, session: SZOperationSession())
        defer { reopened.close() }

        let entries = reopened.entries()
        XCTAssertEqual(Set(entries.map(\.path)), Set(payloads.keys))
        XCTAssertTrue(entries.allSatisfy(\.isEncrypted), "Mutation must keep every data entry encrypted")
        let settings = SZExtractionSettings()
        settings.password = password
        try reopened.extract(toPath: destination.path, settings: settings, session: SZOperationSession())
        for (path, expected) in payloads {
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(path), encoding: .utf8), expected)
        }
    }

    func testAddingAfterIntegrityTestUsesLearnedPassword() throws {
        for encryption in [SZEncryptionMethod.AES256, .zipCrypto] {
            let (archive, root) = try makeArchive([
                Member(path: "existing.txt", contents: "original", encryption: encryption, password: "one"),
            ])
            defer { archive.close() }

            let prompts = PasswordPrompts(["existing.txt": "one"])
            try archive.test(with: prompts.session())
            XCTAssertEqual(prompts.requestedPaths, ["existing.txt"])

            let added = root.appendingPathComponent("added.txt")
            try "added payload".write(to: added, atomically: true, encoding: .utf8)
            try archive.addPaths([added.path], toArchiveSubdir: "", moveMode: false, session: SZOperationSession())

            try verifyEncryptedPayloads(["existing.txt": "original", "added.txt": "added payload"],
                                        at: root.appendingPathComponent("archive.zip"),
                                        password: "one",
                                        destination: root.appendingPathComponent("after-add"))
        }
    }

    func testReplacingAfterExtractionUsesLearnedPassword() throws {
        for encryption in [SZEncryptionMethod.AES256, .zipCrypto] {
            let (archive, root) = try makeArchive([
                Member(path: "existing.txt", contents: "original", encryption: encryption, password: "one"),
            ])
            defer { archive.close() }

            let prompts = PasswordPrompts(["existing.txt": "one"])
            try archive.extract(toPath: root.appendingPathComponent("before-replace").path,
                                settings: SZExtractionSettings(),
                                session: prompts.session())
            XCTAssertEqual(prompts.requestedPaths, ["existing.txt"])

            let replacement = root.appendingPathComponent("replacement.txt")
            try "replacement payload".write(to: replacement, atomically: true, encoding: .utf8)
            let reference = try XCTUnwrap(archive.entries().first { $0.path == "existing.txt" }?.reference)
            try archive.replaceItem(at: reference,
                                    inArchiveSubdir: "",
                                    withFileAtPath: replacement.path,
                                    session: SZOperationSession())

            try verifyEncryptedPayloads(["existing.txt": "replacement payload"],
                                        at: root.appendingPathComponent("archive.zip"),
                                        password: "one",
                                        destination: root.appendingPathComponent("after-replace"))
        }
    }

    func testDeletingMixedEntryClearsPasswordBindingsWhenArchiveIndicesShift() throws {
        let (archive, root) = try makeMixedArchive()
        defer { archive.close() }

        let initialPrompts = PasswordPrompts(["legacy.txt": "one", "secret.txt": "two"])
        try archive.test(with: initialPrompts.session())
        let oldSecret = try XCTUnwrap(archive.entries().first { $0.path == "secret.txt" })
        let legacy = try XCTUnwrap(archive.entries().first { $0.path == "legacy.txt" })

        // Deleting only copies the surviving encrypted records.
        try archive.deleteItems(at: [legacy.reference], inArchiveSubdir: "", session: SZOperationSession())
        let newSecret = try XCTUnwrap(archive.entries().first { $0.path == "secret.txt" })
        XCTAssertNotEqual(newSecret.index, oldSecret.index)
        XCTAssertNotEqual(newSecret.reference.snapshotIdentifier, oldSecret.reference.snapshotIdentifier)

        // The new index formerly belonged to legacy.txt with password "one".
        // Reopening must discard that association and resolve secret.txt anew.
        let reopenedPrompts = PasswordPrompts(["secret.txt": "two"])
        let destination = root.appendingPathComponent("after-delete")
        try archive.extract(toPath: destination.path,
                            settings: SZExtractionSettings(),
                            session: reopenedPrompts.session())
        XCTAssertEqual(reopenedPrompts.requestedPaths, ["secret.txt"])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("secret.txt"), encoding: .utf8),
                       "secret payload")
    }
}
