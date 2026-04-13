import XCTest

/// Base class for ShichiZip UI tests.
///
/// Provides a launched app instance and common helpers for
/// navigating the file manager, opening archives, and interacting
/// with dialogs.
class ShichiZipUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Helpers

    /// The file manager window (first window shown on launch).
    var fileManagerWindow: XCUIElement {
        app.windows.firstMatch
    }

    /// Returns the left pane's file table.
    var leftPaneTable: XCUIElement {
        app.tables.matching(identifier: "fileManager.tableView").firstMatch
    }

    /// Returns the path field in the left pane.
    var leftPanePathField: XCUIElement {
        app.textFields.matching(identifier: "fileManager.pathField").firstMatch
    }

    /// Navigates the left pane to the given directory path by typing into the path field.
    func navigateLeftPane(to path: String) {
        let pathField = leftPanePathField
        pathField.click()
        pathField.selectAll()
        pathField.typeText(path + "\r")
    }

    /// Creates a temporary directory for test fixtures and returns its path.
    /// Registers a teardown block to remove it.
    func makeTemporaryDirectory(named name: String = "UITest") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShichiZipUITests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Creates a simple text file at the given URL.
    func createTextFile(at url: URL, content: String = "test content") throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Waits for a UI element to exist, with a configurable timeout.
    @discardableResult
    func waitForElement(_ element: XCUIElement,
                        timeout: TimeInterval = 10,
                        message: String? = nil) -> Bool
    {
        let exists = element.waitForExistence(timeout: timeout)
        if !exists, let message {
            XCTFail(message)
        }
        return exists
    }
}

// MARK: - XCUIElement Helpers

extension XCUIElement {
    /// Select all text in a text field (Cmd-A).
    func selectAll() {
        typeKey("a", modifierFlags: .command)
    }
}
