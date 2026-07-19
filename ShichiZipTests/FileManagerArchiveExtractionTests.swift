#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerArchiveExtractionTests: XCTestCase {
    func testEntryIndicesExpandDirectorySelections() {
        let directory = makeArchiveItem(index: 1,
                                        path: "payload/",
                                        isDirectory: true)
        let child = makeArchiveItem(index: 2,
                                    path: "payload/file.txt")
        let nestedChild = makeArchiveItem(index: 3,
                                          path: "payload/nested/file.txt")
        let sibling = makeArchiveItem(index: 4,
                                      path: "other.txt")

        let indices = FileManagerArchiveExtraction.entryIndices(for: [directory],
                                                                allEntries: [directory, child, nestedChild, sibling])

        XCTAssertEqual(indices.map(\.intValue), [1, 2, 3])
    }

    func testEntryIndicesExpandSyntheticDirectorySelections() {
        let syntheticDirectory = makeArchiveItem(index: -1,
                                                 path: "payload/nested",
                                                 isDirectory: true)
        let nestedChild = makeArchiveItem(index: 3,
                                          path: "payload/nested/file.txt")
        let sibling = makeArchiveItem(index: 4,
                                      path: "payload/other.txt")

        let indices = FileManagerArchiveExtraction.entryIndices(for: [syntheticDirectory],
                                                                allEntries: [nestedChild, sibling])

        XCTAssertEqual(indices.map(\.intValue), [3])
    }

    func testEntryIndicesUseArchiveHierarchyComponentIdentity() {
        let composedDirectoryName = "caf\u{00E9}"
        let decomposedDirectoryName = "cafe\u{0301}"
        let syntheticDirectory = makeArchiveItem(index: -1,
                                                 path: composedDirectoryName,
                                                 isDirectory: true)
        let selectedChild = makeArchiveItem(index: 3,
                                            path: "\(composedDirectoryName)/selected.txt")
        let canonicallyEquivalentSibling = makeArchiveItem(
            index: 4,
            path: "\(decomposedDirectoryName)/sibling.txt",
        )
        XCTAssertNotEqual(
            SZArchive.fileNameComparisonKey(forArchivePathComponent: composedDirectoryName),
            SZArchive.fileNameComparisonKey(forArchivePathComponent: decomposedDirectoryName),
        )

        let indices = FileManagerArchiveExtraction.entryIndices(
            for: [syntheticDirectory],
            allEntries: [selectedChild, canonicallyEquivalentSibling],
        )

        XCTAssertEqual(indices.map(\.intValue), [3])
    }

    func testPathPrefixUsesCurrentSubdirAndDuplicateRoot() {
        let context = makeContext(currentSubdir: "root")
        let destinationURL = URL(fileURLWithPath: "/tmp/Payload", isDirectory: true)
        let items = [makeArchiveItem(index: 1,
                                     path: "root/Payload/file.txt")]

        XCTAssertEqual(FileManagerArchiveExtraction.pathPrefixToStrip(for: items,
                                                                      context: context,
                                                                      destinationURL: destinationURL,
                                                                      pathMode: .currentPaths,
                                                                      eliminateDuplicates: false),
                       "root")
        XCTAssertEqual(FileManagerArchiveExtraction.pathPrefixToStrip(for: items,
                                                                      context: context,
                                                                      destinationURL: destinationURL,
                                                                      pathMode: .currentPaths,
                                                                      eliminateDuplicates: true),
                       "root/Payload")
    }

    func testPrepareBuildsPreparedExtractionSettings() throws {
        let item = makeArchiveItem(index: 7,
                                   path: "root/Payload/file.txt")
        let context = makeContext(allEntries: [item],
                                  currentSubdir: "root",
                                  quarantineSourceArchivePath: "/tmp/source.7z")
        let destinationURL = URL(fileURLWithPath: "/tmp/Payload", isDirectory: true)

        let prepared = try XCTUnwrap(FileManagerArchiveExtraction.prepare(items: [item],
                                                                          context: context,
                                                                          destinationURL: destinationURL,
                                                                          overwriteMode: .ask,
                                                                          pathMode: .currentPaths,
                                                                          password: "secret",
                                                                          preserveNtSecurityInfo: true,
                                                                          eliminateDuplicates: true,
                                                                          inheritDownloadedFileQuarantine: true))

        XCTAssertEqual(prepared.entryIndices.map(\.intValue), [7])
        XCTAssertEqual(prepared.destinationURL.path, destinationURL.path)
        XCTAssertEqual(prepared.settings.pathPrefixToStrip, "root/Payload")
        XCTAssertEqual(prepared.settings.sourceArchivePathForQuarantine, "/tmp/source.7z")
        XCTAssertEqual(prepared.settings.password, "secret")
        XCTAssertTrue(prepared.settings.preserveNtSecurityInfo)
    }

    private func makeContext(allEntries: [ArchiveItem] = [],
                             currentSubdir: String = "",
                             quarantineSourceArchivePath: String? = nil) -> FileManagerArchiveExtractionContext
    {
        FileManagerArchiveExtractionContext(archive: SZArchive(),
                                            allEntries: allEntries,
                                            currentSubdir: currentSubdir,
                                            quarantineSourceArchivePath: quarantineSourceArchivePath)
    }

    private func makeArchiveItem(index: Int,
                                 path: String,
                                 isDirectory: Bool = false) -> ArchiveItem
    {
        ArchiveItem(index: index,
                    path: path,
                    name: path.split(separator: "/").last.map(String.init) ?? path,
                    size: 0,
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
