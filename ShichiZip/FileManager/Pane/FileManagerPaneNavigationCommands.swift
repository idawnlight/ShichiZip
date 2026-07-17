import Foundation

@MainActor
enum FileManagerPaneNavigationCommands {
    static func openRootFolder(in pane: FileManagerPaneController) {
        if pane.navigationCommandIsInsideArchive {
            pane.navigationCommandNavigateArchiveSubdir("")
            return
        }

        pane.navigationCommandLoadDirectory(FileManagerFileSystemNavigation.rootURL(for: pane.currentDirectoryURL))
    }

    static func openRecentDirectory(_ url: URL,
                                    in pane: FileManagerPaneController)
    {
        if pane.navigationCommandIsInsideArchive,
           !pane.navigationCommandCloseAllArchives(showError: true)
        {
            return
        }

        pane.navigationCommandLoadDirectory(url)
    }

    static func submitPath(_ enteredPath: String,
                           in pane: FileManagerPaneController)
    {
        let path = enteredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return }

        switch FileManagerFileSystemNavigation.addressBarTarget(for: path) {
        case let .directory(url):
            guard pane.navigationCommandCloseAllArchives(showError: true) else {
                pane.navigationCommandRestorePathField()
                pane.navigationCommandReturnFocusToFileList()
                return
            }
            pane.navigationCommandLoadDirectory(url)
            pane.navigationCommandReturnFocusToFileList()

        case let .file(url, hostDirectory):
            openAddressBarFile(url,
                               hostDirectory: hostDirectory,
                               in: pane)

        case nil:
            pane.navigationCommandRestorePathField()
            pane.navigationCommandShowError(invalidPathError(for: path))
            pane.navigationCommandReturnFocusToFileList()
        }
    }

    static func goUp(in pane: FileManagerPaneController) {
        if pane.navigationCommandIsInsideArchive {
            goUpInArchive(in: pane)
            return
        }

        pane.navigationCommandLoadDirectory(pane.currentDirectoryURL.deletingLastPathComponent())
    }

    private static func openAddressBarFile(_ url: URL,
                                           hostDirectory: URL,
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

        guard pane.navigationCommandCloseAllArchives(showError: true) else {
            pane.navigationCommandRestorePathField()
            pane.navigationCommandReturnFocusToFileList()
            return
        }

        Task { @MainActor [weak pane] in
            guard let pane else { return }

            switch await pane.navigationCommandOpenArchiveInline(url,
                                                                 hostDirectory: hostDirectory,
                                                                 showError: false)
            {
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

    private static func goUpInArchive(in pane: FileManagerPaneController) {
        guard let level = pane.navigationCommandCurrentArchiveLevel else { return }

        if !level.currentSubdir.isEmpty {
            pane.navigationCommandNavigateArchiveSubdir(parentSubdir(for: level.currentSubdir))
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

        guard pane.navigationCommandCloseArchiveLevel(level,
                                                      showError: true)
        else {
            return
        }

        if !pane.navigationCommandIsInsideArchive {
            pane.navigationCommandLoadDirectory(fileSystemDirectory)
        } else {
            guard let outer = pane.navigationCommandCurrentArchiveLevel else { return }
            pane.navigationCommandNavigateArchiveSubdir(outer.currentSubdir)
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
