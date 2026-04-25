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
