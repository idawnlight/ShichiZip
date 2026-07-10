import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerArchiveStackTests: XCTestCase {
    func testArchiveLevelTopLevelURLOnlyForPhysicalTopLevelArchives() {
        let archiveURL = URL(fileURLWithPath: "/tmp/source.7z")
        let physicalLevel = makeLevel(archivePath: archiveURL.path)
        let temporaryLevel = makeLevel(archivePath: archiveURL.path,
                                       temporaryDirectory: URL(fileURLWithPath: "/tmp/staged"))

        XCTAssertEqual(physicalLevel.topLevelArchiveURL, archiveURL.standardizedFileURL)
        XCTAssertNil(temporaryLevel.topLevelArchiveURL)
    }

    func testArchiveLevelMutationTargetUsesCurrentSubdirAndTopLevelURL() throws {
        let archiveURL = try makeArchive(named: "mutation-target")
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path,
                         session: SZOperationSession())
        defer { archive.close() }

        let level = makeLevel(archivePath: archiveURL.path,
                              archive: archive,
                              currentSubdir: "folder")

        let target = level.mutationTarget(hasConflictingNestedArchiveInstance: { _ in false })

        XCTAssertTrue(target?.archive === level.archive)
        XCTAssertEqual(target?.subdir, "folder")
        XCTAssertEqual(target?.topLevelArchiveURL, archiveURL.standardizedFileURL)
    }

    func testArchiveStackProvidesArrayLikeAccessForCurrentControllerBoundary() {
        var stack = FileManagerArchiveStack()
        let first = makeLevel(archivePath: "/tmp/first.7z")
        let second = makeLevel(archivePath: "/tmp/second.7z")

        stack.append(first)
        stack.append(second)
        stack[1] = stack[1].replacingCurrentSubdir("nested")

        XCTAssertEqual(stack.count, 2)
        XCTAssertEqual(stack.last?.archivePath, "/tmp/second.7z")
        XCTAssertEqual(stack.last?.currentSubdir, "nested")
        XCTAssertEqual(stack.map(\.archivePath), ["/tmp/first.7z", "/tmp/second.7z"])
    }

    func testArchiveStackReplacesEntriesAndFindsArchiveURL() {
        var stack = FileManagerArchiveStack()
        let level = makeLevel(archivePath: "/tmp/source.7z")
        let replacementEntry = makeArchiveItem(index: 1,
                                               path: "folder/payload.txt",
                                               size: 42)

        stack.append(level)
        let didReplace = stack.replaceEntries(at: 0,
                                              with: [replacementEntry],
                                              preservingSubdir: "folder")

        XCTAssertTrue(didReplace)
        XCTAssertEqual(stack.last?.allEntries.map(\.path), ["folder/payload.txt"])
        XCTAssertEqual(stack.last?.statistics.uncompressedSize, 42)
        XCTAssertEqual(stack.last?.currentSubdir, "folder")
        XCTAssertEqual(stack.archiveURL(for: level.archive), URL(fileURLWithPath: "/tmp/source.7z").standardizedFileURL)
    }

    func testArchiveStackBuildsCoordinationSnapshots() {
        var stack = FileManagerArchiveStack()
        let identity = FileManagerNestedArchiveIdentity(displayPath: "/tmp/source.7z/nested.7z")
        let first = makeLevel(archivePath: "/tmp/first.7z",
                              nestedIdentity: identity)
        let second = makeLevel(archivePath: "/tmp/second.7z")

        stack.append(first)
        stack.append(second)

        let snapshots = stack.coordinationSnapshots { level in
            level.archive === first.archive
        }

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].archiveIdentifier, ObjectIdentifier(first.archive))
        XCTAssertEqual(snapshots[0].identity, identity)
        XCTAssertTrue(snapshots[0].isDirty)
        XCTAssertFalse(snapshots[1].isDirty)
    }

    @MainActor
    func testArchiveSessionNavigatesSubdirsAndSynthesizesIntermediateDirectories() {
        let session = FileManagerArchiveSession()
        let archive = SZArchive()
        let prepared = FileManagerPreparedArchiveOpen(hostDirectory: URL(fileURLWithPath: "/tmp"),
                                                      archivePath: "/tmp/source.7z",
                                                      displayPathPrefix: "/tmp/source.7z",
                                                      archive: archive,
                                                      entries: [
                                                          makeArchiveItem(index: 0,
                                                                          path: "real/",
                                                                          isDirectory: true),
                                                          makeArchiveItem(index: 1,
                                                                          path: "real/file.txt"),
                                                          makeArchiveItem(index: 2,
                                                                          path: "implicit/nested.txt"),
                                                      ],
                                                      temporaryDirectory: nil,
                                                      nestedWriteBackInfo: nil)

        session.appendPreparedArchive(prepared)

        XCTAssertEqual(session.displayItems.map(\.path), ["real/", "implicit"])
        XCTAssertEqual(session.displayItems.map(\.isDirectory), [true, true])

        session.navigateSubdir("implicit")

        XCTAssertEqual(session.displayItems.map(\.path), ["implicit/nested.txt"])
    }

    @MainActor
    func testArchiveSessionFiltersHiddenItemsAndTogglesWithoutReloading() {
        var showHidden = false
        let session = FileManagerArchiveSession(showsHiddenFiles: { showHidden })
        let prepared = FileManagerPreparedArchiveOpen(hostDirectory: URL(fileURLWithPath: "/tmp"),
                                                      archivePath: "/tmp/source.7z",
                                                      displayPathPrefix: "/tmp/source.7z",
                                                      archive: SZArchive(),
                                                      entries: [
                                                          makeArchiveItem(index: 0,
                                                                          path: "visible.txt"),
                                                          makeArchiveItem(index: 1,
                                                                          path: ".secret.txt"),
                                                      ],
                                                      temporaryDirectory: nil,
                                                      nestedWriteBackInfo: nil)

        session.appendPreparedArchive(prepared)
        XCTAssertEqual(session.displayItems.map(\.path), ["visible.txt"])

        showHidden = true
        session.applyHiddenVisibilityFilter()
        XCTAssertEqual(Set(session.displayItems.map(\.path)), ["visible.txt", ".secret.txt"])

        showHidden = false
        session.applyHiddenVisibilityFilter()
        XCTAssertEqual(session.displayItems.map(\.path), ["visible.txt"])
    }

    private func makeLevel(archivePath: String,
                           archive: SZArchive = SZArchive(),
                           currentSubdir: String = "",
                           temporaryDirectory: URL? = nil,
                           nestedIdentity: FileManagerNestedArchiveIdentity? = nil,
                           nestedWriteBackInfo: FileManagerNestedArchiveWriteBackInfo? = nil) -> FileManagerArchiveLevel
    {
        FileManagerArchiveLevel(filesystemDirectory: URL(fileURLWithPath: "/tmp"),
                                archivePath: archivePath,
                                displayPathPrefix: archivePath,
                                archive: archive,
                                operationGate: FileManagerArchiveOperationGate(),
                                allEntries: [],
                                entryProperties: [],
                                currentSubdir: currentSubdir,
                                temporaryDirectory: temporaryDirectory,
                                nestedIdentity: nestedIdentity,
                                nestedWriteBackInfo: nestedWriteBackInfo)
    }

    private func makeArchiveItem(index: Int,
                                 path: String,
                                 size: UInt64 = 0,
                                 isDirectory: Bool = false) -> ArchiveItem
    {
        ArchiveItem(index: index,
                    path: path,
                    name: path.split(separator: "/").last.map(String.init) ?? path,
                    size: size,
                    packedSize: 0,
                    modifiedDate: nil,
                    createdDate: nil,
                    accessedDate: nil,
                    crc: 0,
                    isDirectory: isDirectory,
                    isEncrypted: false,
                    isAnti: false,
                    method: "",
                    attributes: 0,
                    position: 0,
                    block: 0,
                    comment: "")
    }
}
