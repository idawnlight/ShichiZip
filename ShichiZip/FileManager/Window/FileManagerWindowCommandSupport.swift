import AppKit

@MainActor
enum FileManagerArchiveCommandSupport {
    static func addToArchive(from activePane: FileManagerPaneController,
                             inactivePaneSnapshot: FileManagerPaneSnapshot?,
                             parentWindow: NSWindow?,
                             refreshPaneDisplayingDirectory: @escaping @MainActor (URL) -> Void,
                             showError: @escaping @MainActor (Error) -> Void)
    {
        let snapshot = activePane.snapshot
        guard snapshot.capabilities.canAddSelectedItemsToArchive else {
            if snapshot.isVirtualLocation, !snapshot.acceptsFilePaste {
                activePane.showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.addingFilesToArchive"))
            }
            return
        }

        if snapshot.isVirtualLocation {
            guard let target = activePane.currentArchiveMutationTarget() else {
                activePane.showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.addingFilesToArchive"))
                return
            }

            promptForFilesToAddToOpenArchive(from: activePane,
                                             target: target,
                                             suggestedDirectory: suggestedArchiveAddSourceDirectory(targetSnapshot: snapshot,
                                                                                                    inactivePaneSnapshot: inactivePaneSnapshot),
                                             parentWindow: parentWindow)
            return
        }

        let selectedURLs = snapshot.selection.fileURLs
        guard !selectedURLs.isEmpty else { return }

        let baseDirectory = snapshot.currentDirectoryURL

        Task { @MainActor [weak activePane, weak parentWindow] in
            guard let activePane else { return }

            let compressDialog = CompressDialogController(sourceURLs: selectedURLs,
                                                          baseDirectory: baseDirectory)
            guard let result = await compressDialog.runModal(for: parentWindow),
                  let parentWindow
            else {
                return
            }

            do {
                try await createArchive(from: selectedURLs,
                                        result: result,
                                        parentWindow: parentWindow)
                activePane.refresh()
                refreshPaneDisplayingDirectory(result.archiveURL.deletingLastPathComponent())
            } catch {
                showError(error)
            }
        }
    }

    static func extractArchive(from activePane: FileManagerPaneController,
                               inactivePaneSnapshot: FileManagerPaneSnapshot?,
                               parentWindow: NSWindow?,
                               refreshPaneDisplayingDirectory: @escaping @MainActor (URL) -> Void,
                               showError: @escaping @MainActor (Error) -> Void)
    {
        let snapshot = activePane.snapshot
        guard snapshot.capabilities.canExtractSelectionOrArchive else { return }

        if snapshot.isVirtualLocation {
            Task { @MainActor [weak activePane, weak parentWindow] in
                guard let activePane else { return }
                await copyArchiveItemsFromOpenArchive(from: activePane,
                                                      snapshot: snapshot,
                                                      inactivePaneSnapshot: inactivePaneSnapshot,
                                                      parentWindow: parentWindow,
                                                      refreshPaneDisplayingDirectory: refreshPaneDisplayingDirectory,
                                                      showError: showError)
            }
            return
        }

        Task { @MainActor [weak activePane, weak parentWindow] in
            guard activePane != nil,
                  let extractResult = await promptForArchiveDestination(from: snapshot,
                                                                        parentWindow: parentWindow),
                  let parentWindow
            else {
                return
            }

            let sourceArchiveURL = snapshot.sourceArchiveURLForPostProcessing
            let archiveCandidateURL = snapshot.selectedArchiveCandidateURL

            do {
                try await extractArchiveCandidate(archiveCandidateURL,
                                                  result: extractResult,
                                                  parentWindow: parentWindow)

                let postProcessResult: ArchiveExtractionPostProcessResult
                let postProcessError: Error?
                do {
                    postProcessResult = try ArchiveExtractionPostProcessor.finalizeExtraction(sourceArchiveURL: sourceArchiveURL,
                                                                                              moveSourceArchiveToTrash: extractResult.moveArchiveToTrashAfterExtraction)
                    postProcessError = nil
                } catch {
                    postProcessResult = ArchiveExtractionPostProcessResult(movedSourceArchiveToTrash: false)
                    postProcessError = error
                }
                refreshPaneDisplayingDirectory(extractResult.destinationURL)
                if postProcessResult.movedSourceArchiveToTrash,
                   let sourceArchiveURL
                {
                    refreshPaneDisplayingDirectory(sourceArchiveURL.deletingLastPathComponent())
                }
                NSWorkspace.shared.open(extractResult.destinationURL)
                if let postProcessError {
                    showError(postProcessError)
                }
            } catch {
                showError(error)
            }
        }
    }

    static func extractArchiveSmart(from activePane: FileManagerPaneController,
                                    parentWindow: NSWindow?,
                                    refreshPaneDisplayingDirectory: @escaping @MainActor (URL) -> Void)
    {
        let snapshot = activePane.snapshot
        guard !snapshot.isVirtualLocation,
              let archiveURL = snapshot.selectedArchiveCandidateURL
        else { return }

        SmartExtractRunner.extract(archiveURL: archiveURL,
                                   defaults: ExtractDialogController.quickActionDefaults(),
                                   parentWindow: parentWindow,
                                   shouldRevealDestination: { false })
        { destinationURL in
            if let destinationURL {
                refreshPaneDisplayingDirectory(destinationURL.deletingLastPathComponent())
            }
        }
    }

    private static func copyArchiveItemsFromOpenArchive(from activePane: FileManagerPaneController,
                                                        snapshot: FileManagerPaneSnapshot,
                                                        inactivePaneSnapshot: FileManagerPaneSnapshot?,
                                                        parentWindow: NSWindow?,
                                                        refreshPaneDisplayingDirectory: @escaping @MainActor (URL) -> Void,
                                                        showError: @escaping @MainActor (Error) -> Void) async
    {
        let prompt = FileOperationDestinationPrompt(move: false,
                                                    sourcePane: activePane,
                                                    defaultPath: suggestedDestinationPath(sourceSnapshot: snapshot,
                                                                                          inactivePaneSnapshot: inactivePaneSnapshot),
                                                    infoText: snapshot.extractDialogInfoText)
        { _ in
            true
        }

        guard let unresolvedDestinationTarget = await prompt.run(for: parentWindow) else { return }

        let destinationTarget: FileOperationDestinationTarget
        do {
            switch unresolvedDestinationTarget {
            case .directory:
                destinationTarget = unresolvedDestinationTarget
            case .archive:
                destinationTarget = try FileOperationDestinationResolver.prepare(unresolvedDestinationTarget)
            }
        } catch {
            showError(error)
            return
        }

        switch destinationTarget {
        case let .directory(destinationURL):
            guard let parentWindow else { return }

            do {
                let prepared = try activePane.prepareExtraction(to: destinationURL,
                                                                overwriteMode: .ask)
                try await copyPreparedArchiveItems(prepared,
                                                   parentWindow: parentWindow)
                refreshPaneDisplayingDirectory(destinationURL)
            } catch {
                showError(error)
            }
        case .archive:
            szPresentMessage(title: SZL10n.string("app.fileManager.operationNotAvailable"),
                             message: "Copying items from an open archive directly into another archive is not implemented yet.",
                             for: parentWindow)
        }
    }

    static func testArchive(from activePane: FileManagerPaneController,
                            parentWindow: NSWindow?,
                            showError: @escaping @MainActor (Error) -> Void)
    {
        let snapshot = activePane.snapshot
        guard snapshot.capabilities.canTestArchiveSelection else { return }

        let isVirtualLocation = snapshot.isVirtualLocation
        let archiveCandidateURL = isVirtualLocation ? nil : snapshot.selectedArchiveCandidateURL

        Task { @MainActor [weak activePane, weak parentWindow] in
            guard let activePane,
                  let parentWindow
            else { return }

            do {
                if isVirtualLocation {
                    let leasedArchive = try activePane.currentArchiveForTest()
                    try await testPreparedArchive(leasedArchive,
                                                  parentWindow: parentWindow)
                } else {
                    try await testArchiveCandidate(archiveCandidateURL,
                                                   parentWindow: parentWindow)
                }
                szPresentMessage(title: SZL10n.string("app.fileManager.testOK"),
                                 message: SZL10n.string("archive.noErrors"),
                                 for: parentWindow)
            } catch {
                showError(error)
            }
        }
    }

    static func promptForFilesToAddToOpenArchive(from sourcePane: FileManagerPaneController,
                                                 target: (archive: SZArchive, subdir: String),
                                                 suggestedDirectory: URL,
                                                 parentWindow: NSWindow?)
    {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.resolvesAliases = true
        openPanel.prompt = SZL10n.string("toolbar.add")
        openPanel.message = SZL10n.string("app.fileManager.selectFilesToAdd")
        openPanel.directoryURL = suggestedDirectory

        let handleSelection = {
            let selectedURLs = openPanel.urls.map(\.standardizedFileURL)
            guard !selectedURLs.isEmpty else { return }
            sourcePane.beginConfirmedArchiveTransfer(selectedURLs,
                                                     to: target,
                                                     operation: .copy,
                                                     sourcePane: nil,
                                                     parentWindow: parentWindow)
        }

        openPanel.szBeginSheetOrRunModal(for: parentWindow) { response in
            guard response == .OK else {
                return
            }
            handleSelection()
        }
    }

    static func createArchive(from sourceURLs: [URL],
                              result: CompressDialogResult,
                              parentWindow: NSWindow) async throws
    {
        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.compressing"),
                                             parentWindow: parentWindow)
        { session in
            try SZArchive.create(atPath: result.archiveURL.path,
                                 fromPaths: sourceURLs.map(\.path),
                                 settings: result.settings,
                                 session: session)
        }
    }

    static func extractPreparedArchiveItems(_ prepared: FileManagerPreparedExtraction,
                                            parentWindow: NSWindow) async throws
    {
        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                             parentWindow: parentWindow)
        { session in
            try prepared.perform(session: session)
        }
    }

    private static func copyPreparedArchiveItems(_ prepared: FileManagerPreparedExtraction,
                                                 parentWindow: NSWindow) async throws
    {
        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("fileop.copying"),
                                             parentWindow: parentWindow)
        { session in
            try prepared.perform(session: session)
        }
    }

    static func extractArchiveCandidate(_ archiveCandidateURL: URL?,
                                        result: ExtractDialogResult,
                                        parentWindow: NSWindow) async throws
    {
        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                             parentWindow: parentWindow)
        { session in
            guard let archiveURL = archiveCandidateURL else {
                throw NSError(domain: SZArchiveErrorDomain,
                              code: -1,
                              userInfo: [NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.selectArchiveToExtract")])
            }

            let archive = SZArchive()
            try archive.open(atPath: archiveURL.path,
                             password: result.password,
                             session: session)
            defer {
                archive.close()
            }

            let archiveItems = try FileManagerArchiveListing.items(from: archive,
                                                                   session: session)
            let settings = extractionSettings(for: result,
                                              archiveURL: archiveURL,
                                              archiveItems: archiveItems)
            try FileManagerArchiveExtraction.performFullArchiveExtraction(archive,
                                                                          to: result.destinationURL,
                                                                          settings: settings,
                                                                          session: session)
        }
    }

    static func testPreparedArchive(_ leasedArchive: FileManagerLeasedArchive,
                                    parentWindow: NSWindow) async throws
    {
        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.testing"),
                                             parentWindow: parentWindow)
        { session in
            // Captured by value, so the lease is held for the whole test and released when done.
            try leasedArchive.archive.test(with: session)
        }
    }

    static func testArchiveCandidate(_ archiveCandidateURL: URL?,
                                     parentWindow: NSWindow) async throws
    {
        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.testing"),
                                             parentWindow: parentWindow)
        { session in
            guard let archiveURL = archiveCandidateURL else {
                throw NSError(domain: SZArchiveErrorDomain,
                              code: -1,
                              userInfo: [NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.selectArchiveToTest")])
            }

            let archive = SZArchive()
            try archive.open(atPath: archiveURL.path, session: session)
            defer {
                archive.close()
            }
            try archive.test(with: session)
        }
    }

    private static func extractionSettings(for result: ExtractDialogResult,
                                           archiveURL: URL,
                                           archiveItems: [ArchiveItem]) -> SZExtractionSettings
    {
        let settings = SZExtractionSettings()
        settings.overwriteMode = result.overwriteMode
        settings.pathMode = result.pathMode
        settings.password = result.password
        settings.preserveNtSecurityInfo = result.preserveNtSecurityInfo
        settings.pathPrefixToStrip = archiveExtractionPathPrefixToStrip(for: archiveItems,
                                                                        destinationURL: result.destinationURL,
                                                                        pathMode: result.pathMode,
                                                                        eliminateDuplicates: result.eliminateDuplicates)
        if result.inheritDownloadedFileQuarantine {
            settings.sourceArchivePathForQuarantine = archiveURL.path
        }
        return settings
    }

    private static func archiveExtractionPathPrefixToStrip(for items: [ArchiveItem],
                                                           destinationURL: URL,
                                                           pathMode: SZPathMode,
                                                           eliminateDuplicates: Bool) -> String?
    {
        guard eliminateDuplicates,
              pathMode != .absolutePaths,
              pathMode != .noPaths
        else {
            return nil
        }

        return ArchiveItem.duplicateRootPrefixToStrip(for: items,
                                                      destinationLeafName: destinationURL.lastPathComponent)
    }

    private static func suggestedArchiveAddSourceDirectory(targetSnapshot: FileManagerPaneSnapshot,
                                                           inactivePaneSnapshot: FileManagerPaneSnapshot?) -> URL
    {
        if let inactivePaneSnapshot,
           !inactivePaneSnapshot.isVirtualLocation
        {
            return inactivePaneSnapshot.currentDirectoryURL.standardizedFileURL
        }

        return targetSnapshot.currentDirectoryURL.standardizedFileURL
    }

    private static func suggestedDestinationPath(sourceSnapshot: FileManagerPaneSnapshot,
                                                 inactivePaneSnapshot: FileManagerPaneSnapshot?) -> String
    {
        if let inactivePaneSnapshot {
            if let archivePath = inactivePaneSnapshot.currentArchiveDestinationDisplayPath {
                return szNormalizedDestinationDisplayPath(archivePath)
            }

            if !inactivePaneSnapshot.isVirtualLocation {
                return szNormalizedDestinationDisplayPath(inactivePaneSnapshot.currentDirectoryURL.standardizedFileURL.path)
            }
        }

        return szNormalizedDestinationDisplayPath(sourceSnapshot.currentDirectoryURL.standardizedFileURL.path)
    }

    private static func promptForArchiveDestination(from snapshot: FileManagerPaneSnapshot,
                                                    parentWindow: NSWindow?) async -> ExtractDialogResult?
    {
        let dialog = ExtractDialogController(suggestedDestinationURL: snapshot.currentDirectoryURL,
                                             baseDirectory: snapshot.currentDirectoryURL,
                                             message: snapshot.extractDialogInfoText,
                                             defaultPathMode: snapshot.isVirtualLocation ? .currentPaths : .fullPaths,
                                             showsCurrentPathsOption: snapshot.isVirtualLocation,
                                             suggestedSplitDestinationName: snapshot.suggestedExtractDestinationName,
                                             sourceArchiveAvailableForMoveToTrash: snapshot.sourceArchiveURLForPostProcessing != nil,
                                             sourceArchiveAvailableForQuarantineInheritance: snapshot.quarantineSourceArchiveURLForExtraction != nil)
        return await dialog.runModal(for: parentWindow)
    }
}

@MainActor
enum FileManagerTextEditingActionDispatcher {
    static func firstResponder(in window: NSWindow?, supports action: Selector) -> Bool {
        guard let firstResponder = window?.firstResponder as? NSResponder,
              firstResponder is NSTextView
        else {
            return false
        }

        return firstResponder.responds(to: action)
    }

    @discardableResult
    static func dispatchIfPossible(_ action: Selector,
                                   sender: Any?,
                                   window: NSWindow?) -> Bool
    {
        guard firstResponder(in: window, supports: action) else {
            return false
        }

        return NSApp.sendAction(action, to: nil, from: sender)
    }
}

@MainActor
enum FileManagerClipboard {
    static func fileURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]

        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: options) as? [URL]
        else {
            return []
        }

        return urls
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
    }

    static func writeFileURLs(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }
}

@MainActor
enum FileManagerClipboardSupport {
    static func canCopySelection(from snapshot: FileManagerPaneSnapshot) -> Bool {
        !snapshot.isVirtualLocation && !snapshot.selection.fileURLs.isEmpty
    }

    static func canPasteFiles(_ sourceURLs: [URL], into snapshot: FileManagerPaneSnapshot) -> Bool {
        guard !sourceURLs.isEmpty else { return false }
        return snapshot.acceptsFilePaste
    }

    static func copySelection(from snapshot: FileManagerPaneSnapshot) {
        guard canCopySelection(from: snapshot) else { return }
        FileManagerClipboard.writeFileURLs(snapshot.selection.fileURLs)
    }

    static func pasteFiles(_ sourceURLs: [URL],
                           into pane: FileManagerPaneController,
                           parentWindow: NSWindow?,
                           refreshAfterFilesystemTransfer: @escaping @MainActor (FileManagerPaneController, URL, NSDragOperation) -> Void,
                           showError: @escaping @MainActor (Error) -> Void)
    {
        guard !sourceURLs.isEmpty else { return }

        if pane.isVirtualLocation {
            guard let target = pane.currentArchiveMutationTarget() else {
                pane.showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.addingFilesToArchive"))
                return
            }

            pane.beginConfirmedArchiveTransfer(sourceURLs,
                                               to: target,
                                               operation: .copy,
                                               sourcePane: nil,
                                               parentWindow: parentWindow,
                                               operationTitle: SZL10n.string("app.progress.pasting"))
            return
        }

        let destinationURL = pane.currentDirectoryURL.standardizedFileURL
        guard FileManagerTransferDestinationValidation.canMoveOrCopyFileSystemItems(sourceURLs,
                                                                                    to: destinationURL,
                                                                                    operation: .copy,
                                                                                    presentingIn: parentWindow)
        else {
            return
        }
        guard let parentWindow else { return }

        Task { @MainActor [weak pane, weak parentWindow] in
            guard let pane, let parentWindow else { return }
            defer {
                refreshAfterFilesystemTransfer(pane, destinationURL, .copy)
            }
            do {
                try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("app.progress.pasting"),
                                                     parentWindow: parentWindow)
                { session in
                    try FileOperationFileSystemTransfer.perform(sourceURLs,
                                                                to: destinationURL,
                                                                operation: .copy,
                                                                session: session)
                }
            } catch {
                showError(error)
            }
        }
    }
}

enum FileManagerHashAlgorithm {
    case all
    case crc32
    case crc64
    case xxh64
    case md5
    case sha1
    case sha256
    case sha384
    case sha512
    case sha3256
    case blake2sp

    private struct Definition {
        let algorithm: FileManagerHashAlgorithm
        let title: String
        let bridgeName: String
    }

    private static let orderedDefinitions: [Definition] = [
        Definition(algorithm: .crc32, title: "CRC-32", bridgeName: "CRC32"),
        Definition(algorithm: .crc64, title: "CRC-64", bridgeName: "CRC64"),
        Definition(algorithm: .xxh64, title: "XXH64", bridgeName: "XXH64"),
        Definition(algorithm: .md5, title: "MD5", bridgeName: "MD5"),
        Definition(algorithm: .sha1, title: "SHA-1", bridgeName: "SHA1"),
        Definition(algorithm: .sha256, title: "SHA-256", bridgeName: "SHA256"),
        Definition(algorithm: .sha384, title: "SHA-384", bridgeName: "SHA384"),
        Definition(algorithm: .sha512, title: "SHA-512", bridgeName: "SHA512"),
        Definition(algorithm: .sha3256, title: "SHA3-256", bridgeName: "SHA3-256"),
        Definition(algorithm: .blake2sp, title: "BLAKE2sp", bridgeName: "BLAKE2sp"),
    ]

    private static let definitionsByAlgorithm: [FileManagerHashAlgorithm: Definition] = {
        let allDefinition = Definition(algorithm: .all, title: "*", bridgeName: "*")
        let definitions = [allDefinition] + orderedDefinitions
        return Dictionary(uniqueKeysWithValues: definitions.map { ($0.algorithm, $0) })
    }()

    private var definition: Definition {
        Self.definitionsByAlgorithm[self]!
    }

    private var displayedAlgorithms: [FileManagerHashAlgorithm] {
        switch self {
        case .all:
            Self.orderedDefinitions.map(\.algorithm)
        default:
            [self]
        }
    }

    private var title: String {
        definition.title
    }

    private var bridgeName: String {
        definition.bridgeName
    }

    func details(hashValues: [String: String]) -> String {
        displayedAlgorithms
            .map { currentAlgorithm in
                let value = hashValues[currentAlgorithm.bridgeName] ?? "unavailable"
                return "\(currentAlgorithm.title): \(value)"
            }
            .joined(separator: "\n")
    }
}

@MainActor
struct FileManagerCommandValidationContext {
    let activePaneSnapshot: FileManagerPaneSnapshot
    let isDualPane: Bool
    let window: NSWindow?
}

@MainActor
enum FileManagerCommandValidator {
    static func validate(_ item: any NSValidatedUserInterfaceItem,
                         context: FileManagerCommandValidationContext) -> Bool
    {
        let activePane = context.activePaneSnapshot
        let capabilities = activePane.capabilities

        switch item.action {
        case #selector(FileManagerWindowController.openSelectedItem(_:)):
            return capabilities.canOpenSelection
        case #selector(FileManagerWindowController.openSelectedItemInside(_:)),
             #selector(FileManagerWindowController.openSelectedItemInsideWildcard(_:)),
             #selector(FileManagerWindowController.openSelectedItemInsideParser(_:)):
            return capabilities.canOpenSelectionInside
        case #selector(FileManagerWindowController.openSelectedItemOutside(_:)):
            return capabilities.canOpenSelectionOutside
        case #selector(FileManagerWindowController.addToArchive(_:)):
            return capabilities.canAddSelectedItemsToArchive
        case #selector(FileManagerWindowController.extractArchive(_:)):
            return capabilities.canExtractSelectionOrArchive
        case #selector(FileManagerWindowController.extractSmart(_:)):
            return !activePane.isVirtualLocation && activePane.selectedArchiveCandidateURL != nil
        case #selector(FileManagerWindowController.extractHere(_:)):
            return capabilities.canExtractSelectionOrArchive
        case #selector(FileManagerWindowController.testArchive(_:)):
            return capabilities.canTestArchiveSelection
        case #selector(FileManagerWindowController.copyFiles(_:)):
            return capabilities.canCopySelection
        case #selector(FileManagerWindowController.moveFiles(_:)):
            return capabilities.canMoveSelection
        case #selector(FileManagerWindowController.renameSelection(_:)):
            return capabilities.canRenameSelection
        case #selector(FileManagerWindowController.createFolder(_:)):
            return capabilities.canCreateFolderHere
        case #selector(FileManagerWindowController.createFile(_:)):
            return capabilities.canCreateFileHere
        case #selector(FileManagerWindowController.deleteFiles(_:)):
            return capabilities.canDeleteSelection
        case #selector(FileManagerWindowController.showProperties(_:)):
            return capabilities.canShowSelectedItemProperties
        case #selector(FileManagerWindowController.showCRC32Hash(_:)),
             #selector(FileManagerWindowController.showAllHashes(_:)),
             #selector(FileManagerWindowController.showCRC64Hash(_:)),
             #selector(FileManagerWindowController.showXXH64Hash(_:)),
             #selector(FileManagerWindowController.showMD5Hash(_:)),
             #selector(FileManagerWindowController.showSHA1Hash(_:)),
             #selector(FileManagerWindowController.showSHA256Hash(_:)),
             #selector(FileManagerWindowController.showSHA384Hash(_:)),
             #selector(FileManagerWindowController.showSHA512Hash(_:)),
             #selector(FileManagerWindowController.showSHA3256Hash(_:)),
             #selector(FileManagerWindowController.showBLAKE2spHash(_:)):
            return capabilities.canCalculateSelectionHashes
        case #selector(FileManagerWindowController.goUpOneLevel(_:)):
            return capabilities.canGoUp
        case #selector(NSText.copy(_:)):
            return FileManagerTextEditingActionDispatcher.firstResponder(in: context.window,
                                                                         supports: #selector(NSText.copy(_:))) ||
                FileManagerClipboardSupport.canCopySelection(from: activePane)
        case #selector(NSText.paste(_:)):
            return FileManagerTextEditingActionDispatcher.firstResponder(in: context.window,
                                                                         supports: #selector(NSText.paste(_:))) ||
                FileManagerClipboardSupport.canPasteFiles(FileManagerClipboard.fileURLs(),
                                                          into: activePane)
        case #selector(NSText.selectAll(_:)):
            return FileManagerTextEditingActionDispatcher.firstResponder(in: context.window,
                                                                         supports: #selector(NSText.selectAll(_:))) ||
                capabilities.canSelectVisibleItems
        case #selector(FileManagerWindowController.invertSelection(_:)):
            return capabilities.canSelectVisibleItems
        case #selector(FileManagerWindowController.deselectAllItems(_:)):
            return capabilities.canDeselectSelection
        case #selector(FileManagerWindowController.refreshActivePane(_:)),
             #selector(FileManagerWindowController.toggleHiddenFiles(_:)),
             #selector(FileManagerWindowController.sortByName(_:)),
             #selector(FileManagerWindowController.sortByType(_:)),
             #selector(FileManagerWindowController.sortBySize(_:)),
             #selector(FileManagerWindowController.sortByModifiedDate(_:)),
             #selector(FileManagerWindowController.sortByCreatedDate(_:)):
            return true
        case #selector(FileManagerWindowController.closeDirectory(_:)):
            return !activePane.isSuspended
        case #selector(FileManagerWindowController.showTimestampDay(_:)),
             #selector(FileManagerWindowController.showTimestampMinute(_:)),
             #selector(FileManagerWindowController.showTimestampSecond(_:)),
             #selector(FileManagerWindowController.showTimestampNTFS(_:)),
             #selector(FileManagerWindowController.showTimestampNanoseconds(_:)),
             #selector(FileManagerWindowController.toggleTimestampUTC(_:)),
             #selector(FileManagerWindowController.toggleAutoRefresh(_:)):
            return true
        case #selector(FileManagerWindowController.openRootFolder(_:)):
            return true
        case #selector(FileManagerWindowController.showFoldersHistory(_:)):
            return capabilities.canShowFoldersHistory
        case #selector(FileManagerWindowController.toggleArchiveToolbar(_:)),
             #selector(FileManagerWindowController.toggleStandardToolbar(_:)),
             #selector(FileManagerWindowController.toggleToolbarButtonText(_:)),
             #selector(FileManagerWindowController.toggleUnifiedToolbarStyle(_:)):
            return true
        case #selector(FileManagerWindowController.openFavoriteSlot(_:)):
            guard let menuItem = item as? NSMenuItem else { return false }
            return FileManagerFavoriteStore.url(for: menuItem.tag) != nil
        case #selector(FileManagerWindowController.saveFavoriteSlot(_:)):
            return true
        case #selector(FileManagerWindowController.toggleDualPane(_:)):
            return true
        case #selector(FileManagerWindowController.switchPanes(_:)):
            return context.isDualPane
        default:
            return true
        }
    }

    static func validate(_ menuItem: NSMenuItem,
                         context: FileManagerCommandValidationContext) -> Bool
    {
        let isEnabled = validate(menuItem as any NSValidatedUserInterfaceItem,
                                 context: context)
        let activePane = context.activePaneSnapshot

        switch menuItem.action {
        case #selector(FileManagerWindowController.toggleDualPane(_:)):
            menuItem.state = context.isDualPane ? .on : .off
        case #selector(FileManagerWindowController.sortByName(_:)):
            menuItem.state = activePane.primarySortKey == "name" ? .on : .off
        case #selector(FileManagerWindowController.sortByType(_:)):
            menuItem.state = activePane.primarySortKey == "type" ? .on : .off
        case #selector(FileManagerWindowController.sortBySize(_:)):
            menuItem.state = activePane.primarySortKey == "size" ? .on : .off
        case #selector(FileManagerWindowController.sortByModifiedDate(_:)):
            menuItem.state = activePane.primarySortKey == "modified" ? .on : .off
        case #selector(FileManagerWindowController.sortByCreatedDate(_:)):
            menuItem.state = activePane.primarySortKey == "created" ? .on : .off
        case #selector(FileManagerWindowController.showTimestampDay(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .day ? .on : .off
        case #selector(FileManagerWindowController.showTimestampMinute(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .minute ? .on : .off
        case #selector(FileManagerWindowController.showTimestampSecond(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .second ? .on : .off
        case #selector(FileManagerWindowController.showTimestampNTFS(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .ntfs ? .on : .off
        case #selector(FileManagerWindowController.showTimestampNanoseconds(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .nanoseconds ? .on : .off
        case #selector(FileManagerWindowController.toggleTimestampUTC(_:)):
            menuItem.state = FileManagerViewPreferences.usesUTCTimestamps ? .on : .off
        case #selector(FileManagerWindowController.toggleAutoRefresh(_:)):
            menuItem.state = FileManagerViewPreferences.autoRefreshEnabled ? .on : .off
        case #selector(FileManagerWindowController.toggleHiddenFiles(_:)):
            menuItem.state = SZSettings.bool(.showHiddenFiles) ? .on : .off
        case #selector(FileManagerWindowController.toggleArchiveToolbar(_:)):
            menuItem.state = FileManagerToolbarPreferences.showsArchiveToolbar ? .on : .off
        case #selector(FileManagerWindowController.toggleStandardToolbar(_:)):
            menuItem.state = FileManagerToolbarPreferences.showsStandardToolbar ? .on : .off
        case #selector(FileManagerWindowController.toggleToolbarButtonText(_:)):
            menuItem.state = FileManagerToolbarPreferences.showsButtonText ? .on : .off
        case #selector(FileManagerWindowController.toggleUnifiedToolbarStyle(_:)):
            menuItem.state = FileManagerToolbarPreferences.style == .unified ? .on : .off
        default:
            menuItem.state = .off
        }

        return isEnabled
    }
}
