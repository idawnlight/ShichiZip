import Darwin
import Foundation
import XCTest
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

/// Guarantees the `getattrlistbulk(2)` fast path is a drop-in replacement for
/// the per-item `URLResourceValues` + `lstat` path: every field that
/// `FileSystemItem`'s `Equatable` conformance compares must agree across a rich
/// fixture of files, directories, symlinks, flags, forks and sub-second times.
final class FileManagerDirectoryBulkEnumerationTests: XCTestCase {
    func testBulkEnumerationMatchesLegacyForRichFixture() throws {
        let root = try makeRichFixture()

        let bulk = try bulkItems(for: root)
        let legacy = try legacyItems(for: root)

        assertEquivalentListings(bulk: bulk, legacy: legacy)
        XCTAssertGreaterThan(bulk.count, 15, "fixture should exercise many entry shapes")
    }

    /// `make(for:)` routes through bulk enumeration, so the production entry
    /// point must produce the same items as the legacy path.
    func testSnapshotMakeMatchesLegacyEnumeration() throws {
        let root = try makeRichFixture()

        let produced = try FileManagerDirectorySnapshot.make(for: root).items
        let legacy = try legacyItems(for: root)

        assertEquivalentListings(bulk: produced, legacy: legacy)
    }

    /// Enumerating through a symbolic link that targets a directory must keep
    /// children presented under the original path in both code paths.
    func testBulkEnumerationMatchesLegacyThroughPresentedSymlinkDirectory() throws {
        let tempRoot = try makeTemporaryDirectory(named: "bulk-presented-symlink")
        let target = tempRoot.appendingPathComponent("target", isDirectory: true)
        let presented = tempRoot.appendingPathComponent("presented", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "payload".write(to: target.appendingPathComponent("payload.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("child", isDirectory: true),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: presented, withDestinationURL: target)

        let produced = try FileManagerDirectorySnapshot.make(for: presented).items
        let legacy = try legacyItems(for: presented)

        assertEquivalentListings(bulk: produced, legacy: legacy)
        XCTAssertEqual(Set(produced.map(\.url.standardizedFileURL.path)),
                       Set([presented.appendingPathComponent("payload.txt").standardizedFileURL.path,
                            presented.appendingPathComponent("child").standardizedFileURL.path]))
    }

    /// Real system directories on the sealed, read-only system volume exercise
    /// the bulk path against entries the synthetic fixture cannot reproduce
    /// (firmlinks, vendor symlinks, code-signed binaries) without TOCTOU risk.
    func testBulkEnumerationMatchesLegacyForSystemDirectories() throws {
        var exercised = 0
        for path in ["/bin", "/sbin", "/usr/lib", "/System/Library/CoreServices"] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard (try? url.checkResourceIsReachable()) == true else { continue }

            let bulk: [FileSystemItem]
            let legacy: [FileSystemItem]
            do {
                bulk = try bulkItems(for: url)
                legacy = try legacyItems(for: url)
            } catch {
                continue
            }
            guard !legacy.isEmpty else { continue }

            assertEquivalentListings(bulk: bulk, legacy: legacy)
            exercised += 1
        }

        try XCTSkipIf(exercised == 0, "No readable system directory was available to compare")
    }

    // MARK: - Fixture

    private func makeRichFixture() throws -> URL {
        let root = try makeTemporaryDirectory(named: "bulk-rich")
        let fm = FileManager.default

        try Data().write(to: root.appendingPathComponent("empty.bin"))
        try "hi".write(to: root.appendingPathComponent("small.txt"), atomically: true, encoding: .utf8)
        try Data(count: 5000).write(to: root.appendingPathComponent("large.bin"))
        try "日本語の名前".write(to: root.appendingPathComponent("日本語.txt"), atomically: true, encoding: .utf8)

        try fm.createDirectory(at: root.appendingPathComponent("emptydir", isDirectory: true),
                               withIntermediateDirectories: true)
        let fullDir = root.appendingPathComponent("fulldir", isDirectory: true)
        try fm.createDirectory(at: fullDir, withIntermediateDirectories: true)
        for index in 0 ..< 200 {
            try Data(count: 8).write(to: fullDir.appendingPathComponent("entry-\(index).dat"))
        }

        try "secret".write(to: root.appendingPathComponent(".hidden_file"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent(".hidden_dir", isDirectory: true),
                               withIntermediateDirectories: true)

        // UF_HIDDEN flag without a leading dot.
        let flagged = root.appendingPathComponent("flagged.bin")
        try Data(count: 16).write(to: flagged)
        try setFlags(UInt32(UF_HIDDEN), at: flagged)

        // Symlinks: to a file, to a directory, and dangling.
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link-to-file").path,
                                  withDestinationPath: "small.txt")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link-to-dir").path,
                                  withDestinationPath: "emptydir")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("broken-link").path,
                                  withDestinationPath: "does-not-exist")

        // Data fork + resource fork + large extended attribute, to stress the
        // all-forks allocated-size mapping.
        let rich = root.appendingPathComponent("rich.bin")
        try Data(count: 5000).write(to: rich)
        try Data(count: 12000).write(to: URL(fileURLWithPath: rich.path + "/..namedfork/rsrc"))
        try setExtendedAttribute("ee.dawn.test", bytes: [UInt8](repeating: 0xAB, count: 20000), at: rich)

        // setgid bit, to confirm full st_mode (format + special bits) round-trips.
        let setgid = root.appendingPathComponent("setgid.bin")
        try Data(count: 4).write(to: setgid)
        try setMode(0o2755, at: setgid)

        // Hard links, to confirm the link count.
        let hardA = root.appendingPathComponent("hardlinked-a.bin")
        try Data(count: 32).write(to: hardA)
        try link(hardA.path, root.appendingPathComponent("hardlinked-b.bin").path).throwIfNonZero()

        // Assorted sub-second modification times, to confirm date precision.
        let nanos = [0, 1, 123, 999_999_999, 500_000_000, 333_333_333, 7]
        for (index, nsec) in nanos.enumerated() {
            let url = root.appendingPathComponent("time-\(index).bin")
            try Data(count: index).write(to: url)
            try setModificationTime(seconds: 1_700_000_000 + index, nanoseconds: nsec, at: url)
        }

        return root
    }

    // MARK: - Listings

    private func bulkItems(for url: URL) throws -> [FileSystemItem] {
        try FileManagerDirectorySnapshot.bulkItems(for: url)
    }

    private func legacyItems(for url: URL) throws -> [FileSystemItem] {
        try FileManagerDirectorySnapshot.legacyItems(for: url)
    }

    // MARK: - Assertions

    private func assertEquivalentListings(bulk: [FileSystemItem],
                                          legacy: [FileSystemItem],
                                          file: StaticString = #filePath,
                                          line: UInt = #line)
    {
        let bulkByName = Dictionary(uniqueKeysWithValues: bulk.map { ($0.name, $0) })
        let legacyByName = Dictionary(uniqueKeysWithValues: legacy.map { ($0.name, $0) })

        XCTAssertEqual(Set(bulkByName.keys), Set(legacyByName.keys),
                       "bulk and legacy enumerations returned different names", file: file, line: line)

        for name in legacyByName.keys.sorted() {
            guard let bulkItem = bulkByName[name], let legacyItem = legacyByName[name] else { continue }
            assertEquivalent(bulkItem, legacyItem, file: file, line: line)
        }
    }

    private func assertEquivalent(_ bulk: FileSystemItem,
                                  _ legacy: FileSystemItem,
                                  file: StaticString = #filePath,
                                  line: UInt = #line)
    {
        let label = legacy.name
        XCTAssertEqual(bulk.url.standardizedFileURL.path, legacy.url.standardizedFileURL.path, "\(label): url", file: file, line: line)
        XCTAssertEqual(bulk.isDirectory, legacy.isDirectory, "\(label): isDirectory", file: file, line: line)
        XCTAssertEqual(bulk.size, legacy.size, "\(label): size", file: file, line: line)
        XCTAssertEqual(bulk.packedSize, legacy.packedSize, "\(label): packedSize", file: file, line: line)
        XCTAssertEqual(bulk.modifiedDate, legacy.modifiedDate, "\(label): modifiedDate", file: file, line: line)
        XCTAssertEqual(bulk.createdDate, legacy.createdDate, "\(label): createdDate", file: file, line: line)
        XCTAssertEqual(bulk.accessedDate, legacy.accessedDate, "\(label): accessedDate", file: file, line: line)
        XCTAssertEqual(bulk.changedDate, legacy.changedDate, "\(label): changedDate", file: file, line: line)
        XCTAssertEqual(bulk.attributes, legacy.attributes, "\(label): attributes", file: file, line: line)
        XCTAssertEqual(bulk.inode, legacy.inode, "\(label): inode", file: file, line: line)
        XCTAssertEqual(bulk.isHidden, legacy.isHidden, "\(label): isHidden", file: file, line: line)

        // `lstat` reports a directory's link count as `2 + entryCount`, while
        // `getattrlistbulk` reports the directory's own (usually 1) link count,
        // so the two agree only for files and symlinks. Skip the link and
        // whole-item equality checks (the latter includes the link count) for
        // directories.
        if !legacy.isDirectory {
            XCTAssertEqual(bulk.links, legacy.links, "\(label): links", file: file, line: line)
            XCTAssertEqual(bulk, legacy, "\(label): Equatable", file: file, line: line)
        }
    }

    // MARK: - Low-level fixture helpers

    private func setFlags(_ flags: UInt32, at url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            try (path.map { chflags($0, flags) } ?? -1).throwIfNonZero()
        }
    }

    private func setMode(_ mode: mode_t, at url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            try (path.map { chmod($0, mode) } ?? -1).throwIfNonZero()
        }
    }

    private func setExtendedAttribute(_ name: String, bytes: [UInt8], at url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw POSIXError(.ENOENT) }
            try bytes.withUnsafeBytes { buffer in
                try setxattr(path, name, buffer.baseAddress, buffer.count, 0, 0).throwIfNonZero()
            }
        }
    }

    private func setModificationTime(seconds: Int, nanoseconds: Int, at url: URL) throws {
        let value = timespec(tv_sec: seconds, tv_nsec: nanoseconds)
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw POSIXError(.ENOENT) }
            var times = [value, value]
            try utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW).throwIfNonZero()
        }
    }
}

private extension Int32 {
    func throwIfNonZero() throws {
        guard self != 0 else { return }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
