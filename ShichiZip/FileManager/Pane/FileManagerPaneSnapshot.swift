import Foundation

struct FileManagerPaneCapabilities {
    let canOpenSelection: Bool
    let canOpenSelectionInside: Bool
    let canOpenSelectionOutside: Bool
    let canAddSelectedItemsToArchive: Bool
    let canExtractSelectionOrArchive: Bool
    let canTestArchiveSelection: Bool
    let canCopySelection: Bool
    let canMoveSelection: Bool
    let canRenameSelection: Bool
    let canCreateFolderHere: Bool
    let canCreateFileHere: Bool
    let canDeleteSelection: Bool
    let canShowSelectedItemProperties: Bool
    let canCalculateSelectionHashes: Bool
    let canGoUp: Bool
    let canSelectVisibleItems: Bool
    let canDeselectSelection: Bool
    let canShowFoldersHistory: Bool
}

struct FileManagerPaneCommandState {
    let isInsideArchive: Bool
    let supportsInPlaceArchiveMutation: Bool
    let hasCurrentArchive: Bool
    let canGoUp: Bool
    let canSelectVisibleItems: Bool
    let canDeselectSelection: Bool
    let canShowFoldersHistory: Bool
}

extension FileManagerPaneCapabilities {
    init(selection: FileManagerPaneSelectionState,
         commandState: FileManagerPaneCommandState)
    {
        let hasFileSystemSelection = !selection.fileSystemItems.isEmpty
        let hasArchiveSelection = !selection.archiveItems.isEmpty
        let isInsideArchive = commandState.isInsideArchive
        let supportsInPlaceArchiveMutation = commandState.supportsInPlaceArchiveMutation

        self.init(canOpenSelection: !selection.items.isEmpty,
                  canOpenSelectionInside: selection.realItems.count == 1,
                  canOpenSelectionOutside: Self.canOpenOutside(selection.singleRealItem),
                  canAddSelectedItemsToArchive: isInsideArchive ? supportsInPlaceArchiveMutation : hasFileSystemSelection,
                  canExtractSelectionOrArchive: isInsideArchive ? !selection.archiveItemsForSelectionOrDisplayedItems.isEmpty : selection.archiveCandidateURL != nil,
                  canTestArchiveSelection: isInsideArchive ? commandState.hasCurrentArchive : selection.archiveCandidateURL != nil,
                  canCopySelection: isInsideArchive ? hasArchiveSelection : hasFileSystemSelection,
                  canMoveSelection: !isInsideArchive && hasFileSystemSelection,
                  canRenameSelection: isInsideArchive ? supportsInPlaceArchiveMutation && selection.archiveItems.count == 1 : selection.fileSystemItems.count == 1,
                  canCreateFolderHere: isInsideArchive ? supportsInPlaceArchiveMutation : true,
                  canCreateFileHere: !isInsideArchive,
                  canDeleteSelection: isInsideArchive ? supportsInPlaceArchiveMutation && hasArchiveSelection : hasFileSystemSelection,
                  canShowSelectedItemProperties: !selection.realItems.isEmpty,
                  canCalculateSelectionHashes: selection.singleFileSystemFile != nil,
                  canGoUp: commandState.canGoUp,
                  canSelectVisibleItems: commandState.canSelectVisibleItems,
                  canDeselectSelection: commandState.canDeselectSelection,
                  canShowFoldersHistory: commandState.canShowFoldersHistory)
    }

    private static func canOpenOutside(_ item: FileManagerPaneItem?) -> Bool {
        guard let item else { return false }

        switch item {
        case .parent:
            return false
        case .filesystem:
            return true
        case let .archive(archiveItem):
            return !archiveItem.isDirectory
        }
    }
}

struct FileManagerPaneSelectionSnapshot {
    let fileURLs: [URL]
    let displayedNames: [String]
    let realItemCount: Int

    var hasHiddenDisplayedNames: Bool {
        realItemCount > displayedNames.count
    }
}

struct FileManagerPaneSelectedFileSnapshot {
    let url: URL
    let name: String
}

struct FileManagerPaneSnapshot {
    let currentDirectoryURL: URL
    let currentLocationDisplayPath: String
    let isVirtualLocation: Bool
    let isSuspended: Bool
    let primarySortKey: String?
    let currentArchiveDestinationDisplayPath: String?
    let recentDirectoryHistory: [URL]
    let acceptsFilePaste: Bool
    let selectedArchiveCandidateURL: URL?
    let selection: FileManagerPaneSelectionSnapshot
    let selectedSingleFileSystemFile: FileManagerPaneSelectedFileSnapshot?
    let suggestedExtractDestinationName: String?
    let extractDialogInfoText: String
    let sourceArchiveURLForPostProcessing: URL?
    let quarantineSourceArchiveURLForExtraction: URL?
    let capabilities: FileManagerPaneCapabilities

    var fileOperationInfoText: String {
        var lines = [currentLocationDisplayPath]
        lines.append(contentsOf: selection.displayedNames.map { "  \($0)" })

        if selection.hasHiddenDisplayedNames {
            lines.append("  ...")
        }

        return lines.joined(separator: "\n")
    }
}

@MainActor
extension FileManagerPaneController {
    var snapshot: FileManagerPaneSnapshot {
        let selection = paneSelectionState
        let commandState = paneCommandState
        let selectedSingleFileSystemFile = selection.singleFileSystemFile
        let capabilities = makePaneCapabilities(selection: selection,
                                                commandState: commandState)

        return FileManagerPaneSnapshot(
            currentDirectoryURL: currentDirectoryURL,
            currentLocationDisplayPath: currentLocationDisplayPath,
            isVirtualLocation: isVirtualLocation,
            isSuspended: isSuspended,
            primarySortKey: primarySortKey,
            currentArchiveDestinationDisplayPath: currentArchiveDestinationDisplayPath(),
            recentDirectoryHistory: recentDirectoryHistory(),
            acceptsFilePaste: !isVirtualLocation || supportsInPlaceArchiveMutation,
            selectedArchiveCandidateURL: selection.archiveCandidateURL,
            selection: FileManagerPaneSelectionSnapshot(fileURLs: selection.fileURLs,
                                                        displayedNames: selectedItemNames(limit: 5),
                                                        realItemCount: selection.realItems.count),
            selectedSingleFileSystemFile: selectedSingleFileSystemFile.map {
                FileManagerPaneSelectedFileSnapshot(url: $0.url,
                                                    name: $0.name)
            },
            suggestedExtractDestinationName: suggestedExtractDestinationName,
            extractDialogInfoText: extractDialogInfoText(),
            sourceArchiveURLForPostProcessing: sourceArchiveURLForPostProcessing(),
            quarantineSourceArchiveURLForExtraction: quarantineSourceArchiveURLForExtraction(),
            capabilities: capabilities,
        )
    }

    private func makePaneCapabilities(selection: FileManagerPaneSelectionState,
                                      commandState: FileManagerPaneCommandState) -> FileManagerPaneCapabilities
    {
        FileManagerPaneCapabilities(selection: selection,
                                    commandState: commandState)
    }
}
