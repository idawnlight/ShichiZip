import XCTest

/// Tests for the file manager window — the primary UI surface.
final class FileManagerUITests: ShichiZipUITestCase {
    func testFileManagerWindowAppearsOnLaunch() {
        let window = fileManagerWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10), "File manager window should appear on launch")
    }

    func testPathFieldShowsCurrentDirectory() {
        let pathField = leftPanePathField
        XCTAssertTrue(pathField.waitForExistence(timeout: 10), "Path field should exist")
        XCTAssertFalse(pathField.value as? String == "", "Path field should show a directory path")
    }

    func testNavigateToDirectory() throws {
        let tempDir = try makeTemporaryDirectory(named: "NavTest")
        let testFile = tempDir.appendingPathComponent("hello.txt")
        try createTextFile(at: testFile, content: "hello")

        navigateLeftPane(to: tempDir.path)

        // The table should eventually show our test file
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let fileCell = table.cells.staticTexts["hello.txt"]
        XCTAssertTrue(fileCell.waitForExistence(timeout: 5),
                      "Should see hello.txt in the file list after navigating")
    }

    func testUpButtonNavigatesUp() throws {
        let tempDir = try makeTemporaryDirectory(named: "UpTest")
        let subDir = tempDir.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        navigateLeftPane(to: subDir.path)

        let upButton = app.buttons.matching(identifier: "fileManager.upButton").firstMatch
        XCTAssertTrue(upButton.waitForExistence(timeout: 5))
        upButton.click()

        // After going up, path field should show the parent
        let pathField = leftPanePathField
        // Wait briefly for navigation
        sleep(1)
        let pathValue = pathField.value as? String ?? ""
        XCTAssertTrue(pathValue.hasSuffix(tempDir.lastPathComponent) || pathValue == tempDir.path,
                      "Path field should show parent directory after clicking Up. Got: \(pathValue)")
    }

    func testStatusLabelShowsItemCount() throws {
        let tempDir = try makeTemporaryDirectory(named: "StatusTest")
        try createTextFile(at: tempDir.appendingPathComponent("a.txt"))
        try createTextFile(at: tempDir.appendingPathComponent("b.txt"))
        try createTextFile(at: tempDir.appendingPathComponent("c.txt"))

        navigateLeftPane(to: tempDir.path)

        let statusLabel = app.staticTexts.matching(identifier: "fileManager.statusLabel").firstMatch
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5))

        // Wait for the listing to complete
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS '3'"),
            object: statusLabel,
        )
        wait(for: [expectation], timeout: 5)
    }

    func testDeleteTemporaryFilesWindowOpens() {
        // Open via Tools menu
        app.menuBars.menuBarItems["Tools"].click()
        app.menuBars.menuBarItems["Tools"].menus.menuItems["Delete Temporary Files..."].click()

        // The window should appear with its table and controls
        let table = app.tables.matching(identifier: "deleteTempFiles.tableView").firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10),
                      "Delete Temporary Files table should appear")

        // The path field is a non-editable NSTextField, which XCUI may
        // expose as either a textField or staticText depending on its state.
        let pathField = app.descendants(matching: .any)
            .matching(identifier: "deleteTempFiles.pathField").firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 5), "Path field should exist")

        let statusLabel = app.staticTexts.matching(identifier: "deleteTempFiles.statusLabel").firstMatch
        XCTAssertTrue(statusLabel.exists, "Status label should exist")

        let deleteButton = app.buttons.matching(identifier: "deleteTempFiles.deleteButton").firstMatch
        XCTAssertTrue(deleteButton.exists, "Delete button should exist")

        let refreshButton = app.buttons.matching(identifier: "deleteTempFiles.refreshButton").firstMatch
        XCTAssertTrue(refreshButton.exists, "Refresh button should exist")
    }
}

final class FileManagerListViewPreferencesUITests: ShichiZipUITestCase {
    override var additionalLaunchArguments: [String] {
        ["-FileManager.IsDualPane", "NO",
         "-FileManager.ListViewInfo.FSFolder", Self.fileSystemListViewInfoArgumentValue]
    }

    func testRestoresSortingAndColumnWidthsFromDefaults() throws {
        let tempDir = try makeTemporaryDirectory(named: "ListViewPreferences")
        try Data(repeating: 0x61, count: 1).write(to: tempDir.appendingPathComponent("small.bin"))
        try Data(repeating: 0x62, count: 4096).write(to: tempDir.appendingPathComponent("large.bin"))

        navigateLeftPane(to: tempDir.path)

        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let largeName = table.staticTexts["large.bin"]
        let smallName = table.staticTexts["small.bin"]
        XCTAssertTrue(largeName.waitForExistence(timeout: 5))
        XCTAssertTrue(smallName.waitForExistence(timeout: 5))

        XCTAssertLessThan(largeName.frame.minY,
                          smallName.frame.minY,
                          "Saved size-descending sort should place the larger file above the smaller file")

        let nameTextOffset = largeName.frame.minX - table.frame.minX
        XCTAssertGreaterThan(nameTextOffset,
                             300,
                             "Saved size column width should shift the name column to the right")
        XCTAssertLessThan(nameTextOffset,
                          360,
                          "Saved size column width should be restored within the expected table geometry")
        XCTAssertGreaterThan(largeName.frame.width,
                             300,
                             "Saved name column width should be reflected in the name cell text field")
    }

    private static let fileSystemListViewInfoArgumentValue: String = {
        let propertyList: [String: Any] = [
            "version": 1,
            "sortKey": "size",
            "ascending": false,
            "columns": [
                ["id": "size", "isVisible": true, "width": 280.0],
                ["id": "name", "isVisible": true, "width": 360.0],
                ["id": "modified", "isVisible": true, "width": 140.0],
                ["id": "created", "isVisible": true, "width": 140.0],
            ],
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: propertyList,
                                                          format: .xml,
                                                          options: 0)
            return "<data>\(data.base64EncodedString())</data>"
        } catch {
            fatalError("Could not encode list-view defaults for UI test: \(error)")
        }
    }()
}
