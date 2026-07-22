import XCTest

final class OperationProgressWindowUITests: ShichiZipUITestCase {
    func testRealUnreadableInputProducesAcknowledgedWarningOutcome() throws {
        let tempDirectory = try makeTemporaryDirectory(named: "ProgressWarnings")
        let readableURL = tempDirectory.appendingPathComponent("readable.txt")
        let unreadableURL = tempDirectory.appendingPathComponent("unreadable.txt")
        try createTextFile(at: readableURL, content: "readable")
        try createTextFile(at: unreadableURL, content: "must not be archived")
        try FileManager.default.setAttributes([.posixPermissions: 0],
                                              ofItemAtPath: unreadableURL.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: unreadableURL.path)
        }

        navigateLeftPane(to: tempDirectory.path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let readableCell = table.cells.staticTexts[readableURL.lastPathComponent]
        let unreadableCell = table.cells.staticTexts[unreadableURL.lastPathComponent]
        XCTAssertTrue(readableCell.waitForExistence(timeout: 5))
        XCTAssertTrue(unreadableCell.waitForExistence(timeout: 5))
        readableCell.click()
        XCUIElement.perform(withKeyModifiers: .command) {
            unreadableCell.click()
        }

        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["Add"].click()

        let archivePathField = app.comboBoxes.matching(
            identifier: "compress.archivePath",
        ).firstMatch
        XCTAssertTrue(archivePathField.waitForExistence(timeout: 5))

        let formatPopup = app.popUpButtons.matching(
            identifier: "compress.format",
        ).firstMatch
        XCTAssertTrue(formatPopup.exists)
        formatPopup.click()
        formatPopup.menuItems["zip"].click()

        let zipPathExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value ENDSWITH '.zip'"),
            object: archivePathField,
        )
        wait(for: [zipPathExpectation], timeout: 5)
        let archivePath = try XCTUnwrap(archivePathField.value as? String)
        let archiveURL = URL(fileURLWithPath: archivePath)

        let compressButton = app.buttons.matching(
            identifier: "modal.button.1",
        ).firstMatch
        XCTAssertTrue(compressButton.exists)
        compressButton.click()

        let status = app.staticTexts.matching(
            identifier: "operationProgress.status",
        ).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        let statusValue = status.value as? String
        let displayedStatus = (statusValue?.isEmpty == false ? statusValue : nil)
            ?? status.label
        XCTAssertEqual(displayedStatus, "Completed with warnings")

        let warnings = app.descendants(matching: .any).matching(
            identifier: "operationProgress.issues",
        ).firstMatch
        XCTAssertTrue(warnings.waitForExistence(timeout: 5))
        let issuePath = warnings.descendants(matching: .staticText).matching(
            NSPredicate(
                format: "label == %@ OR value == %@",
                unreadableURL.path,
                unreadableURL.path,
            ),
        ).firstMatch
        XCTAssertTrue(issuePath.waitForExistence(timeout: 5))

        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadableURL.path),
                      "A skipped input must remain on disk")
        XCTAssertTrue(waitForFile(at: archiveURL),
                      "The readable input should still produce a committed archive")

        let close = app.buttons.matching(
            identifier: "operationProgress.close",
        ).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        XCTAssertFalse(status.waitForExistence(timeout: 1))

        let archivedPaths = try listArchiveContents(archiveURL)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertTrue(archivedPaths.contains(readableURL.lastPathComponent))
        XCTAssertFalse(archivedPaths.contains(unreadableURL.lastPathComponent))
    }
}
