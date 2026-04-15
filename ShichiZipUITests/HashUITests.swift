import XCTest

/// Tests for hash/checksum calculation and the details dialog.
final class HashUITests: ShichiZipUITestCase {
    /// Verifies the checksum submenu lists expected algorithms,
    /// computes CRC-32, and checks the result in the details dialog.
    func testHashSubmenuAndCRC32Result() throws {
        let tempDir = try makeTemporaryDirectory(named: "hash")
        // CRC-32 of "hash input" = E982ED18
        try createTextFile(at: tempDir.appendingPathComponent("hashme.txt"), content: "hash input")

        navigateLeftPane(to: tempDir.path)

        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let fileCell = table.cells.staticTexts["hashme.txt"]
        XCTAssertTrue(fileCell.waitForExistence(timeout: 5))
        fileCell.click()

        // Open File menu → Calculate checksum submenu
        app.menuBars.menuBarItems["File"].click()
        let checksumMenu = app.menuBars.menuBarItems["File"].menus.menuItems["Calculate checksum"]
        XCTAssertTrue(checksumMenu.waitForExistence(timeout: 5),
                      "Calculate checksum submenu should exist in File menu")
        checksumMenu.hover()

        // Verify key algorithms are listed
        let crc32Item = checksumMenu.menus.menuItems["CRC-32"]
        XCTAssertTrue(crc32Item.waitForExistence(timeout: 3), "CRC-32 should be in the checksum submenu")
        XCTAssertTrue(checksumMenu.menus.menuItems["SHA-256"].exists, "SHA-256 should be listed")
        XCTAssertTrue(checksumMenu.menus.menuItems["*"].exists, "* (all hashes) should be listed")

        // Click CRC-32 to compute
        crc32Item.click()

        // The details dialog should appear with the hash result
        let okButton = app.buttons.matching(identifier: "modal.button.0").firstMatch
        XCTAssertTrue(okButton.waitForExistence(timeout: 15),
                      "Hash result dialog should appear with an OK button")

        // Verify the dialog contains the expected CRC-32 value
        let expectedCRC = "E982ED18"
        let textView = app.textViews.firstMatch
        XCTAssertTrue(textView.waitForExistence(timeout: 5), "Result text view should exist")
        let text = textView.value as? String ?? ""
        XCTAssertTrue(text.contains(expectedCRC),
                      "Dialog should contain CRC-32 result \(expectedCRC), got: \(text)")

        okButton.click()
        XCTAssertTrue(app.state == .runningForeground)
    }
}
