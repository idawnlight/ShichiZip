import AppKit
import Foundation
import ShichiZipQuickActionCore

@MainActor
final class AppQuickActionHandler {
    private static let logPrefix = "QuickActionTransport"

    private let fileManagerWindowRegistry: FileManagerWindowRegistry
    private let shouldRevealSmartQuickExtractDestination: @MainActor () -> Bool

    init(fileManagerWindowRegistry: FileManagerWindowRegistry,
         shouldRevealSmartQuickExtractDestination: @escaping @MainActor () -> Bool)
    {
        self.fileManagerWindowRegistry = fileManagerWindowRegistry
        self.shouldRevealSmartQuickExtractDestination = shouldRevealSmartQuickExtractDestination
    }

    func handleLaunchURL(_ url: URL) {
        SZLog.info(Self.logPrefix, "received launchURL=\(url.absoluteString)")
        do {
            SZLog.info(Self.logPrefix, "consuming launchURL=\(url.absoluteString)")
            let request = try ShichiZipQuickActionTransport.consumeRequest(from: url)
            SZLog.info(Self.logPrefix, "decoded request action=\(request.action.rawValue) pathCount=\(request.paths.count)")
            NSApp.activate(ignoringOtherApps: true)
            try handle(request)
        } catch {
            SZLog.error(Self.logPrefix, "failed launchURL=\(url.absoluteString) error=\(String(describing: error))")
            szPresentError(error, for: NSApp.keyWindow ?? NSApp.mainWindow)
        }
    }

    private func handle(_ request: ShichiZipQuickActionRequest) throws {
        switch request.action {
        case .showInFileManager:
            try handleShowInFileManager(request)
        case .openInShichiZip:
            try handleOpenInShichiZip(request)
        case .compress:
            try handleCompress(request)
        case .smartQuickExtract:
            try handleSmartQuickExtract(request)
        }
    }

    private func handleShowInFileManager(_ request: ShichiZipQuickActionRequest) throws {
        let fileURLs = try existingFileURLs(from: request)
        let groups = groupedFileSystemItemsByParentDirectory(fileURLs)

        guard !groups.isEmpty else {
            throw ShichiZipQuickActionError.unsupportedSelection(SZL10n.string("archive.selectOneOrMoreFiles"))
        }

        for group in groups {
            SZLog.info(Self.logPrefix, "show-in-file-manager opening new window urlCount=\(group.count)")
            fileManagerWindowRegistry.revealFileSystemItemsInNewWindow(group)
        }
    }

    private func handleOpenInShichiZip(_ request: ShichiZipQuickActionRequest) throws {
        let itemURL = try existingSingleURL(from: request,
                                            selectionError: SZL10n.string("archive.selectOneFile"))
        SZLog.info(Self.logPrefix, "open-in-shichizip opening new window item=\(itemURL.path)")
        Task { @MainActor [fileManagerWindowRegistry] in
            _ = await fileManagerWindowRegistry.openFileSystemItemInNewFileManager(itemURL)
        }
    }

    private func handleCompress(_ request: ShichiZipQuickActionRequest) throws {
        let fileURLs = try existingFileURLs(from: request)
        SZLog.info(Self.logPrefix, "compress presenting dialog urlCount=\(fileURLs.count)")

        Task { @MainActor in
            let dialog = CompressDialogController(sourceURLs: fileURLs)
            // Finder Quick Actions should present independently, not as a sheet on
            // whichever ShichiZip window happens to be key.
            guard let result = await dialog.runModal(for: nil) else { return }

            do {
                try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.compressing"),
                                                     parentWindow: nil)
                { session in
                    try SZArchive.create(atPath: result.archiveURL.path,
                                         fromPaths: fileURLs.map(\.path),
                                         settings: result.settings,
                                         session: session)
                }
                NSWorkspace.shared.selectFile(result.archiveURL.path, inFileViewerRootedAtPath: "")
            } catch {
                szPresentError(error, for: nil)
            }
        }
    }

    private func handleSmartQuickExtract(_ request: ShichiZipQuickActionRequest) throws {
        let archiveURL = try existingSingleFileURL(from: request,
                                                   selectionError: SZL10n.string("app.fileManager.selectArchiveToExtract"),
                                                   directoryError: "Folders cannot be extracted as archives.")
        SmartExtractRunner.extract(archiveURL: archiveURL,
                                   defaults: ExtractDialogController.quickActionDefaults(),
                                   parentWindow: NSApp.keyWindow ?? NSApp.mainWindow,
                                   shouldRevealDestination: shouldRevealSmartQuickExtractDestination)
    }

    private func existingFileURLs(from request: ShichiZipQuickActionRequest) throws -> [URL] {
        let fileURLs = request.fileURLs.filter { FileManager.default.szExistingItemKind(at: $0) != nil }
        guard !fileURLs.isEmpty else {
            throw ShichiZipQuickActionError.unsupportedSelection("The selected files are no longer available.")
        }

        return fileURLs
    }

    private func existingSingleFileURL(from request: ShichiZipQuickActionRequest,
                                       selectionError: String,
                                       directoryError: String) throws -> URL
    {
        let fileURLs = try existingFileURLs(from: request)
        guard fileURLs.count == 1 else {
            throw ShichiZipQuickActionError.unsupportedSelection(selectionError)
        }

        guard let itemKind = FileManager.default.szExistingItemKind(at: fileURLs[0]) else {
            throw ShichiZipQuickActionError.unsupportedSelection("The selected file is no longer available.")
        }
        guard itemKind != .directory else {
            throw ShichiZipQuickActionError.unsupportedSelection(directoryError)
        }

        return fileURLs[0]
    }

    private func existingSingleURL(from request: ShichiZipQuickActionRequest,
                                   selectionError: String) throws -> URL
    {
        let fileURLs = try existingFileURLs(from: request)
        guard fileURLs.count == 1 else {
            throw ShichiZipQuickActionError.unsupportedSelection(selectionError)
        }

        return fileURLs[0]
    }

    private func groupedFileSystemItemsByParentDirectory(_ urls: [URL]) -> [[URL]] {
        var orderedParentPaths: [String] = []
        var groups: [String: [URL]] = [:]

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            let parentDirectory = standardizedURL.deletingLastPathComponent().standardizedFileURL
            let parentPath = parentDirectory.path

            if groups[parentPath] == nil {
                groups[parentPath] = []
                orderedParentPaths.append(parentPath)
            }

            groups[parentPath]?.append(standardizedURL)
        }

        return orderedParentPaths.compactMap { groups[$0] }
    }
}
