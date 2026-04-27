#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerViewPreferencesTests: XCTestCase {
    func testMakeDateFormatterReturnsIndependentInstances() {
        let first = FileManagerViewPreferences.makeDateFormatter(dateStyle: .medium,
                                                                 timeStyle: .medium)
        let second = FileManagerViewPreferences.makeDateFormatter(dateStyle: .medium,
                                                                  timeStyle: .medium)

        XCTAssertFalse(first === second)
        XCTAssertEqual(first.string(from: Date(timeIntervalSince1970: 1_713_635_445)),
                       second.string(from: Date(timeIntervalSince1970: 1_713_635_445)))
    }

    func testMakeListDateFormatterReturnsIndependentInstances() {
        let first = FileManagerViewPreferences.makeListDateFormatter()
        let second = FileManagerViewPreferences.makeListDateFormatter()

        XCTAssertFalse(first === second)
        XCTAssertEqual(first.string(from: Date(timeIntervalSince1970: 1_713_635_445)),
                       second.string(from: Date(timeIntervalSince1970: 1_713_635_445)))
    }
}

final class FileManagerColumnTests: XCTestCase {
    func testFileSystemColumnsRemainFixed() {
        XCTAssertEqual(FileManagerColumn.fileSystemColumns.map(\.id), [.name, .size, .modified, .created])
    }

    func testArchiveColumnsFollowSupportedPropertyOrder() {
        let columns = FileManagerColumn.archiveColumns(availablePropertyKeys: [
            "crc",
            "method",
            "size",
            "unknown",
            "name",
            "encrypted",
            "accessed",
            "block",
            "position",
            "anti",
            "size",
            "packedSize",
        ])

        XCTAssertEqual(columns.map(\.id), [.name, .size, .packedSize, .accessed, .encrypted, .method, .crc, .block, .position, .anti])
    }

    func testArchiveColumnsAlwaysIncludeName() {
        XCTAssertEqual(FileManagerColumn.archiveColumns(availablePropertyKeys: []).map(\.id), [.name])
    }

    func testColumnAlignmentFollowsUpstreamPropertyTypes() {
        XCTAssertEqual(FileManagerColumn.definition(for: .method).alignment, .left)
        XCTAssertEqual(FileManagerColumn.definition(for: .comment).alignment, .left)
        XCTAssertEqual(FileManagerColumn.definition(for: .modified).alignment, .left)
        XCTAssertEqual(FileManagerColumn.definition(for: .crc).alignment, .right)
        XCTAssertEqual(FileManagerColumn.definition(for: .attributes).alignment, .right)
        XCTAssertEqual(FileManagerColumn.definition(for: .encrypted).alignment, .right)
        XCTAssertEqual(FileManagerColumn.definition(for: .anti).alignment, .right)
    }

    func testColumnTextStylesSeparateNumbersAndFixedWidthFields() {
        XCTAssertEqual(FileManagerColumn.definition(for: .method).textStyle, .standard)
        XCTAssertEqual(FileManagerColumn.definition(for: .size).textStyle, .tabularNumbers)
        XCTAssertEqual(FileManagerColumn.definition(for: .modified).textStyle, .tabularNumbers)
        XCTAssertEqual(FileManagerColumn.definition(for: .crc).textStyle, .fixedWidth)
        XCTAssertEqual(FileManagerColumn.definition(for: .attributes).textStyle, .fixedWidth)
    }

    func testColumnDisplayStringsFlattenLineBreaks() {
        let column = FileManagerColumn.definition(for: .comment)

        XCTAssertEqual(column.normalizedDisplayString("alpha\nbeta\rgamma\r\ndelta\u{2028}epsilon"),
                       "alpha beta gamma delta epsilon")
        XCTAssertEqual(column.normalizedDisplayString("plain text"), "plain text")
    }

    func testArchiveExposesEntryPropertyKeysFromHandler() throws {
        let archiveURL = try makeArchive(named: "entry-property-keys")
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let keys = Set(archive.entryPropertyKeys)
        XCTAssertTrue(keys.contains("name"))
        XCTAssertTrue(keys.contains("size"))
        XCTAssertTrue(keys.contains("modified"))
    }
}

final class FileManagerDirectoryListingTests: XCTestCase {
    func testEntriesPreservePresentedSymlinkDirectoryPath() throws {
        let tempRoot = try makeTemporaryDirectory(named: "directory-listing-symlink")
        let targetDirectory = tempRoot.appendingPathComponent("target", isDirectory: true)
        let presentedDirectory = tempRoot.appendingPathComponent("presented", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: presentedDirectory, withDestinationURL: targetDirectory)

        let childDirectory = targetDirectory.appendingPathComponent("child", isDirectory: true)
        let childFile = targetDirectory.appendingPathComponent("payload.txt")
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        try "payload".write(to: childFile, atomically: true, encoding: .utf8)

        let entries = try FileManagerDirectoryListing.entriesPreservingPresentedPath(for: presentedDirectory,
                                                                                     options: [])
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }

        XCTAssertEqual(entries.map { $0.url.deletingLastPathComponent().standardizedFileURL },
                       [presentedDirectory.standardizedFileURL, presentedDirectory.standardizedFileURL])
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["child", "payload.txt"])
        XCTAssertEqual(entries.map { $0.resourceValues?.isDirectory }, [true, false])
    }
}
