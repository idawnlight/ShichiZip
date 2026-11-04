import XCTest

/// Tests for the extract dialog workflow — the flow that previously caused a crash.
final class ExtractDialogUITests: ShichiZipUITestCase {
    override var additionalLaunchArguments: [String] {
        [
            "-LanguageOverride", "en",
            "-FileManager.ToolbarStyle", "expanded",
            "-FileManager.ShowArchiveToolbar", "YES",
            "-FileManager.ExtractSplitDestination", "YES",
            "-FileManager.ExtractPathMode", "0",
            "-MoveArchiveToTrashAfterExtraction", "NO",
            "-RevealAfterExtractInFileManager", "NO",
            "-RevealAfterTransfer", "NO",
        ]
    }

    func testOpenArchiveAndNavigate() throws {
        let (archiveURL, _) = try makeTestArchive(named: "navigate",
                                                  payloads: ["payload.txt": "This is test content for extraction."])

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
        let (archiveURL, _) = try makeTestArchive(named: "dialog",
                                                  payloads: ["payload.txt": "This is test content for extraction."])

        // Navigate to the directory containing the archive and select it.
        navigateLeftPane(to: archiveURL.deletingLastPathComponent().path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5))
        archiveCell.click()

        // Trigger Extract via the toolbar
        app.buttons["Extract"].click()

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

        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["Copy To..."].click()
        let copyDestination = app.comboBoxes.matching(identifier: "fileOperation.destinationPath").firstMatch
        XCTAssertTrue(copyDestination.waitForExistence(timeout: 5))
        XCTAssertFalse(app.checkBoxes.matching(identifier: "fileOperation.splitDestination").firstMatch.exists,
                       "Ordinary Copy should not offer extraction-specific folder options")
        app.buttons.matching(identifier: "modal.button.0").firstMatch.click()
    }

    func testExtractFromOpenArchiveShowsCopyDialogWithSeparateFolder() throws {
        let (archiveURL, _) = try makeTestArchive(named: "extract-dialog",
                                                  payloads: ["payload.txt": "This is test content for extraction."])

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

        app.buttons["Extract"].click()

        let destinationField = app.comboBoxes.matching(identifier: "fileOperation.destinationPath").firstMatch
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5),
                      "Extract from an open archive should keep the Copy destination dialog")
        let separateFolder = app.checkBoxes.matching(identifier: "fileOperation.splitDestination").firstMatch
        XCTAssertEqual(separateFolder.value as? Int, 1)
        XCTAssertEqual(app.textFields.matching(identifier: "fileOperation.splitName").firstMatch.value as? String,
                       archiveURL.deletingPathExtension().lastPathComponent)
        XCTAssertFalse(app.popUpButtons.matching(identifier: "extract.pathMode").firstMatch.exists)
        XCTAssertFalse(app.checkBoxes.matching(identifier: "extract.moveToTrash").firstMatch.exists)

        let cancelButton = app.buttons.matching(identifier: "modal.button.0").firstMatch
        XCTAssertTrue(cancelButton.exists)
        cancelButton.click()
    }

    func testExtractDialogCancelDoesNotCrash() throws {
        let (archiveURL, _) = try makeTestArchive(named: "cancel",
                                                  payloads: ["payload.txt": "This is test content for extraction."])

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

        let canceledDestination = archiveURL.deletingLastPathComponent().appendingPathComponent("cancel-output")
        // Open and cancel the Copy dialog multiple times to check stability.
        for _ in 0 ..< 3 {
            app.buttons["Extract"].click()

            let destinationField = app.comboBoxes.matching(identifier: "fileOperation.destinationPath").firstMatch
            XCTAssertTrue(destinationField.waitForExistence(timeout: 5))
            destinationField.click()
            destinationField.selectAll()
            destinationField.pasteText(canceledDestination.path)

            let cancelButton = app.buttons.matching(identifier: "modal.button.0").firstMatch
            cancelButton.click()

            // Small delay to ensure the dialog fully dismisses
            usleep(300_000)
        }

        // App should still be running
        XCTAssertTrue(app.state == .runningForeground, "App should still be running after cancelling extract 3 times")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canceledDestination.path))
    }

    func testExtractPerformsExtraction() throws {
        try checkSelectedFileExtraction(separateFolder: true)
    }

    func testExtractHonorsDisabledSeparateFolderPreference() throws {
        app.terminate()
        let keyIndex = try XCTUnwrap(app.launchArguments.firstIndex(of: "-FileManager.ExtractSplitDestination"))
        app.launchArguments[keyIndex + 1] = "NO"
        app.launch()
        try checkSelectedFileExtraction(separateFolder: false)
    }

    func testExtractFromSubdirectoryKeepsCurrentPaths() throws {
        try checkSelectedFileExtraction(separateFolder: true, subdirectory: "parent/docs")
    }

    private func checkSelectedFileExtraction(separateFolder: Bool, subdirectory: String? = nil) throws {
        let directoryURL = try makeTemporaryDirectory(named: "extract")
        let sourceDirectory = subdirectory.map { directoryURL.appendingPathComponent($0, isDirectory: true) } ?? directoryURL
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try createTextFile(at: sourceDirectory.appendingPathComponent("payload.txt"), content: "This is test content for extraction.")
        try createTextFile(at: sourceDirectory.appendingPathComponent("unselected.txt"), content: "Leave this in the archive.")
        let prefix = subdirectory.map { $0 + "/" } ?? ""
        let archiveURL = try createTestArchive(named: "extract",
                                               sourceFileNames: [prefix + "payload.txt", prefix + "unselected.txt"],
                                               in: directoryURL)

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

        for component in subdirectory?.split(separator: "/") ?? [] {
            let folderCell = table.cells.staticTexts[String(component)]
            XCTAssertTrue(folderCell.waitForExistence(timeout: 5))
            folderCell.doubleClick()
        }

        let payloadCell = table.cells.staticTexts["payload.txt"]
        XCTAssertTrue(payloadCell.waitForExistence(timeout: 5))
        payloadCell.click()

        // Extract only the selected file, honoring the existing separate-folder preference.
        app.buttons["Extract"].click()

        let destinationField = app.comboBoxes.matching(identifier: "fileOperation.destinationPath").firstMatch
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5))
        XCTAssertEqual(app.checkBoxes.matching(identifier: "fileOperation.splitDestination").firstMatch.value as? Int,
                       separateFolder ? 1 : 0)
        let suggestedName = subdirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "extract"
        XCTAssertEqual(app.textFields.matching(identifier: "fileOperation.splitName").firstMatch.value as? String,
                       suggestedName)

        let extractDir = archiveURL.deletingLastPathComponent().appendingPathComponent("extract-output", isDirectory: true)
        destinationField.click()
        destinationField.selectAll()
        destinationField.pasteText(extractDir.path)

        app.buttons.matching(identifier: "modal.button.1").firstMatch.click()

        let outputFolder = separateFolder ? extractDir.appendingPathComponent(suggestedName, isDirectory: true) : extractDir
        let extractedURL = outputFolder.appendingPathComponent("payload.txt")
        XCTAssertTrue(waitForFile(at: extractedURL))
        XCTAssertEqual(try String(contentsOf: extractedURL, encoding: .utf8),
                       "This is test content for extraction.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputFolder.path), ["payload.txt"])
        if separateFolder {
            XCTAssertFalse(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("payload.txt").path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    func testPasswordPromptAcceptsCommandSelectAllAndPaste() throws {
        let password = "shichizip-password"
        let payloadName = "secret.txt"
        let payloadContent = "encrypted payload"
        let (archiveURL, directoryURL) = try makeTestArchive(named: "password-shortcuts",
                                                             payloads: [payloadName: payloadContent],
                                                             password: password)

        navigateLeftPane(to: directoryURL.path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5))
        archiveCell.doubleClick()

        let pathField = leftPanePathField
        let openPredicate = NSPredicate(format: "value CONTAINS %@", archiveURL.lastPathComponent)
        let openExpectation = XCTNSPredicateExpectation(predicate: openPredicate, object: pathField)
        wait(for: [openExpectation], timeout: 10)

        app.buttons["Extract"].click()

        let destinationField = app.comboBoxes.matching(identifier: "fileOperation.destinationPath").firstMatch
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5))
        let destinationURL = directoryURL.appendingPathComponent("password-extract", isDirectory: true)
        destinationField.click()
        destinationField.selectAll()
        destinationField.pasteText(destinationURL.path)

        let extractButton = app.buttons.matching(identifier: "modal.button.1").firstMatch
        XCTAssertTrue(extractButton.exists)
        extractButton.click()

        let passwordField = waitForPasswordPromptField()
        XCTAssertTrue(passwordField.exists,
                      "Password prompt should appear for encrypted archive extraction")
        let promptMessage = app.descendants(matching: .any)
            .matching(identifier: "modal.message")
            .firstMatch
        XCTAssertTrue(promptMessage.waitForExistence(timeout: 2),
                      "Password prompt should identify the archive that needs a password")
        let promptMessageText = [promptMessage.label, promptMessage.value as? String]
            .compactMap(\.self)
            .joined(separator: "\n")
        XCTAssertTrue(promptMessageText.contains(archiveURL.lastPathComponent),
                      "Password prompt should include the archive name")
        passwordField.click()
        passwordField.typeText("wrong-password")
        passwordField.selectAll()
        passwordField.pasteText(password)

        app.buttons.matching(identifier: "modal.button.1").firstMatch.click()

        let extractedURL = destinationURL.appendingPathComponent("password-shortcuts").appendingPathComponent(payloadName)
        XCTAssertTrue(waitForFile(at: extractedURL),
                      "Extraction should succeed when the pasted password replaces the selected wrong password")
        XCTAssertEqual(try String(contentsOf: extractedURL, encoding: .utf8), payloadContent)
    }

    private func waitForPasswordPromptField(timeout: TimeInterval = 10) -> XCUIElement {
        let secureField = app.secureTextFields.matching(identifier: "passwordPrompt.password").firstMatch
        let plainField = app.textFields.matching(identifier: "passwordPrompt.passwordPlain").firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if secureField.exists {
                return secureField
            }
            if plainField.exists {
                return plainField
            }
            usleep(100_000)
        }

        return secureField
    }
}
