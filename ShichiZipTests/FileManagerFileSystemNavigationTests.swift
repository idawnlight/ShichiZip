#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerFileSystemNavigationTests: XCTestCase {
    func testAddressBarTreatsSystemTemporaryDirectoryAsDirectory() throws {
        let url = try directoryTarget(for: "/tmp")

        XCTAssertEqual(url.path, "/tmp")
    }

    func testAddressBarPreservesPresentedDirectorySymlink() throws {
        let root = try makeTemporaryDirectory(named: "address-directory-symlink")
        let target = root.appendingPathComponent("target", isDirectory: true)
        let presented = root.appendingPathComponent("presented", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: presented, withDestinationURL: target)

        let url = try directoryTarget(for: presented.path)

        XCTAssertEqual(url.standardizedFileURL.path, presented.standardizedFileURL.path)
    }

    func testAddressBarKeepsFileSymlinkAsFile() throws {
        let root = try makeTemporaryDirectory(named: "address-file-symlink")
        let target = root.appendingPathComponent("target.txt")
        let presented = root.appendingPathComponent("presented.txt")
        try "payload".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: presented, withDestinationURL: target)

        guard case let .file(url, hostDirectory)? =
            FileManagerFileSystemNavigation.addressBarTarget(for: presented.path)
        else {
            return XCTFail("Expected a file target for a symbolic link to a file")
        }

        XCTAssertEqual(url.standardizedFileURL, presented.standardizedFileURL)
        XCTAssertEqual(hostDirectory.standardizedFileURL, root.standardizedFileURL)
    }

    private func directoryTarget(for path: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws -> URL
    {
        guard case let .directory(url)? =
            FileManagerFileSystemNavigation.addressBarTarget(for: path)
        else {
            XCTFail("Expected a directory target for \(path)", file: file, line: line)
            throw CocoaError(.fileReadUnknown)
        }
        return url
    }
}
