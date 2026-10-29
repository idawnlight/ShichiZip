import AppKit
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileManagerPaneCoordinatorHostTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipIfAffectedByIsolatedDeinitTaskLocalRuntimeBug()
    }

    func testDirectoryPresentationSortsRowsAndRestoresRevealedSelection() async throws {
        let directory = try makeTemporaryDirectory(named: "host-directory")
        let alpha = directory.appendingPathComponent("alpha.txt")
        try "alpha".write(to: alpha, atomically: true, encoding: .utf8)
        try "beta".write(to: directory.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
        let pane = FileManagerPaneController()
        let view = try XCTUnwrap(pane.view as? FileManagerPaneView)
        sortByDescendingNameWithoutSaving(view.tableView)
        view.pathField.stringValue = "stale"
        view.statusView.clear()

        XCTAssertTrue(pane.loadDirectory(directory))

        XCTAssertEqual(view.pathField.stringValue, directory.standardizedFileURL.path)
        XCTAssertEqual(displayedNames(in: pane, tableView: view.tableView), ["beta.txt", "alpha.txt"])
        XCTAssertFalse(view.statusView.summaryLabel.stringValue.isEmpty)
        let unselectedSummary = view.statusView.summaryLabel.stringValue

        let revealed = await pane.revealFileSystemItemURLs([alpha])
        XCTAssertTrue(revealed)
        await waitForSelection(of: alpha, in: pane)

        XCTAssertEqual(pane.selectedFileURLs().map(\.standardizedFileURL.path), [alpha.standardizedFileURL.path])
        XCTAssertEqual(view.tableView.selectedRow, 1 + (pane.showsParentRow ? 1 : 0))
        XCTAssertEqual(displayedNames(in: pane, tableView: view.tableView), ["beta.txt", "alpha.txt"])
        XCTAssertNotEqual(view.statusView.summaryLabel.stringValue, unselectedSummary)
    }

    func testArchivePresentationNavigatesAndReturnsToHostDirectory() async throws {
        let directory = try makeTemporaryDirectory(named: "host-archive")
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for name in ["alpha.txt", "beta.txt"] {
            try name.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let archiveURL = directory.appendingPathComponent("sample.7z")
        try createArchive(at: archiveURL, from: [folder])
        let pane = FileManagerPaneController()
        let view = try XCTUnwrap(pane.view as? FileManagerPaneView)
        XCTAssertTrue(pane.loadDirectory(directory))
        let fileSystemColumns = view.tableView.tableColumns.map(\.identifier)
        let openGeneration = try XCTUnwrap(pane.beginArchiveOpen())
        let prepared = FileManagerArchiveOpenService.prepareArchiveOpen(
            url: archiveURL,
            hostDirectory: directory,
            temporaryDirectory: nil,
            displayPathPrefix: archiveURL.path,
            nestedWriteBackInfo: nil,
            openMode: .defaultBehavior,
            session: SZOperationSession(),
        )
        let result = await pane.finishArchiveOpen(prepared,
                                                  temporaryDirectory: nil,
                                                  preserveTemporaryDirectoryOnUnsupported: false,
                                                  replaceCurrentState: false,
                                                  showError: false,
                                                  expectedOpenGeneration: openGeneration)

        if case .opened = result {
            XCTAssertEqual(view.pathField.stringValue, archiveURL.path)
            XCTAssertEqual(displayedNames(in: pane, tableView: view.tableView), ["folder"])
            if let level = pane.currentArchiveLevel {
                let columns = FileManagerColumn.archiveColumns(entryProperties: level.entryProperties)
                let folderTypeID = FileManagerViewPreferences.archiveListViewFolderTypeID(formatName: level.archive.formatName)
                let expectedColumns = FileManagerViewPreferences.resolvedListViewColumns(
                    columns,
                    using: FileManagerViewPreferences.listViewInfo(forFolderTypeID: folderTypeID),
                ).map { NSUserInterfaceItemIdentifier($0.column.id.rawValue) }
                XCTAssertEqual(view.tableView.tableColumns.map(\.identifier), expectedColumns)
            } else {
                XCTFail("Opening an archive must install its current level")
            }
            sortByDescendingNameWithoutSaving(view.tableView)
            view.statusView.clear()

            pane.navigateArchiveSubdir("folder")

            XCTAssertEqual(view.pathField.stringValue, archiveURL.path + "/folder")
            XCTAssertEqual(displayedNames(in: pane, tableView: view.tableView), ["beta.txt", "alpha.txt"])
            XCTAssertFalse(view.statusView.summaryLabel.stringValue.isEmpty)

            let revealed = await pane.revealFileSystemItemURLs([archiveURL])
            XCTAssertTrue(revealed)
            await waitForSelection(of: archiveURL, in: pane)

            XCTAssertFalse(pane.isInsideArchive)
            XCTAssertEqual(view.pathField.stringValue, directory.standardizedFileURL.path)
            XCTAssertEqual(view.tableView.tableColumns.map(\.identifier), fileSystemColumns)
            XCTAssertEqual(Set(displayedNames(in: pane, tableView: view.tableView)), ["folder", "sample.7z"])
            XCTAssertEqual(pane.selectedFileURLs().map(\.standardizedFileURL.path), [archiveURL.standardizedFileURL.path])
        } else {
            XCTFail("Expected the real archive to open in the pane")
        }
        let didClose = await pane.closeAllArchives(showError: false)
        XCTAssertTrue(didClose)
    }

    private func sortByDescendingNameWithoutSaving(_ tableView: NSTableView) {
        let delegate = tableView.delegate
        tableView.delegate = nil
        tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false,
                                                     selector: #selector(NSString.localizedStandardCompare(_:)))]
        tableView.delegate = delegate
    }

    private func displayedNames(in pane: FileManagerPaneController, tableView: NSTableView) -> [String] {
        (0 ..< tableView.numberOfRows).compactMap { row in
            switch pane.paneItem(at: row) {
            case let .filesystem(item): item.name
            case let .archive(item): item.name
            case .parent, nil: nil
            }
        }
    }

    private func waitForSelection(of url: URL, in pane: FileManagerPaneController) async {
        for _ in 0 ..< 200 {
            if pane.selectedFileURLs().map(\.standardizedFileURL.path) == [url.standardizedFileURL.path] { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
