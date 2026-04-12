import AppKit
import Darwin
import Foundation

struct FileManagerArchiveItemWorkflowContext {
    let archive: SZArchive
    let hostDirectory: URL
    let displayPathPrefix: String
    let quarantineSourceArchivePath: String?
    let mutationTarget: FileManagerArchiveMutationTarget?
}

struct FileManagerArchiveQuickLookPreview {
    let temporaryDirectory: URL
    let fileURLs: [URL]
}

enum FileManagerArchiveItemOpenStrategy {
    case automatic
    case forceInternal(FileManagerArchiveOpenMode)
    case forceExternal
}

final class FileManagerArchiveItemWorkflowService {
    private final class TemporaryDirectoryCleanupObserver {
        private weak var owner: FileManagerArchiveItemWorkflowService?
        private let applicationProcessIdentifier: pid_t
        let temporaryDirectory: URL
        private var observer: NSObjectProtocol?

        init(owner: FileManagerArchiveItemWorkflowService,
             application: NSRunningApplication,
             temporaryDirectory: URL)
        {
            self.owner = owner
            applicationProcessIdentifier = application.processIdentifier
            self.temporaryDirectory = temporaryDirectory.standardizedFileURL
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleTermination(notification)
            }
        }

        deinit {
            invalidate()
        }

        private func handleTermination(_ notification: Notification) {
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier == applicationProcessIdentifier
            else {
                return
            }

            owner?.cleanup(temporaryDirectory)
            owner?.removeCleanupObserver(self)
        }

        func invalidate() {
            if let observer {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                self.observer = nil
            }
        }
    }

    private struct StagedArchiveItem {
        let temporaryDirectory: URL
        let fileURL: URL
    }

    private let fileManager: FileManager
    private let quarantineInheritanceEnabled: () -> Bool
    private let temporaryDirectoriesLock = NSLock()
    private var temporaryDirectories: Set<URL> = []
    private let cleanupObserversLock = NSLock()
    private var cleanupObservers: [ObjectIdentifier: TemporaryDirectoryCleanupObserver] = [:]

    init(fileManager: FileManager = .default,
         quarantineInheritanceEnabled: @escaping () -> Bool = { SZSettings.bool(.inheritDownloadedFileQuarantine) })
    {
        self.fileManager = fileManager
        self.quarantineInheritanceEnabled = quarantineInheritanceEnabled
    }

    func register(_ url: URL) {
        rememberTemporaryDirectory(url)
    }

    func cleanup(_ url: URL?) {
        guard let url else { return }
        _ = cleanupIfPossible(url)
    }

    func unregister(_ url: URL?) {
        guard let url else { return }
        removeCleanupObservers(for: url)
        forgetTemporaryDirectory(url.standardizedFileURL)
    }

    func cleanupAll() {
        invalidateCleanupObservers()
        for url in trackedTemporaryDirectories() {
            _ = cleanupIfPossible(url)
        }
    }

    func scheduleCleanup(_ url: URL,
                         when application: NSRunningApplication)
    {
        let observer = TemporaryDirectoryCleanupObserver(owner: self,
                                                         application: application,
                                                         temporaryDirectory: url)
        cleanupObserversLock.lock()
        cleanupObservers[ObjectIdentifier(observer)] = observer
        cleanupObserversLock.unlock()
    }

    func open(_ item: ArchiveItem,
              context: FileManagerArchiveItemWorkflowContext,
              strategy: FileManagerArchiveItemOpenStrategy = .automatic,
              openArchiveInline: (URL, URL, String, URL, FileManagerNestedArchiveWriteBackInfo?, FileManagerArchiveOpenMode) -> FileManagerArchiveOpenResult,
              openExternally: (URL, URL, URL) -> Bool,
              openExternallyIfPossible: (URL, URL) -> Bool) throws
    {
        let stagedItem = try stage(item: item,
                                   context: context,
                                   temporaryDirectoryPrefix: FileManagerTemporaryDirectorySupport.openArchivePrefix)
        let preferredApplicationURL = FileManagerExternalOpenRouter.preferredExternalApplicationURL(forArchiveItemPath: item.path)

        switch strategy {
        case .automatic:
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

            let nestedWriteBackInfo = try makeNestedArchiveWriteBackInfo(for: item,
                                                                         context: context,
                                                                         stagedArchiveURL: stagedItem.fileURL)
            switch openArchiveInline(stagedItem.fileURL,
                                     stagedItem.temporaryDirectory,
                                     nestedDisplayPath(for: item,
                                                       displayPathPrefix: context.displayPathPrefix),
                                     context.hostDirectory,
                                     nestedWriteBackInfo,
                                     .defaultBehavior)
            {
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
                                                        stagedItem.temporaryDirectory)
                    {
                        cleanup(stagedItem.temporaryDirectory)
                        throw error
                    }
                } else {
                    cleanup(stagedItem.temporaryDirectory)
                    throw error
                }

            case .cancelled:
                cleanup(stagedItem.temporaryDirectory)
                return

            case let .failed(error):
                cleanup(stagedItem.temporaryDirectory)
                throw error
            }

        case let .forceInternal(openMode):
            let nestedWriteBackInfo = try makeNestedArchiveWriteBackInfo(for: item,
                                                                         context: context,
                                                                         stagedArchiveURL: stagedItem.fileURL)
            switch openArchiveInline(stagedItem.fileURL,
                                     stagedItem.temporaryDirectory,
                                     nestedDisplayPath(for: item,
                                                       displayPathPrefix: context.displayPathPrefix),
                                     context.hostDirectory,
                                     nestedWriteBackInfo,
                                     openMode)
            {
            case .opened:
                return
            case .cancelled:
                cleanup(stagedItem.temporaryDirectory)
                return
            case let .unsupportedArchive(error), let .failed(error):
                cleanup(stagedItem.temporaryDirectory)
                throw error
            }

        case .forceExternal:
            if let preferredApplicationURL {
                _ = openExternally(stagedItem.fileURL,
                                   preferredApplicationURL,
                                   stagedItem.temporaryDirectory)
                return
            }

            if openExternallyIfPossible(stagedItem.fileURL,
                                        stagedItem.temporaryDirectory)
            {
                return
            }

            cleanup(stagedItem.temporaryDirectory)
            throw unavailableExternalOpenError(for: item.name)
        }
    }

    func writePromise(for item: ArchiveItem,
                      context: FileManagerArchiveItemWorkflowContext,
                      to destinationURL: URL,
                      session: SZOperationSession?) throws
    {
        let standardizedDestinationURL = destinationURL.standardizedFileURL

        if !item.isDirectory,
           try extractPromiseDirectlyIfPossible(for: item,
                                                context: context,
                                                to: standardizedDestinationURL,
                                                session: session)
        {
            return
        }

        let stagedItem = try stagePromiseItem(for: item,
                                              context: context,
                                              session: session)
        defer {
            cleanup(stagedItem.temporaryDirectory)
        }

        try moveItemPreservingMetadata(from: stagedItem.fileURL,
                                       to: standardizedDestinationURL)
    }

    func stageQuickLookItems(_ items: [ArchiveItem],
                             context: FileManagerArchiveItemWorkflowContext,
                             session: SZOperationSession?) throws -> FileManagerArchiveQuickLookPreview
    {
        guard !items.isEmpty else {
            throw extractionPreparationError()
        }

        let temporaryDirectory = try createTemporaryDirectory(prefix: FileManagerTemporaryDirectorySupport.quickLookPrefix)

        do {
            let settings = stagingExtractionSettings(for: context)
            let indices = items.map { NSNumber(value: $0.index) }
            try context.archive.extractEntries(indices,
                                               toPath: temporaryDirectory.path,
                                               settings: settings,
                                               session: session)

            let fileURLs = items.map { temporaryDirectory.appendingPathComponent($0.path) }
            guard fileURLs.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
                throw extractionPreparationError()
            }

            return FileManagerArchiveQuickLookPreview(temporaryDirectory: temporaryDirectory,
                                                      fileURLs: fileURLs)
        } catch {
            cleanup(temporaryDirectory)
            throw error
        }
    }

    private func stage(item: ArchiveItem,
                       context: FileManagerArchiveItemWorkflowContext,
                       temporaryDirectoryPrefix: String,
                       session: SZOperationSession? = nil) throws -> StagedArchiveItem
    {
        let temporaryDirectory = try createTemporaryDirectory(prefix: temporaryDirectoryPrefix)

        do {
            let settings = stagingExtractionSettings(for: context)
            try context.archive.extractEntries([NSNumber(value: item.index)],
                                               toPath: temporaryDirectory.path,
                                               settings: settings,
                                               session: session)

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

    private func stagePromiseItem(for item: ArchiveItem,
                                  context: FileManagerArchiveItemWorkflowContext,
                                  session: SZOperationSession?) throws -> StagedArchiveItem
    {
        let extractionIndices = promiseExtractionIndices(for: item,
                                                         context: context)
        guard !extractionIndices.isEmpty else {
            throw extractionPreparationError()
        }

        let temporaryDirectory = try createTemporaryDirectory(prefix: FileManagerTemporaryDirectorySupport.dragPrefix)

        do {
            let settings = stagingExtractionSettings(for: context)
            try context.archive.extractEntries(extractionIndices,
                                               toPath: temporaryDirectory.path,
                                               settings: settings,
                                               session: session)

            let fileURL = temporaryDirectory.appendingPathComponent(item.path,
                                                                    isDirectory: item.isDirectory)
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

    private func promiseExtractionIndices(for item: ArchiveItem,
                                          context: FileManagerArchiveItemWorkflowContext) -> [NSNumber]
    {
        let archiveItems = context.archive.entries().map { ArchiveItem(from: $0) }
        var indices = Set<Int>()

        if item.index >= 0 {
            indices.insert(item.index)
        }

        if item.isDirectory || item.index < 0 {
            let directoryPath = normalizeArchivePath(item.path)
            let prefix = directoryPath.isEmpty ? "" : directoryPath + "/"

            for entry in archiveItems where entry.index >= 0 {
                let entryPath = normalizeArchivePath(entry.path)
                if entryPath == directoryPath || (!prefix.isEmpty && entryPath.hasPrefix(prefix)) {
                    indices.insert(entry.index)
                }
            }
        }

        return indices.sorted().map { NSNumber(value: $0) }
    }

    private func makeNestedArchiveWriteBackInfo(for item: ArchiveItem,
                                                context: FileManagerArchiveItemWorkflowContext,
                                                stagedArchiveURL: URL) throws -> FileManagerNestedArchiveWriteBackInfo?
    {
        guard let parentTarget = context.mutationTarget else {
            return nil
        }

        guard let initialFingerprint = FileManagerArchiveFileFingerprint.captureIfPossible(for: stagedArchiveURL,
                                                                                           fileManager: fileManager)
        else {
            throw extractionPreparationError()
        }

        return FileManagerNestedArchiveWriteBackInfo(parentTarget: parentTarget,
                                                     parentItemPath: item.path,
                                                     initialFingerprint: initialFingerprint)
    }

    private func extractPromiseDirectlyIfPossible(for item: ArchiveItem,
                                                  context: FileManagerArchiveItemWorkflowContext,
                                                  to destinationURL: URL,
                                                  session: SZOperationSession?) throws -> Bool
    {
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        let extractedURL = destinationDirectory.appendingPathComponent(item.name, isDirectory: false)
        let standardizedExtractedURL = extractedURL.standardizedFileURL

        if standardizedExtractedURL != destinationURL,
           fileManager.fileExists(atPath: standardizedExtractedURL.path)
        {
            return false
        }

        let settings = directPromiseExtractionSettings(for: context)

        do {
            try context.archive.extractEntries([NSNumber(value: item.index)],
                                               toPath: destinationDirectory.path,
                                               settings: settings,
                                               session: session)

            guard fileManager.fileExists(atPath: standardizedExtractedURL.path) else {
                throw extractionPreparationError()
            }

            if standardizedExtractedURL != destinationURL {
                try moveItemPreservingMetadata(from: standardizedExtractedURL,
                                               to: destinationURL)
            }

            return true
        } catch {
            if standardizedExtractedURL != destinationURL,
               fileManager.fileExists(atPath: standardizedExtractedURL.path)
            {
                try? fileManager.removeItem(at: standardizedExtractedURL)
            }
            throw error
        }
    }

    private func createTemporaryDirectory(prefix: String) throws -> URL {
        let tempDir = try FileManagerTemporaryDirectorySupport.makeTemporaryDirectory(prefix: prefix,
                                                                                      fileManager: fileManager)
        rememberTemporaryDirectory(tempDir)
        return tempDir
    }

    @discardableResult
    private func cleanupIfPossible(_ url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL

        if !fileManager.fileExists(atPath: standardizedURL.path) {
            removeCleanupObservers(for: standardizedURL)
            forgetTemporaryDirectory(standardizedURL)
            return true
        }

        do {
            try fileManager.removeItem(at: standardizedURL)
            removeCleanupObservers(for: standardizedURL)
            forgetTemporaryDirectory(standardizedURL)
            return true
        } catch {
            return false
        }
    }

    private func stagingExtractionSettings(for context: FileManagerArchiveItemWorkflowContext) -> SZExtractionSettings {
        let settings = SZExtractionSettings()
        settings.overwriteMode = .overwrite
        settings.pathMode = .fullPaths
        configureQuarantineInheritance(on: settings, context: context)
        return settings
    }

    private func directPromiseExtractionSettings(for context: FileManagerArchiveItemWorkflowContext) -> SZExtractionSettings {
        let settings = SZExtractionSettings()
        settings.overwriteMode = .overwrite
        settings.pathMode = .noPaths
        configureQuarantineInheritance(on: settings, context: context)
        return settings
    }

    private func configureQuarantineInheritance(on settings: SZExtractionSettings,
                                                context: FileManagerArchiveItemWorkflowContext)
    {
        guard quarantineInheritanceEnabled(),
              let quarantineSourceArchivePath = context.quarantineSourceArchivePath,
              !quarantineSourceArchivePath.isEmpty
        else {
            return
        }

        settings.sourceArchivePathForQuarantine = quarantineSourceArchivePath
    }

    private func normalizeArchivePath(_ path: String) -> String {
        var normalized = path
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func nestedDisplayPath(for item: ArchiveItem,
                                   displayPathPrefix: String) -> String
    {
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

    private func rememberTemporaryDirectory(_ url: URL) {
        temporaryDirectoriesLock.lock()
        temporaryDirectories.insert(url.standardizedFileURL)
        temporaryDirectoriesLock.unlock()
    }

    private func forgetTemporaryDirectory(_ url: URL) {
        temporaryDirectoriesLock.lock()
        temporaryDirectories.remove(url.standardizedFileURL)
        temporaryDirectories.remove(url)
        temporaryDirectoriesLock.unlock()
    }

    private func trackedTemporaryDirectories() -> [URL] {
        temporaryDirectoriesLock.lock()
        let urls = Array(temporaryDirectories)
        temporaryDirectoriesLock.unlock()
        return urls
    }

    private func removeCleanupObserver(_ observer: TemporaryDirectoryCleanupObserver) {
        cleanupObserversLock.lock()
        cleanupObservers.removeValue(forKey: ObjectIdentifier(observer))
        cleanupObserversLock.unlock()
        observer.invalidate()
    }

    private func removeCleanupObservers(for temporaryDirectory: URL) {
        let standardizedURL = temporaryDirectory.standardizedFileURL

        cleanupObserversLock.lock()
        let matching = cleanupObservers.filter { $0.value.temporaryDirectory == standardizedURL }
        for key in matching.keys {
            cleanupObservers.removeValue(forKey: key)
        }
        cleanupObserversLock.unlock()

        for observer in matching.values {
            observer.invalidate()
        }
    }

    private func invalidateCleanupObservers() {
        cleanupObserversLock.lock()
        let observers = Array(cleanupObservers.values)
        cleanupObservers.removeAll()
        cleanupObserversLock.unlock()

        for observer in observers {
            observer.invalidate()
        }
    }

    private func moveItemPreservingMetadata(from sourceURL: URL,
                                            to destinationURL: URL) throws
    {
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                throw error
            }
        }

        try copyItemPreservingMetadata(from: sourceURL, to: destinationURL)
        try fileManager.removeItem(at: sourceURL)
    }

    private func copyItemPreservingMetadata(from sourceURL: URL,
                                            to destinationURL: URL) throws
    {
        let cloneResult = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                copyfile(sourcePath,
                         destinationPath,
                         nil,
                         copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE_FORCE))
            }
        }
        if cloneResult == 0 {
            return
        }

        let copyResult = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                copyfile(sourcePath,
                         destinationPath,
                         nil,
                         copyfile_flags_t(COPYFILE_ALL))
            }
        }
        if copyResult == 0 {
            return
        }

        let errorCode = errno
        throw NSError(domain: NSPOSIXErrorDomain,
                      code: Int(errorCode),
                      userInfo: [NSLocalizedDescriptionKey: "The promised file could not be written."])
    }
}
