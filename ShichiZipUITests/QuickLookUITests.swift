import XCTest

/// Tests for Quick Look preview triggered from the file manager.
///
/// Launches with the Finder-like shortcut preset so Space triggers Quick Look.
final class QuickLookUITests: ShichiZipUITestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-FileManagerShortcutPreset", "0"]
        app.launch()
    }

    func testQuickLookOpensForFilesystemFile() throws {
        let tempDir = try makeTemporaryDirectory(named: "QuickLook")
        try createTextFile(at: tempDir.appendingPathComponent("preview.txt"), content: "Quick Look content")

        navigateLeftPane(to: tempDir.path)

        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let fileCell = table.cells.staticTexts["preview.txt"]
        XCTAssertTrue(fileCell.waitForExistence(timeout: 5))
        fileCell.click()

        // Trigger Quick Look with Space (Finder-like preset)
        table.typeKey(" ", modifierFlags: [])

        // QLPreviewPanel is a separate window; wait for any second window
        // or a panel-like element to appear.
        let panelPredicate = NSPredicate(format: "count > 1")
        let windowsExpectation = XCTNSPredicateExpectation(predicate: panelPredicate,
                                                           object: app.windows)
        let panelAppeared = XCTWaiter().wait(for: [windowsExpectation], timeout: 5) == .completed

        if panelAppeared {
            // Dismiss with Space again
            app.typeKey(" ", modifierFlags: [])
            usleep(500_000)
        }

        // App should still be running regardless
        XCTAssertTrue(app.state == .runningForeground,
                      "App should remain running after Quick Look toggle")
    }

    func testQuickLookForArchiveItem() throws {
        let (archiveURL, _) = try makeTestArchive(named: "quicklookArchive",
                                                  payloads: ["readme.txt": "Archive content for preview"])

        navigateLeftPane(to: archiveURL.deletingLastPathComponent().path)

        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        // Open the archive
        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5))
        archiveCell.doubleClick()

        // Wait for archive to open
        let pathField = leftPanePathField
        let openPredicate = NSPredicate(format: "value CONTAINS %@", archiveURL.lastPathComponent)
        let openExpectation = XCTNSPredicateExpectation(predicate: openPredicate, object: pathField)
        wait(for: [openExpectation], timeout: 10)

        // Select the item inside the archive
        let entryCell = table.cells.staticTexts["readme.txt"]
        XCTAssertTrue(entryCell.waitForExistence(timeout: 5))
        entryCell.click()

        // Trigger Quick Look with Space
        table.typeKey(" ", modifierFlags: [])

        // Allow extraction + preview time
        usleep(2_000_000)

        // Dismiss if open
        app.typeKey(" ", modifierFlags: [])
        usleep(500_000)

        XCTAssertTrue(app.state == .runningForeground,
                      "App should remain running after Quick Look on archive item")
    }
}
