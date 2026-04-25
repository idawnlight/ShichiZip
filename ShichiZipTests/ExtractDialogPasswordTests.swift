import XCTest

#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

final class ExtractDialogPasswordTests: XCTestCase {
    func testEmptyPasswordMeansNoPassword() {
        XCTAssertNil(ExtractDialogController.normalizedPassword(from: ""))
    }

    func testPasswordPreservesLeadingAndTrailingWhitespace() {
        XCTAssertEqual(ExtractDialogController.normalizedPassword(from: "  secret \n"), "  secret \n")
    }

    func testWhitespaceOnlyPasswordIsPreserved() {
        XCTAssertEqual(ExtractDialogController.normalizedPassword(from: " \t\n"), " \t\n")
    }
}
