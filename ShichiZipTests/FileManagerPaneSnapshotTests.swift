import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerPaneSnapshotTests: XCTestCase {
    func testFileOperationInfoTextIncludesLocationAndDisplayedNames() {
        let snapshot = makeSnapshot(
            currentLocationDisplayPath: "/tmp/source",
            displayedNames: ["a.txt", "b.txt"],
        )

        XCTAssertEqual(snapshot.fileOperationInfoText,
                       "/tmp/source\n  a.txt\n  b.txt")
    }

    func testFileOperationInfoTextMarksHiddenDisplayedNames() {
        let snapshot = makeSnapshot(
            displayedNames: ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"],
            realItemCount: 6,
        )

        XCTAssertEqual(snapshot.fileOperationInfoText,
                       "/tmp/source\n  a.txt\n  b.txt\n  c.txt\n  d.txt\n  e.txt\n  ...")
    }

    func testSelectionSnapshotReportsHiddenNamesWhenRealCountExceedsDisplayedNames() {
        XCTAssertFalse(FileManagerPaneSelectionSnapshot(fileURLs: [],
                                                        displayedNames: ["a.txt", "b.txt"],
                                                        realItemCount: 2).hasHiddenDisplayedNames)
        XCTAssertTrue(FileManagerPaneSelectionSnapshot(fileURLs: [],
                                                       displayedNames: ["a.txt", "b.txt"],
                                                       realItemCount: 3).hasHiddenDisplayedNames)
    }

    private func makeSnapshot(currentLocationDisplayPath: String = "/tmp/source",
                              displayedNames: [String] = [],
                              realItemCount: Int? = nil) -> FileManagerPaneSnapshot
    {
        let selection = FileManagerPaneSelectionSnapshot(fileURLs: [],
                                                         displayedNames: displayedNames,
                                                         realItemCount: realItemCount ?? displayedNames.count)
        let capabilities = FileManagerPaneCapabilities(
            selection: FileManagerPaneSelectionState(tableModel: FileManagerPaneTableModel(fileSystemItems: [], showsParentRow: false),
                                                     selectedRowIndexes: []),
            commandState: FileManagerPaneCommandState(isInsideArchive: false,
                                                      supportsInPlaceArchiveMutation: false,
                                                      hasCurrentArchive: false,
                                                      canGoUp: false,
                                                      canSelectVisibleItems: false,
                                                      canDeselectSelection: false,
                                                      canShowFoldersHistory: false),
        )
        return FileManagerPaneSnapshot(currentDirectoryURL: URL(fileURLWithPath: "/tmp/source", isDirectory: true),
                                       currentLocationDisplayPath: currentLocationDisplayPath,
                                       isVirtualLocation: false,
                                       isSuspended: false,
                                       primarySortKey: nil,
                                       currentArchiveDestinationDisplayPath: nil,
                                       recentDirectoryHistory: [],
                                       acceptsFilePaste: true,
                                       selectedArchiveCandidateURL: nil,
                                       selection: selection,
                                       selectedSingleFileSystemFile: nil,
                                       suggestedExtractDestinationName: nil,
                                       extractDialogInfoText: "",
                                       sourceArchiveURLForPostProcessing: nil,
                                       quarantineSourceArchiveURLForExtraction: nil,
                                       capabilities: capabilities)
    }
}
