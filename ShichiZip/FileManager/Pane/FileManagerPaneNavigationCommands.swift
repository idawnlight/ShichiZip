import Foundation

@MainActor
enum FileManagerPaneNavigationCommands {
    static func openRootFolder(in pane: FileManagerPaneController) {
        guard let navigationGeneration = pane.navigationCommandBeginNavigation() else { return }
        if pane.navigationCommandIsInsideArchive {
            pane.navigationCommandNavigateArchiveSubdir("",
                                                        expectedNavigationGeneration: navigationGeneration)
            return
        }

        pane.navigationCommandLoadDirectory(
            FileManagerFileSystemNavigation.rootURL(for: pane.currentDirectoryURL),
            expectedNavigationGeneration: navigationGeneration,
        )
    }

    static func openRecentDirectory(_ url: URL,
                                    in pane: FileManagerPaneController)
    {
        guard let navigationGeneration = pane.navigationCommandBeginNavigation() else { return }
        guard pane.navigationCommandIsInsideArchive else {
            pane.navigationCommandLoadDirectory(url,
                                                expectedNavigationGeneration: navigationGeneration)
            return
        }
        guard let transitionToken = pane.navigationCommandBeginTransition(navigationGeneration) else {
            return
        }

        Task { @MainActor [weak pane] in
            guard let pane else { return }
            defer { pane.navigationCommandEndTransition(transitionToken) }
            guard pane.navigationCommandIsCurrentNavigation(navigationGeneration) else { return }
            guard await pane.navigationCommandCloseAllArchives(showError: true) else { return }
            guard pane.navigationCommandIsCurrentNavigation(navigationGeneration) else { return }
            pane.navigationCommandLoadDirectory(url,
                                                expectedNavigationGeneration: navigationGeneration)
        }
    }

    static func submitPath(_ enteredPath: String,
                           in pane: FileManagerPaneController)
    {
        let path = enteredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            return
        }
        guard let navigationGeneration = pane.navigationCommandBeginNavigation() else { return }

        switch FileManagerFileSystemNavigation.addressBarTarget(for: path) {
        case let .directory(url):
            if pane.navigationCommandIsInsideArchive {
                guard let transitionToken = pane.navigationCommandBeginTransition(navigationGeneration) else {
                    return
                }
                Task { @MainActor [weak pane] in
                    guard let pane else { return }
                    defer { pane.navigationCommandEndTransition(transitionToken) }
                    guard pane.navigationCommandIsCurrentNavigation(navigationGeneration) else { return }
                    guard await pane.navigationCommandCloseAllArchives(showError: true) else {
                        guard pane.navigationCommandIsCurrentNavigation(navigationGeneration) else { return }
                        pane.navigationCommandRestorePathField()
                        pane.navigationCommandReturnFocusToFileList()
                        return
                    }
                    guard pane.navigationCommandIsCurrentNavigation(navigationGeneration) else { return }
                    pane.navigationCommandLoadDirectory(url,
                                                        expectedNavigationGeneration: navigationGeneration)
                    pane.navigationCommandReturnFocusToFileList()
                }
            } else {
                pane.navigationCommandLoadDirectory(url,
                                                    expectedNavigationGeneration: navigationGeneration)
                pane.navigationCommandReturnFocusToFileList()
            }

        case let .file(url, hostDirectory):
            openAddressBarFile(url,
                               hostDirectory: hostDirectory,
                               navigationGeneration: navigationGeneration,
                               in: pane)

        case nil:
            pane.navigationCommandRestorePathField()
            pane.navigationCommandShowError(invalidPathError(for: path))
            pane.navigationCommandReturnFocusToFileList()
        }
    }

    static func goUp(in pane: FileManagerPaneController) {
        guard let navigationGeneration = pane.navigationCommandBeginNavigation() else { return }
        if pane.navigationCommandIsInsideArchive {
            goUpInArchive(navigationGeneration: navigationGeneration,
                          in: pane)
            return
        }

        pane.navigationCommandLoadDirectory(
            pane.currentDirectoryURL.deletingLastPathComponent(),
            expectedNavigationGeneration: navigationGeneration,
        )
    }

    private static func openAddressBarFile(_ url: URL,
                                           hostDirectory: URL,
                                           navigationGeneration: Int,
                                           in pane: FileManagerPaneController)
    {
        if FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(url) {
            pane.navigationCommandRestorePathField()
            if !pane.navigationCommandOpenExternallyIfPossible(url) {
                pane.navigationCommandShowError(pane.navigationCommandUnavailableExternalOpenError(for: url.lastPathComponent))
            }
            pane.navigationCommandReturnFocusToFileList()
            return
        }

        if pane.navigationCommandIsInsideArchive,
           !pane.navigationCommandCanOpenArchive(at: url)
        {
            pane.navigationCommandRestorePathField()
            if !pane.navigationCommandOpenExternallyIfPossible(url) {
                pane.navigationCommandShowError(pane.navigationCommandUnavailableExternalOpenError(for: url.lastPathComponent))
            }
            pane.navigationCommandReturnFocusToFileList()
            return
        }

        let transitionToken: UUID?
        if pane.navigationCommandIsInsideArchive {
            guard let token = pane.navigationCommandBeginTransition(navigationGeneration) else {
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
                    pane.navigationCommandEndTransition(transitionToken)
                }
            }
            guard pane.navigationCommandIsCurrentNavigation(navigationGeneration) else { return }

            if pane.navigationCommandIsInsideArchive,
               await !(pane.navigationCommandCloseAllArchives(showError: true))
            {
                guard pane.navigationCommandIsCurrentNavigation(navigationGeneration) else { return }
                pane.navigationCommandRestorePathField()
                pane.navigationCommandReturnFocusToFileList()
                return
            }

            guard pane.navigationCommandIsCurrentNavigation(navigationGeneration) else { return }
            let result = await pane.navigationCommandOpenArchiveInline(
                url,
                hostDirectory: hostDirectory,
                showError: false,
                expectedNavigationGeneration: navigationGeneration,
            )
            guard pane.navigationCommandIsCurrentNavigation(navigationGeneration) else { return }
            switch result {
            case .opened:
                break

            case let .unsupportedArchive(error):
                pane.navigationCommandRestorePathField()
                let shouldFallbackExternally = FileManagerExternalOpenRouter.shouldFallbackUnsupportedArchiveExternally(for: url)
                if shouldFallbackExternally {
                    if !pane.navigationCommandOpenExternallyIfPossible(url) {
                        pane.navigationCommandShowError(error)
                    }
                } else {
                    pane.navigationCommandShowError(error)
                }

            case .cancelled:
                pane.navigationCommandRestorePathField()

            case let .failed(error):
                pane.navigationCommandRestorePathField()
                pane.navigationCommandShowError(error)
            }

            pane.navigationCommandReturnFocusToFileList()
        }
    }

    private static func goUpInArchive(navigationGeneration: Int,
                                      in pane: FileManagerPaneController)
    {
        guard let level = pane.navigationCommandCurrentArchiveLevel else { return }

        if !level.currentSubdir.isEmpty {
            pane.navigationCommandNavigateArchiveSubdir(
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
            pane.navigationCommandShowError(error)
            return
        }
        guard let transitionToken = pane.navigationCommandBeginTransition(navigationGeneration) else {
            return
        }

        Task { @MainActor [weak pane] in
            guard let pane else { return }
            defer { pane.navigationCommandEndTransition(transitionToken) }
            guard pane.navigationCommandIsCurrentNavigation(navigationGeneration) else { return }
            guard await pane.navigationCommandCloseArchiveLevel(level,
                                                                showError: true)
            else {
                return
            }
            guard pane.navigationCommandIsCurrentNavigation(navigationGeneration) else { return }

            if !pane.navigationCommandIsInsideArchive {
                pane.navigationCommandLoadDirectory(
                    fileSystemDirectory,
                    expectedNavigationGeneration: navigationGeneration,
                )
            } else {
                guard let outer = pane.navigationCommandCurrentArchiveLevel else { return }
                pane.navigationCommandNavigateArchiveSubdir(
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
