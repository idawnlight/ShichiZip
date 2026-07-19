import AppKit

@MainActor
enum FileManagerPaneMutationCommandSupport {
    static func createFolder(named name: String,
                             in pane: FileManagerPaneController)
    {
        if pane.isVirtualLocation {
            guard let target = pane.currentArchiveMutationTarget() else {
                pane.showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.creatingFolders"))
                return
            }

            Task { @MainActor [weak pane] in
                guard let pane else { return }
                guard let currentTarget = pane.revalidatedArchiveMutationTarget(for: target) else {
                    pane.showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.creatingFolders"))
                    return
                }

                let createdPath = currentTarget.subdir.isEmpty ? name : currentTarget.subdir + "/" + name

                do {
                    let outcome = try await ArchiveOperationRunner.run(
                        operationTitle: SZL10n.string("create.folder"),
                        parentWindow: pane.view.window,
                        deferredDisplay: true
                    ) { session in
                        try FileManagerArchiveMutationOutcome.perform {
                            try currentTarget.archive.createFolderNamed(
                                name,
                                inArchiveSubdir: currentTarget.subdir,
                                session: session,
                            )
                        }
                    }
                    pane.refreshArchiveAfterMutation(
                        selectingPaths: [createdPath],
                        reopenBeforeListing: outcome.requiresReopenBeforeRefresh,
                    )
                    pane.publishArchiveMutationIfNeeded(selectingPaths: [createdPath])
                    if let committedError = outcome.committedError {
                        showError(committedError,
                                  in: pane)
                    }
                } catch {
                    showError(error,
                              in: pane)
                }
            }
            return
        }

        let url = pane.currentDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            pane.refresh()
        } catch {
            showError(error,
                      in: pane)
        }
    }

    static func createFile(named name: String,
                           in pane: FileManagerPaneController)
    {
        guard !pane.isVirtualLocation else {
            showUnsupportedArchiveOperationAlert(action: SZL10n.string("app.fileManager.action.creatingFiles"),
                                                 in: pane)
            return
        }

        let url = pane.currentDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            showError(NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteFileExistsError,
                              userInfo: [
                                  NSFilePathErrorKey: url.path,
                                  NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.error.fileAlreadyExists", name),
                              ]),
                      in: pane)
            return
        }

        if FileManager.default.createFile(atPath: url.path, contents: Data()) {
            pane.refresh()
            return
        }

        showError(NSError(domain: NSCocoaErrorDomain,
                          code: NSFileWriteUnknownError,
                          userInfo: [
                              NSFilePathErrorKey: url.path,
                              NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.error.unableToCreate", name),
                          ]),
                  in: pane)
    }

    static func extractHere(in pane: FileManagerPaneController) {
        if pane.isVirtualLocation {
            let destinationURL = pane.archiveHostDirectory()
            Task { @MainActor [weak pane] in
                guard let pane, let parentWindow = pane.view.window else { return }
                do {
                    let prepared = try pane.prepareExtraction(to: destinationURL,
                                                              overwriteMode: .ask,
                                                              inheritDownloadedFileQuarantine: SZSettings.bool(.inheritDownloadedFileQuarantine))
                    try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                                         parentWindow: parentWindow)
                    { session in
                        try prepared.perform(session: session)
                    }
                } catch {
                    showError(error,
                              in: pane)
                }
            }
            return
        }

        guard let url = pane.selectedArchiveCandidateURL() else { return }

        let destinationURL = pane.currentDirectory
        Task { @MainActor [weak pane] in
            guard let pane, let parentWindow = pane.view.window else { return }
            do {
                try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                                     parentWindow: parentWindow)
                { session in
                    let archive = SZArchive()
                    try archive.open(atPath: url.path, session: session)
                    defer {
                        archive.close()
                    }
                    let settings = SZExtractionSettings()
                    settings.overwriteMode = .ask
                    if SZSettings.bool(.inheritDownloadedFileQuarantine) {
                        settings.sourceArchivePathForQuarantine = url.path
                    }
                    try FileManagerArchiveExtraction.performFullArchiveExtraction(archive,
                                                                                  to: destinationURL,
                                                                                  settings: settings,
                                                                                  session: session)
                }
                pane.refresh()
            } catch {
                showError(error,
                          in: pane)
            }
        }
    }

    static func renameSelection(in pane: FileManagerPaneController) {
        if pane.isVirtualLocation {
            renameArchiveSelection(in: pane)
            return
        }

        let selectedItems = pane.selectedFileSystemItems()
        guard selectedItems.count == 1 else { return }
        let item = selectedItems[0]

        guard let window = pane.view.window else { return }
        szBeginTextInput(on: window,
                         title: SZL10n.string("menu.rename"),
                         initialValue: item.name,
                         confirmTitle: SZL10n.string("menu.rename"))
        { [weak pane] value in
            guard let newName = value else { return }
            guard !newName.isEmpty, newName != item.name else { return }
            let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(at: item.url, to: newURL)
                pane?.refresh()
            } catch {
                if let pane {
                    showError(error,
                              in: pane)
                }
            }
        }
    }

    static func deleteSelection(in pane: FileManagerPaneController) {
        if pane.isVirtualLocation {
            deleteArchiveSelection(in: pane)
            return
        }

        let paths = pane.selectedFilePaths()
        guard !paths.isEmpty else { return }

        guard let window = pane.view.window else { return }
        szBeginConfirmation(on: window,
                            title: SZL10n.string("app.fileManager.deleteItemsTitle", paths.count),
                            message: SZL10n.string("app.fileManager.deleteItemsMessage"),
                            confirmTitle: SZL10n.string("toolbar.delete"))
        { [weak pane] confirmed in
            guard confirmed else { return }
            let failures = FileManagerTrashOperation.trashItems(at: paths)
            pane?.refresh()
            if let error = FileManagerTrashOperation.error(for: failures, attemptedCount: paths.count),
               let pane
            {
                showError(error,
                          in: pane)
            }
        }
    }

    static func promptForFolderCreation(in pane: FileManagerPaneController) {
        guard let window = pane.view.window else { return }
        szBeginTextInput(on: window,
                         title: SZL10n.string("create.folder"),
                         placeholder: SZL10n.string("create.newFolder"),
                         confirmTitle: SZL10n.string("create.folder"))
        { [weak pane] value in
            guard let pane,
                  let name = value,
                  !name.isEmpty
            else { return }
            createFolder(named: name,
                         in: pane)
        }
    }

    private static func renameArchiveSelection(in pane: FileManagerPaneController) {
        guard let target = pane.currentArchiveMutationTarget() else {
            pane.showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.renamingArchiveItems"))
            return
        }

        let selectedItems = pane.selectedArchiveItems()
        guard selectedItems.count == 1 else { return }
        let item = selectedItems[0]
        guard let itemReference = item.reference else {
            pane.showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.renamingArchiveItems"))
            return
        }

        guard let window = pane.view.window else { return }
        szBeginTextInput(on: window,
                         title: SZL10n.string("menu.rename"),
                         initialValue: item.name,
                         confirmTitle: SZL10n.string("menu.rename"))
        { [weak pane] value in
            guard let pane,
                  let newName = value
            else { return }
            guard !newName.isEmpty, newName != item.name else { return }

            let renamedPath = item.parentPath.isEmpty ? newName : item.parentPath + "/" + newName
            Task { @MainActor [weak pane] in
                guard let pane else { return }
                guard let currentTarget = pane.revalidatedArchiveMutationTarget(for: target) else {
                    pane.showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.renamingArchiveItems"))
                    return
                }

                do {
                    let outcome = try await ArchiveOperationRunner.run(
                        operationTitle: SZL10n.string("fileop.renaming"),
                        parentWindow: pane.view.window,
                        deferredDisplay: true
                    ) { session in
                        try FileManagerArchiveMutationOutcome.perform {
                            try currentTarget.archive.renameItem(
                                at: itemReference,
                                inArchiveSubdir: currentTarget.subdir,
                                newName: newName,
                                session: session,
                            )
                        }
                    }
                    pane.refreshArchiveAfterMutation(
                        selectingPaths: [renamedPath],
                        reopenBeforeListing: outcome.requiresReopenBeforeRefresh,
                    )
                    pane.publishArchiveMutationIfNeeded(selectingPaths: [renamedPath])
                    if let committedError = outcome.committedError {
                        showError(committedError,
                                  in: pane)
                    }
                } catch {
                    showError(error,
                              in: pane)
                }
            }
        }
    }

    private static func deleteArchiveSelection(in pane: FileManagerPaneController) {
        guard let target = pane.currentArchiveMutationTarget() else {
            pane.showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.deletingArchiveItems"))
            return
        }

        let selectedItems = pane.selectedArchiveItems()
        guard !selectedItems.isEmpty else { return }

        let itemReferences = selectedItems.compactMap(\.reference)
        guard itemReferences.count == selectedItems.count else {
            pane.showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.deletingArchiveItems"))
            return
        }
        let itemPaths = selectedItems.map(\.path)
        guard let window = pane.view.window else { return }
        szBeginConfirmation(on: window,
                            title: SZL10n.string("app.fileManager.deleteFromArchiveTitle", itemPaths.count),
                            message: SZL10n.string("app.fileManager.deleteFromArchiveMessage"),
                            confirmTitle: SZL10n.string("toolbar.delete"))
        { [weak pane] confirmed in
            guard let pane, confirmed else { return }

            Task { @MainActor [weak pane] in
                guard let pane else { return }
                guard let currentTarget = pane.revalidatedArchiveMutationTarget(for: target) else {
                    pane.showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.deletingArchiveItems"))
                    return
                }

                do {
                    let outcome = try await ArchiveOperationRunner.run(
                        operationTitle: SZL10n.string("progress.deleting"),
                        parentWindow: pane.view.window,
                        deferredDisplay: true
                    ) { session in
                        try FileManagerArchiveMutationOutcome.perform {
                            try currentTarget.archive.deleteItems(
                                at: itemReferences,
                                inArchiveSubdir: currentTarget.subdir,
                                session: session,
                            )
                        }
                    }
                    pane.refreshArchiveAfterMutation(
                        reopenBeforeListing: outcome.requiresReopenBeforeRefresh
                    )
                    pane.publishArchiveMutationIfNeeded(targetSubdir: currentTarget.subdir)
                    if let committedError = outcome.committedError {
                        showError(committedError,
                                  in: pane)
                    }
                } catch {
                    showError(error,
                              in: pane)
                }
            }
        }
    }

    private static func showError(_ error: Error,
                                  in pane: FileManagerPaneController)
    {
        szPresentError(error, for: pane.view.window)
    }

    private static func showUnsupportedArchiveOperationAlert(action: String,
                                                             in pane: FileManagerPaneController)
    {
        szPresentMessage(title: SZL10n.string("app.fileManager.alert.actionNotAvailableTitle", action),
                         message: SZL10n.string("app.fileManager.alert.archiveModificationNotSupported"),
                         for: pane.view.window)
    }
}
