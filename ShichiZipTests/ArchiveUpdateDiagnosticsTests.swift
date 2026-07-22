import Foundation
import XCTest

final class ArchiveUpdateDiagnosticsTests: XCTestCase {
    func testCreateReportsMissingInputAsCommittedWarning() throws {
        let tempRoot = try makeTemporaryDirectory(named: "update-diagnostics-missing-create")
        let archiveURL = tempRoot.appendingPathComponent("out.7z")
        let missingURL = tempRoot.appendingPathComponent("missing.txt")
        let settings = SZCompressionSettings()

        let outcome = try SZArchive.create(atPath: archiveURL.path,
                                           fromPaths: [missingURL.path],
                                           settings: settings,
                                           session: nil)

        XCTAssertTrue(outcome.hasWarnings)
        XCTAssertTrue(outcome.wasArchiveCommitted)
        XCTAssertEqual(outcome.totalIssueCount, 1)
        XCTAssertEqual(outcome.issues.first?.stage, .scan)
        XCTAssertEqual(outcome.issues.first?.path, missingURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    func testCreateContinuesWithReadableInputAndReportsUnreadableInput() throws {
        let tempRoot = try makeTemporaryDirectory(named: "update-diagnostics-mixed-create")
        let readableURL = tempRoot.appendingPathComponent("readable.txt")
        let unreadableURL = tempRoot.appendingPathComponent("unreadable.txt")
        let archiveURL = tempRoot.appendingPathComponent("out.7z")
        try "readable".write(to: readableURL, atomically: true, encoding: .utf8)
        try "unreadable".write(to: unreadableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0],
                                              ofItemAtPath: unreadableURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: unreadableURL.path)
        }

        let settings = SZCompressionSettings()
        let outcome = try SZArchive.create(atPath: archiveURL.path,
                                           fromPaths: [readableURL.path, unreadableURL.path],
                                           settings: settings,
                                           session: nil)

        XCTAssertTrue(outcome.hasWarnings)
        XCTAssertEqual(outcome.issues.first?.stage, .open)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }
        let paths = Set(archive.entries().map(\.path))
        XCTAssertTrue(paths.contains("readable.txt"))
        XCTAssertFalse(paths.contains("unreadable.txt"))
    }

    func testZipUsesUpstreamSkipSemanticsForInitialOpenFailure() throws {
        let tempRoot = try makeTemporaryDirectory(named: "update-diagnostics-zip-open")
        let readableURL = tempRoot.appendingPathComponent("readable.txt")
        let unreadableURL = tempRoot.appendingPathComponent("unreadable.txt")
        let archiveURL = tempRoot.appendingPathComponent("out.zip")
        try "readable".write(to: readableURL, atomically: true, encoding: .utf8)
        try "unreadable".write(to: unreadableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0],
                                              ofItemAtPath: unreadableURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: unreadableURL.path)
        }

        let settings = SZCompressionSettings()
        settings.format = .formatZip
        settings.method = .deflate
        settings.methodName = "Deflate"
        let outcome = try SZArchive.create(
            atPath: archiveURL.path,
            fromPaths: [readableURL.path, unreadableURL.path],
            settings: settings,
            session: nil,
        )
        XCTAssertTrue(outcome.hasWarnings)
        XCTAssertEqual(outcome.issues.first?.stage, .open)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        let paths = Set(archive.entries().map(\.path))
        archive.close()
        XCTAssertTrue(paths.contains("readable.txt"))
        XCTAssertFalse(paths.contains("unreadable.txt"))
    }

    func testCopyIntoArchiveFailsClosedWhenAnyInputCannotBeScanned() throws {
        let (archiveURL, tempRoot) = try makeArchive(
            named: "warning-add",
            payloads: ["existing.txt": "existing"],
        )
        let readableURL = tempRoot.appendingPathComponent("added.txt")
        let missingURL = tempRoot.appendingPathComponent("missing.txt")
        try "added".write(to: readableURL, atomically: true, encoding: .utf8)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        XCTAssertThrowsError(
            try archive.addPaths([readableURL.path, missingURL.path],
                                 toArchiveSubdir: "",
                                 moveMode: false,
                                 session: nil),
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: readableURL.path))
        XCTAssertFalse(archive.entries().contains { $0.path == "added.txt" })
        XCTAssertFalse(archive.entries().contains { $0.path == "missing.txt" })
        XCTAssertTrue(archive.entries().contains { $0.path == "existing.txt" })
    }

    func testOutcomeBoundsIssueDetailsAndPreservesTotalCount() throws {
        let tempRoot = try makeTemporaryDirectory(named: "update-diagnostics-cap")
        let archiveURL = tempRoot.appendingPathComponent("out.7z")
        let missingPaths = (0 ..< 300).map {
            tempRoot.appendingPathComponent("missing-\($0).txt").path
        }

        let outcome = try SZArchive.create(atPath: archiveURL.path,
                                           fromPaths: missingPaths,
                                           settings: SZCompressionSettings(),
                                           session: nil)

        XCTAssertEqual(outcome.totalIssueCount, 300)
        XCTAssertEqual(outcome.issues.count, 256)
        XCTAssertTrue(outcome.areIssuesTruncated)
    }

    func testMoveIntoArchiveFailsClosedWhenAnyInputCannotBeScanned() throws {
        let (archiveURL, tempRoot) = try makeArchive(
            named: "strict-move",
            payloads: ["existing.txt": "existing"],
        )
        let sourceURL = tempRoot.appendingPathComponent("move-me.txt")
        let missingURL = tempRoot.appendingPathComponent("missing.txt")
        try "move me".write(to: sourceURL, atomically: true, encoding: .utf8)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        XCTAssertThrowsError(
            try archive.addPaths([sourceURL.path, missingURL.path],
                                 toArchiveSubdir: "",
                                 moveMode: true,
                                 session: nil),
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(archive.entries().contains { $0.path == "move-me.txt" })
        XCTAssertTrue(archive.entries().contains { $0.path == "existing.txt" })
    }

    func testDeleteAfterCompressionFailsClosedBeforeDeletingReadableSource() throws {
        let tempRoot = try makeTemporaryDirectory(named: "strict-delete-after")
        let readableURL = tempRoot.appendingPathComponent("readable.txt")
        let missingURL = tempRoot.appendingPathComponent("missing.txt")
        let archiveURL = tempRoot.appendingPathComponent("out.7z")
        try "readable".write(to: readableURL, atomically: true, encoding: .utf8)

        let settings = SZCompressionSettings()
        settings.deleteAfterCompression = true

        XCTAssertThrowsError(
            try SZArchive.create(atPath: archiveURL.path,
                                 fromPaths: [readableURL.path, missingURL.path],
                                 settings: settings,
                                 session: nil),
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: readableURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    func testAddModeToExistingArchiveFailsClosedOnInputOpenFailure() throws {
        let tempRoot = try makeTemporaryDirectory(named: "strict-existing-add-mode")
        let sourceURL = tempRoot.appendingPathComponent("entry.txt")
        let archiveURL = tempRoot.appendingPathComponent("out.7z")
        try "original".write(to: sourceURL, atomically: true, encoding: .utf8)
        try createArchive(at: archiveURL, from: [sourceURL])

        try "replacement".write(to: sourceURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0],
                                              ofItemAtPath: sourceURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: sourceURL.path)
        }

        XCTAssertThrowsError(
            try SZArchive.create(atPath: archiveURL.path,
                                 fromPaths: [sourceURL.path],
                                 settings: SZCompressionSettings(),
                                 session: nil),
        )

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }
        let entry = try XCTUnwrap(archive.entries().first { $0.path == "entry.txt" })
        let contents = try contents(of: entry,
                                    in: archive,
                                    under: tempRoot,
                                    label: "strict-existing-add-result")
        XCTAssertEqual(contents, "original")
    }

    func testUpdateModeFailsClosedAndPreservesExistingArchiveMember() throws {
        let tempRoot = try makeTemporaryDirectory(named: "strict-update-mode")
        let sourceURL = tempRoot.appendingPathComponent("entry.txt")
        let archiveURL = tempRoot.appendingPathComponent("out.7z")
        try "original".write(to: sourceURL, atomically: true, encoding: .utf8)
        try createArchive(at: archiveURL, from: [sourceURL])

        try "replacement".write(to: sourceURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0],
                                              ofItemAtPath: sourceURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: sourceURL.path)
        }

        let settings = SZCompressionSettings()
        settings.updateMode = .update
        XCTAssertThrowsError(
            try SZArchive.create(atPath: archiveURL.path,
                                 fromPaths: [sourceURL.path],
                                 settings: settings,
                                 session: nil),
        )

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }
        let entry = try XCTUnwrap(archive.entries().first { $0.path == "entry.txt" })
        let contents = try contents(of: entry,
                                    in: archive,
                                    under: tempRoot,
                                    label: "strict-update-mode-result")
        XCTAssertEqual(contents, "original")
    }

    func testReplaceFailsClosedAndPreservesOldMemberWhenSourceCannotOpen() throws {
        let (archiveURL, tempRoot) = try makeArchive(
            named: "strict-replace",
            payloads: ["entry.txt": "original"],
        )
        let replacementURL = tempRoot.appendingPathComponent("replacement.txt")
        try "replacement".write(to: replacementURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0],
                                              ofItemAtPath: replacementURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: replacementURL.path)
        }

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }
        let reference = try XCTUnwrap(
            archive.entries().first { $0.path == "entry.txt" }?.reference,
        )

        XCTAssertThrowsError(
            try archive.replaceItem(at: reference,
                                    inArchiveSubdir: "",
                                    withFileAtPath: replacementURL.path,
                                    session: nil),
        )

        let entry = try XCTUnwrap(archive.entries().first { $0.path == "entry.txt" })
        let contents = try contents(of: entry,
                                    in: archive,
                                    under: tempRoot,
                                    label: "strict-replace-result")
        XCTAssertEqual(contents, "original")
    }

    private func makeArchive(named name: String,
                             payloads: [String: String]) throws -> (URL, URL)
    {
        let tempRoot = try makeTemporaryDirectory(named: name)
        let sourceURLs = try payloads.sorted(by: { $0.key < $1.key }).map { path, contents in
            let url = tempRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let archiveURL = tempRoot.appendingPathComponent("\(name).7z")
        try createArchive(at: archiveURL, from: sourceURLs)
        return (archiveURL, tempRoot)
    }

    private func contents(of entry: SZArchiveEntry,
                          in archive: SZArchive,
                          under tempRoot: URL,
                          label: String) throws -> String
    {
        let extractionRoot = tempRoot.appendingPathComponent(
            "extract-\(label)-\(UUID().uuidString)",
            isDirectory: true,
        )
        try FileManager.default.createDirectory(at: extractionRoot,
                                                withIntermediateDirectories: true)
        let settings = SZExtractionSettings()
        settings.pathMode = .fullPaths
        try archive.extractEntries([NSNumber(value: entry.index)],
                                   toPath: extractionRoot.path,
                                   settings: settings,
                                   session: nil)
        return try String(contentsOf: extractionRoot.appendingPathComponent(entry.path),
                          encoding: .utf8)
    }
}
