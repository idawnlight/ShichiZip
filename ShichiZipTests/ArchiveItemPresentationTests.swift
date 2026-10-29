#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class ArchiveItemPresentationTests: XCTestCase {
    func testAttributesPreserveWindowsFlagsAlongsidePosixPermissions() {
        XCTAssertEqual(ArchiveItemPresentation.formattedAttributes(0), "")
        XCTAssertEqual(ArchiveItemPresentation.formattedAttributes(0x0000_0003), "RH")
        XCTAssertEqual(ArchiveItemPresentation.formattedAttributes(0x81ED_8003), "RH -rwxr-xr-x")
    }

    func testAttributesPreserveSetIDAndStickyPermissions() {
        XCTAssertEqual(ArchiveItemPresentation.formattedAttributes(0x89ED_8000), "-rwsr-xr-x")
        XCTAssertEqual(ArchiveItemPresentation.formattedAttributes(0x43FF_8000), "drwxrwxrwt")
    }
}
