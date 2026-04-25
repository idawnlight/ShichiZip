import AppKit
import Darwin
import Foundation
import os

protocol FileManagerExternalTemporaryDirectoryCleaning: AnyObject {
    func scheduleCleanup(_ url: URL,
                         when application: NSRunningApplication)
}

/// Process-wide owner for temp directories that were handed to an external app.
/// Pane cleanup must not delete these while the external app may still be using them.
final class FileManagerExternalTemporaryDirectoryCleanup: FileManagerExternalTemporaryDirectoryCleaning, @unchecked Sendable {
    static let shared = FileManagerExternalTemporaryDirectoryCleanup()

    private final class CleanupObserver: @unchecked Sendable {
        private let notificationCenter: NotificationCenter
        private var observer: NSObjectProtocol?

        init(notificationCenter: NotificationCenter,
             application: NSRunningApplication,
             onTermination: @escaping @Sendable () -> Void)
        {
            let applicationProcessIdentifier = application.processIdentifier
            self.notificationCenter = notificationCenter
            observer = notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main,
            ) { notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.processIdentifier == applicationProcessIdentifier
                else {
                    return
                }

                onTermination()
            }
        }

        deinit {
            invalidate()
        }

        func invalidate() {
            if let observer {
                notificationCenter.removeObserver(observer)
                self.observer = nil
            }
        }
    }

    private let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let cleanupObserversState = OSAllocatedUnfairLock(initialState: [URL: CleanupObserver]())

    init(fileManager: FileManager = .default,
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter)
    {
        self.fileManager = fileManager
        self.notificationCenter = notificationCenter
    }

    func scheduleCleanup(_ url: URL,
                         when application: NSRunningApplication)
    {
        let temporaryDirectory = url.standardizedFileURL
        let observer = CleanupObserver(notificationCenter: notificationCenter,
                                       application: application)
        { [weak self] in
            self?.cleanup(temporaryDirectory)
        }

        let previousObserver = cleanupObserversState.withLock { observers in
            observers.updateValue(observer,
                                  forKey: temporaryDirectory)
        }
        previousObserver?.invalidate()

        if application.isTerminated {
            cleanup(temporaryDirectory)
        }
    }

    private func cleanup(_ temporaryDirectory: URL) {
        if fileManager.fileExists(atPath: temporaryDirectory.path) {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let observer = cleanupObserversState.withLock { observers in
            observers.removeValue(forKey: temporaryDirectory.standardizedFileURL)
        }
        observer?.invalidate()
    }
}

final class FileManagerArchiveOperationGate: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let gate: FileManagerArchiveOperationGate

        fileprivate init(gate: FileManagerArchiveOperationGate) {
            self.gate = gate
        }

        deinit {
            gate.releaseLease()
        }
    }

    private let condition = NSCondition()
    private var activeLeaseCount = 0
    private var isClosing = false

    func acquireLease() -> Lease? {
        condition.lock()
        defer { condition.unlock() }

        guard !isClosing else {
            return nil
        }

        activeLeaseCount += 1
        return Lease(gate: self)
    }

    func beginClosing() {
        condition.lock()
        isClosing = true
        condition.unlock()
    }

    func beginClosingAndWaitForLeases() {
        beginClosing()
        waitForLeasesToDrain()
    }

    var hasActiveLeases: Bool {
        condition.lock()
        let hasActiveLeases = activeLeaseCount > 0
        condition.unlock()
        return hasActiveLeases
    }

    func waitForLeasesToDrain() {
        while true {
            condition.lock()
            if activeLeaseCount == 0 {
                condition.unlock()
                return
            }

            if Thread.isMainThread {
                condition.unlock()
                _ = RunLoop.current.run(mode: .default,
                                        before: Date().addingTimeInterval(0.05))
            } else {
                _ = condition.wait(until: Date().addingTimeInterval(0.05))
                condition.unlock()
            }
        }
    }

    func cancelClosing() {
        condition.lock()
        isClosing = false
        condition.broadcast()
        condition.unlock()
    }

    private func releaseLease() {
        condition.lock()
        activeLeaseCount -= 1
        precondition(activeLeaseCount >= 0)
        if activeLeaseCount == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }
}

struct FileManagerArchiveItemWorkflowContext {
    let archive: SZArchive
    let hostDirectory: URL
    let displayPathPrefix: String
    let quarantineSourceArchivePath: String?
    let mutationTarget: FileManagerArchiveMutationTarget?
    var archiveOperationLease: FileManagerArchiveOperationGate.Lease?
}

struct FileManagerArchiveQuickLookPreview {
    let temporaryDirectory: URL
    let fileURLs: [URL]
}

struct FileManagerPreparedArchiveItemInternalOpen {
    let stagedArchiveURL: URL
    let temporaryDirectory: URL
    let preparedResult: FileManagerPreparedArchiveOpenResult
}

struct FileManagerPreparedArchiveItemExternalOpen {
    let stagedFileURL: URL
    let temporaryDirectory: URL
    let applicationURL: URL?
}

enum FileManagerArchiveItemOpenStrategy {
    case automatic
    case forceInternal(FileManagerArchiveOpenMode)
    case forceExternal
}

final class FileManagerArchiveItemWorkflowService {
    private struct StagedArchiveItem {
        let temporaryDirectory: URL
        let fileURL: URL
    }

    private let fileManager: FileManager
    private let externalTemporaryDirectoryCleanup: FileManagerExternalTemporaryDirectoryCleaning
    private let quarantineInheritanceEnabled: () -> Bool
    private let temporaryDirectoriesState = OSAllocatedUnfairLock(initialState: Set<URL>())

    init(fileManager: FileManager = .default,
         externalTemporaryDirectoryCleanup: FileManagerExternalTemporaryDirectoryCleaning = FileManagerExternalTemporaryDirectoryCleanup.shared,
         quarantineInheritanceEnabled: @escaping () -> Bool = { SZSettings.bool(.inheritDownloadedFileQuarantine) })
    {
        self.fileManager = fileManager
        self.externalTemporaryDirectoryCleanup = externalTemporaryDirectoryCleanup
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
        forgetTemporaryDirectory(url.standardizedFileURL)
    }

    func cleanupAll() {
        for url in trackedTemporaryDirectories() {
            _ = cleanupIfPossible(url)
        }
    }

    func scheduleCleanup(_ url: URL,
                         when application: NSRunningApplication)
    {
        let standardizedURL = url.standardizedFileURL
        // External apps may outlive this pane, so pane cleanup must stop owning it.
        forgetTemporaryDirectory(standardizedURL)
        externalTemporaryDirectoryCleanup.scheduleCleanup(standardizedURL,
                                                          when: application)
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

            let fileURLs = try items.map { try stagedFileURL(for: $0,
                                                             in: temporaryDirectory) }

            return FileManagerArchiveQuickLookPreview(temporaryDirectory: temporaryDirectory,
                                                      fileURLs: fileURLs)
        } catch {
            cleanup(temporaryDirectory)
            throw error
        }
    }

    func prepareExternalArchiveItemOpen(for item: ArchiveItem,
                                        context: FileManagerArchiveItemWorkflowContext,
                                        strategy: FileManagerArchiveItemOpenStrategy,
                                        session: SZOperationSession) throws -> FileManagerPreparedArchiveItemExternalOpen
    {
        let preferredApplicationURL = FileManagerExternalOpenRouter.preferredExternalApplicationURL(forArchiveItemPath: item.path)

        switch strategy {
        case .automatic:
            guard FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(archiveItemPath: item.path),
                  preferredApplicationURL != nil
            else {
                throw unavailableExternalOpenError(for: item.name)
            }

        case .forceExternal:
            break

        case .forceInternal:
            throw extractionPreparationError()
        }

        let stagedItem = try stage(item: item,
                                   context: context,
                                   temporaryDirectoryPrefix: FileManagerTemporaryDirectorySupport.openArchivePrefix,
                                   session: session)
        return FileManagerPreparedArchiveItemExternalOpen(stagedFileURL: stagedItem.fileURL,
                                                          temporaryDirectory: stagedItem.temporaryDirectory,
                                                          applicationURL: preferredApplicationURL)
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

            let fileURL = try stagedFileURL(for: item,
                                            in: temporaryDirectory)

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

            let fileURL = try stagedFileURL(for: item,
                                            in: temporaryDirectory)

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

    func prepareInternalArchiveOpen(for item: ArchiveItem,
                                    context: FileManagerArchiveItemWorkflowContext,
                                    openMode: FileManagerArchiveOpenMode,
                                    session: SZOperationSession) throws -> FileManagerPreparedArchiveItemInternalOpen
    {
        let stagedItem = try stage(item: item,
                                   context: context,
                                   temporaryDirectoryPrefix: FileManagerTemporaryDirectorySupport.openArchivePrefix,
                                   session: session)
        do {
            let nestedWriteBackInfo = try makeNestedArchiveWriteBackInfo(for: item,
                                                                         context: context,
                                                                         stagedArchiveURL: stagedItem.fileURL)
            let preparedResult = FileManagerArchiveOpenService.prepareArchiveOpen(url: stagedItem.fileURL,
                                                                                  hostDirectory: context.hostDirectory,
                                                                                  temporaryDirectory: stagedItem.temporaryDirectory,
                                                                                  displayPathPrefix: nestedDisplayPath(for: item,
                                                                                                                       displayPathPrefix: context.displayPathPrefix),
                                                                                  nestedWriteBackInfo: nestedWriteBackInfo,
                                                                                  openMode: openMode,
                                                                                  session: session)
            return FileManagerPreparedArchiveItemInternalOpen(stagedArchiveURL: stagedItem.fileURL,
                                                              temporaryDirectory: stagedItem.temporaryDirectory,
                                                              preparedResult: preparedResult)
        } catch {
            cleanup(stagedItem.temporaryDirectory)
            throw error
        }
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

        return FileManagerNestedArchiveWriteBackInfo(identity: FileManagerNestedArchiveIdentity(displayPath: nestedDisplayPath(for: item,
                                                                                                                               displayPathPrefix: context.displayPathPrefix)),
                                                     parentTarget: parentTarget,
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
            forgetTemporaryDirectory(standardizedURL)
            return true
        }

        do {
            try fileManager.removeItem(at: standardizedURL)
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

    private func stagedFileURL(for item: ArchiveItem,
                               in temporaryDirectory: URL) throws -> URL
    {
        let relativePath = SZArchive.correctedFileSystemRelativePath(forArchivePath: item.path,
                                                                     isDirectory: item.isDirectory)
        guard !relativePath.isEmpty else {
            throw extractionPreparationError()
        }

        let fileURL = temporaryDirectory.appendingPathComponent(relativePath,
                                                                isDirectory: item.isDirectory)
        guard fileManager.fileExists(atPath: fileURL.path),
              isStagedURL(fileURL,
                          containedIn: temporaryDirectory)
        else {
            throw extractionPreparationError()
        }

        return fileURL
    }

    private func isStagedURL(_ candidate: URL,
                             containedIn temporaryDirectory: URL) -> Bool
    {
        let parentComponents = temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
        let candidateComponents = candidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents

        guard candidateComponents.count > parentComponents.count else {
            return false
        }

        return Array(candidateComponents.prefix(parentComponents.count)) == parentComponents
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
        temporaryDirectoriesState.withLock { _ = $0.insert(url.standardizedFileURL) }
    }

    private func forgetTemporaryDirectory(_ url: URL) {
        temporaryDirectoriesState.withLock {
            _ = $0.remove(url.standardizedFileURL)
            _ = $0.remove(url)
        }
    }

    private func trackedTemporaryDirectories() -> [URL] {
        temporaryDirectoriesState.withLock { Array($0) }
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
