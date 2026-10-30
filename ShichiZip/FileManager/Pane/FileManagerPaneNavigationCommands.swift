import Foundation

@MainActor
enum FileManagerPaneNavigationCommands {
    static func openRootFolder(in pane: FileManagerPaneController) {
        guard let navigationGeneration = pane.beginNavigation() else { return }
        if pane.isInsideArchive {
            pane.navigateArchiveSubdir("",
                                       expectedNavigationGeneration: navigationGeneration)
            return
        }

        pane.loadDirectory(
            FileManagerFileSystemNavigation.rootURL(for: pane.currentDirectoryURL),
            budget: FileManagerPaneDirectoryCoordinator.navigationBudget,
            expectedNavigationGeneration: navigationGeneration,
        )
    }

    static func openRecentDirectory(_ url: URL,
                                    in pane: FileManagerPaneController)
    {
        guard let navigationGeneration = pane.beginNavigation() else { return }
        guard pane.isInsideArchive else {
            pane.loadDirectory(url,
                               budget: FileManagerPaneDirectoryCoordinator.navigationBudget,
                               expectedNavigationGeneration: navigationGeneration)
            return
        }
        guard let transitionToken = pane.beginNavigationTransition(navigationGeneration) else {
            return
        }

        Task { @MainActor [weak pane] in
            guard let pane else { return }
            defer { pane.endNavigationTransition(transitionToken) }
            guard pane.isCurrentNavigation(navigationGeneration) else { return }
            guard await pane.closeAllArchives(showError: true) else { return }
            guard pane.isCurrentNavigation(navigationGeneration) else { return }
            pane.loadDirectory(url,
                               budget: FileManagerPaneDirectoryCoordinator.navigationBudget,
                               expectedNavigationGeneration: navigationGeneration)
        }
    }

    @discardableResult
    static func submitPath(_ enteredPath: String,
                           in pane: FileManagerPaneController) -> Bool
    {
        let path = enteredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            return false
        }
        guard let navigationGeneration = pane.beginNavigation() else { return false }

        switch FileManagerFileSystemNavigation.addressBarTarget(for: path) {
        case let .directory(url):
            if pane.isInsideArchive {
                guard let transitionToken = pane.beginNavigationTransition(navigationGeneration) else {
                    return false
                }
                Task { @MainActor [weak pane] in
                    guard let pane else { return }
                    defer { pane.endNavigationTransition(transitionToken) }
                    guard pane.isCurrentNavigation(navigationGeneration) else { return }
                    guard await pane.closeAllArchives(showError: true) else {
                        guard pane.isCurrentNavigation(navigationGeneration) else { return }
                        pane.updatePathField()
                        pane.returnFocusToFileList()
                        return
                    }
                    guard pane.isCurrentNavigation(navigationGeneration) else { return }
                    pane.loadDirectory(url,
                                       budget: FileManagerPaneDirectoryCoordinator.navigationBudget,
                                       expectedNavigationGeneration: navigationGeneration)
                    pane.returnFocusToFileList()
                }
            } else {
                pane.loadDirectory(url,
                                   budget: FileManagerPaneDirectoryCoordinator.navigationBudget,
                                   expectedNavigationGeneration: navigationGeneration)
                pane.returnFocusToFileList()
            }

        case let .file(url, hostDirectory):
            openAddressBarFile(url,
                               hostDirectory: hostDirectory,
                               navigationGeneration: navigationGeneration,
                               in: pane)

        case nil:
            pane.updatePathField()
            pane.showErrorAlert(invalidPathError(for: path))
            pane.returnFocusToFileList()
            return false
        }
        return true
    }

    static func goUp(in pane: FileManagerPaneController) {
        guard let navigationGeneration = pane.beginNavigation() else { return }
        if pane.isInsideArchive {
            goUpInArchive(navigationGeneration: navigationGeneration,
                          in: pane)
            return
        }

        pane.loadDirectory(
            pane.currentDirectoryURL.deletingLastPathComponent(),
            budget: FileManagerPaneDirectoryCoordinator.navigationBudget,
            expectedNavigationGeneration: navigationGeneration,
        )
    }

    private static func openAddressBarFile(_ url: URL,
                                           hostDirectory: URL,
                                           navigationGeneration: Int,
                                           in pane: FileManagerPaneController)
    {
        if FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(url) {
            pane.updatePathField()
            if !pane.openExternallyIfPossible(url) {
                pane.showErrorAlert(pane.unavailableExternalOpenError(for: url.lastPathComponent))
            }
            pane.returnFocusToFileList()
            return
        }

        if pane.isInsideArchive,
           !pane.canOpenArchive(at: url)
        {
            pane.updatePathField()
            if !pane.openExternallyIfPossible(url) {
                pane.showErrorAlert(pane.unavailableExternalOpenError(for: url.lastPathComponent))
            }
            pane.returnFocusToFileList()
            return
        }

        let transitionToken: UUID?
        if pane.isInsideArchive {
            guard let token = pane.beginNavigationTransition(navigationGeneration) else {
                return
            }
            transitionToken = token
        } else {
            transitionToken = nil
        }

        Task { @MainActor [weak pane] in
            guard let pane else { return }
            defer {
                if let transitionToken {
                    pane.endNavigationTransition(transitionToken)
                }
            }
            guard pane.isCurrentNavigation(navigationGeneration) else { return }

            if pane.isInsideArchive,
               await !(pane.closeAllArchives(showError: true))
            {
                guard pane.isCurrentNavigation(navigationGeneration) else { return }
                pane.updatePathField()
                pane.returnFocusToFileList()
                return
            }

            guard pane.isCurrentNavigation(navigationGeneration) else { return }
            let result = await pane.openArchiveInline(
                url,
                hostDirectory: hostDirectory,
                showError: false,
                expectedNavigationGeneration: navigationGeneration,
            )
            guard pane.isCurrentNavigation(navigationGeneration) else { return }
            switch result {
            case .opened:
                break

            case let .unsupportedArchive(error):
                pane.updatePathField()
                let shouldFallbackExternally = FileManagerExternalOpenRouter.shouldFallbackUnsupportedArchiveExternally(for: url)
                if shouldFallbackExternally {
                    if !pane.openExternallyIfPossible(url) {
                        pane.showErrorAlert(error)
                    }
                } else {
                    pane.showErrorAlert(error)
                }

            case .cancelled:
                pane.updatePathField()

            case let .failed(error):
                pane.updatePathField()
                pane.showErrorAlert(error)
            }

            pane.returnFocusToFileList()
        }
    }

    private static func goUpInArchive(navigationGeneration: Int,
                                      in pane: FileManagerPaneController)
    {
        guard let level = pane.currentArchiveLevel else { return }

        if !level.currentSubdir.isEmpty {
            pane.navigateArchiveSubdir(
                parentSubdir(for: level.currentSubdir),
                expectedNavigationGeneration: navigationGeneration,
            )
            return
        }

        let fileSystemDirectory = level.filesystemDirectory
        // Closing the archive is destructive: probe the destination first so a
        // permission / reachability failure surfaces before we tear the archive
        // down and leave the pane stranded.
        do {
            _ = try FileManager.default.contentsOfDirectory(at: fileSystemDirectory,
                                                            includingPropertiesForKeys: nil)
        } catch {
            pane.showErrorAlert(error)
            return
        }
        guard let transitionToken = pane.beginNavigationTransition(navigationGeneration) else {
            return
        }

        Task { @MainActor [weak pane] in
            guard let pane else { return }
            defer { pane.endNavigationTransition(transitionToken) }
            guard pane.isCurrentNavigation(navigationGeneration) else { return }
            guard await pane.closeArchiveLevel(level,
                                               showError: true)
            else {
                return
            }
            guard pane.isCurrentNavigation(navigationGeneration) else { return }

            if !pane.isInsideArchive {
                pane.loadDirectory(
                    fileSystemDirectory,
                    budget: FileManagerPaneDirectoryCoordinator.navigationBudget,
                    expectedNavigationGeneration: navigationGeneration,
                )
            } else {
                guard let outer = pane.currentArchiveLevel else { return }
                pane.navigateArchiveSubdir(
                    outer.currentSubdir,
                    expectedNavigationGeneration: navigationGeneration,
                )
            }
        }
    }

    private static func parentSubdir(for subdir: String) -> String {
        if let lastSlash = subdir.lastIndex(of: "/") {
            return String(subdir[subdir.startIndex ..< lastSlash])
        }

        return ""
    }

    private static func invalidPathError(for path: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [
                    NSFilePathErrorKey: path,
                    NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.error.pathNotFound", path),
                ])
    }
}
