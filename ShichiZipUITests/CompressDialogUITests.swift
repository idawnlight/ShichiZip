import XCTest

/// Tests for the compress (Add to Archive) dialog.
final class CompressDialogUITests: ShichiZipUITestCase {
    func testCompressDialogAppears() throws {
        let tempDir = try makeTemporaryDirectory(named: "compress")
        try createTextFile(at: tempDir.appendingPathComponent("file1.txt"))

        navigateLeftPane(to: tempDir.path)

        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let fileCell = table.cells.staticTexts["file1.txt"]
        XCTAssertTrue(fileCell.waitForExistence(timeout: 5))
        fileCell.click()

        // Trigger Add to Archive via menu
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["Add"].click()

        // Verify dialog appeared with expected controls
        let archivePathField = app.comboBoxes.matching(identifier: "compress.archivePath").firstMatch
        XCTAssertTrue(archivePathField.waitForExistence(timeout: 5),
                      "Compress dialog archive path field should appear")

        let formatPopup = app.popUpButtons.matching(identifier: "compress.format").firstMatch
        XCTAssertTrue(formatPopup.exists, "Format popup should exist")

        let levelPopup = app.popUpButtons.matching(identifier: "compress.level").firstMatch
        XCTAssertTrue(levelPopup.exists, "Compression level popup should exist")

        let methodPopup = app.popUpButtons.matching(identifier: "compress.method").firstMatch
        XCTAssertTrue(methodPopup.exists, "Method popup should exist")

        // Cancel
        let cancelButton = app.buttons.matching(identifier: "modal.button.0").firstMatch
        XCTAssertTrue(cancelButton.exists)
        cancelButton.click()
    }

    func testCompressDialogCancelDoesNotCrash() throws {
        let tempDir = try makeTemporaryDirectory(named: "compressCancel")
        try createTextFile(at: tempDir.appendingPathComponent("data.txt"))

        navigateLeftPane(to: tempDir.path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let fileCell = table.cells.staticTexts["data.txt"]
        XCTAssertTrue(fileCell.waitForExistence(timeout: 5))
        fileCell.click()

        for _ in 0 ..< 3 {
            app.menuBars.menuBarItems["File"].click()
            app.menuBars.menuBarItems["File"].menus.menuItems["Add"].click()

            let archivePathField = app.comboBoxes.matching(identifier: "compress.archivePath").firstMatch
            XCTAssertTrue(archivePathField.waitForExistence(timeout: 5))

            let cancelButton = app.buttons.matching(identifier: "modal.button.0").firstMatch
            cancelButton.click()

            usleep(300_000)
        }

        XCTAssertTrue(app.state == .runningForeground)
    }

    func testCompressCreatesArchive() throws {
        let tempDir = try makeTemporaryDirectory(named: "compressCreate")
        try createTextFile(at: tempDir.appendingPathComponent("document.txt"), content: "Hello, world!")

        navigateLeftPane(to: tempDir.path)

        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let fileCell = table.cells.staticTexts["document.txt"]
        XCTAssertTrue(fileCell.waitForExistence(timeout: 5))
        fileCell.click()

        // Open Add to Archive dialog
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["Add"].click()

        let archivePathField = app.comboBoxes.matching(identifier: "compress.archivePath").firstMatch
        XCTAssertTrue(archivePathField.waitForExistence(timeout: 5))

        // Read the prefilled archive path
        let prefilledPath = archivePathField.value as? String ?? ""
        XCTAssertFalse(prefilledPath.isEmpty, "Archive path should be prefilled")
        XCTAssertTrue(prefilledPath.hasSuffix(".7z"), "Default archive should be .7z, got: \(prefilledPath)")

        // Click OK to create the archive
        let okButton = app.buttons.matching(identifier: "modal.button.1").firstMatch
        XCTAssertTrue(okButton.exists, "OK button should exist")
        okButton.click()

        // Wait for the archive to be created on disk
        let deadline = Date().addingTimeInterval(15)
        var archiveExists = false
        while Date() < deadline {
            archiveExists = FileManager.default.fileExists(atPath: prefilledPath)
            if archiveExists { break }
            usleep(500_000)
        }

        XCTAssertTrue(archiveExists, "Archive should exist at \(prefilledPath)")

        // Verify the archive is non-empty
        let attrs = try FileManager.default.attributesOfItem(atPath: prefilledPath)
        let fileSize = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Archive should be non-empty")
    }
}
