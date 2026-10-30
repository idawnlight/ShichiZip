import AppKit
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class PasswordFieldTests: XCTestCase {
    func testVisibilityChangesPreserveValuesAndWhitespace() {
        let field = SZPasswordField(value: "", placeholder: "", accessibilityIdentifier: "password")
        field.visibleField.stringValue = " \t\n"
        field.showsPassword = true
        XCTAssertEqual(field.stringValue, " \t\n")
        field.visibleField.stringValue = "  secret  "
        field.showsPassword = false
        XCTAssertEqual(field.stringValue, "  secret  ")
    }

    func testSwitchPreservesConfirmationFocusAndSelection() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let password = SZPasswordField(value: "password", placeholder: "", accessibilityIdentifier: "password")
        let confirmation = SZPasswordField(value: "confirmation", placeholder: "", accessibilityIdentifier: "confirmation")
        window.contentView?.addSubview(password)
        window.contentView?.addSubview(confirmation)
        password.frame.origin.y = 50
        confirmation.frame.origin.y = 10
        confirmation.setShowsPassword(false, moveFocus: true)
        let editor = try XCTUnwrap(confirmation.visibleField.currentEditor())
        XCTAssertTrue(window.firstResponder === editor)
        editor.selectedRange = NSRange(location: 2, length: 4)
        for shown in [true, false] {
            password.showsPassword = shown
            confirmation.showsPassword = shown
            let currentEditor = try XCTUnwrap(confirmation.visibleField.currentEditor())
            XCTAssertTrue(window.firstResponder === currentEditor)
            XCTAssertEqual(currentEditor.selectedRange, NSRange(location: 2, length: 4))
            XCTAssertNil(password.visibleField.currentEditor())
        }
        XCTAssertEqual(confirmation.stringValue, "confirmation")
    }
}
