// ArchiveMutationTests.swift
//
// Unit coverage for the five in-place archive mutation bridge entry
// points that all funnel through SZOpenAgentFolder and therefore share
// the CAgent refcount logic exercised by 5fe0dcc:
//
//   createFolderNamed:inArchiveSubdir:session:error:
//   renameItemAtPath:inArchiveSubdir:newName:session:error:
//   deleteItemsAtPaths:inArchiveSubdir:session:error:
//   addPaths:toArchiveSubdir:moveMode:session:error:
//   replaceItemAtPath:inArchiveSubdir:withFileAtPath:session:error:
//
// Before these tests, only addPaths was exercised (by a single UI test
// in DragFromArchiveUITests). A UAF or double-free in any of the other
// four entry points would not have been caught. Each case here opens a
// small archive, performs the mutation, and asserts the bridge's own
// post-mutation view matches the expected entry set.

import XCTest

final class ArchiveMutationTests: XCTestCase {
    // MARK: - Helpers

    private func makeArchive(named name: String,
                             format: SZArchiveFormat = .format7z,
                             payloads: [String: String]) throws -> (URL, URL)
    {
        let tempRoot = try makeTemporaryDirectory(named: name)
        var sourceURLs: [URL] = []
        for (relativePath, contents) in payloads.sorted(by: { $0.key < $1.key }) {
            let fileURL = tempRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            sourceURLs.append(fileURL)
        }

        let ext: String
        switch format {
        case .formatZip: ext = "zip"
        case .formatTar: ext = "tar"
        default: ext = "7z"
        }
        let archiveURL = tempRoot.appendingPathComponent("\(name).\(ext)")

        let settings = SZCompressionSettings()
        settings.format = format
        settings.pathMode = .relativePaths
        // Zip needs a zip-compatible method; LZMA2 (the default) only
        // applies to 7z. Tar is method-less.
        if format == .formatZip {
            settings.method = .deflate
            settings.methodName = "Deflate"
        }
        try SZArchive.create(atPath: archiveURL.path,
                             fromPaths: sourceURLs.map(\.path),
                             settings: settings,
                             session: nil)
        return (archiveURL, tempRoot)
    }

    private func entryPaths(in archive: SZArchive) -> Set<String> {
        var paths: Set<String> = []
        for entry in archive.entries() {
            paths.insert(entry.path)
        }
        return paths
    }

    // MARK: - createFolderNamed

    func testCreateFolderAddsDirectoryEntryAndPreservesExisting() throws {
        let (archiveURL, _) = try makeArchive(named: "createfolder",
                                              payloads: ["keep.txt": "keep"])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        try archive.createFolderNamed("NewFolder",
                                 inArchiveSubdir: "",
                                 session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertTrue(paths.contains("keep.txt"),
                      "pre-existing entry should survive the mutation")
        XCTAssertTrue(paths.contains("NewFolder"),
                      "new folder entry should be present after createFolder")
    }

    // MARK: - renameItemAtPath

    func testRenameItemChangesPathAndLeavesOtherEntriesAlone() throws {
        let (archiveURL, _) = try makeArchive(named: "rename",
                                              payloads: [
                                                "old.txt": "contents",
                                                "other.txt": "untouched",
                                              ])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        try archive.renameItem(atPath: "old.txt",
                               inArchiveSubdir: "",
                               newName: "renamed.txt",
                               session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertTrue(paths.contains("renamed.txt"),
                      "renamed entry should appear under the new name")
        XCTAssertFalse(paths.contains("old.txt"),
                       "old entry name must be gone after rename")
        XCTAssertTrue(paths.contains("other.txt"),
                      "unrelated entry must not be disturbed by rename")
    }

    // MARK: - deleteItemsAtPaths

    func testDeleteItemsRemovesEverySpecifiedEntry() throws {
        let (archiveURL, _) = try makeArchive(named: "delete",
                                              payloads: [
                                                "a.txt": "a",
                                                "b.txt": "b",
                                                "c.txt": "c",
                                              ])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        try archive.deleteItems(atPaths: ["a.txt", "c.txt"],
                                inArchiveSubdir: "",
                                session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertEqual(paths, ["b.txt"],
                       "only the non-deleted entry should remain")
    }

    // MARK: - addPaths

    func testAddPathsInsertsLooseFileIntoArchive() throws {
        let (archiveURL, tempRoot) = try makeArchive(named: "addpaths",
                                                     payloads: ["existing.txt": "first"])

        let looseFile = tempRoot.appendingPathComponent("added.txt")
        try "second".write(to: looseFile, atomically: true, encoding: .utf8)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        try archive.addPaths([looseFile.path],
                             toArchiveSubdir: "",
                             moveMode: false,
                             session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertTrue(paths.contains("existing.txt"),
                      "pre-existing entry should survive addPaths")
        XCTAssertTrue(paths.contains("added.txt"),
                      "new entry should be present after addPaths")
        XCTAssertTrue(FileManager.default.fileExists(atPath: looseFile.path),
                      "moveMode:false must leave the source file in place")
    }

    func testAddPathsMoveModeRemovesSourceFile() throws {
        let (archiveURL, tempRoot) = try makeArchive(named: "addpathsmove",
                                                     payloads: ["existing.txt": "first"])

        let looseFile = tempRoot.appendingPathComponent("moved.txt")
        try "move me".write(to: looseFile, atomically: true, encoding: .utf8)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        try archive.addPaths([looseFile.path],
                             toArchiveSubdir: "",
                             moveMode: true,
                             session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertTrue(paths.contains("moved.txt"),
                      "moved entry should be in the archive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: looseFile.path),
                       "moveMode:true must delete the source file once the mutation succeeds")
    }

    // MARK: - replaceItemAtPath

    func testReplaceItemSubstitutesContentsAndKeepsEntryName() throws {
        let (archiveURL, tempRoot) = try makeArchive(named: "replace",
                                                     payloads: [
                                                       "entry.txt": "original",
                                                       "keep.txt": "untouched",
                                                     ])

        let newContentsURL = tempRoot.appendingPathComponent("source.bin")
        try "replacement".write(to: newContentsURL, atomically: true, encoding: .utf8)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        try archive.replaceItem(atPath: "entry.txt",
                                inArchiveSubdir: "",
                                withFileAtPath: newContentsURL.path,
                                session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertEqual(paths, ["entry.txt", "keep.txt"],
                       "replaceItem must not change the entry set")

        // Extract and verify the new contents replaced the old ones.
        let extractDir = tempRoot.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let extractSettings = SZExtractionSettings()
        extractSettings.pathMode = .fullPaths
        try archive.extract(toPath: extractDir.path,
                            settings: extractSettings,
                            session: nil)

        let extracted = try String(contentsOf: extractDir.appendingPathComponent("entry.txt"),
                                   encoding: .utf8)
        XCTAssertEqual(extracted, "replacement",
                       "extracted entry should hold the replacement bytes")
    }

    // MARK: - Regression: repeated mutations do not corrupt CAgent teardown

    /// Hammer the same archive with several mutations in a row. Before
    /// 5fe0dcc, each call destroyed the CAgent early, so any test that
    /// relied on a second mutation succeeding crashed in
    /// CMyComPtr<IInFolderArchive>::~CMyComPtr() the second time.
    func testRepeatedMutationsDoNotCorruptAgent() throws {
        let (archiveURL, tempRoot) = try makeArchive(named: "repeat",
                                                     payloads: ["seed.txt": "seed"])

        let loose = tempRoot.appendingPathComponent("loose.txt")
        try "loose".write(to: loose, atomically: true, encoding: .utf8)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        try archive.createFolderNamed("dir1", inArchiveSubdir: "", session: nil)
        try archive.addPaths([loose.path],
                             toArchiveSubdir: "",
                             moveMode: false,
                             session: nil)
        try archive.renameItem(atPath: "seed.txt",
                               inArchiveSubdir: "",
                               newName: "seed-renamed.txt",
                               session: nil)
        try archive.deleteItems(atPaths: ["loose.txt"],
                                inArchiveSubdir: "",
                                session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertTrue(paths.contains("dir1"))
        XCTAssertTrue(paths.contains("seed-renamed.txt"))
        XCTAssertFalse(paths.contains("loose.txt"))
        XCTAssertFalse(paths.contains("seed.txt"))
    }
}
