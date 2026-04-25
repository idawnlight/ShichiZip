import Foundation
import XCTest

final class BridgeStringConversionTests: XCTestCase {
    func testBridgeStringRoundTripPreservesNonBMPCharacters() {
        let source = "folder/emoji-🔒/han-𠜎.txt"

        XCTAssertEqual(SZTestBridgeRoundTripString(source), source)
    }

    func testNSFromCStringFallsBackToMacRomanForInvalidUTF8() throws {
        let bytes = Data([0x80, 0x81, 0x82])
        let expected = try XCTUnwrap(String(data: bytes, encoding: .macOSRoman))

        XCTAssertEqual(SZTestBridgeDecodeCStringData(bytes), expected)
    }

    func testCorrectedFileSystemRelativePathUsesUpstreamExtractionRules() {
        XCTAssertEqual(
            SZArchive.correctedFileSystemRelativePath(forArchivePath: "../payload.txt", isDirectory: false),
            "payload.txt",
        )
        XCTAssertEqual(
            SZArchive.correctedFileSystemRelativePath(forArchivePath: "safe/../payload.txt", isDirectory: false),
            "safe/payload.txt",
        )
        XCTAssertEqual(
            SZArchive.correctedFileSystemRelativePath(forArchivePath: ".", isDirectory: false),
            "_",
        )
        XCTAssertEqual(
            SZArchive.correctedFileSystemRelativePath(forArchivePath: ".", isDirectory: true),
            "",
        )
    }
}
