import Foundation

struct FileManagerArchiveItemWorkflowContext {
    let archive: SZArchive
    let hostDirectory: URL
    let displayPathPrefix: String
}

final class FileManagerArchiveItemWorkflowService {
    private struct StagedArchiveItem {
        let temporaryDirectory: URL
        let fileURL: URL
    }

    private let fileManager: FileManager
    private var temporaryDirectories: Set<URL> = []

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func register(_ url: URL) {
        temporaryDirectories.insert(url)
    }

    func cleanup(_ url: URL?) {
        guard let url else { return }
        temporaryDirectories.remove(url)
        try? fileManager.removeItem(at: url)
    }

    func cleanupAll() {
        for url in temporaryDirectories {
            try? fileManager.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
    }

    func open(_ item: ArchiveItem,
              context: FileManagerArchiveItemWorkflowContext,
              openArchiveInline: (URL, URL, String, URL) -> FileManagerArchiveOpenResult,
              openExternally: (URL, URL, URL) -> Bool,
              openExternallyIfPossible: (URL, URL) -> Bool) throws {
        let stagedItem = try stage(item: item,
                                   context: context,
                                   temporaryDirectoryPrefix: "7zO")
        let preferredApplicationURL = FileManagerExternalOpenRouter.preferredExternalApplicationURL(forArchiveItemPath: item.path)

        if FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(archiveItemPath: item.path) {
            guard let preferredApplicationURL else {
                cleanup(stagedItem.temporaryDirectory)
                throw unavailableExternalOpenError(for: item.name)
            }

            _ = openExternally(stagedItem.fileURL,
                               preferredApplicationURL,
                               stagedItem.temporaryDirectory)
            return
        }

        switch openArchiveInline(stagedItem.fileURL,
                                 stagedItem.temporaryDirectory,
                                 nestedDisplayPath(for: item,
                                                   displayPathPrefix: context.displayPathPrefix),
                                 context.hostDirectory) {
        case .opened:
            return

        case let .unsupportedArchive(error):
            let shouldFallbackExternally = FileManagerExternalOpenRouter.shouldFallbackUnsupportedArchiveExternally(for: stagedItem.fileURL)
            if shouldFallbackExternally {
                if let preferredApplicationURL {
                    _ = openExternally(stagedItem.fileURL,
                                       preferredApplicationURL,
                                       stagedItem.temporaryDirectory)
                } else if !openExternallyIfPossible(stagedItem.fileURL,
                                                    stagedItem.temporaryDirectory) {
                    cleanup(stagedItem.temporaryDirectory)
                    throw error
                }
            } else {
                cleanup(stagedItem.temporaryDirectory)
                throw error
            }

        case .cancelled:
            return

        case let .failed(error):
            throw error
        }
    }

    func dragURL(for item: ArchiveItem,
                 context: FileManagerArchiveItemWorkflowContext) -> URL? {
        guard !item.isDirectory, item.index >= 0 else { return nil }

        do {
            return try stage(item: item,
                             context: context,
                             temporaryDirectoryPrefix: "ShichiZip-drag-").fileURL
        } catch {
            return nil
        }
    }

    private func stage(item: ArchiveItem,
                       context: FileManagerArchiveItemWorkflowContext,
                       temporaryDirectoryPrefix: String) throws -> StagedArchiveItem {
        let temporaryDirectory = try createTemporaryDirectory(prefix: temporaryDirectoryPrefix)

        do {
            try context.archive.extractEntries([NSNumber(value: item.index)],
                                              toPath: temporaryDirectory.path,
                                              settings: stagingExtractionSettings(),
                                              progress: nil)

            let fileURL = temporaryDirectory.appendingPathComponent(item.path)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                throw extractionPreparationError()
            }

            return StagedArchiveItem(temporaryDirectory: temporaryDirectory,
                                     fileURL: fileURL)
        } catch {
            cleanup(temporaryDirectory)
            throw error
        }
    }

    private func createTemporaryDirectory(prefix: String) throws -> URL {
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        register(tempDir)
        return tempDir
    }

    private func stagingExtractionSettings() -> SZExtractionSettings {
        let settings = SZExtractionSettings()
        settings.overwriteMode = .overwrite
        settings.pathMode = .fullPaths
        return settings
    }

    private func nestedDisplayPath(for item: ArchiveItem,
                                   displayPathPrefix: String) -> String {
        displayPathPrefix + "/" + item.pathParts.joined(separator: "/")
    }

    private func extractionPreparationError() -> NSError {
        NSError(domain: SZArchiveErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "The archive item could not be prepared for opening."])
    }

    private func unavailableExternalOpenError(for itemName: String) -> NSError {
        NSError(domain: SZArchiveErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No application is available to open \"\(itemName)\"."])
    }
}