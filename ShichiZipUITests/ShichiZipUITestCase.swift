import XCTest

/// Base class for ShichiZip UI tests.
///
/// Provides a launched app instance and common helpers for
/// navigating the file manager, opening archives, and interacting
/// with dialogs.
@MainActor
class ShichiZipUITestCase: XCTestCase {
    var app: XCUIApplication!

    /// Additional launch arguments to pass to the app. Override in
    /// subclasses instead of overriding `setUp()` so the base class
    /// can keep owning the XCUIApplication lifecycle (and so we can
    /// chain to `super.setUp()` without launching the app twice).
    var additionalLaunchArguments: [String] { [] }

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += additionalLaunchArguments
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
        try await super.tearDown()
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

    /// Navigates the left pane to the given directory path by pasting into the path field.
    func navigateLeftPane(to path: String) {
        let pathField = leftPanePathField
        pathField.click()
        pathField.selectAll()
        pathField.pasteText(path)
        pathField.typeText("\r")
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
    /// exist in `directory`. Paths inside the archive are relative to
    /// `directory`. Always produces a `.zip` through the macOS-shipped
    /// `/usr/bin/zip`, so fixtures are reproducible regardless of which
    /// third-party 7z binary the developer has in their PATH and never
    /// silently fall back to a different archive format.
    ///
    /// Returns the URL of the created archive.
    func createTestArchive(named name: String,
                           sourceFileNames: [String],
                           in directory: URL) throws -> URL
    {
        let archiveURL = directory.appendingPathComponent("\(name).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -q: quiet
        // -X: omit platform-specific extra attributes so the archive is
        //     byte-reproducible across machines.
        // --: terminate options before file-name list.
        process.arguments = ["-q", "-X", archiveURL.path, "--"] + sourceFileNames
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ShichiZipUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "/usr/bin/zip failed (status \(process.terminationStatus))"])
        }
        return archiveURL
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

    /// Pastes text via the pasteboard (much faster than `typeText` for long strings).
    func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        typeKey("v", modifierFlags: .command)
        // Restore previous pasteboard content.
        pasteboard.clearContents()
        if let previous {
            pasteboard.setString(previous, forType: .string)
        }
    }
}
