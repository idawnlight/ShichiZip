import AppKit
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileManagerPaneListViewCoordinatorTests: XCTestCase {
    func testUpdateForCurrentLocationUsesLatestLocationProvider() {
        withDisabledListViewInfoPersistence {
            let tableView = NSTableView()
            var location = FileManagerPaneListViewLocation(columns: FileManagerColumn.fileSystemColumns,
                                                           folderTypeID: uniqueFolderTypeID())
            let coordinator = FileManagerPaneListViewCoordinator(tableView: tableView,
                                                                 currentLocation: { location })

            coordinator.updateForCurrentLocation()
            XCTAssertEqual(tableView.tableColumns.map(\.identifier.rawValue), ["name", "size", "modified", "created"])

            location = FileManagerPaneListViewLocation(columns: FileManagerColumn.archiveColumns(availablePropertyKeys: ["method", "crc"]),
                                                       folderTypeID: uniqueFolderTypeID())
            coordinator.updateForCurrentLocation()

            XCTAssertEqual(tableView.tableColumns.map(\.identifier.rawValue), ["name", "method", "crc"])
        }
    }

    func testSortCommandSortsAndReloadsThroughCoordinator() {
        withDisabledListViewInfoPersistence {
            let tableView = NSTableView()
            let folderTypeID = uniqueFolderTypeID()
            var sortedDescriptors: [NSSortDescriptor] = []
            var reloadCount = 0
            let coordinator = FileManagerPaneListViewCoordinator(
                tableView: tableView,
                currentLocation: {
                    FileManagerPaneListViewLocation(columns: FileManagerColumn.fileSystemColumns,
                                                    folderTypeID: folderTypeID)
                },
                sortItems: { sortedDescriptors = $0 },
                reloadTableData: { reloadCount += 1 },
            )
            coordinator.updateForCurrentLocation()

            coordinator.applySortDescriptor(columnIdentifier: "size",
                                            key: "size",
                                            ascending: false)

            XCTAssertEqual(sortedDescriptors.first?.key, "size")
            XCTAssertEqual(sortedDescriptors.first?.ascending, false)
            XCTAssertEqual(tableView.highlightedTableColumn?.identifier.rawValue, "size")
            XCTAssertEqual(reloadCount, 1)
        }
    }

    func testToggleColumnVisibilityUsesCurrentLocationAndRefreshesPresentation() {
        withDisabledListViewInfoPersistence {
            let tableView = NSTableView()
            let folderTypeID = uniqueFolderTypeID()
            var sortedDescriptors: [NSSortDescriptor] = []
            var reloadCount = 0
            let coordinator = FileManagerPaneListViewCoordinator(
                tableView: tableView,
                currentLocation: {
                    FileManagerPaneListViewLocation(columns: FileManagerColumn.fileSystemColumns,
                                                    folderTypeID: folderTypeID)
                },
                sortItems: { sortedDescriptors = $0 },
                reloadTableData: { reloadCount += 1 },
            )
            coordinator.updateForCurrentLocation()
            coordinator.applySortDescriptor(columnIdentifier: "size",
                                            key: "size",
                                            ascending: false)

            let didHideSize = coordinator.toggleColumnVisibility(.size)

            XCTAssertTrue(didHideSize)
            XCTAssertFalse(tableView.tableColumns.contains { $0.identifier.rawValue == "size" })
            XCTAssertEqual(sortedDescriptors.first?.key, "name")
            XCTAssertEqual(tableView.highlightedTableColumn?.identifier.rawValue, "name")
            XCTAssertEqual(reloadCount, 2)
        }
    }

    private func uniqueFolderTypeID() -> String {
        "FileManagerPaneListViewCoordinatorTests.\(UUID().uuidString)"
    }

    private func withDisabledListViewInfoPersistence(_ body: () -> Void) {
        setenv("SHICHIZIP_DISABLE_LIST_VIEW_INFO_PERSISTENCE", "1", 1)
        defer {
            unsetenv("SHICHIZIP_DISABLE_LIST_VIEW_INFO_PERSISTENCE")
        }

        body()
    }
}
