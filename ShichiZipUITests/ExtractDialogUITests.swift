import XCTest

/// Tests for the extract dialog workflow — the flow that previously caused a crash.
final class ExtractDialogUITests: ShichiZipUITestCase {
    /// Creates a test .7z archive containing a single text file.
    /// Returns (archiveURL, containingDirectory).
    private func makeTestArchive(named name: String = "test") throws -> (archive: URL, directory: URL) {
        let tempDir = try makeTemporaryDirectory(named: name)
        let sourceDir = tempDir.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let payloadFile = sourceDir.appendingPathComponent("payload.txt")
        try createTextFile(at: payloadFile, content: "This is test content for extraction.")

        // Use the command-line 7z to create the archive since we can't link the bridge from UI tests
        let archiveURL = tempDir.appendingPathComponent("\(name).7z")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/7z")
        process.arguments = ["a", archiveURL.path, payloadFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Fall back: create a zip if 7z CLI is not available
        if !FileManager.default.fileExists(atPath: "/usr/local/bin/7z") {
            let zipURL = tempDir.appendingPathComponent("\(name).zip")
            let zipProcess = Process()
            zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            zipProcess.arguments = ["-c", "-k", "--sequesterRsrc", sourceDir.path, zipURL.path]
            zipProcess.standardOutput = FileHandle.nullDevice
            zipProcess.standardError = FileHandle.nullDevice
            try zipProcess.run()
            zipProcess.waitUntilExit()
            guard zipProcess.terminationStatus == 0 else {
                throw NSError(domain: "ShichiZipUITests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to create test zip archive"])
            }
            return (zipURL, tempDir)
        }

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ShichiZipUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create test 7z archive"])
        }
        return (archiveURL, tempDir)
    }

    func testOpenArchiveAndNavigate() throws {
        let (archiveURL, _) = try makeTestArchive(named: "navigate")

        // Navigate to the directory containing the archive
        navigateLeftPane(to: archiveURL.deletingLastPathComponent().path)

        // Wait for the table to show the archive file
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5),
                      "Archive file should appear in file list")

        // Double-click to open the archive (inline navigation)
        archiveCell.doubleClick()

        // After opening, the path field should reflect the archive path
        let pathField = leftPanePathField
        let predicate = NSPredicate(format: "value CONTAINS %@", archiveURL.lastPathComponent)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pathField)
        wait(for: [expectation], timeout: 10)
    }

    func testExtractDialogAppears() throws {
        let (archiveURL, _) = try makeTestArchive(named: "dialog")

        // Navigate to the directory and open the archive
        navigateLeftPane(to: archiveURL.deletingLastPathComponent().path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5))
        archiveCell.doubleClick()

        // Wait for archive to open (path field updates)
        let pathField = leftPanePathField
        let openPredicate = NSPredicate(format: "value CONTAINS %@", archiveURL.lastPathComponent)
        let openExpectation = XCTNSPredicateExpectation(predicate: openPredicate, object: pathField)
        wait(for: [openExpectation], timeout: 10)

        // Trigger Extract via menu
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["Extract…"].click()

        // The extract dialog should appear with our accessibility-tagged controls
        let destinationField = app.comboBoxes.matching(identifier: "extract.destinationPath").firstMatch
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5),
                      "Extract dialog destination field should appear")

        let pathModePopup = app.popUpButtons.matching(identifier: "extract.pathMode").firstMatch
        XCTAssertTrue(pathModePopup.exists, "Path mode popup should exist in extract dialog")

        let overwritePopup = app.popUpButtons.matching(identifier: "extract.overwriteMode").firstMatch
        XCTAssertTrue(overwritePopup.exists, "Overwrite mode popup should exist in extract dialog")

        // Cancel the dialog
        let cancelButton = app.buttons.matching(identifier: "modal.button.0").firstMatch
        XCTAssertTrue(cancelButton.exists, "Cancel button should exist")
        cancelButton.click()
    }

    func testExtractDialogCancelDoesNotCrash() throws {
        let (archiveURL, _) = try makeTestArchive(named: "cancel")

        navigateLeftPane(to: archiveURL.deletingLastPathComponent().path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5))
        archiveCell.doubleClick()

        let pathField = leftPanePathField
        let openPredicate = NSPredicate(format: "value CONTAINS %@", archiveURL.lastPathComponent)
        let openExpectation = XCTNSPredicateExpectation(predicate: openPredicate, object: pathField)
        wait(for: [openExpectation], timeout: 10)

        // Open and cancel extract dialog multiple times to check stability
        for _ in 0 ..< 3 {
            app.menuBars.menuBarItems["File"].click()
            app.menuBars.menuBarItems["File"].menus.menuItems["Extract…"].click()

            let destinationField = app.comboBoxes.matching(identifier: "extract.destinationPath").firstMatch
            XCTAssertTrue(destinationField.waitForExistence(timeout: 5))

            let cancelButton = app.buttons.matching(identifier: "modal.button.0").firstMatch
            cancelButton.click()

            // Small delay to ensure the dialog fully dismisses
            usleep(300_000)
        }

        // App should still be running
        XCTAssertTrue(app.state == .runningForeground, "App should still be running after cancelling extract 3 times")
    }

    func testExtractPerformsExtraction() throws {
        let (archiveURL, tempDir) = try makeTestArchive(named: "extract")

        // Navigate to archive directory and open it
        navigateLeftPane(to: archiveURL.deletingLastPathComponent().path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5))
        archiveCell.doubleClick()

        let pathField = leftPanePathField
        let openPredicate = NSPredicate(format: "value CONTAINS %@", archiveURL.lastPathComponent)
        let openExpectation = XCTNSPredicateExpectation(predicate: openPredicate, object: pathField)
        wait(for: [openExpectation], timeout: 10)

        // Open extract dialog
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["Extract…"].click()

        let destinationField = app.comboBoxes.matching(identifier: "extract.destinationPath").firstMatch
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5))

        // Read the prefilled destination path — it should be the archive's containing directory
        let prefilledPath = destinationField.value as? String ?? ""
        XCTAssertFalse(prefilledPath.isEmpty, "Destination field should have a prefilled path")

        // Uncheck "separate folder" to extract directly into the prefilled destination
        let splitCheckbox = app.checkBoxes.matching(identifier: "extract.splitDestination").firstMatch
        if splitCheckbox.exists, splitCheckbox.value as? Int == 1 {
            splitCheckbox.click()
        }

        // Click Extract button
        let extractButton = app.buttons.matching(identifier: "modal.button.1").firstMatch
        XCTAssertTrue(extractButton.exists, "Extract button should exist")
        extractButton.click()

        // Wait for extraction to complete — poll for output files
        let extractDir = URL(fileURLWithPath: prefilledPath)
        let deadline = Date().addingTimeInterval(15)
        var extractedFiles: [String] = []
        while Date() < deadline {
            extractedFiles = (try? FileManager.default.contentsOfDirectory(atPath: extractDir.path)) ?? []
            // Filter out the archive itself if it's in the same directory
            extractedFiles = extractedFiles.filter { $0 != archiveURL.lastPathComponent }
            if !extractedFiles.isEmpty { break }
            usleep(500_000)
        }

        XCTAssertFalse(extractedFiles.isEmpty,
                       "Extracted output directory should contain files. Got: \(extractedFiles)")
    }
}
