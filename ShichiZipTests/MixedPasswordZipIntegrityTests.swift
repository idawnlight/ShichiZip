import XCTest

#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

final class MixedPasswordZipIntegrityTests: XCTestCase {
    private struct Member {
        let path: String
        let contents: String
        let encryption: SZEncryptionMethod
        let password: String
    }

    private let members = [
        Member(path: "legacy.txt", contents: "ZipCrypto payload", encryption: .zipCrypto, password: "one"),
        Member(path: "secret.txt", contents: "AES payload", encryption: .AES256, password: "two"),
    ]

    private struct ZipRecord {
        let path: String
        let localNameRange: Range<Int>
        let centralNameRange: Range<Int>
        let packedDataRange: Range<Int>
    }

    private func makeArchive(members: [Member]) throws -> (archiveURL: URL, root: URL) {
        let root = try makeTemporaryDirectory(named: "mixed-password-integrity")
        let archiveURL = root.appendingPathComponent("mixed.zip")
        for member in members {
            let sourceURL = root.appendingPathComponent(member.path)
            try member.contents.write(to: sourceURL, atomically: true, encoding: .utf8)
            let settings = SZCompressionSettings()
            settings.format = .formatZip
            settings.pathMode = .relativePaths
            settings.method = .copy
            settings.methodName = "Copy"
            settings.encryption = member.encryption
            settings.password = member.password
            try SZArchive.create(atPath: archiveURL.path,
                                 fromPaths: [sourceURL.path],
                                 settings: settings,
                                 session: SZOperationSession())
        }
        return (archiveURL, root)
    }

    /// Reads the ordinary ZIP records emitted by these small fixtures. Editing
    /// record fields avoids accidentally replacing bytes in encrypted payloads.
    private func records(in data: Data) throws -> [ZipRecord] {
        func integer(at offset: Int, width: Int) throws -> Int {
            guard offset >= 0, offset + width <= data.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (0 ..< width).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
        }

        let end = try XCTUnwrap(data.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards)?.lowerBound)
        let count = try integer(at: end + 10, width: 2)
        var centralOffset = try integer(at: end + 16, width: 4)
        var result: [ZipRecord] = []
        for _ in 0 ..< count {
            guard try integer(at: centralOffset, width: 4) == 0x0201_4B50 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let nameLength = try integer(at: centralOffset + 28, width: 2)
            let extraLength = try integer(at: centralOffset + 30, width: 2)
            let commentLength = try integer(at: centralOffset + 32, width: 2)
            let packedSize = try integer(at: centralOffset + 20, width: 4)
            let localOffset = try integer(at: centralOffset + 42, width: 4)
            guard try integer(at: localOffset, width: 4) == 0x0403_4B50 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let localNameLength = try integer(at: localOffset + 26, width: 2)
            let localExtraLength = try integer(at: localOffset + 28, width: 2)
            let centralName = (centralOffset + 46) ..< (centralOffset + 46 + nameLength)
            let localName = (localOffset + 30) ..< (localOffset + 30 + localNameLength)
            let payloadOffset = localName.upperBound + localExtraLength
            let payload = payloadOffset ..< (payloadOffset + packedSize)
            guard centralName.upperBound <= data.count, localName.upperBound <= data.count,
                  payload.upperBound <= data.count,
                  data[centralName] == data[localName]
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let path = try XCTUnwrap(String(data: data[centralName], encoding: .utf8))
            result.append(ZipRecord(path: path, localNameRange: localName,
                                    centralNameRange: centralName, packedDataRange: payload))
            centralOffset = centralName.upperBound + extraLength + commentLength
        }
        return result
    }

    func testDuplicatePathsKeepSeparatePasswordsAndRenamedOutputFiles() throws {
        let fixture = try makeArchive(members: members)
        var data = try Data(contentsOf: fixture.archiveURL)
        let secret = try XCTUnwrap(try records(in: data).first { $0.path == "secret.txt" })
        let duplicateName = Data("legacy.txt".utf8)
        XCTAssertEqual(secret.localNameRange.count, duplicateName.count)
        XCTAssertEqual(secret.centralNameRange.count, duplicateName.count)
        data.replaceSubrange(secret.localNameRange, with: duplicateName)
        data.replaceSubrange(secret.centralNameRange, with: duplicateName)
        try data.write(to: fixture.archiveURL, options: .atomic)

        let archive = SZArchive()
        try archive.open(atPath: fixture.archiveURL.path, session: SZOperationSession())
        defer { archive.close() }
        let entries = archive.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.path)), ["legacy.txt"])
        let legacy = try XCTUnwrap(entries.first { $0.method?.contains("ZipCrypto") == true })
        let aes = try XCTUnwrap(entries.first { $0.method?.contains("AES-256") == true })
        XCTAssertNotEqual(legacy.index, aes.index)

        var promptCount = 0
        let session = SZOperationSession()
        session.passwordRequestHandler = { _, message, _, password in
            XCTAssertTrue(message?.contains("legacy.txt") == true)
            guard promptCount < 2 else {
                XCTFail("Unexpected extra prompt for a duplicate ZIP path")
                return false
            }
            password?.pointee = (promptCount == 0 ? "one" : "two") as NSString
            promptCount += 1
            return true
        }
        let settings = SZExtractionSettings()
        settings.overwriteMode = .rename
        let outputs = try archive.extractEntriesWithOutputURLs(
            [NSNumber(value: legacy.index), NSNumber(value: aes.index)],
            toPath: fixture.root.appendingPathComponent("bulk").path,
            settings: settings,
            session: session,
        )
        XCTAssertEqual(promptCount, 2)
        XCTAssertEqual(Set(outputs).count, 2, "Overwrite rename must produce separate output files")
        XCTAssertEqual(try Set(outputs.map { try String(contentsOf: $0, encoding: .utf8) }),
                       Set(members.map(\.contents)))

        // Both cached passwords must still select the correct entry when its
        // sibling has the same path. No session here can answer another prompt.
        for (entry, contents) in [(legacy, "ZipCrypto payload"), (aes, "AES payload")] {
            let destination = fixture.root.appendingPathComponent("entry-\(entry.index)")
            try archive.extractEntries([NSNumber(value: entry.index)], toPath: destination.path,
                                       settings: SZExtractionSettings(), session: SZOperationSession())
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("legacy.txt"), encoding: .utf8),
                           contents)
        }
        try archive.test(with: SZOperationSession())
    }

    func testCachedIntegrityTestReadsPayloadAndReportsCorruptionWithoutReprompting() throws {
        let fixture = try makeArchive(members: members)
        let data = try Data(contentsOf: fixture.archiveURL)
        let secret = try XCTUnwrap(try records(in: data).first { $0.path == "secret.txt" })
        XCTAssertGreaterThan(secret.packedDataRange.count, 10)

        let archive = SZArchive()
        try archive.open(atPath: fixture.archiveURL.path, session: SZOperationSession())
        defer { archive.close() }
        let initialSession = SZOperationSession()
        var initialPrompts = 0
        initialSession.passwordRequestHandler = { _, message, _, password in
            initialPrompts += 1
            guard initialPrompts <= 2 else {
                XCTFail("Unexpected password retry while learning the fixture passwords")
                return false
            }
            password?.pointee = (message?.contains("secret.txt") == true ? "two" : "one") as NSString
            return true
        }
        try archive.test(with: initialSession)
        XCTAssertEqual(initialPrompts, 2)

        // Change one AES authentication byte through the same inode. Atomic
        // replacement would leave the archive's open descriptor on old bytes.
        // GetItemStream seeks its file stream anew for each test operation.
        let offset = secret.packedDataRange.upperBound - 1
        let handle = try FileHandle(forWritingTo: fixture.archiveURL)
        defer { try? handle.close() }
        func writeAuthenticationByte(_ byte: UInt8) throws {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: Data([byte]))
            try handle.synchronize()
        }
        try writeAuthenticationByte(data[offset] ^ 0x01)

        let cachedSession = SZOperationSession()
        var unexpectedPrompts = 0
        cachedSession.passwordRequestHandler = { _, _, _, _ in
            unexpectedPrompts += 1
            return false
        }
        XCTAssertThrowsError(try archive.test(with: cachedSession)) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, SZArchiveErrorDomain)
            XCTAssertEqual(error.code, -13, "An authenticated entry's corruption must remain an integrity failure")
            XCTAssertTrue(error.localizedFailureReason?.contains("secret.txt") == true)
            XCTAssertTrue(error.localizedFailureReason?.contains(SZL10n.string("error.crcFailedGeneric")) == true)
        }
        XCTAssertEqual(unexpectedPrompts, 0)

        // A corrupt payload does not invalidate either entry's proven password.
        try writeAuthenticationByte(data[offset])
        try archive.test(with: SZOperationSession())
    }

    private final class CancelWhenExtractingSession: SZOperationSession, @unchecked Sendable {
        private(set) var reachedExtraction = false

        override func reportPhase(_ phase: SZOperationPhase) {
            super.reportPhase(phase)
            if phase == .extracting {
                reachedExtraction = true
                requestCancel()
            }
        }
    }

    func testCachedZeroByteExtractionHonorsCancellation() throws {
        let fixture = try makeArchive(members: [
            Member(path: "empty.txt", contents: "", encryption: .AES256, password: "empty-password"),
        ])
        let archive = SZArchive()
        try archive.open(atPath: fixture.archiveURL.path, password: "empty-password", session: SZOperationSession())
        defer { archive.close() }
        try archive.test(with: SZOperationSession())

        let session = CancelWhenExtractingSession()
        XCTAssertThrowsError(try archive.extract(toPath: fixture.root.appendingPathComponent("cancelled").path,
                                                 settings: SZExtractionSettings(), session: session))
        { error in
            XCTAssertTrue(szIsUserCancellation(error), "Expected cancellation, got \(error)")
        }
        XCTAssertTrue(session.reachedExtraction, "Cancellation must occur after the cached-password preflight")
        XCTAssertEqual(session.bytesTotal, 0)
    }
}
