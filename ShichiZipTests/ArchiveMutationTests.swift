// ArchiveMutationTests.swift
//
// Exercises the five in-place mutation entry points and verifies the
// resulting archive contents.

import XCTest
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

final class ArchiveMutationTests: XCTestCase {
    private final class CancelAfterReplacementSession: SZOperationSession, @unchecked Sendable {
        private let archivePath: String
        private let initialFileNumber: UInt64
        private(set) var requestedCancellationAfterReplacement = false

        init(archivePath: String) throws {
            self.archivePath = archivePath
            let attributes = try FileManager.default.attributesOfItem(atPath: archivePath)
            initialFileNumber = try XCTUnwrap(
                (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            )
            super.init()
        }

        override func reportProgressFraction(_ fraction: Double) {
            super.reportProgressFraction(fraction)
            guard fraction >= 1,
                  !requestedCancellationAfterReplacement,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: archivePath),
                  let currentFileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  currentFileNumber != initialFileNumber
            else {
                return
            }

            requestedCancellationAfterReplacement = true
            requestCancel()
        }

        override func shouldCancel() -> Bool {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: archivePath),
                  let currentFileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  currentFileNumber != initialFileNumber
            else {
                return super.shouldCancel()
            }

            requestedCancellationAfterReplacement = true
            return true
        }
    }

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
                withIntermediateDirectories: true,
            )
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            sourceURLs.append(fileURL)
        }

        let ext = switch format {
        case .formatZip: "zip"
        case .formatTar: "tar"
        default: "7z"
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

    private func makeDuplicatePathArchive(named name: String) throws -> (URL, URL) {
        let tempRoot = try makeTemporaryDirectory(named: name)
        let archiveURL = tempRoot.appendingPathComponent("\(name).tar")
        try createTarFixture(
            at: archiveURL,
            entries: [
                (path: "duplicate.txt", contents: "first"),
                (path: "duplicate.txt", contents: "second"),
            ],
        )
        return (archiveURL, tempRoot)
    }

    private func duplicateEntries(in archive: SZArchive) throws -> [SZArchiveEntry] {
        let entries = archive.entries()
            .filter { $0.path == "duplicate.txt" }
            .sorted { $0.index < $1.index }
        XCTAssertEqual(entries.count, 2)
        return entries
    }

    private func reference(forPath path: String,
                           in archive: SZArchive) throws -> SZArchiveItemReference
    {
        try XCTUnwrap(archive.entries().first { $0.path == path }?.reference)
    }

    private func contents(of entry: SZArchiveEntry,
                          in archive: SZArchive,
                          under tempRoot: URL,
                          label: String) throws -> String
    {
        let extractDirectory = tempRoot.appendingPathComponent(
            "extract-\(label)-\(UUID().uuidString)",
            isDirectory: true,
        )
        try FileManager.default.createDirectory(at: extractDirectory,
                                                withIntermediateDirectories: true)
        let settings = SZExtractionSettings()
        settings.pathMode = .fullPaths
        settings.overwriteMode = .overwrite
        try archive.extractEntries([NSNumber(value: entry.index)],
                                   toPath: extractDirectory.path,
                                   settings: settings,
                                   session: nil)
        return try String(contentsOf: extractDirectory.appendingPathComponent(entry.path),
                          encoding: .utf8)
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

    func testCreateFolderRejectsNamesEndingInDotComponents() throws {
        let (archiveURL, _) = try makeArchive(named: "createfolder-invalid",
                                              payloads: ["keep.txt": "keep"])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        for name in [".", "..", "nested/.", "nested/.."] {
            XCTAssertThrowsError(
                try archive.createFolderNamed(name,
                                              inArchiveSubdir: "",
                                              session: nil),
                "createFolder should reject upstream-invalid name: \(name)",
            ) { error in
                XCTAssertEqual((error as NSError).domain, SZArchiveErrorDomain)
            }
        }

        XCTAssertEqual(entryPaths(in: archive), ["keep.txt"])
    }

    func testCreateFolderAllowsSeparatorsAndSpecialSymbolsLikeUpstream() throws {
        let (archiveURL, _) = try makeArchive(named: "createfolder-special",
                                              payloads: ["keep.txt": "keep"])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        try archive.createFolderNamed("nested/New Folder #1 [ok]! @&+=,;",
                                      inArchiveSubdir: "",
                                      session: nil)
        try archive.createFolderNamed("name.with.dots...",
                                      inArchiveSubdir: "",
                                      session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertTrue(paths.contains("nested/New Folder #1 [ok]! @&+=,;"))
        XCTAssertTrue(paths.contains("name.with.dots..."))
        XCTAssertTrue(paths.contains("keep.txt"))
    }

    // MARK: - renameItemAtReference

    func testRenameItemChangesPathAndLeavesOtherEntriesAlone() throws {
        let (archiveURL, _) = try makeArchive(named: "rename",
                                              payloads: [
                                                  "old.txt": "contents",
                                                  "other.txt": "untouched",
                                              ])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        try archive.renameItem(at: reference(forPath: "old.txt",
                                             in: archive),
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

    func testRenameItemTargetsSelectedDuplicateRecord() throws {
        let (archiveURL, tempRoot) = try makeDuplicatePathArchive(named: "rename-duplicate")
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let selectedEntry = try XCTUnwrap(try duplicateEntries(in: archive).last)
        try archive.renameItem(at: selectedEntry.reference,
                               inArchiveSubdir: "",
                               newName: "renamed.txt",
                               session: nil)

        let entries = archive.entries()
        let remainingDuplicate = try XCTUnwrap(entries.first { $0.path == "duplicate.txt" })
        let renamed = try XCTUnwrap(entries.first { $0.path == "renamed.txt" })
        XCTAssertEqual(try contents(of: remainingDuplicate,
                                    in: archive,
                                    under: tempRoot,
                                    label: "rename-remaining"),
                       "first")
        XCTAssertEqual(try contents(of: renamed,
                                    in: archive,
                                    under: tempRoot,
                                    label: "rename-selected"),
                       "second")
    }

    func testRenameItemRejectsNamesEndingInDotComponents() throws {
        let (archiveURL, _) = try makeArchive(named: "rename-invalid",
                                              payloads: ["old.txt": "contents"])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let itemReference = try reference(forPath: "old.txt",
                                          in: archive)
        for name in [".", "..", "nested/.", "nested/.."] {
            XCTAssertThrowsError(
                try archive.renameItem(at: itemReference,
                                       inArchiveSubdir: "",
                                       newName: name,
                                       session: nil),
                "rename should reject upstream-invalid name: \(name)",
            ) { error in
                XCTAssertEqual((error as NSError).domain, SZArchiveErrorDomain)
            }
        }

        XCTAssertEqual(entryPaths(in: archive), ["old.txt"])
    }

    func testRenameItemAllowsSeparatorsAndSpecialSymbolsLikeUpstream() throws {
        let (archiveURL, _) = try makeArchive(named: "rename-special",
                                              payloads: ["old.txt": "contents"])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        try archive.renameItem(at: reference(forPath: "old.txt",
                                             in: archive),
                               inArchiveSubdir: "",
                               newName: "nested/Renamed File #1 [ok]! @&+=,;.txt",
                               session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertTrue(paths.contains("nested/Renamed File #1 [ok]! @&+=,;.txt"))
        XCTAssertFalse(paths.contains("old.txt"))
    }

    // MARK: - deleteItemsAtReferences

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

        try archive.deleteItems(at: [
            reference(forPath: "a.txt", in: archive),
            reference(forPath: "c.txt", in: archive),
        ],
        inArchiveSubdir: "",
        session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertEqual(paths, ["b.txt"],
                       "only the non-deleted entry should remain")
    }

    func testDeleteItemsTargetsSelectedDuplicateRecord() throws {
        let (archiveURL, tempRoot) = try makeDuplicatePathArchive(named: "delete-duplicate")
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let selectedEntry = try XCTUnwrap(try duplicateEntries(in: archive).last)
        try archive.deleteItems(at: [selectedEntry.reference],
                                inArchiveSubdir: "",
                                session: nil)

        let remainingEntry = try XCTUnwrap(archive.entries().first { $0.path == "duplicate.txt" })
        XCTAssertEqual(try contents(of: remainingEntry,
                                    in: archive,
                                    under: tempRoot,
                                    label: "delete-remaining"),
                       "first")
    }

    func testDeleteItemsCanTargetAllDuplicateRecords() throws {
        let (archiveURL, _) = try makeDuplicatePathArchive(named: "delete-all-duplicates")
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let references = try duplicateEntries(in: archive).map(\.reference)
        try archive.deleteItems(at: references,
                                inArchiveSubdir: "",
                                session: nil)

        XCTAssertFalse(archive.entries().contains { $0.path == "duplicate.txt" })
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

    // MARK: - replaceItemAtReference

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

        try archive.replaceItem(at: reference(forPath: "entry.txt",
                                              in: archive),
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

    func testReplaceItemTargetsSelectedDuplicateRecord() throws {
        let (archiveURL, tempRoot) = try makeDuplicatePathArchive(named: "replace-duplicate")
        let replacementURL = tempRoot.appendingPathComponent("replacement.txt")
        try "replacement".write(to: replacementURL,
                                atomically: true,
                                encoding: .utf8)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let selectedEntry = try XCTUnwrap(try duplicateEntries(in: archive).last)
        try archive.replaceItem(at: selectedEntry.reference,
                                inArchiveSubdir: "",
                                withFileAtPath: replacementURL.path,
                                session: nil)

        let entryContents = try duplicateEntries(in: archive).enumerated().map { offset, entry in
            try contents(of: entry,
                         in: archive,
                         under: tempRoot,
                         label: "replace-\(offset)")
        }
        XCTAssertEqual(entryContents, ["first", "replacement"])
    }

    func testMutationRejectsReferenceFromPreviousArchiveSnapshot() throws {
        let (archiveURL, _) = try makeArchive(
            named: "stale-reference",
            payloads: ["entry.txt": "contents"],
        )
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let staleReference = try reference(forPath: "entry.txt",
                                           in: archive)
        try archive.createFolderNamed("new-folder",
                                      inArchiveSubdir: "",
                                      session: nil)

        XCTAssertThrowsError(
            try archive.renameItem(at: staleReference,
                                   inArchiveSubdir: "",
                                   newName: "renamed.txt",
                                   session: nil),
        )
        XCTAssertTrue(entryPaths(in: archive).contains("entry.txt"))
        XCTAssertFalse(entryPaths(in: archive).contains("renamed.txt"))
    }

    func testLateCancellationReturnsCommittedMutationOutcome() throws {
        let (archiveURL, _) = try makeArchive(
            named: "late-update-cancellation",
            payloads: ["entry.txt": "contents"],
        )
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }
        let reference = try reference(forPath: "entry.txt",
                                      in: archive)
        let session = try CancelAfterReplacementSession(archivePath: archiveURL.path)

        let outcome = try FileManagerArchiveMutationOutcome.perform {
            try archive.renameItem(at: reference,
                                   inArchiveSubdir: "",
                                   newName: "renamed.txt",
                                   session: session)
        }

        XCTAssertTrue(session.requestedCancellationAfterReplacement)
        guard case .archiveCommittedAfterCancellation = outcome else {
            return XCTFail("Expected a committed cancellation outcome")
        }
        XCTAssertTrue(entryPaths(in: archive).contains("renamed.txt"))
        XCTAssertFalse(entryPaths(in: archive).contains("entry.txt"))
    }

    func testCommittedReopenFailureProducesRecoveryOutcome() throws {
        let reopenError = NSError(
            domain: SZArchiveErrorDomain,
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: "reopen failed",
                SZArchiveMutationCommittedErrorKey: true,
                SZArchiveMutationReopenFailedErrorKey: true,
            ],
        )

        let outcome = try FileManagerArchiveMutationOutcome.perform {
            throw reopenError
        }

        guard case let .archiveCommittedAfterError(error, requiresReopen) = outcome else {
            return XCTFail("Expected a committed error outcome")
        }
        XCTAssertTrue(requiresReopen)
        XCTAssertEqual((error as NSError).localizedDescription, "reopen failed")
    }

    func testLateCancellationPreservesMoveSourceAfterArchiveCommit() throws {
        let (archiveURL, tempRoot) = try makeArchive(
            named: "late-move-cancellation",
            payloads: ["existing.txt": "existing"],
        )
        let sourceURL = tempRoot.appendingPathComponent("move-source.txt")
        try "moved".write(to: sourceURL,
                          atomically: true,
                          encoding: .utf8)
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }
        let session = try CancelAfterReplacementSession(archivePath: archiveURL.path)

        XCTAssertThrowsError(
            try archive.addPaths([sourceURL.path],
                                 toArchiveSubdir: "",
                                 moveMode: true,
                                 session: session),
        ) { error in
            XCTAssertTrue(szIsUserCancellation(error))
            XCTAssertTrue(szArchiveMutationWasCommitted(error))
        }

        XCTAssertTrue(session.requestedCancellationAfterReplacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(entryPaths(in: archive).contains("move-source.txt"))
    }

    func testCancellationBeforeCommitIsNotMarkedAsCommitted() throws {
        let (archiveURL, _) = try makeArchive(
            named: "pre-commit-cancellation",
            payloads: ["existing.txt": "existing"],
        )
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }
        let session = SZOperationSession()
        session.requestCancel()

        XCTAssertThrowsError(
            try archive.createFolderNamed("cancelled",
                                          inArchiveSubdir: "",
                                          session: session),
        ) { error in
            XCTAssertTrue(szIsUserCancellation(error))
            XCTAssertFalse(szArchiveMutationWasCommitted(error))
        }

        XCTAssertFalse(entryPaths(in: archive).contains("cancelled"))
    }

    func testRenameSyntheticDirectoryUsesLogicalPathResolution() throws {
        let (archiveURL, _) = try makeArchive(
            named: "rename-synthetic-directory",
            payloads: [
                "implicit/entry.txt": "contents",
                "sibling.txt": "sibling",
            ],
        )
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }
        let snapshotIdentifier = try XCTUnwrap(archive.entrySnapshotIdentifier)
        let reference = SZArchiveItemReference(
            logicalDirectoryPath: "implicit",
            snapshotIdentifier: snapshotIdentifier,
        )

        try archive.renameItem(at: reference,
                               inArchiveSubdir: "",
                               newName: "renamed",
                               session: nil)

        XCTAssertTrue(entryPaths(in: archive).contains("renamed/entry.txt"))
        XCTAssertFalse(entryPaths(in: archive).contains("implicit/entry.txt"))
    }

    func testDeleteSyntheticDirectoryUsesLogicalPathResolution() throws {
        let (archiveURL, _) = try makeArchive(
            named: "delete-synthetic-directory",
            payloads: [
                "implicit/entry.txt": "contents",
                "sibling.txt": "sibling",
            ],
        )
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }
        let snapshotIdentifier = try XCTUnwrap(archive.entrySnapshotIdentifier)
        let reference = SZArchiveItemReference(
            logicalDirectoryPath: "implicit",
            snapshotIdentifier: snapshotIdentifier,
        )

        try archive.deleteItems(at: [reference],
                                inArchiveSubdir: "",
                                session: nil)

        XCTAssertFalse(entryPaths(in: archive).contains("implicit/entry.txt"))
        XCTAssertTrue(entryPaths(in: archive).contains("sibling.txt"))
    }

    // MARK: - Regression: repeated mutations do not corrupt CAgent teardown

    /// Repeated mutations on the same archive should keep working.
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
        try archive.renameItem(at: reference(forPath: "seed.txt",
                                             in: archive),
                               inArchiveSubdir: "",
                               newName: "seed-renamed.txt",
                               session: nil)
        try archive.deleteItems(at: [
            reference(forPath: "loose.txt", in: archive),
        ],
        inArchiveSubdir: "",
        session: nil)

        let paths = entryPaths(in: archive)
        XCTAssertTrue(paths.contains("dir1"))
        XCTAssertTrue(paths.contains("seed-renamed.txt"))
        XCTAssertFalse(paths.contains("loose.txt"))
        XCTAssertFalse(paths.contains("seed.txt"))
    }
}
