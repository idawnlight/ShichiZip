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
}
