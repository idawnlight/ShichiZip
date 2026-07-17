import Cocoa

@MainActor
private final class FileManagerLegacyArchiveCommitQueue {
    static let shared = FileManagerLegacyArchiveCommitQueue()

    private var pendingOperations: [@MainActor () -> Void] = []
    private var isRunning = false

    func perform(
        _ operation: @escaping @MainActor () -> FileManagerArchiveOpenResult,
    ) async -> FileManagerArchiveOpenResult {
        await withCheckedContinuation { continuation in
            pendingOperations.append {
                continuation.resume(returning: operation())
            }
            scheduleNextIfNeeded()
        }
    }

    private func scheduleNextIfNeeded() {
        guard !isRunning, !pendingOperations.isEmpty else { return }
        isRunning = true

        // Phase 2 will make archive closing asynchronous. Until then, begin the
        // legacy close/write-back path from a RunLoop callback rather than a
        // MainActor task so its synchronous UI callbacks remain serviceable.
        RunLoop.main.perform(inModes: [.default]) { [self] in
            MainActor.assumeIsolated {
                let operation = pendingOperations.removeFirst()
                operation()
                isRunning = false
                scheduleNextIfNeeded()
            }
        }
    }
}

@MainActor
final class FileManagerPaneArchiveCoordinator {
    private let archiveSession: FileManagerArchiveSession
    private let observerIdentifier: ObjectIdentifier
    private let parentWindow: () -> NSWindow?
    private let isViewLoaded: () -> Bool
    private let currentDirectory: () -> URL
    private let prepareDirectoryForArchivePresentation: (URL) -> Void
    private let updateTableColumns: () -> Void
    private let sortCurrentItems: () -> Void
    private let updatePathField: () -> Void
    private let updateStatusBar: () -> Void
    private let reloadTableData: () -> Void
    private let selectArchivePaths: ([String]) -> Void
    private let selectedArchivePaths: () -> [String]
    private let hasConflictingNestedArchiveInstance: (FileManagerNestedArchiveIdentity) -> Bool
    private let hasDirtyNestedArchiveInstance: (FileManagerNestedArchiveIdentity) -> Bool
    private let showError: (Error) -> Void

    private var archiveRefreshGeneration = 0
    private var archiveRefreshTask: Task<Void, Never>?
    private var archiveOpenGeneration = 0

    init(archiveSession: FileManagerArchiveSession,
         observerIdentifier: ObjectIdentifier,
         parentWindow: @escaping () -> NSWindow?,
         isViewLoaded: @escaping () -> Bool,
         updateTableColumns: @escaping () -> Void,
         currentDirectory: @escaping () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
         prepareDirectoryForArchivePresentation: @escaping (URL) -> Void = { _ in },
         sortCurrentItems: @escaping () -> Void = {},
         updatePathField: @escaping () -> Void = {},
         updateStatusBar: @escaping () -> Void = {},
         reloadTableData: @escaping () -> Void = {},
         selectArchivePaths: @escaping ([String]) -> Void,
         selectedArchivePaths: @escaping () -> [String] = { [] },
         hasConflictingNestedArchiveInstance: @escaping (FileManagerNestedArchiveIdentity) -> Bool = { _ in false },
         hasDirtyNestedArchiveInstance: @escaping (FileManagerNestedArchiveIdentity) -> Bool = { _ in false },
         showError: @escaping (Error) -> Void)
    {
        self.archiveSession = archiveSession
        self.observerIdentifier = observerIdentifier
        self.parentWindow = parentWindow
        self.isViewLoaded = isViewLoaded
        self.currentDirectory = currentDirectory
        self.prepareDirectoryForArchivePresentation = prepareDirectoryForArchivePresentation
        self.updateTableColumns = updateTableColumns
        self.sortCurrentItems = sortCurrentItems
        self.updatePathField = updatePathField
        self.updateStatusBar = updateStatusBar
        self.reloadTableData = reloadTableData
        self.selectArchivePaths = selectArchivePaths
        self.selectedArchivePaths = selectedArchivePaths
        self.hasConflictingNestedArchiveInstance = hasConflictingNestedArchiveInstance
        self.hasDirtyNestedArchiveInstance = hasDirtyNestedArchiveInstance
        self.showError = showError
    }

    // MARK: - Opening And Presentation

    @discardableResult
    func openArchiveInline(_ url: URL,
                           hostDirectory: URL? = nil,
                           temporaryDirectory: URL? = nil,
                           displayPathPrefix: String? = nil,
                           nestedWriteBackInfo: FileManagerNestedArchiveWriteBackInfo? = nil,
                           openMode: FileManagerArchiveOpenMode = .defaultBehavior,
                           showError: Bool = true,
                           preserveTemporaryDirectoryOnUnsupported: Bool = false,
                           replaceCurrentState: Bool = false) async -> FileManagerArchiveOpenResult
    {
        archiveOpenGeneration += 1
        let openGeneration = archiveOpenGeneration
        let paneHostDirectory = hostDirectory ?? archiveHostDirectory()
        let resolvedDisplayPathPrefix = displayPathPrefix ?? url.path
        let progressParentWindow = parentWindow().flatMap { window in
            window.isVisible ? window : nil
        }

        let preparedResult = await FileManagerArchiveOpenService.open(url: url,
                                                                     hostDirectory: paneHostDirectory,
                                                                     temporaryDirectory: temporaryDirectory,
                                                                     displayPathPrefix: resolvedDisplayPathPrefix,
                                                                     parentWindow: progressParentWindow,
                                                                     nestedWriteBackInfo: nestedWriteBackInfo,
                                                                     openMode: openMode)

        guard !Task.isCancelled, openGeneration == archiveOpenGeneration else {
            discardPreparedArchiveOpen(preparedResult,
                                       temporaryDirectory: temporaryDirectory)
            return .cancelled
        }

        let finish = {
            self.finishArchiveOpen(preparedResult,
                                   temporaryDirectory: temporaryDirectory,
                                   preserveTemporaryDirectoryOnUnsupported: preserveTemporaryDirectoryOnUnsupported,
                                   replaceCurrentState: replaceCurrentState,
                                   showError: showError,
                                   invalidatePendingOpen: false)
        }

        guard replaceCurrentState, archiveSession.isInsideArchive else {
            return finish()
        }

        return await FileManagerLegacyArchiveCommitQueue.shared.perform {
            guard openGeneration == self.archiveOpenGeneration else {
                self.discardPreparedArchiveOpen(preparedResult,
                                                temporaryDirectory: temporaryDirectory)
                return .cancelled
            }
            return finish()
        }
    }

    private func discardPreparedArchiveOpen(_ preparedResult: FileManagerPreparedArchiveOpenResult,
                                            temporaryDirectory: URL?)
    {
        if case let .opened(prepared) = preparedResult {
            prepared.archive.close()
            archiveSession.cleanupTemporaryDirectory(prepared.temporaryDirectory)
            return
        }

        archiveSession.cleanupTemporaryDirectory(temporaryDirectory)
    }

    func finishArchiveOpen(_ preparedResult: FileManagerPreparedArchiveOpenResult,
                           temporaryDirectory: URL?,
                           preserveTemporaryDirectoryOnUnsupported: Bool,
                           replaceCurrentState: Bool,
                           showError: Bool,
                           invalidatePendingOpen: Bool = true) -> FileManagerArchiveOpenResult
    {
        if invalidatePendingOpen {
            invalidatePendingArchiveOpen()
        }

        let result: FileManagerArchiveOpenResult
        switch preparedResult {
        case let .opened(prepared):
            if let nestedIdentity = prepared.nestedWriteBackInfo?.identity,
               hasDirtyNestedArchiveInstance(nestedIdentity)
            {
                prepared.archive.close()
                archiveSession.cleanupTemporaryDirectory(prepared.temporaryDirectory)
                result = .failed(operationError(SZL10n.string("app.fileManager.error.nestedArchiveDirty")))
                break
            }

            if commitPreparedArchive(prepared,
                                     replaceCurrentState: replaceCurrentState)
            {
                return .opened
            }
            return .cancelled

        case let .unsupportedArchive(error):
            if !preserveTemporaryDirectoryOnUnsupported {
                archiveSession.cleanupTemporaryDirectory(temporaryDirectory)
            }
            result = .unsupportedArchive(error)

        case .cancelled:
            archiveSession.cleanupTemporaryDirectory(temporaryDirectory)
            result = .cancelled

        case let .failed(error):
            archiveSession.cleanupTemporaryDirectory(temporaryDirectory)
            result = .failed(error)
        }

        if showError {
            switch result {
            case let .unsupportedArchive(error), let .failed(error):
                self.showError(error)
            case .opened, .cancelled:
                break
            }
        }

        return result
    }

    func navigateSubdir(_ subdir: String) {
        invalidatePendingArchiveOpen()
        guard archiveSession.navigateSubdir(subdir) else { return }
        presentCurrentArchiveSubdir()
    }

    func cleanupTemporaryDirectory(_ temporaryDirectory: URL?) {
        archiveSession.cleanupTemporaryDirectory(temporaryDirectory)
    }

    private func commitPreparedArchive(_ prepared: FileManagerPreparedArchiveOpen,
                                       replaceCurrentState: Bool) -> Bool
    {
        if replaceCurrentState, !closeAll(showError: true) {
            prepared.archive.close()
            archiveSession.cleanupTemporaryDirectory(prepared.temporaryDirectory)
            return false
        }

        prepareDirectoryForArchivePresentation(prepared.hostDirectory)
        archiveSession.appendPreparedArchive(prepared)
        presentCurrentArchiveSubdir()
        return true
    }

    private func presentCurrentArchiveSubdir() {
        updateTableColumns()
        sortCurrentItems()
        updatePathField()
        updateStatusBar()
        reloadTableData()
    }

    func archiveHostDirectory() -> URL {
        archiveSession.currentHostDirectory ?? currentDirectory()
    }

    // MARK: - Command Context

    func supportsInPlaceMutation() -> Bool {
        archiveSession.supportsInPlaceMutation(hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance)
    }

    func currentMutationTarget() -> (archive: SZArchive, subdir: String)? {
        guard let target = archiveSession.currentMutationTarget(hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance) else { return nil }
        return (target.archive, target.subdir)
    }

    func revalidatedMutationTarget(for target: (archive: SZArchive, subdir: String)) -> FileManagerLeasedArchiveMutationTarget? {
        archiveSession.leasedMutationTarget(for: target.archive,
                                            subdir: target.subdir,
                                            hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance)
    }

    func currentDestinationDisplayPath(locationDisplayPath: String) -> String? {
        guard archiveSession.isInsideArchive, supportsInPlaceMutation() else { return nil }
        return locationDisplayPath
    }

    func mutationTarget(for archiveURL: URL,
                        subdir: String) -> (archive: SZArchive, subdir: String)?
    {
        guard let level = archiveSession.currentLevel,
              URL(fileURLWithPath: level.archivePath).standardizedFileURL == archiveURL.standardizedFileURL
        else {
            return nil
        }

        guard let target = archiveSession.mutationTarget(for: level,
                                                         subdir: subdir,
                                                         hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance)
        else {
            return nil
        }

        return (target.archive, target.subdir)
    }

    func transferTarget(for archive: SZArchive,
                        subdir: String) -> FileManagerPaneArchiveTransferTarget?
    {
        guard let archiveURL = archiveSession.archiveURL(for: archive),
              let target = mutationTarget(for: archiveURL,
                                          subdir: subdir)
        else {
            return nil
        }

        return FileManagerPaneArchiveTransferTarget(archive: target.archive,
                                                    subdir: target.subdir,
                                                    archiveURL: archiveURL)
    }

    func currentItemWorkflowContext(acquireLease: Bool = true,
                                    quarantineSourceArchivePath: String?) -> FileManagerArchiveItemWorkflowContext?
    {
        archiveSession.currentItemWorkflowContext(acquireLease: acquireLease,
                                                  hostDirectory: archiveHostDirectory(),
                                                  displayPathPrefix: currentDisplayPathPrefix(),
                                                  quarantineSourceArchivePath: quarantineSourceArchivePath,
                                                  hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance)
    }

    func selectedOrDisplayedEntriesForExtraction(from items: [ArchiveItem],
                                                 quarantineSourceArchivePath: String?) -> [ArchiveItem]
    {
        guard let context = currentExtractionContext(quarantineSourceArchivePath: quarantineSourceArchivePath) else { return [] }

        let indices = Set(FileManagerArchiveExtraction.entryIndices(for: items,
                                                                    allEntries: context.allEntries).map(\.intValue))
        return context.allEntries.filter { indices.contains($0.index) }
    }

    func pathPrefixToStripForExtraction(items: [ArchiveItem],
                                        destinationURL: URL,
                                        pathMode: SZPathMode,
                                        eliminateDuplicates: Bool,
                                        quarantineSourceArchivePath: String?) -> String?
    {
        guard let context = currentExtractionContext(quarantineSourceArchivePath: quarantineSourceArchivePath) else { return nil }

        return FileManagerArchiveExtraction.pathPrefixToStrip(for: items,
                                                              context: context,
                                                              destinationURL: destinationURL,
                                                              pathMode: pathMode,
                                                              eliminateDuplicates: eliminateDuplicates)
    }

    func prepareExtraction(of itemsToExtract: [ArchiveItem],
                           emptySelectionMessage: String,
                           to destinationURL: URL,
                           overwriteMode: SZOverwriteMode,
                           pathMode: SZPathMode,
                           password: String?,
                           preserveNtSecurityInfo: Bool,
                           eliminateDuplicates: Bool,
                           inheritDownloadedFileQuarantine: Bool,
                           quarantineSourceArchivePath: String?) throws -> FileManagerPreparedExtraction
    {
        guard !itemsToExtract.isEmpty else {
            throw operationError(emptySelectionMessage)
        }

        guard let context = currentExtractionContext(quarantineSourceArchivePath: quarantineSourceArchivePath) else {
            throw operationError(SZL10n.string("app.fileManager.error.noArchiveOpen"))
        }

        guard var preparedExtraction = FileManagerArchiveExtraction.prepare(items: itemsToExtract,
                                                                            context: context,
                                                                            destinationURL: destinationURL,
                                                                            overwriteMode: overwriteMode,
                                                                            pathMode: pathMode,
                                                                            password: password,
                                                                            preserveNtSecurityInfo: preserveNtSecurityInfo,
                                                                            eliminateDuplicates: eliminateDuplicates,
                                                                            inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
        else {
            throw operationError(SZL10n.string("app.fileManager.error.cannotExtractSelected"))
        }

        // Lease the gate so `closeLevel`'s drain waits for a background extraction instead of letting
        // `close()` hard-block the main thread. Best-effort: `nil` when already closing.
        preparedExtraction.archiveOperationLease = archiveSession.currentLevel?.operationGate.acquireLease()
        return preparedExtraction
    }

    func extractArchiveItems(_ itemsToExtract: [ArchiveItem],
                             emptySelectionMessage: String,
                             to destinationURL: URL,
                             session: SZOperationSession?,
                             overwriteMode: SZOverwriteMode,
                             pathMode: SZPathMode,
                             password: String?,
                             preserveNtSecurityInfo: Bool,
                             eliminateDuplicates: Bool,
                             inheritDownloadedFileQuarantine: Bool,
                             quarantineSourceArchivePath: String?) throws
    {
        let preparedExtraction = try prepareExtraction(of: itemsToExtract,
                                                       emptySelectionMessage: emptySelectionMessage,
                                                       to: destinationURL,
                                                       overwriteMode: overwriteMode,
                                                       pathMode: pathMode,
                                                       password: password,
                                                       preserveNtSecurityInfo: preserveNtSecurityInfo,
                                                       eliminateDuplicates: eliminateDuplicates,
                                                       inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine,
                                                       quarantineSourceArchivePath: quarantineSourceArchivePath)
        try preparedExtraction.perform(session: session)
    }

    func testCurrentArchive(session: SZOperationSession? = nil) throws {
        guard let level = archiveSession.currentLevel else {
            throw operationError(SZL10n.string("app.fileManager.error.noArchiveOpen"))
        }
        try level.archive.test(with: session)
    }

    func currentArchiveForTest() throws -> FileManagerLeasedArchive {
        guard let level = archiveSession.currentLevel else {
            throw operationError(SZL10n.string("app.fileManager.error.noArchiveOpen"))
        }
        // Lease the gate so `closeLevel`'s drain waits for a background test instead of hard-blocking
        // the main thread. Best-effort: `nil` when already closing.
        return FileManagerLeasedArchive(archive: level.archive,
                                        lease: level.operationGate.acquireLease())
    }

    private func currentDisplayPathPrefix() -> String {
        archiveSession.currentDisplayPathPrefix ?? currentDirectory().path
    }

    private func currentExtractionContext(quarantineSourceArchivePath: String?) -> FileManagerArchiveExtractionContext? {
        archiveSession.currentExtractionContext(quarantineSourceArchivePath: quarantineSourceArchivePath)
    }

    // MARK: - Reloads And Change Propagation

    func reloadCurrentArchiveEntries(selectingPaths paths: [String] = []) {
        guard let level = archiveSession.currentLevel else { return }
        scheduleEntriesReload(at: archiveSession.count - 1,
                              selectingPaths: paths,
                              preservingSubdir: level.currentSubdir)
    }

    func reapplyHiddenVisibility() {
        let selectedPaths = selectedArchivePaths()
        archiveSession.applyHiddenVisibilityFilter()
        reloadTableData()
        updateStatusBar()
        selectArchivePaths(selectedPaths)
    }

    func handlePublishedArchiveChange(_ change: FileManagerArchiveChange) {
        switch FileManagerArchiveChangeBus.handlingDecision(for: change,
                                                            currentLocation: archiveSession.coordinatedLocation(),
                                                            observerIdentifier: observerIdentifier)
        {
        case .ignore:
            return
        case let .reload(selectingPaths):
            reloadCoordinatedArchive(selectingPaths: selectingPaths)
        }
    }

    func publishMutationIfNeeded(targetSubdir: String? = nil,
                                 selectingPaths paths: [String] = [])
    {
        guard let level = archiveSession.currentLevel,
              let archiveURL = level.topLevelArchiveURL
        else {
            return
        }

        let normalizedTargetSubdir = normalizeArchivePath(targetSubdir ?? level.currentSubdir)
        let normalizedPaths = paths.map(normalizeArchivePath)

        FileManagerArchiveChangeBus.publish(
            FileManagerArchiveChange(archiveURL: archiveURL,
                                     targetSubdir: normalizedTargetSubdir,
                                     selectingPaths: normalizedPaths,
                                     sourceIdentifier: observerIdentifier),
        )
    }

    func refreshAfterMutation(targetSubdir: String? = nil,
                              selectingPaths paths: [String] = [])
    {
        let normalizedTargetSubdir = normalizeArchivePath(targetSubdir ?? archiveSession.currentLevel?.currentSubdir ?? "")
        let normalizedCurrentSubdir = normalizeArchivePath(archiveSession.currentLevel?.currentSubdir ?? "")
        let selectionPaths = normalizedTargetSubdir == normalizedCurrentSubdir
            ? paths.map(normalizeArchivePath)
            : []
        reloadCurrentArchiveEntries(selectingPaths: selectionPaths)
    }

    func refreshAfterMutation(selectingPath path: String? = nil) {
        refreshAfterMutation(selectingPaths: path.map { [$0] } ?? [])
    }

    func cancelPendingReload() {
        archiveRefreshGeneration += 1
        archiveRefreshTask?.cancel()
        archiveRefreshTask = nil
    }

    func invalidatePendingArchiveOpen() {
        archiveOpenGeneration += 1
    }

    // MARK: - Closing And Temporary Directories

    @discardableResult
    func closeLevel(_ level: FileManagerArchiveLevel,
                    showError: Bool = false) -> Bool
    {
        invalidatePendingArchiveOpen()
        cancelPendingReload()
        level.operationGate.beginClosingAndWaitForLeases()

        do {
            let nestedWriteBackResult = try writeBackNestedArchiveChangesIfNeeded(for: level)
            level.archive.close()
            archiveSession.cleanupTemporaryDirectory(level.temporaryDirectory)

            archiveSession.removeCurrentLevelIfMatching(level)

            if let refreshedParent = nestedWriteBackResult.refreshedParent {
                archiveSession.replaceEntries(at: refreshedParent.index,
                                              with: refreshedParent.entries)
            }

            if let publishedChange = nestedWriteBackResult.publishedChange {
                FileManagerArchiveChangeBus.publish(publishedChange)
            }

            if !archiveSession.isInsideArchive {
                archiveSession.clearDisplayItems()
                updatePathField()
                updateStatusBar()
                reloadTableData()
            } else if isViewLoaded(), let currentLevel = archiveSession.currentLevel {
                archiveSession.navigateSubdir(currentLevel.currentSubdir)
                presentCurrentArchiveSubdir()
            }
            updateTableColumns()

            return true
        } catch {
            level.operationGate.cancelClosing()
            if showError {
                self.showError(error)
            }
            return false
        }
    }

    @discardableResult
    func closeAll(showError: Bool = false) -> Bool {
        invalidatePendingArchiveOpen()
        while let level = archiveSession.currentLevel {
            guard closeLevel(level, showError: showError) else {
                return false
            }
        }
        archiveSession.clearDisplayItems()
        updatePathField()
        updateStatusBar()
        reloadTableData()
        updateTableColumns()
        return true
    }

    func preserveNestedTemporaryDirectories() -> [URL] {
        archiveSession.preserveNestedTemporaryDirectories()
    }

    func preserveRemainingTemporaryDirectories(_ urls: [URL]) {
        archiveSession.preserveRemainingTemporaryDirectories(urls)
    }

    func cleanupAllTemporaryDirectories() {
        archiveSession.cleanupAllTemporaryDirectories()
    }

    // MARK: - Reload Implementation

    private func reloadCoordinatedArchive(selectingPaths paths: [String]) {
        guard let level = archiveSession.currentLevel,
              level.temporaryDirectory == nil,
              level.nestedWriteBackInfo == nil
        else {
            return
        }

        scheduleEntriesReload(at: archiveSession.count - 1,
                              selectingPaths: paths,
                              preservingSubdir: level.currentSubdir,
                              reopenBeforeListing: true)
    }

    private func scheduleEntriesReload(at index: Int,
                                       selectingPaths paths: [String],
                                       preservingSubdir subdir: String,
                                       reopenBeforeListing: Bool = false)
    {
        guard archiveSession.containsLevel(at: index) else { return }

        cancelPendingReload()

        guard let level = archiveSession.currentLevel else { return }
        guard index == archiveSession.count - 1 else { return }
        guard let lease = level.operationGate.acquireLease() else { return }

        archiveRefreshGeneration += 1
        let generation = archiveRefreshGeneration
        let archive = level.archive
        let archivePath = level.archivePath
        let normalizedPaths = paths.map(normalizeArchivePath)
        let session = SZOperationSession()

        archiveRefreshTask = Task { @MainActor [weak self] in
            defer { withExtendedLifetime(lease) {} }

            do {
                let refreshedEntries = try await FileManagerArchiveListing.itemsAsync(from: archive,
                                                                                      session: session,
                                                                                      reopenBeforeListing: reopenBeforeListing)
                guard !Task.isCancelled else { return }
                self?.finishEntriesReload(refreshedEntries,
                                          generation: generation,
                                          index: index,
                                          archive: archive,
                                          archivePath: archivePath,
                                          subdir: subdir,
                                          selectingPaths: normalizedPaths)
            } catch {
                guard !Task.isCancelled else { return }
                guard !szIsUserCancellation(error) else { return }
                guard self?.archiveRefreshGeneration == generation else { return }
                self?.showError(error)
            }
        }
    }

    private func finishEntriesReload(_ entries: [ArchiveItem],
                                     generation: Int,
                                     index: Int,
                                     archive: SZArchive,
                                     archivePath: String,
                                     subdir: String,
                                     selectingPaths paths: [String])
    {
        guard archiveRefreshGeneration == generation else { return }
        guard let level = archiveSession.level(at: index) else { return }

        guard level.archive === archive,
              level.archivePath == archivePath
        else {
            return
        }

        archiveSession.replaceEntries(at: index,
                                      with: entries,
                                      preservingSubdir: subdir)
        guard archiveSession.navigateSubdir(subdir) else { return }
        presentCurrentArchiveSubdir()
        selectArchivePaths(paths)
    }

    // MARK: - Close Implementation

    private func writeBackNestedArchiveChangesIfNeeded(for level: FileManagerArchiveLevel) throws -> (refreshedParent: (index: Int, entries: [ArchiveItem])?, publishedChange: FileManagerArchiveChange?) {
        guard let writeBackInfo = level.nestedWriteBackInfo else {
            return (nil, nil)
        }

        let temporaryArchiveURL = URL(fileURLWithPath: level.archivePath).standardizedFileURL
        guard let currentFingerprint = FileManagerArchiveFileFingerprint.captureIfPossible(for: temporaryArchiveURL) else {
            throw operationError(SZL10n.string("app.fileManager.error.nestedArchiveSyncFailed"))
        }

        guard currentFingerprint != writeBackInfo.initialFingerprint else {
            return (nil, nil)
        }

        let refreshedParentEntries = try ArchiveOperationRunner.runSynchronously(operationTitle: SZL10n.string("progress.updating"),
                                                                                 initialFileName: (writeBackInfo.parentItemPath as NSString).lastPathComponent,
                                                                                 parentWindow: parentWindow(),
                                                                                 deferredDisplay: true)
        { session -> [ArchiveItem] in
            try writeBackInfo.parentTarget.archive.replaceItem(atPath: writeBackInfo.parentItemPath,
                                                               inArchiveSubdir: writeBackInfo.parentTarget.subdir,
                                                               withFileAtPath: temporaryArchiveURL.path,
                                                               session: session)
            return try FileManagerArchiveListing.items(from: writeBackInfo.parentTarget.archive,
                                                       session: session)
        }

        let publishedChange = writeBackInfo.parentTarget.topLevelArchiveURL.map {
            FileManagerArchiveChange(archiveURL: $0,
                                     targetSubdir: writeBackInfo.parentTarget.subdir,
                                     selectingPaths: [writeBackInfo.parentItemPath],
                                     sourceIdentifier: observerIdentifier)
        }
        let refreshedParent = archiveSession.parentIndexForCurrentNestedArchive
            .map { (index: $0, entries: refreshedParentEntries) }
        return (refreshedParent, publishedChange)
    }

    private func normalizeArchivePath(_ path: String) -> String {
        FileManagerArchiveChange.normalizeArchivePath(path)
    }

    private func operationError(_ description: String) -> NSError {
        NSError(domain: SZArchiveErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: description])
    }
}
