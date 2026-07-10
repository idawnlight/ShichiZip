import AppKit
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class SettingsTextInputTests: XCTestCase {
    func testFileTypeSearchDisablesAutomaticTextCompletion() {
        let searchField = SettingsSearchFieldControl(frame: .zero)

        XCTAssertFalse(searchField.isAutomaticTextCompletionEnabled)
    }

    func testFileManagerAddressBarDisablesAutomaticTextCompletion() {
        let paneView = FileManagerPaneView(
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser,
            addressBarIconSize: 16,
            listRowHeight: 22,
        )

        XCTAssertFalse(paneView.pathField.isAutomaticTextCompletionEnabled)
    }
}
