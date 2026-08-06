import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerArchiveListingTests: XCTestCase {
    // Zstandard frame containing "payload" with no frame content-size field.
    private static let unknownContentSizeZstd = Data([
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x39, 0x00, 0x00, 0x70,
        0x61, 0x79, 0x6C, 0x6F, 0x61, 0x64, 0x5C, 0x2C, 0x22, 0x73,
    ])

    func testUnknownZstdContentSizeRemainsUndefined() throws {
        let tempRoot = try makeTemporaryDirectory(named: "archive-listing-unknown-size")
        let archiveURL = tempRoot.appendingPathComponent("payload.zst")
        try Self.unknownContentSizeZstd.write(to: archiveURL)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        defer { archive.close() }

        let item = try XCTUnwrap(FileManagerArchiveListing.items(from: archive,
                                                                 session: nil).first)

        XCTAssertNil(item.size)
        XCTAssertEqual(item.formattedSize, "")
        XCTAssertNil(item.packedSize)
        XCTAssertEqual(item.formattedPackedSize, "")
        XCTAssertThrowsError(
            try FileManagerQuickLookPreparation.validateArchiveItems(
                [item],
                archiveHasActiveOperations: false,
                isSolidArchive: false,
                archiveSizeProvider: { 0 },
                maxArchiveItemSize: 1,
                maxArchiveCombinedSize: 1,
                maxSolidArchiveSize: 1,
            ),
        )
    }

    func testZeroByteArchiveEntryRetainsDefinedSize() throws {
        let tempRoot = try makeTemporaryDirectory(named: "archive-listing-zero-size")
        let payloadURL = tempRoot.appendingPathComponent("empty.txt")
        let archiveURL = tempRoot.appendingPathComponent("payload.7z")
        try Data().write(to: payloadURL)
        try createArchive(at: archiveURL, from: [payloadURL])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        defer { archive.close() }

        let items = try FileManagerArchiveListing.items(from: archive,
                                                        session: nil)

        let payloadItem = try XCTUnwrap(items.first { $0.name == "empty.txt" && !$0.isDirectory })
        XCTAssertEqual(payloadItem.size, 0)
        let zeroText = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
        XCTAssertEqual(payloadItem.formattedSize, zeroText)
        XCTAssertNoThrow(
            try FileManagerQuickLookPreparation.validateArchiveItems(
                [payloadItem],
                archiveHasActiveOperations: false,
                isSolidArchive: false,
                archiveSizeProvider: { 0 },
                maxArchiveItemSize: 1,
                maxArchiveCombinedSize: 1,
                maxSolidArchiveSize: 1,
            ),
        )
    }
}
