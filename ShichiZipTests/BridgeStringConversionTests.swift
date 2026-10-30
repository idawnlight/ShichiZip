import Foundation
import XCTest

final class BridgeStringConversionTests: XCTestCase {
    func testBridgeStringRoundTripPreservesNonBMPCharacters() {
        let source = "folder/emoji-🔒/han-𠜎.txt"

        XCTAssertEqual(SZTestBridgeRoundTripString(source), source)
    }

    func testBridgeConversionsPreserveUTF16CodeUnitsAndEmbeddedNulls() {
        let source = "\0folder/🔒\0𠜎.txt\0"
        let expectedUnits = Array(source.utf16)

        XCTAssertEqual(SZTestBridgeUStringCodeUnits(source).map(\.uint32Value), expectedUnits.map(UInt32.init))
        XCTAssertEqual(SZTestBridgeStringFromUStringCodeUnits(expectedUnits.map { NSNumber(value: $0) }), source)
        XCTAssertEqual(SZTestBridgeRoundTripString(source), source)
    }

    func testBridgeConversionsPreserveLongUTF16Buffers() {
        let source = String(repeating: "路径/🔒\0", count: 100)
        let expectedUnits = Array(source.utf16)
        XCTAssertGreaterThan(expectedUnits.count, 256)

        XCTAssertEqual(SZTestBridgeUStringCodeUnits(source).map(\.uint32Value), expectedUnits.map(UInt32.init))
        XCTAssertEqual(SZTestBridgeStringFromUStringCodeUnits(expectedUnits.map { NSNumber(value: $0) }), source)
        XCTAssertEqual(SZTestBridgeRoundTripString(source), source)
    }

    func testBridgeConversionsHandleEmptyAndNilInput() {
        XCTAssertEqual(SZTestBridgeRoundTripString(""), "")
        XCTAssertEqual(SZTestBridgeRoundTripString(nil), "")
        XCTAssertTrue(SZTestBridgeUStringCodeUnits("").isEmpty)
        XCTAssertEqual(SZTestBridgeStringFromUStringCodeUnits([]), "")
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
