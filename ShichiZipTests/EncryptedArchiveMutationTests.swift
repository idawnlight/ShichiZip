// EncryptedArchiveMutationTests.swift
//
// Exercises in-place mutations on password-protected archives and
// verifies that they remain reopenable afterward.

import XCTest

final class EncryptedArchiveMutationTests: XCTestCase {
    private static let password = "test-password-please-ignore"

    // MARK: - Helpers

    private func makeEncryptedArchive(named name: String,
                                      format: SZArchiveFormat = .format7z,
                                      payloads: [String: String]) throws -> (URL, URL)
    {
        let tempRoot = try makeTemporaryDirectory(named: name)
        var sourceURLs: [URL] = []
        for (relativePath, contents) in payloads.sorted(by: { $0.key < $1.key }) {
            let fileURL = tempRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            sourceURLs.append(fileURL)
        }

        let ext = switch format {
        case .formatZip: "zip"
        default: "7z"
        }
        let archiveURL = tempRoot.appendingPathComponent("\(name).\(ext)")

        let settings = SZCompressionSettings()
        settings.format = format
        settings.pathMode = .relativePaths
        settings.password = Self.password
        if format == .format7z {
            settings.encryptFileNames = true
        } else {
            settings.encryption = .AES256
            settings.method = .deflate
            settings.methodName = "Deflate"
        }
        try SZArchive.create(atPath: archiveURL.path,
                             fromPaths: sourceURLs.map(\.path),
                             settings: settings,
                             session: nil)
        return (archiveURL, tempRoot)
    }

    private func openEncrypted(_ archiveURL: URL) throws -> SZArchive {
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path,
                         password: Self.password,
                         session: nil)
        return archive
    }

    private func entryPaths(in archive: SZArchive) -> Set<String> {
        Set(archive.entries().map(\.path))
    }

    // MARK: - AddPaths on encrypted archive

    /// Updating an encrypted 7z should not require a second password prompt.
    func testAddPathsRoundTripsOnEncrypted7z() throws {
        let (archiveURL, tempRoot) = try makeEncryptedArchive(
            named: "enc-add",
            payloads: ["existing.txt": "one"],
        )

        let looseFile = tempRoot.appendingPathComponent("added.txt")
        try "two".write(to: looseFile, atomically: true, encoding: .utf8)

        let archive = try openEncrypted(archiveURL)
        defer { archive.close() }

        try archive.addPaths([looseFile.path],
                             toArchiveSubdir: "",
                             moveMode: false,
                             session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertTrue(paths.contains("existing.txt"))
        XCTAssertTrue(paths.contains("added.txt"))

        // Close the archive object and re-open from scratch to prove
        // the bridge's cached password state survived the internal
        // reopen that addPaths performs.
        archive.close()
        let reopened = try openEncrypted(archiveURL)
        defer { reopened.close() }
        XCTAssertEqual(entryPaths(in: reopened), paths)
    }

    // MARK: - CreateFolder on encrypted archive

    func testCreateFolderOnEncrypted7z() throws {
        let (archiveURL, _) = try makeEncryptedArchive(
            named: "enc-mkdir",
            payloads: ["file.txt": "x"],
        )

        let archive = try openEncrypted(archiveURL)
        defer { archive.close() }

        try archive.createFolderNamed("sub",
                                      inArchiveSubdir: "",
                                      session: nil)

        XCTAssertTrue(entryPaths(in: archive).contains("sub"))
    }

    // MARK: - Rename on encrypted archive

    func testRenameOnEncrypted7z() throws {
        let (archiveURL, _) = try makeEncryptedArchive(
            named: "enc-rename",
            payloads: ["old.txt": "hello"],
        )

        let archive = try openEncrypted(archiveURL)
        defer { archive.close() }

        try archive.renameItem(atPath: "old.txt",
                               inArchiveSubdir: "",
                               newName: "new.txt",
                               session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertTrue(paths.contains("new.txt"))
        XCTAssertFalse(paths.contains("old.txt"))
    }

    // MARK: - Delete on encrypted archive

    func testDeleteOnEncrypted7z() throws {
        let (archiveURL, _) = try makeEncryptedArchive(
            named: "enc-delete",
            payloads: ["a.txt": "a", "b.txt": "b"],
        )

        let archive = try openEncrypted(archiveURL)
        defer { archive.close() }

        try archive.deleteItems(atPaths: ["a.txt"],
                                inArchiveSubdir: "",
                                session: nil)

        XCTAssertEqual(entryPaths(in: archive), ["b.txt"])
    }

    // MARK: - Replace on encrypted archive

    func testReplaceOnEncrypted7z() throws {
        let (archiveURL, tempRoot) = try makeEncryptedArchive(
            named: "enc-replace",
            payloads: ["entry.txt": "original"],
        )

        let substitute = tempRoot.appendingPathComponent("new.bin")
        try "replaced".write(to: substitute, atomically: true, encoding: .utf8)

        let archive = try openEncrypted(archiveURL)
        defer { archive.close() }

        try archive.replaceItem(atPath: "entry.txt",
                                inArchiveSubdir: "",
                                withFileAtPath: substitute.path,
                                session: nil)

        let extractDir = tempRoot.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let extractSettings = SZExtractionSettings()
        extractSettings.pathMode = .fullPaths
        extractSettings.password = Self.password
        try archive.extract(toPath: extractDir.path,
                            settings: extractSettings,
                            session: nil)

        let extracted = try String(contentsOf: extractDir.appendingPathComponent("entry.txt"),
                                   encoding: .utf8)
        XCTAssertEqual(extracted, "replaced")
    }

    // MARK: - Encrypted zip (AES-256) update

    /// Zip archives take a different route through the update code
    /// than 7z (the password only applies to data entries, not the
    /// central directory), so run addPaths against an AES-256 zip too.
    func testAddPathsRoundTripsOnAES256Zip() throws {
        let (archiveURL, tempRoot) = try makeEncryptedArchive(
            named: "enc-zip-add",
            format: .formatZip,
            payloads: ["existing.txt": "one"],
        )

        let looseFile = tempRoot.appendingPathComponent("added.txt")
        try "two".write(to: looseFile, atomically: true, encoding: .utf8)

        let archive = try openEncrypted(archiveURL)
        defer { archive.close() }

        try archive.addPaths([looseFile.path],
                             toArchiveSubdir: "",
                             moveMode: false,
                             session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertTrue(paths.contains("existing.txt"))
        XCTAssertTrue(paths.contains("added.txt"))
        XCTAssertTrue(archive.entries().allSatisfy { $0.isEncrypted || $0.isDirectory },
                      "all data entries in an AES-256 zip must stay encrypted after update")
    }
}
