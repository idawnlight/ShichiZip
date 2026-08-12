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

    func testCompressValidationFailureKeepsDialogOpen() throws {
        let tempDir = try makeTemporaryDirectory(named: "compressValidation")
        try createTextFile(at: tempDir.appendingPathComponent("data.txt"))

        navigateLeftPane(to: tempDir.path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let fileCell = table.cells.staticTexts["data.txt"]
        XCTAssertTrue(fileCell.waitForExistence(timeout: 5))
        fileCell.click()

        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["Add"].click()

        let archivePathField = app.comboBoxes.matching(identifier: "compress.archivePath").firstMatch
        XCTAssertTrue(archivePathField.waitForExistence(timeout: 5))

        let securePasswordField = app.secureTextFields.matching(identifier: "compress.password").firstMatch
        let plainPasswordField = app.textFields.matching(identifier: "compress.passwordPlain").firstMatch
        let passwordField = securePasswordField.waitForExistence(timeout: 2) && securePasswordField.isHittable
            ? securePasswordField
            : plainPasswordField
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.click()
        passwordField.pasteText("one")

        let secureConfirmationField = app.secureTextFields.matching(identifier: "compress.confirmPassword").firstMatch
        let plainConfirmationField = app.textFields.matching(identifier: "compress.confirmPasswordPlain").firstMatch
        let confirmationField = secureConfirmationField.waitForExistence(timeout: 2) && secureConfirmationField.isHittable
            ? secureConfirmationField
            : plainConfirmationField
        XCTAssertTrue(confirmationField.waitForExistence(timeout: 5))
        confirmationField.click()
        confirmationField.pasteText("two")

        let okButton = app.buttons.matching(identifier: "modal.button.1").firstMatch
        XCTAssertTrue(okButton.exists)
        okButton.click()

        let errorTitle = app.staticTexts["Passwords do not match"].firstMatch
        XCTAssertTrue(errorTitle.waitForExistence(timeout: 5),
                      "Validation errors should be presented without dismissing the Compress dialog")
        XCTAssertTrue(archivePathField.exists,
                      "Compress dialog should remain open after failed validation")
    }

    // MARK: - Compress & Verify via App

    /// Compresses multiple files as .7z, opens the resulting archive
    /// in the app, and verifies the entries appear in the file list.
    /// Then extracts via the Extract dialog and checks the files on disk.
    func testCompressAs7zAndVerify() throws {
        let tempDir = try makeTemporaryDirectory(named: "compress7z")
        try createTextFile(at: tempDir.appendingPathComponent("alpha.txt"), content: "alpha content")
        try createTextFile(at: tempDir.appendingPathComponent("beta.txt"), content: "beta content")

        let archivePath = try compressFiles(["alpha.txt", "beta.txt"],
                                            in: tempDir,
                                            format: "7z")
        XCTAssertTrue(archivePath.hasSuffix(".7z"), "Should produce .7z, got: \(archivePath)")

        verifyArchiveContents(archivePath: archivePath,
                              expectedFiles: ["alpha.txt", "beta.txt"])

        // Extract via the app and verify file content
        let extractDir = try extractViaApp(archivePath: archivePath)

        let alphaContent = try String(contentsOf: extractDir.appendingPathComponent("alpha.txt"), encoding: .utf8)
        let betaContent = try String(contentsOf: extractDir.appendingPathComponent("beta.txt"), encoding: .utf8)
        XCTAssertEqual(alphaContent, "alpha content")
        XCTAssertEqual(betaContent, "beta content")
    }

    /// Compresses a file as .zip, opens it in the app, and verifies
    /// the entry appears. Then extracts and checks content.
    func testCompressAsZipAndVerify() throws {
        let tempDir = try makeTemporaryDirectory(named: "compressZip")
        try createTextFile(at: tempDir.appendingPathComponent("data.txt"), content: "zip test data")

        let archivePath = try compressFiles(["data.txt"],
                                            in: tempDir,
                                            format: "zip")
        XCTAssertTrue(archivePath.hasSuffix(".zip"), "Should produce .zip, got: \(archivePath)")

        verifyArchiveContents(archivePath: archivePath,
                              expectedFiles: ["data.txt"])

        let extractDir = try extractViaApp(archivePath: archivePath)

        let content = try String(contentsOf: extractDir.appendingPathComponent("data.txt"), encoding: .utf8)
        XCTAssertEqual(content, "zip test data")
    }

    // MARK: - Helpers

    /// Selects files in the left pane, opens the Add dialog, optionally
    /// changes format, clicks OK, and waits for the archive to appear.
    /// Returns the archive path on disk.
    private func compressFiles(_ fileNames: [String],
                               in directory: URL,
                               format: String) throws -> String
    {
        navigateLeftPane(to: directory.path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        // Select file(s)
        let firstCell = table.cells.staticTexts[fileNames[0]]
        XCTAssertTrue(firstCell.waitForExistence(timeout: 5))
        firstCell.click()

        for name in fileNames.dropFirst() {
            let cell = table.cells.staticTexts[name]
            XCTAssertTrue(cell.waitForExistence(timeout: 5))
            XCUIElement.perform(withKeyModifiers: .command) {
                cell.click()
            }
        }

        // Open Add to Archive
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["Add"].click()

        let archivePathField = app.comboBoxes.matching(identifier: "compress.archivePath").firstMatch
        XCTAssertTrue(archivePathField.waitForExistence(timeout: 5))

        // Change format if not the default
        let formatPopup = app.popUpButtons.matching(identifier: "compress.format").firstMatch
        XCTAssertTrue(formatPopup.exists)
        formatPopup.click()
        formatPopup.menuItems[format].click()

        let archivePath = archivePathField.value as? String ?? ""
        XCTAssertFalse(archivePath.isEmpty)

        // Click OK
        let okButton = app.buttons.matching(identifier: "modal.button.1").firstMatch
        XCTAssertTrue(okButton.exists)
        okButton.click()

        // Wait for the archive to appear on disk
        XCTAssertTrue(waitForFile(at: URL(fileURLWithPath: archivePath)),
                      "Archive should be created at \(archivePath)")
        return archivePath
    }

    /// Opens the archive in the app's file manager (assumes the pane
    /// is already showing the directory that contains it) and asserts
    /// the expected file names appear in the table.
    private func verifyArchiveContents(archivePath: String,
                                       expectedFiles: [String])
    {
        let archiveURL = URL(fileURLWithPath: archivePath)

        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5),
                      "Archive should appear in file list")
        archiveCell.doubleClick()

        // Wait for the archive to open
        let pathField = leftPanePathField
        let openPredicate = NSPredicate(format: "value CONTAINS %@",
                                        archiveURL.lastPathComponent)
        let openExpectation = XCTNSPredicateExpectation(predicate: openPredicate,
                                                        object: pathField)
        wait(for: [openExpectation], timeout: 10)

        // Every expected file should be visible inside the archive
        for fileName in expectedFiles {
            let cell = table.cells.staticTexts[fileName]
            XCTAssertTrue(cell.waitForExistence(timeout: 5),
                          "\(fileName) should be visible inside the archive")
        }
    }

    /// Triggers Extract from the currently open archive, which follows
    /// upstream 7-Zip and uses the Copy dialog for archive contents.
    /// Returns the extraction directory URL.
    private func extractViaApp(archivePath: String) throws -> URL {
        let archiveURL = URL(fileURLWithPath: archivePath)

        // Open the copy dialog used for archive contents.
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["Extract…"].click()

        let destinationField = app.comboBoxes.matching(identifier: "fileOperation.destinationPath").firstMatch
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5))

        let archiveStem = archiveURL.deletingPathExtension().lastPathComponent
        let extractDir = archiveURL.deletingLastPathComponent()
            .appendingPathComponent("\(archiveStem)-extracted", isDirectory: true)
        destinationField.click()
        destinationField.selectAll()
        destinationField.pasteText(extractDir.path)

        let copyButton = app.buttons.matching(identifier: "modal.button.1").firstMatch
        XCTAssertTrue(copyButton.exists)
        copyButton.click()

        // Wait for extraction to complete
        let deadline = Date().addingTimeInterval(15)
        var found = false
        while Date() < deadline {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: extractDir.path)) ?? []
            if !contents.isEmpty {
                found = true; break
            }
            usleep(500_000)
        }
        XCTAssertTrue(found, "Extraction should produce files in \(extractDir.path)")

        return extractDir
    }
}
