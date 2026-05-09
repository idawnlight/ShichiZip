import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileManagerPaneDirectoryCoordinatorTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // https://github.com/swiftlang/swift/issues/85663
        // Fixed in https://github.com/swiftlang/swift/pull/85204 but only released with Swift 6.3+, so skip affected macOS 26.0-26.3 runtimes.
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion == 26, version.minorVersion < 4 else { return }
        throw XCTSkip("macOS 26.0-26.3 system Swift runtime crashes when isolated deinit tears down fallback task locals.")
    }

    func testLoadDirectoryAppliesSnapshotAndPresentationCallbacks() throws {
        let directoryURL = try makeTemporaryDirectory(named: "load-directory",
                                                      prefix: "ShichiZipDirectoryCoordinatorTests")
        try "alpha".write(to: directoryURL.appendingPathComponent("alpha.txt"),
                          atomically: true,
                          encoding: .utf8)
        try "beta".write(to: directoryURL.appendingPathComponent("beta.txt"),
                         atomically: true,
                         encoding: .utf8)
        var didUpdatePathField = false
        var didUpdateStatusBar = false
        var didUpdateTableColumns = false
        var didReloadTableData = false
        let coordinator = makeCoordinator(updatePathField: { didUpdatePathField = true },
                                          updateStatusBar: { didUpdateStatusBar = true },
                                          updateTableColumns: { didUpdateTableColumns = true },
                                          reloadTableData: { didReloadTableData = true })
        defer { coordinator.tearDown() }

        XCTAssertTrue(coordinator.loadDirectory(directoryURL))

        XCTAssertEqual(coordinator.currentDirectory.standardizedFileURL,
                       directoryURL.standardizedFileURL)
        XCTAssertEqual(Set(coordinator.items.map(\.name)), ["alpha.txt", "beta.txt"])
        XCTAssertEqual(coordinator.recentDirectoryHistory().first,
                       directoryURL.standardizedFileURL)
        XCTAssertTrue(didUpdatePathField)
        XCTAssertTrue(didUpdateStatusBar)
        XCTAssertTrue(didUpdateTableColumns)
        XCTAssertTrue(didReloadTableData)
    }

    func testPrepareForSuspensionClearsPresentedItemsAndReloadsTable() throws {
        let directoryURL = try makeTemporaryDirectory(named: "suspend-directory",
                                                      prefix: "ShichiZipDirectoryCoordinatorTests")
        try "payload".write(to: directoryURL.appendingPathComponent("payload.txt"),
                            atomically: true,
                            encoding: .utf8)
        var reloadCount = 0
        let coordinator = makeCoordinator(reloadTableData: { reloadCount += 1 })
        defer { coordinator.tearDown() }

        XCTAssertTrue(coordinator.loadDirectory(directoryURL))
        XCTAssertFalse(coordinator.items.isEmpty)

        coordinator.prepareForSuspension()

        XCTAssertTrue(coordinator.items.isEmpty)
        XCTAssertGreaterThanOrEqual(reloadCount, 2)
    }

    func testPrepareForArchivePresentationUpdatesCurrentDirectoryAndHistory() throws {
        let hostDirectory = try makeTemporaryDirectory(named: "archive-host",
                                                       prefix: "ShichiZipDirectoryCoordinatorTests")
        let coordinator = makeCoordinator()
        defer { coordinator.tearDown() }

        coordinator.prepareForArchivePresentation(hostDirectory: hostDirectory)

        XCTAssertEqual(coordinator.currentDirectory.standardizedFileURL,
                       hostDirectory.standardizedFileURL)
        XCTAssertEqual(coordinator.recentDirectoryHistory().first,
                       hostDirectory.standardizedFileURL)
    }

    private func makeCoordinator(isViewLoaded: @escaping () -> Bool = { true },
                                 isInsideArchive: @escaping () -> Bool = { false },
                                 showsParentRow: @escaping () -> Bool = { false },
                                 selectedFileSystemItems: @escaping () -> [FileSystemItem] = { [] },
                                 focusedFileSystemItemPath: @escaping () -> String? = { nil },
                                 clearSuspendedState: @escaping () -> Void = {},
                                 updatePathField: @escaping () -> Void = {},
                                 updateStatusBar: @escaping () -> Void = {},
                                 updateTableColumns: @escaping () -> Void = {},
                                 sortCurrentItems: @escaping () -> Void = {},
                                 reloadTableData: @escaping () -> Void = {},
                                 focusFileList: @escaping () -> Void = {},
                                 selectRows: @escaping (IndexSet) -> Void = { _ in },
                                 deselectRows: @escaping () -> Void = {},
                                 scrollRowToVisible: @escaping (Int) -> Void = { _ in },
                                 showError: @escaping (Error) -> Void = { error in XCTFail("Unexpected directory coordinator error: \(error)") },
                                 directoryDidChange: @escaping () -> Void = {}) -> FileManagerPaneDirectoryCoordinator
    {
        FileManagerPaneDirectoryCoordinator(isViewLoaded: isViewLoaded,
                                            isInsideArchive: isInsideArchive,
                                            showsParentRow: showsParentRow,
                                            selectedFileSystemItems: selectedFileSystemItems,
                                            focusedFileSystemItemPath: focusedFileSystemItemPath,
                                            clearSuspendedState: clearSuspendedState,
                                            updatePathField: updatePathField,
                                            updateStatusBar: updateStatusBar,
                                            updateTableColumns: updateTableColumns,
                                            sortCurrentItems: sortCurrentItems,
                                            reloadTableData: reloadTableData,
                                            focusFileList: focusFileList,
                                            selectRows: selectRows,
                                            deselectRows: deselectRows,
                                            scrollRowToVisible: scrollRowToVisible,
                                            showError: showError,
                                            directoryDidChange: directoryDidChange)
    }
}
