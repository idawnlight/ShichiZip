import AppKit

@MainActor
enum FileManagerPaneOpenCommandSupport {
    static func openSelection(in pane: FileManagerPaneController) {
        activateItem(at: pane.openCommandActivationRow,
                     in: pane)
    }

    static func openSelectionInside(_ openMode: FileManagerArchiveOpenMode,
                                    in pane: FileManagerPaneController)
    {
        guard let item = pane.paneSelectionState.singleRealItem else { return }

        switch item {
        case .parent:
            return

        case let .filesystem(fileSystemItem):
            if fileSystemItem.isDirectory {
                pane.loadDirectory(fileSystemItem.url,
                                   budget: FileManagerPaneDirectoryCoordinator.navigationBudget)
            } else {
                Task { @MainActor [weak pane] in
                    guard let pane else { return }
                    _ = await pane.openCommandOpenArchiveInline(fileSystemItem.url,
                                                                hostDirectory: pane.currentDirectoryURL,
                                                                openMode: openMode)
                }
            }

        case let .archive(archiveItem):
            if archiveItem.isDirectory {
                pane.navigateArchiveSubdir(archiveItem.pathParts.joined(separator: "/"))
            } else {
                openItemInArchive(archiveItem,
                                  strategy: .forceInternal(openMode),
                                  in: pane)
            }
        }
    }

    static func openSelectionOutside(in pane: FileManagerPaneController) {
        guard let item = pane.paneSelectionState.singleRealItem else { return }

        switch item {
        case .parent:
            return

        case let .filesystem(fileSystemItem):
            if fileSystemItem.isDirectory {
                _ = NSWorkspace.shared.open(fileSystemItem.url)
                return
            }

            if !pane.openCommandOpenExternallyIfPossible(fileSystemItem.url) {
                pane.openCommandShowError(pane.openCommandUnavailableExternalOpenError(for: fileSystemItem.name))
            }

        case let .archive(archiveItem):
            guard !archiveItem.isDirectory,
                  let context = pane.openCommandArchiveItemWorkflowContext()
            else { return }

            openArchiveItemExternally(archiveItem,
                                      context: context,
                                      strategy: .forceExternal,
                                      in: pane)
        }
    }

    static func activateItem(at row: Int,
                             in pane: FileManagerPaneController)
    {
        guard let item = pane.openCommandItem(at: row) else { return }

        switch item {
        case .parent:
            pane.goUpOneLevel()

        case let .archive(archiveItem):
            if archiveItem.isDirectory {
                pane.navigateArchiveSubdir(archiveItem.pathParts.joined(separator: "/"))
            } else {
                openItemInArchive(archiveItem,
                                  in: pane)
            }

        case let .filesystem(fileSystemItem):
            if fileSystemItem.isDirectory {
                pane.loadDirectory(fileSystemItem.url,
                                   budget: FileManagerPaneDirectoryCoordinator.navigationBudget)
            } else {
                openFileSystemFile(fileSystemItem,
                                   in: pane)
            }
        }
    }

    private static func openFileSystemFile(_ fileSystemItem: FileSystemItem,
                                           in pane: FileManagerPaneController)
    {
        if FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(fileSystemItem.url) {
            if !pane.openCommandOpenExternallyIfPossible(fileSystemItem.url) {
                pane.openCommandShowError(pane.openCommandUnavailableExternalOpenError(for: fileSystemItem.name))
            }
            return
        }

        Task { @MainActor [weak pane] in
            guard let pane else { return }

            switch await pane.openCommandOpenArchiveInline(fileSystemItem.url,
                                                           hostDirectory: pane.currentDirectoryURL,
                                                           showError: false)
            {
            case .opened:
                break
            case let .unsupportedArchive(error):
                let shouldFallbackExternally = FileManagerExternalOpenRouter.shouldFallbackUnsupportedArchiveExternally(for: fileSystemItem.url)
                if shouldFallbackExternally {
                    if !pane.openCommandOpenExternallyIfPossible(fileSystemItem.url) {
                        pane.openCommandShowError(error)
                    }
                } else {
                    pane.openCommandShowError(error)
                }
            case .cancelled:
                break
            case let .failed(error):
                pane.openCommandShowError(error)
            }
        }
    }

    private static func openItemInArchive(_ item: ArchiveItem,
                                          strategy: FileManagerArchiveItemOpenStrategy = .automatic,
                                          in pane: FileManagerPaneController)
    {
        guard item.index >= 0,
              let context = pane.openCommandArchiveItemWorkflowContext()
        else { return }

        if case .forceExternal = strategy {
            openArchiveItemExternally(item,
                                      context: context,
                                      strategy: strategy,
                                      in: pane)
            return
        }

        if case .automatic = strategy,
           FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(archiveItemPath: item.path)
        {
            openArchiveItemExternally(item,
                                      context: context,
                                      strategy: strategy,
                                      in: pane)
            return
        }

        let openMode: FileManagerArchiveOpenMode
        let preserveTemporaryDirectoryOnUnsupported: Bool
        switch strategy {
        case .automatic:
            openMode = .defaultBehavior
            preserveTemporaryDirectoryOnUnsupported = true
        case let .forceInternal(mode):
            openMode = mode
            preserveTemporaryDirectoryOnUnsupported = false
        case .forceExternal:
            return
        }

        openArchiveItemInternally(item,
                                  context: context,
                                  openMode: openMode,
                                  preserveTemporaryDirectoryOnUnsupported: preserveTemporaryDirectoryOnUnsupported,
                                  in: pane)
    }

    private static func openArchiveItemExternally(_ item: ArchiveItem,
                                                  context: FileManagerArchiveItemWorkflowContext,
                                                  strategy: FileManagerArchiveItemOpenStrategy,
                                                  in pane: FileManagerPaneController)
    {
        let displayPath = context.displayPath(for: item)

        Task { @MainActor [weak pane] in
            guard let pane else { return }

            do {
                let workflowService = pane.openCommandItemWorkflowService
                let preparedOpen = try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                                                        initialFileName: displayPath,
                                                                        parentWindow: pane.view.window,
                                                                        deferredDisplay: true)
                { session in
                    try workflowService.prepareExternalArchiveItemOpen(for: item,
                                                                       context: context,
                                                                       strategy: strategy,
                                                                       session: session)
                }

                finishExternalArchiveItemOpen(preparedOpen,
                                              itemName: item.name,
                                              in: pane)
            } catch {
                pane.openCommandShowError(error)
            }
        }
    }

    private static func finishExternalArchiveItemOpen(_ preparedOpen: FileManagerPreparedArchiveItemExternalOpen,
                                                      itemName: String,
                                                      in pane: FileManagerPaneController)
    {
        if let applicationURL = preparedOpen.applicationURL {
            _ = pane.openCommandOpenExternally(preparedOpen.stagedFileURL,
                                               withApplicationAt: applicationURL,
                                               preservingTemporaryDirectory: preparedOpen.temporaryDirectory)
            return
        }

        if pane.openCommandOpenExternallyIfPossible(preparedOpen.stagedFileURL,
                                                    preservingTemporaryDirectory: preparedOpen.temporaryDirectory)
        {
            return
        }

        pane.openCommandCleanupTemporaryDirectory(preparedOpen.temporaryDirectory)
        pane.openCommandShowError(pane.openCommandUnavailableExternalOpenError(for: itemName))
    }

    private static func openArchiveItemInternally(_ item: ArchiveItem,
                                                  context: FileManagerArchiveItemWorkflowContext,
                                                  openMode: FileManagerArchiveOpenMode,
                                                  preserveTemporaryDirectoryOnUnsupported: Bool,
                                                  in pane: FileManagerPaneController)
    {
        let displayPath = context.displayPath(for: item)

        Task { @MainActor [weak pane] in
            guard let pane else { return }

            do {
                let workflowService = pane.openCommandItemWorkflowService
                let preparedOpen = try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.opening"),
                                                                        initialFileName: displayPath,
                                                                        parentWindow: pane.view.window,
                                                                        deferredDisplay: true)
                { session in
                    try workflowService.prepareInternalArchiveOpen(for: item,
                                                                   context: context,
                                                                   openMode: openMode,
                                                                   session: session)
                }

                let result = pane.openCommandFinishArchiveOpen(preparedOpen.preparedResult,
                                                               temporaryDirectory: preparedOpen.temporaryDirectory,
                                                               preserveTemporaryDirectoryOnUnsupported: preserveTemporaryDirectoryOnUnsupported,
                                                               replaceCurrentState: false,
                                                               showError: false)

                switch result {
                case .opened, .cancelled:
                    return

                case let .unsupportedArchive(error):
                    guard preserveTemporaryDirectoryOnUnsupported else {
                        pane.openCommandShowError(error)
                        return
                    }

                    let shouldFallbackExternally = FileManagerExternalOpenRouter.shouldFallbackUnsupportedArchiveExternally(for: preparedOpen.stagedArchiveURL)
                    if shouldFallbackExternally {
                        if let applicationURL = FileManagerExternalOpenRouter.defaultExternalApplicationURL(forArchiveItemPath: item.path) {
                            _ = pane.openCommandOpenExternally(preparedOpen.stagedArchiveURL,
                                                               withApplicationAt: applicationURL,
                                                               preservingTemporaryDirectory: preparedOpen.temporaryDirectory)
                        } else if !pane.openCommandOpenExternallyIfPossible(preparedOpen.stagedArchiveURL,
                                                                            preservingTemporaryDirectory: preparedOpen.temporaryDirectory)
                        {
                            pane.openCommandCleanupTemporaryDirectory(preparedOpen.temporaryDirectory)
                            pane.openCommandShowError(error)
                        }
                    } else {
                        pane.openCommandCleanupTemporaryDirectory(preparedOpen.temporaryDirectory)
                        pane.openCommandShowError(error)
                    }

                case let .failed(error):
                    pane.openCommandShowError(error)
                }
            } catch {
                pane.openCommandShowError(error)
            }
        }
    }
}
