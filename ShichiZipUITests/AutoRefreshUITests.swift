import XCTest

/// Tests for FSEvents-backed auto refresh in the file manager.
///
/// The app is launched with `-FileManager.AutoRefresh YES` so auto refresh
/// is active from the start. External filesystem mutations should be
/// reflected in the file list within roughly one second (FSEvents latency
/// plus the 2-second timer heartbeat).
final class AutoRefreshUITests: ShichiZipUITestCase {
    override var additionalLaunchArguments: [String] {
        ["-FileManager.AutoRefresh", "YES"]
    }

    // MARK: - Tests

    func testExternalMutationsRefreshAutomatically() throws {
        let tempDir = try makeTemporaryDirectory(named: "AutoRefresh")
        let existingFile = tempDir.appendingPathComponent("doomed.txt")
        try createTextFile(at: existingFile)

        navigateLeftPane(to: tempDir.path)

        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        XCTAssertTrue(table.cells.staticTexts["doomed.txt"].waitForExistence(timeout: 5))

        // 1. Create a file externally — should appear
        try createTextFile(at: tempDir.appendingPathComponent("appeared.txt"))
        XCTAssertTrue(table.cells.staticTexts["appeared.txt"].waitForExistence(timeout: 5),
                      "Externally created file should appear via auto refresh")

        // 2. Delete a file externally — should disappear
        try FileManager.default.removeItem(at: existingFile)
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: table.cells.staticTexts["doomed.txt"],
        )
        wait(for: [gone], timeout: 5)

        // 3. Rename a file externally — old name gone, new name visible
        try FileManager.default.moveItem(at: tempDir.appendingPathComponent("appeared.txt"),
                                         to: tempDir.appendingPathComponent("renamed.txt"))
        XCTAssertTrue(table.cells.staticTexts["renamed.txt"].waitForExistence(timeout: 5),
                      "Renamed file should appear via auto refresh")
        XCTAssertFalse(table.cells.staticTexts["appeared.txt"].exists,
                       "Old file name should no longer be visible")
    }
}
