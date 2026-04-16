import XCTest

/// Tests for archive drag operations in the dual-pane file manager.
///
/// Covers drag-from-archive (extract by dragging to filesystem pane),
/// drag-into-archive (add files by dragging from filesystem pane),
/// and nested archive operations (open archive inside archive, drag out).
///
/// All tests launch in dual-pane mode via the `FileManager.IsDualPane`
/// launch argument.
final class DragFromArchiveUITests: ShichiZipUITestCase {
    // MARK: - Launch with dual-pane mode

    override var additionalLaunchArguments: [String] {
        // NSUserDefaults picks up launch arguments as `-key value` pairs,
        // so this forces the file manager into two-column mode.
        ["-FileManager.IsDualPane", "YES"]
    }

    // MARK: - Pane-scoped element accessors

    // Both panes reuse the same accessibility identifiers for their
    // table view ("fileManager.tableView") and path field
    // ("fileManager.pathField").  In dual-pane mode the split view
    // lays out the left pane first, so index 0 = left, index 1 = right.

    private var splitView: XCUIElement {
        fileManagerWindow.splitGroups.matching(identifier: "fileManager.splitView").firstMatch
    }

    private var leftTable: XCUIElement {
        fileManagerWindow.tables.matching(identifier: "fileManager.tableView").element(boundBy: 0)
    }

    private var rightTable: XCUIElement {
        fileManagerWindow.tables.matching(identifier: "fileManager.tableView").element(boundBy: 1)
    }

    private var leftPathField: XCUIElement {
        fileManagerWindow.textFields.matching(identifier: "fileManager.pathField").element(boundBy: 0)
    }

    private var rightPathField: XCUIElement {
        fileManagerWindow.textFields.matching(identifier: "fileManager.pathField").element(boundBy: 1)
    }

    // MARK: - Navigation helpers (pane-scoped)

    private func navigatePane(_ pathField: XCUIElement, to path: String) {
        XCTAssertTrue(pathField.waitForExistence(timeout: 10),
                      "Path field should exist before navigating")
        pathField.click()
        pathField.selectAll()
        pathField.pasteText(path)
        pathField.typeText("\r")
    }

    // MARK: - Workflow helpers

    /// Opens an archive in the left pane and navigates the right pane
    /// to a destination directory.  Returns after both panes are ready.
    private func openArchiveInLeftPane(_ archiveURL: URL,
                                       destinationDir: URL)
    {
        // Left pane: navigate to the archive's directory, then open it.
        navigatePane(leftPathField, to: archiveURL.deletingLastPathComponent().path)
        XCTAssertTrue(leftTable.waitForExistence(timeout: 10))

        let archiveCell = leftTable.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5),
                      "Archive should appear in the left pane")
        archiveCell.doubleClick()

        // Wait until the path field reflects the opened archive.
        let openPredicate = NSPredicate(format: "value CONTAINS %@",
                                        archiveURL.lastPathComponent)
        let openExpectation = XCTNSPredicateExpectation(predicate: openPredicate,
                                                        object: leftPathField)
        wait(for: [openExpectation], timeout: 10)

        // Right pane: point at the destination directory.
        navigatePane(rightPathField, to: destinationDir.path)
        XCTAssertTrue(rightTable.waitForExistence(timeout: 10))
    }

    // MARK: - Tests

    /// Sanity-check that dual-pane mode is active when the launch
    /// argument is set.
    func testDualPaneLaunches() {
        XCTAssertTrue(splitView.waitForExistence(timeout: 10),
                      "Split view should exist")
        XCTAssertTrue(leftTable.waitForExistence(timeout: 5),
                      "Left table should exist")
        XCTAssertTrue(rightTable.waitForExistence(timeout: 5),
                      "Right table should exist")
        XCTAssertTrue(leftPathField.waitForExistence(timeout: 5),
                      "Left path field should exist")
        XCTAssertTrue(rightPathField.waitForExistence(timeout: 5),
                      "Right path field should exist")
    }

    /// Opens an archive in the left pane, drags a single file to the
    /// right (filesystem) pane, and verifies the file on disk.
    func testDragSingleFileFromArchive() throws {
        let (archiveURL, tempDir) = try makeTestArchive(named: "dragtest",
                                                        payloads: ["payload.txt": "Drag-out test content."])
        let destinationDir = tempDir.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir,
                                                withIntermediateDirectories: true)

        openArchiveInLeftPane(archiveURL, destinationDir: destinationDir)

        // Locate the entry inside the archive.
        let payloadCell = leftTable.cells.staticTexts["payload.txt"]
        XCTAssertTrue(payloadCell.waitForExistence(timeout: 5),
                      "payload.txt should be visible inside the opened archive")

        // Drag from archive (left) to filesystem (right).
        payloadCell.click(forDuration: 1.0, thenDragTo: rightTable)

        // Verify extraction on disk.
        let extractedFile = destinationDir.appendingPathComponent("payload.txt")
        XCTAssertTrue(waitForFile(at: extractedFile),
                      "payload.txt should be extracted to \(destinationDir.path)")

        let content = try String(contentsOf: extractedFile, encoding: .utf8)
        XCTAssertEqual(content, "Drag-out test content.",
                       "Extracted file content should match the original")

        // The app should remain responsive after drag-out (no deadlock).
        XCTAssertEqual(app.state, .runningForeground,
                       "App should still be in the foreground after drag-out")
        XCTAssertTrue(leftTable.isHittable,
                      "Left table should remain hittable after drag-out")
    }

    /// Selects two files inside an archive with Cmd-click, drags the
    /// selection to the right pane, and verifies both land on disk.
    func testDragMultipleFilesFromArchive() throws {
        let (archiveURL, tempDir) = try makeTestArchive(named: "dragmulti",
                                                        payloads: ["alpha.txt": "alpha",
                                                                   "beta.txt": "beta"])

        let destinationDir = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir,
                                                withIntermediateDirectories: true)

        openArchiveInLeftPane(archiveURL, destinationDir: destinationDir)

        // Locate both entries inside the archive.
        let alphaCell = leftTable.cells.staticTexts["alpha.txt"]
        let betaCell = leftTable.cells.staticTexts["beta.txt"]
        XCTAssertTrue(alphaCell.waitForExistence(timeout: 5))
        XCTAssertTrue(betaCell.waitForExistence(timeout: 5))

        // Build a multi-selection: click the first, Cmd-click the second.
        alphaCell.click()
        XCUIElement.perform(withKeyModifiers: .command) {
            betaCell.click()
        }

        // Drag the multi-selection to the right pane.
        // click(forDuration:thenDragTo:) initiates a drag of the
        // *current selection* starting from the clicked row.
        alphaCell.click(forDuration: 1.0, thenDragTo: rightTable)

        // Verify both files extracted.
        let alphaExtracted = destinationDir.appendingPathComponent("alpha.txt")
        let betaExtracted = destinationDir.appendingPathComponent("beta.txt")

        XCTAssertTrue(waitForFile(at: alphaExtracted), "alpha.txt should be extracted")
        XCTAssertTrue(waitForFile(at: betaExtracted), "beta.txt should be extracted")
    }

    // MARK: - Drag Into Archive

    /// Drags a filesystem file from the left pane into an open archive
    /// in the right pane, then verifies the file was added to the archive.
    func testDragFileIntoArchive() throws {
        // Create the archive (right pane) with one existing file.
        let (archiveURL, tempDir) = try makeTestArchive(named: "dragintoarchive",
                                                        payloads: ["existing.txt": "already here"])

        // Create a loose file in the same temp dir (left pane source).
        let newFile = tempDir.appendingPathComponent("added.txt")
        try createTextFile(at: newFile, content: "newly added")

        // Right pane: open the archive.
        navigatePane(rightPathField, to: tempDir.path)
        XCTAssertTrue(rightTable.waitForExistence(timeout: 10))

        let archiveCell = rightTable.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5),
                      "Archive should appear in the right pane")
        archiveCell.doubleClick()

        let openPredicate = NSPredicate(format: "value CONTAINS %@",
                                        archiveURL.lastPathComponent)
        let openExpectation = XCTNSPredicateExpectation(predicate: openPredicate,
                                                        object: rightPathField)
        wait(for: [openExpectation], timeout: 10)

        // Left pane: navigate to the temp dir (shows added.txt).
        navigatePane(leftPathField, to: tempDir.path)
        XCTAssertTrue(leftTable.waitForExistence(timeout: 10))

        let addedCell = leftTable.cells.staticTexts["added.txt"]
        XCTAssertTrue(addedCell.waitForExistence(timeout: 5),
                      "added.txt should appear in the left pane")

        // Drag the file from filesystem (left) into the archive (right).
        addedCell.click(forDuration: 1.0, thenDragTo: rightTable)

        // A confirmation alert appears — press the confirm button.
        let confirmButton = app.buttons.matching(identifier: "modal.button.1").firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 10),
                      "Archive transfer confirmation dialog should appear")
        confirmButton.click()

        // Wait for the archive to be updated — the new file should
        // appear in the right pane's listing.
        let addedInArchive = rightTable.cells.staticTexts["added.txt"]
        XCTAssertTrue(addedInArchive.waitForExistence(timeout: 15),
                      "added.txt should appear inside the archive after drag-in")

        // Verify the archive on disk actually contains the new file
        // by listing its contents with the 7z CLI.
        let listOutput = try listArchiveContents(archiveURL)
        XCTAssertTrue(listOutput.contains("added.txt"),
                      "Archive listing should contain added.txt. Got: \(listOutput)")
        XCTAssertTrue(listOutput.contains("existing.txt"),
                      "Archive listing should still contain existing.txt. Got: \(listOutput)")
    }

    // MARK: - Nested Archive

    /// Opens a nested archive (archive inside archive), verifies the
    /// path field reflects the nesting, and drags a file out.
    func testOpenAndDragFromNestedArchive() throws {
        let tempDir = try makeTemporaryDirectory(named: "nested")

        // Create the inner archive containing a payload file.
        let innerPayload = tempDir.appendingPathComponent("inner_payload.txt")
        try createTextFile(at: innerPayload, content: "from nested archive")
        let innerArchiveURL = try createTestArchive(named: "inner",
                                                    sourceFileNames: ["inner_payload.txt"],
                                                    in: tempDir)
        try FileManager.default.removeItem(at: innerPayload)

        // Create the outer archive containing the inner archive.
        let outerArchiveURL = try createTestArchive(named: "outer",
                                                    sourceFileNames: [innerArchiveURL.lastPathComponent],
                                                    in: tempDir)
        try FileManager.default.removeItem(at: innerArchiveURL)

        let destinationDir = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir,
                                                withIntermediateDirectories: true)

        // Left pane: navigate to the temp dir and open the outer archive.
        navigatePane(leftPathField, to: tempDir.path)
        XCTAssertTrue(leftTable.waitForExistence(timeout: 10))

        let outerCell = leftTable.cells.staticTexts[outerArchiveURL.lastPathComponent]
        XCTAssertTrue(outerCell.waitForExistence(timeout: 5))
        outerCell.doubleClick()

        let outerPredicate = NSPredicate(format: "value CONTAINS %@",
                                         outerArchiveURL.lastPathComponent)
        let outerExpectation = XCTNSPredicateExpectation(predicate: outerPredicate,
                                                         object: leftPathField)
        wait(for: [outerExpectation], timeout: 10)

        // The inner archive should appear as an entry.
        let innerCell = leftTable.cells.staticTexts[innerArchiveURL.lastPathComponent]
        XCTAssertTrue(innerCell.waitForExistence(timeout: 5),
                      "Inner archive should be visible inside the outer archive")

        // Double-click to open the nested archive.
        innerCell.doubleClick()

        // Wait for path field to reflect nesting (contains both names).
        let nestedPredicate = NSPredicate(format: "value CONTAINS %@",
                                          innerArchiveURL.lastPathComponent)
        let nestedExpectation = XCTNSPredicateExpectation(predicate: nestedPredicate,
                                                          object: leftPathField)
        wait(for: [nestedExpectation], timeout: 10)

        // Verify the nested payload is visible.
        let nestedPayloadCell = leftTable.cells.staticTexts["inner_payload.txt"]
        XCTAssertTrue(nestedPayloadCell.waitForExistence(timeout: 5),
                      "inner_payload.txt should be visible inside the nested archive")

        // Right pane: navigate to the destination directory.
        navigatePane(rightPathField, to: destinationDir.path)
        XCTAssertTrue(rightTable.waitForExistence(timeout: 10))

        // Drag the file out from the nested archive.
        nestedPayloadCell.click(forDuration: 1.0, thenDragTo: rightTable)

        // Verify extraction on disk.
        let extractedFile = destinationDir.appendingPathComponent("inner_payload.txt")
        XCTAssertTrue(waitForFile(at: extractedFile),
                      "inner_payload.txt should be extracted from nested archive")

        let content = try String(contentsOf: extractedFile, encoding: .utf8)
        XCTAssertEqual(content, "from nested archive",
                       "Extracted nested file content should match the original")
    }

    // MARK: - Archive CLI helpers

    /// Lists archive contents using the system-provided zipinfo.
    /// All test fixtures are .zip archives produced via /usr/bin/zip,
    /// so zipinfo (shipped with macOS) is always sufficient. Do not
    /// branch on /usr/local/bin/7z — that would make the test's listing
    /// behaviour depend on whether p7zip happens to be installed on the
    /// developer machine, which is exactly what createTestArchive was
    /// changed to avoid.
    private func listArchiveContents(_ archiveURL: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", archiveURL.path]

        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
