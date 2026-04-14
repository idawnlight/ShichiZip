import XCTest

/// Base class for ShichiZip UI tests.
///
/// Provides a launched app instance and common helpers for
/// navigating the file manager, opening archives, and interacting
/// with dialogs.
@MainActor
class ShichiZipUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() async throws {
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

    // MARK: - Archive Creation

    /// Creates a test archive from the given source file names that already
    /// exist in `directory`.  Paths inside the archive are relative to
    /// `directory`.  Uses the 7z CLI when available, otherwise falls back
    /// to a ditto-produced .zip.
    ///
    /// Returns the URL of the created archive.
    func createTestArchive(named name: String,
                           sourceFileNames: [String],
                           in directory: URL) throws -> URL
    {
        if FileManager.default.fileExists(atPath: "/usr/local/bin/7z") {
            let archiveURL = directory.appendingPathComponent("\(name).7z")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/7z")
            process.arguments = ["a", archiveURL.path] + sourceFileNames
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ShichiZipUITests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "7z archive creation failed"])
            }
            return archiveURL
        } else {
            // ditto archives a directory tree, so stage the files first.
            let stageDir = directory.appendingPathComponent("__stage__", isDirectory: true)
            try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
            for fileName in sourceFileNames {
                try FileManager.default.copyItem(
                    at: directory.appendingPathComponent(fileName),
                    to: stageDir.appendingPathComponent(fileName),
                )
            }

            let archiveURL = directory.appendingPathComponent("\(name).zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", stageDir.path, archiveURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try FileManager.default.removeItem(at: stageDir)
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ShichiZipUITests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "zip archive creation failed"])
            }
            return archiveURL
        }
    }

    /// Convenience: creates a temp directory, writes the given payload
    /// files, archives them, then removes the loose source files.
    ///
    /// Returns `(archiveURL, containingDirectory)`.
    func makeTestArchive(named name: String,
                         payloads: [String: String] = ["payload.txt": "test content"]) throws -> (archive: URL, directory: URL)
    {
        let tempDir = try makeTemporaryDirectory(named: name)
        for (fileName, content) in payloads {
            try createTextFile(at: tempDir.appendingPathComponent(fileName), content: content)
        }

        let archiveURL = try createTestArchive(named: name,
                                               sourceFileNames: Array(payloads.keys),
                                               in: tempDir)

        // Remove the loose source files so only the archive is listed.
        for fileName in payloads.keys {
            try FileManager.default.removeItem(at: tempDir.appendingPathComponent(fileName))
        }
        return (archiveURL, tempDir)
    }

    // MARK: - File Polling

    /// Polls for a file at `url` until it appears or `timeout` expires.
    func waitForFile(at url: URL, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            usleep(500_000)
        }
        return false
    }
}

// MARK: - XCUIElement Helpers

extension XCUIElement {
    /// Select all text in a text field (Cmd-A).
    func selectAll() {
        typeKey("a", modifierFlags: .command)
    }
}
