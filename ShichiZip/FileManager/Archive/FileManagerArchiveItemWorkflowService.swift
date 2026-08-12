import AppKit
import Foundation
import os

protocol FileManagerExternalTemporaryDirectoryCleaning: AnyObject {
    func scheduleCleanup(_ url: URL,
                         when application: NSRunningApplication)
}

/// Process-wide owner for temp directories that were handed to an external app.
/// Pane cleanup must not delete these while the external app may still be using them.
/// Observer state is protected by `cleanupObserversState`; cleanup may be scheduled from AppKit callbacks.
final class FileManagerExternalTemporaryDirectoryCleanup: FileManagerExternalTemporaryDirectoryCleaning, @unchecked Sendable {
    static let shared = FileManagerExternalTemporaryDirectoryCleanup()

    /// Retained across notification callbacks; observer mutation is confined to `invalidate()` and owner lock updates.
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

struct FileManagerArchiveItemWorkflowContext {
    let archive: SZArchive
    let hostDirectory: URL
    let displayPathPrefix: String
    let quarantineSourceArchivePath: String?
    let mutationTarget: FileManagerArchiveMutationTarget?
    let backingArchiveURL: URL?
    let topLevelArchiveURL: URL?
    let parentNestedIdentity: FileManagerNestedArchiveIdentity?
    var archiveOperationLease: FileManagerArchiveOperationGate.Lease?

    init(archive: SZArchive,
         hostDirectory: URL,
         displayPathPrefix: String,
         quarantineSourceArchivePath: String?,
         mutationTarget: FileManagerArchiveMutationTarget?,
         backingArchiveURL: URL? = nil,
         topLevelArchiveURL: URL? = nil,
         parentNestedIdentity: FileManagerNestedArchiveIdentity? = nil,
         archiveOperationLease: FileManagerArchiveOperationGate.Lease? = nil)
    {
        self.archive = archive
        self.hostDirectory = hostDirectory
        self.displayPathPrefix = displayPathPrefix
        self.quarantineSourceArchivePath = quarantineSourceArchivePath
        self.mutationTarget = mutationTarget
        self.backingArchiveURL = backingArchiveURL?.standardizedFileURL
        self.topLevelArchiveURL = topLevelArchiveURL?.standardizedFileURL
        self.parentNestedIdentity = parentNestedIdentity
        self.archiveOperationLease = archiveOperationLease
    }

    func displayPath(for item: ArchiveItem) -> String {
        displayPathPrefix + "/" + item.pathParts.joined(separator: "/")
    }

    func nestedIdentity(for item: ArchiveItem) -> FileManagerNestedArchiveIdentity? {
        guard let itemReference = item.reference,
              itemReference.hasArchiveIndex,
              itemReference.archiveIndex <= UInt(Int.max),
              let topLevelArchiveURL = parentNestedIdentity?.topLevelArchiveURL
              ?? topLevelArchiveURL
              ?? mutationTarget?.topLevelArchiveURL
        else {
            return nil
        }

        let parentLineage = parentNestedIdentity?.entryLineage ?? []
        let entry = FileManagerNestedArchiveIdentity.Entry(
            archiveIndex: Int(itemReference.archiveIndex),
            path: itemReference.path,
            isDirectory: itemReference.isDirectory,
        )
        return FileManagerNestedArchiveIdentity(
            topLevelArchiveURL: topLevelArchiveURL,
            entryLineage: parentLineage + [entry],
            displayPath: displayPath(for: item),
        )
    }
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

    private struct NestedArchiveParentSnapshot {
        let identity: FileManagerNestedArchiveIdentity
        let parentTarget: FileManagerArchiveMutationTarget
        let parentItemReference: SZArchiveItemReference
        let parentArchiveURL: URL
        let parentArchiveFingerprint: FileManagerArchiveFileFingerprint
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
        guard let materialization = try FileManagerExtractionMaterialization.prepareNewDestination(
            finalURL: standardizedDestinationURL,
            publishRootIsDirectory: item.isDirectory,
            fileManager: fileManager,
        )
        else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileWriteFileExistsError,
                          userInfo: [
                              NSFilePathErrorKey: standardizedDestinationURL.path,
                              NSLocalizedDescriptionKey: "The promised file already exists.",
                          ])
        }

        var extractionError: Error?
        do {
            if item.isDirectory {
                try extractPromiseDirectory(for: item,
                                            context: context,
                                            into: materialization,
                                            session: session)
            } else {
                try extractPromiseFile(for: item,
                                       context: context,
                                       into: materialization,
                                       session: session)
            }
        } catch {
            extractionError = error
            if !item.isDirectory {
                _ = try? materialization.moveSidecarItemToPublishRoot(named: item.name)
            }
        }

        try materialization.finish(operationError: extractionError)
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
            let relativePaths = try items.map(stagedRelativePath)
            let collisionKeys = relativePaths.map(stagingCollisionKey)
            let pathCounts = collisionKeys.reduce(into: [String: Int]()) { counts, key in
                counts[key, default: 0] += 1
            }
            let collidingPositions = items.indices.filter {
                pathCounts[collisionKeys[$0], default: 0] > 1
            }

            if collidingPositions.isEmpty {
                let indices = items.map { NSNumber(value: $0.index) }
                try context.archive.extractEntries(indices,
                                                   toPath: temporaryDirectory.path,
                                                   settings: settings,
                                                   session: session)

                let fileURLs = try items.map {
                    try stagedFileURL(for: $0,
                                      in: temporaryDirectory)
                }
                return FileManagerArchiveQuickLookPreview(temporaryDirectory: temporaryDirectory,
                                                          fileURLs: fileURLs)
            }

            var fileURLs = [URL?](repeating: nil,
                                  count: items.count)
            let noncollidingPositions = items.indices.filter {
                pathCounts[collisionKeys[$0], default: 0] == 1
            }
            if !noncollidingPositions.isEmpty {
                let batchDirectory = temporaryDirectory
                    .appendingPathComponent("batch", isDirectory: true)
                try fileManager.createDirectory(at: batchDirectory,
                                                withIntermediateDirectories: true)
                let indices = noncollidingPositions.map {
                    NSNumber(value: items[$0].index)
                }
                try context.archive.extractEntries(indices,
                                                   toPath: batchDirectory.path,
                                                   settings: settings,
                                                   session: session)
                for position in noncollidingPositions {
                    fileURLs[position] = try stagedFileURL(
                        for: items[position],
                        in: batchDirectory,
                    )
                }
            }

            let occurrencesDirectory = temporaryDirectory
                .appendingPathComponent("occurrences", isDirectory: true)
            try fileManager.createDirectory(at: occurrencesDirectory,
                                            withIntermediateDirectories: true)
            for position in collidingPositions {
                let occurrenceDirectory = occurrencesDirectory
                    .appendingPathComponent("\(position)",
                                            isDirectory: true)
                try fileManager.createDirectory(at: occurrenceDirectory,
                                                withIntermediateDirectories: true)
                try context.archive.extractEntries(
                    [NSNumber(value: items[position].index)],
                    toPath: occurrenceDirectory.path,
                    settings: settings,
                    session: session,
                )
                fileURLs[position] = try stagedFileURL(
                    for: items[position],
                    in: occurrenceDirectory,
                )
            }

            return try FileManagerArchiveQuickLookPreview(temporaryDirectory: temporaryDirectory,
                                                          fileURLs: fileURLs.map {
                                                              guard let fileURL = $0 else {
                                                                  throw extractionPreparationError()
                                                              }
                                                              return fileURL
                                                          })
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
        let defaultApplicationURL = FileManagerExternalOpenRouter.defaultExternalApplicationURL(forArchiveItemPath: item.path)

        switch strategy {
        case .automatic:
            guard FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(archiveItemPath: item.path),
                  defaultApplicationURL != nil
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
                                                          applicationURL: defaultApplicationURL)
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

    private func promiseExtractionIndices(for item: ArchiveItem,
                                          context: FileManagerArchiveItemWorkflowContext,
                                          session: SZOperationSession?) throws -> [NSNumber]
    {
        let archiveItems = try FileManagerArchiveListing.items(from: context.archive,
                                                               session: session)
        return FileManagerArchiveExtraction.entryIndices(for: [item],
                                                         allEntries: archiveItems)
    }

    func prepareInternalArchiveOpen(for item: ArchiveItem,
                                    context: FileManagerArchiveItemWorkflowContext,
                                    openMode: FileManagerArchiveOpenMode,
                                    session: SZOperationSession) throws -> FileManagerPreparedArchiveItemInternalOpen
    {
        guard let nestedIdentity = context.nestedIdentity(for: item) else {
            throw extractionPreparationError()
        }
        let parentSnapshot = try makeNestedArchiveParentSnapshot(
            for: item,
            identity: nestedIdentity,
            context: context,
        )
        let stagedItem = try stage(item: item,
                                   context: context,
                                   temporaryDirectoryPrefix: FileManagerTemporaryDirectorySupport.openArchivePrefix,
                                   session: session)
        do {
            let nestedWriteBackInfo = try makeNestedArchiveWriteBackInfo(parentSnapshot: parentSnapshot,
                                                                         stagedArchiveURL: stagedItem.fileURL)
            let preparedResult = FileManagerArchiveOpenService.prepareArchiveOpen(url: stagedItem.fileURL,
                                                                                  hostDirectory: context.hostDirectory,
                                                                                  temporaryDirectory: stagedItem.temporaryDirectory,
                                                                                  displayPathPrefix: context.displayPath(for: item),
                                                                                  nestedIdentity: nestedIdentity,
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

    private func makeNestedArchiveParentSnapshot(
        for item: ArchiveItem,
        identity: FileManagerNestedArchiveIdentity,
        context: FileManagerArchiveItemWorkflowContext,
    ) throws -> NestedArchiveParentSnapshot? {
        guard let parentTarget = context.mutationTarget else {
            return nil
        }
        guard let parentItemReference = item.reference else {
            throw extractionPreparationError()
        }
        guard let parentArchiveURL = context.backingArchiveURL
            ?? parentTarget.topLevelArchiveURL,
            let parentArchiveFingerprint =
            FileManagerArchiveFileFingerprint.captureIfPossible(
                for: parentArchiveURL,
                fileManager: fileManager,
            )
        else {
            throw extractionPreparationError()
        }

        return NestedArchiveParentSnapshot(
            identity: identity,
            parentTarget: parentTarget,
            parentItemReference: parentItemReference,
            parentArchiveURL: parentArchiveURL,
            parentArchiveFingerprint: parentArchiveFingerprint,
        )
    }

    private func makeNestedArchiveWriteBackInfo(
        parentSnapshot: NestedArchiveParentSnapshot?,
        stagedArchiveURL: URL,
    ) throws -> FileManagerNestedArchiveWriteBackInfo? {
        guard let parentSnapshot else { return nil }
        guard let initialFingerprint =
            FileManagerArchiveFileFingerprint.captureIfPossible(
                for: stagedArchiveURL,
                fileManager: fileManager,
            ),
            parentSnapshot.parentArchiveFingerprint.matchesCurrentFile(
                at: parentSnapshot.parentArchiveURL,
                fileManager: fileManager,
            )
        else {
            throw extractionPreparationError()
        }

        return FileManagerNestedArchiveWriteBackInfo(
            identity: parentSnapshot.identity,
            parentTarget: parentSnapshot.parentTarget,
            parentItemReference: parentSnapshot.parentItemReference,
            parentArchiveURL: parentSnapshot.parentArchiveURL,
            parentArchiveFingerprint: parentSnapshot.parentArchiveFingerprint,
            initialFingerprint: initialFingerprint,
        )
    }

    private func extractPromiseDirectory(for item: ArchiveItem,
                                         context: FileManagerArchiveItemWorkflowContext,
                                         into materialization: FileManagerExtractionMaterialization,
                                         session: SZOperationSession?) throws
    {
        let extractionIndices = try promiseExtractionIndices(for: item,
                                                             context: context,
                                                             session: session)
        guard !extractionIndices.isEmpty else {
            throw extractionPreparationError()
        }

        try materialization.createPublishRootDirectoryIfNeeded()
        let settings = stagingExtractionSettings(for: context)
        let pathPrefix = normalizeArchivePath(item.path)
        if !pathPrefix.isEmpty {
            settings.pathPrefixToStrip = pathPrefix
        }

        try context.archive.extractEntries(extractionIndices,
                                           toPath: materialization.publishRootURL.path,
                                           settings: settings,
                                           session: session)
    }

    private func extractPromiseFile(for item: ArchiveItem,
                                    context: FileManagerArchiveItemWorkflowContext,
                                    into materialization: FileManagerExtractionMaterialization,
                                    session: SZOperationSession?) throws
    {
        guard item.index >= 0 else {
            throw extractionPreparationError()
        }

        let settings = directPromiseExtractionSettings(for: context)
        try context.archive.extractEntries([NSNumber(value: item.index)],
                                           toPath: materialization.sidecarURL.path,
                                           settings: settings,
                                           session: session)

        guard try materialization.moveSidecarItemToPublishRoot(named: item.name) else {
            throw extractionPreparationError()
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
        let relativePath = try stagedRelativePath(for: item)

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

    private func stagedRelativePath(for item: ArchiveItem) throws -> String {
        let relativePath = SZArchive.correctedFileSystemRelativePath(
            forArchivePath: item.path,
            isDirectory: item.isDirectory,
        )
        guard !relativePath.isEmpty else {
            throw extractionPreparationError()
        }
        return relativePath
    }

    private func stagingCollisionKey(for relativePath: String) -> String {
        relativePath.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
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

    private func extractionPreparationError() -> NSError {
        NSError(domain: SZArchiveErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "The archive item could not be prepared for opening."])
    }

    private func unavailableExternalOpenError(for itemName: String) -> NSError {
        NSError(domain: SZArchiveErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.error.noAppToOpen", itemName)])
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
}
