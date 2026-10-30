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
            selection: FileManagerPaneSelectionSnapshot(fileURLs: [URL(fileURLWithPath: "/tmp/source/a.txt"),
                                                                   URL(fileURLWithPath: "/tmp/source/b.txt")],
                                                        displayedNames: ["a.txt", "b.txt"],
                                                        realItemCount: 2),
        )

        XCTAssertEqual(snapshot.fileOperationInfoText,
                       "/tmp/source\n  a.txt\n  b.txt")
    }

    func testFileOperationInfoTextMarksHiddenDisplayedNames() {
        let snapshot = makeSnapshot(
            currentLocationDisplayPath: "/tmp/source",
            selection: FileManagerPaneSelectionSnapshot(fileURLs: [],
                                                        displayedNames: ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"],
                                                        realItemCount: 6),
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

    private func makeSnapshot(currentDirectoryURL: URL = URL(fileURLWithPath: "/tmp/source", isDirectory: true),
                              currentLocationDisplayPath: String = "/tmp/source",
                              isVirtualLocation: Bool = false,
                              isSuspended: Bool = false,
                              primarySortKey: String? = nil,
                              currentArchiveDestinationDisplayPath: String? = nil,
                              recentDirectoryHistory: [URL] = [],
                              acceptsFilePaste: Bool = true,
                              selectedArchiveCandidateURL: URL? = nil,
                              selection: FileManagerPaneSelectionSnapshot = FileManagerPaneSelectionSnapshot(fileURLs: [],
                                                                                                             displayedNames: [],
                                                                                                             realItemCount: 0),
                              selectedSingleFileSystemFile: FileManagerPaneSelectedFileSnapshot? = nil,
                              suggestedExtractDestinationName: String? = nil,
                              extractDialogInfoText: String = "",
                              sourceArchiveURLForPostProcessing: URL? = nil,
                              quarantineSourceArchiveURLForExtraction: URL? = nil,
                              capabilities: FileManagerPaneCapabilities = unavailableCapabilities()) -> FileManagerPaneSnapshot
    {
        FileManagerPaneSnapshot(currentDirectoryURL: currentDirectoryURL,
                                currentLocationDisplayPath: currentLocationDisplayPath,
                                isVirtualLocation: isVirtualLocation,
                                isSuspended: isSuspended,
                                primarySortKey: primarySortKey,
                                currentArchiveDestinationDisplayPath: currentArchiveDestinationDisplayPath,
                                recentDirectoryHistory: recentDirectoryHistory,
                                acceptsFilePaste: acceptsFilePaste,
                                selectedArchiveCandidateURL: selectedArchiveCandidateURL,
                                selection: selection,
                                selectedSingleFileSystemFile: selectedSingleFileSystemFile,
                                suggestedExtractDestinationName: suggestedExtractDestinationName,
                                extractDialogInfoText: extractDialogInfoText,
                                sourceArchiveURLForPostProcessing: sourceArchiveURLForPostProcessing,
                                quarantineSourceArchiveURLForExtraction: quarantineSourceArchiveURLForExtraction,
                                capabilities: capabilities)
    }

    private static func unavailableCapabilities() -> FileManagerPaneCapabilities {
        FileManagerPaneCapabilities(canOpenSelection: false,
                                    canOpenSelectionInside: false,
                                    canOpenSelectionOutside: false,
                                    canAddSelectedItemsToArchive: false,
                                    canExtractSelectionOrArchive: false,
                                    canTestArchiveSelection: false,
                                    canCopySelection: false,
                                    canMoveSelection: false,
                                    canRenameSelection: false,
                                    canCreateFolderHere: false,
                                    canCreateFileHere: false,
                                    canDeleteSelection: false,
                                    canShowSelectedItemProperties: false,
                                    canCalculateSelectionHashes: false,
                                    canGoUp: false,
                                    canSelectVisibleItems: false,
                                    canDeselectSelection: false,
                                    canShowFoldersHistory: false)
    }
}
