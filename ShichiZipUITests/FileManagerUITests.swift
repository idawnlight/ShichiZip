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
}
