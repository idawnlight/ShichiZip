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

    func testPreparedExtractionReportsAutoRenamedFilesInsteadOfExistingFiles() throws {
        for overwriteMode in [SZOverwriteMode.ask, .rename] {
            let prepared = try makePreparedExtraction(names: ["report.txt"],
                                                      overwriteMode: overwriteMode)
            let existingURL = prepared.destinationURL.appendingPathComponent("report.txt")
            try Data("existing".utf8).write(to: existingURL)
            let session = SZOperationSession()
            var askedToOverwrite = false
            session.choiceRequestHandler = { _ in
                askedToOverwrite = true
                return 4
            }

            let outputs = try prepared.perform(session: session, collectOutputURLs: true)

            XCTAssertEqual(outputs.count, 1)
            let extractedURL = try XCTUnwrap(outputs.first)
            XCTAssertNotEqual(extractedURL.path, existingURL.path)
            XCTAssertEqual(try Data(contentsOf: extractedURL), Data("report.txt".utf8))
            XCTAssertEqual(try Data(contentsOf: existingURL), Data("existing".utf8))
            XCTAssertEqual(askedToOverwrite, overwriteMode == .ask)
            XCTAssertEqual(FileOperationTransferReveal.itemURLs(for: outputs, in: prepared.destinationURL).map(\.path),
                           [extractedURL.path])
        }
    }

    func testPreparedExtractionReportsEveryOutputBeyondTheDialogPreviewLimit() throws {
        let names = (1 ... 8).map { "item-\($0).txt" }
        let prepared = try makePreparedExtraction(names: names)

        let outputs = try prepared.perform(session: nil, collectOutputURLs: true)
        let revealedItems = FileOperationTransferReveal.itemURLs(for: outputs, in: prepared.destinationURL)

        XCTAssertEqual(outputs.count, names.count)
        XCTAssertEqual(Set(outputs.map(\.lastPathComponent)), Set(names))
        XCTAssertEqual(revealedItems.count, names.count)
        XCTAssertEqual(Set(revealedItems.map(\.lastPathComponent)), Set(names))
    }

    func testPreparedExtractionOmitsSkippedFiles() throws {
        let prepared = try makePreparedExtraction(names: ["existing.txt", "new.txt"],
                                                  overwriteMode: .skip)
        let existingURL = prepared.destinationURL.appendingPathComponent("existing.txt")
        try Data("preserved".utf8).write(to: existingURL)

        let outputs = try prepared.perform(session: nil, collectOutputURLs: true)

        XCTAssertEqual(outputs.map(\.lastPathComponent), ["new.txt"])
        XCTAssertEqual(try Data(contentsOf: existingURL), Data("preserved".utf8))
    }

    func testPreparedExtractionHasNothingToRevealWhenEveryFileIsSkipped() throws {
        let prepared = try makePreparedExtraction(names: ["existing.txt"],
                                                  overwriteMode: .skip)
        try Data("preserved".utf8).write(to: prepared.destinationURL.appendingPathComponent("existing.txt"))

        let outputs = try prepared.perform(session: nil, collectOutputURLs: true)

        XCTAssertTrue(outputs.isEmpty)
        XCTAssertTrue(FileOperationTransferReveal.itemURLs(for: outputs, in: prepared.destinationURL).isEmpty)
    }

    func testPreparedExtractionReturnsPublishedRatherThanStagingURLs() throws {
        let names = ["first.txt", "second.txt"]
        let prepared = try makePreparedExtraction(names: names, destinationExists: false)

        let outputs = try prepared.perform(session: nil, collectOutputURLs: true)

        XCTAssertEqual(Set(outputs.map(\.path)),
                       Set(names.map { prepared.destinationURL.appendingPathComponent($0).path }))
        for output in outputs {
            XCTAssertEqual(try Data(contentsOf: output), Data(output.lastPathComponent.utf8))
        }
        let remainingItems = try FileManager.default.contentsOfDirectory(atPath: prepared.destinationURL.deletingLastPathComponent().path)
        XCTAssertFalse(remainingItems.contains { $0.hasPrefix(FileManagerTemporaryDirectorySupport.extractionSidecarPrefix) })
    }

    func testPreparedExtractionCanSkipOutputCollection() throws {
        let prepared = try makePreparedExtraction(names: ["payload.txt"], destinationExists: false)

        let outputs = try prepared.perform(session: nil, collectOutputURLs: false)

        XCTAssertTrue(outputs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: prepared.destinationURL.appendingPathComponent("payload.txt")),
                       Data("payload.txt".utf8))
    }

    func testPreparedExtractionReportsEmptyDirectoriesAndSymbolicLinks() throws {
        let root = try makeTemporaryDirectory(named: "extraction-output-links")
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty", isDirectory: true),
                                                withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: source.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path,
                                                   withDestinationPath: "file.txt")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("dangling").path,
                                                   withDestinationPath: "missing.txt")
        let archiveURL = root.appendingPathComponent("source.zip")
        try createZipFixture(at: archiveURL,
                             currentDirectory: source,
                             entryPaths: ["empty/", "file.txt", "link", "dangling"],
                             preserveSymlinks: true)
        let prepared = try makePreparedExtraction(archiveURL: archiveURL,
                                                  destinationURL: root.appendingPathComponent("Destination", isDirectory: true))

        let outputs = try prepared.perform(session: nil, collectOutputURLs: true)

        XCTAssertEqual(Set(outputs.map(\.lastPathComponent)), ["empty", "file.txt", "link", "dangling"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: prepared.destinationURL.appendingPathComponent("link").path),
                       "file.txt")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: prepared.destinationURL.appendingPathComponent("dangling").path),
                       "missing.txt")
        XCTAssertEqual(FileOperationTransferReveal.itemURLs(for: outputs, in: prepared.destinationURL).count, 4)
    }

    func testOutputCollectionPropagatesExtractionFailure() throws {
        let destination = try makeTemporaryDirectory(named: "extraction-output-failure")

        XCTAssertThrowsError(try SZArchive().extractEntriesWithOutputURLs([0],
                                                                          toPath: destination.path,
                                                                          settings: SZExtractionSettings(),
                                                                          session: nil))
    }

    func testRevealSelectionCollapsesNestedOutputsAndKeepsExternalPaths() {
        let destination = URL(fileURLWithPath: "/tmp/output", isDirectory: true)
        let external = URL(fileURLWithPath: "/tmp/output-other/file.txt")
        let outputs = [
            destination.appendingPathComponent("folder/first.txt"),
            destination.appendingPathComponent("folder/second.txt"),
            destination.appendingPathComponent("file.txt"),
            destination.appendingPathComponent("file.txt"),
            external,
        ]

        XCTAssertEqual(FileOperationTransferReveal.itemURLs(for: outputs, in: destination).map(\.path),
                       [destination.appendingPathComponent("folder").path,
                        destination.appendingPathComponent("file.txt").path,
                        external.path])
    }

    private func makePreparedExtraction(names: [String],
                                        destinationExists: Bool = true,
                                        overwriteMode: SZOverwriteMode = .ask) throws -> FileManagerPreparedExtraction
    {
        let root = try makeTemporaryDirectory(named: "extraction-output-paths")
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        if destinationExists {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }
        let sourceURLs = names.map { source.appendingPathComponent($0) }
        for sourceURL in sourceURLs {
            try Data(sourceURL.lastPathComponent.utf8).write(to: sourceURL)
        }
        let archiveURL = root.appendingPathComponent("source.7z")
        try createArchive(at: archiveURL, from: sourceURLs)
        return try makePreparedExtraction(archiveURL: archiveURL,
                                          destinationURL: destination,
                                          overwriteMode: overwriteMode)
    }

    private func makePreparedExtraction(archiveURL: URL,
                                        destinationURL: URL,
                                        overwriteMode: SZOverwriteMode = .ask) throws -> FileManagerPreparedExtraction
    {
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        addTeardownBlock { archive.close() }
        let entries = try FileManagerArchiveListing.items(from: archive, session: nil)
        let context = FileManagerArchiveExtractionContext(archive: archive,
                                                          allEntries: entries,
                                                          currentSubdir: "",
                                                          quarantineSourceArchivePath: nil)
        return try XCTUnwrap(FileManagerArchiveExtraction.prepare(items: entries,
                                                                  context: context,
                                                                  destinationURL: destinationURL,
                                                                  overwriteMode: overwriteMode,
                                                                  pathMode: .currentPaths,
                                                                  password: nil,
                                                                  preserveNtSecurityInfo: false,
                                                                  eliminateDuplicates: false,
                                                                  inheritDownloadedFileQuarantine: false))
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
