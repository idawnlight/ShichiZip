import Foundation

enum FileManagerArchiveListing {
    static func items(from archive: SZArchive,
                      session: SZOperationSession?) throws -> [ArchiveItem]
    {
        try archive.entries(with: session).map { ArchiveItem(from: $0) }
    }

    static func itemsAsync(from archive: SZArchive,
                           session: SZOperationSession,
                           reopenBeforeListing: Bool) async throws -> [ArchiveItem]
    {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    session.requestCancel()
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    let result: Result<[ArchiveItem], Error> = Result {
                        if reopenBeforeListing {
                            try archive.reopenAfterExternalMutation(with: session)
                        }
                        return try items(from: archive,
                                         session: session)
                    }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            session.requestCancel()
        }
    }
}

struct FileManagerArchiveStatistics: Equatable {
    let uncompressedSize: UInt64?

    init(entries: [ArchiveItem]) {
        var total: UInt64 = 0
        for entry in entries {
            guard !entry.isDirectory, !entry.isAnti else { continue }
            guard let size = entry.size else {
                uncompressedSize = nil
                return
            }
            let (sum, overflow) = total.addingReportingOverflow(size)
            total = overflow ? .max : sum
        }
        uncompressedSize = total
    }
}

struct FileManagerArchiveLevel {
    let filesystemDirectory: URL
    let archivePath: String
    let displayPathPrefix: String
    let archive: SZArchive
    let operationGate: FileManagerArchiveOperationGate
    let allEntries: [ArchiveItem]
    let hierarchy: ArchiveHierarchy
    let statistics: FileManagerArchiveStatistics
    let entryProperties: [FileManagerArchiveEntryProperty]
    let currentSubdir: String
    let temporaryDirectory: URL?
    let nestedIdentity: FileManagerNestedArchiveIdentity?
    let nestedWriteBackInfo: FileManagerNestedArchiveWriteBackInfo?

    init(filesystemDirectory: URL,
         archivePath: String,
         displayPathPrefix: String,
         archive: SZArchive,
         operationGate: FileManagerArchiveOperationGate,
         allEntries: [ArchiveItem],
         entryProperties: [FileManagerArchiveEntryProperty],
         currentSubdir: String,
         temporaryDirectory: URL?,
         nestedIdentity: FileManagerNestedArchiveIdentity?,
         nestedWriteBackInfo: FileManagerNestedArchiveWriteBackInfo?)
    {
        self.filesystemDirectory = filesystemDirectory
        self.archivePath = archivePath
        self.displayPathPrefix = displayPathPrefix
        self.archive = archive
        self.operationGate = operationGate
        self.allEntries = allEntries
        hierarchy = Self.makeHierarchy(entries: allEntries)
        statistics = FileManagerArchiveStatistics(entries: allEntries)
        self.entryProperties = entryProperties
        self.currentSubdir = currentSubdir
        self.temporaryDirectory = temporaryDirectory
        self.nestedIdentity = nestedIdentity
        self.nestedWriteBackInfo = nestedWriteBackInfo
    }

    private init(filesystemDirectory: URL,
                 archivePath: String,
                 displayPathPrefix: String,
                 archive: SZArchive,
                 operationGate: FileManagerArchiveOperationGate,
                 allEntries: [ArchiveItem],
                 hierarchy: ArchiveHierarchy,
                 statistics: FileManagerArchiveStatistics,
                 entryProperties: [FileManagerArchiveEntryProperty],
                 currentSubdir: String,
                 temporaryDirectory: URL?,
                 nestedIdentity: FileManagerNestedArchiveIdentity?,
                 nestedWriteBackInfo: FileManagerNestedArchiveWriteBackInfo?)
    {
        self.filesystemDirectory = filesystemDirectory
        self.archivePath = archivePath
        self.displayPathPrefix = displayPathPrefix
        self.archive = archive
        self.operationGate = operationGate
        self.allEntries = allEntries
        self.hierarchy = hierarchy
        self.statistics = statistics
        self.entryProperties = entryProperties
        self.currentSubdir = currentSubdir
        self.temporaryDirectory = temporaryDirectory
        self.nestedIdentity = nestedIdentity
        self.nestedWriteBackInfo = nestedWriteBackInfo
    }

    var topLevelArchiveURL: URL? {
        guard temporaryDirectory == nil,
              nestedWriteBackInfo == nil
        else {
            return nil
        }

        return URL(fileURLWithPath: archivePath).standardizedFileURL
    }

    var coordinatedLocation: FileManagerCoordinatedArchiveLocation? {
        guard let topLevelArchiveURL else { return nil }
        return FileManagerCoordinatedArchiveLocation(archiveURL: topLevelArchiveURL,
                                                     currentSubdir: currentSubdir)
    }

    func replacingEntries(_ entries: [ArchiveItem],
                          preservingSubdir subdir: String? = nil) -> FileManagerArchiveLevel
    {
        FileManagerArchiveLevel(filesystemDirectory: filesystemDirectory,
                                archivePath: archivePath,
                                displayPathPrefix: displayPathPrefix,
                                archive: archive,
                                operationGate: operationGate,
                                allEntries: entries,
                                entryProperties: entryProperties,
                                currentSubdir: subdir ?? currentSubdir,
                                temporaryDirectory: temporaryDirectory,
                                nestedIdentity: nestedIdentity,
                                nestedWriteBackInfo: nestedWriteBackInfo)
    }

    func replacingCurrentSubdir(_ subdir: String) -> FileManagerArchiveLevel {
        FileManagerArchiveLevel(filesystemDirectory: filesystemDirectory,
                                archivePath: archivePath,
                                displayPathPrefix: displayPathPrefix,
                                archive: archive,
                                operationGate: operationGate,
                                allEntries: allEntries,
                                hierarchy: hierarchy,
                                statistics: statistics,
                                entryProperties: entryProperties,
                                currentSubdir: subdir,
                                temporaryDirectory: temporaryDirectory,
                                nestedIdentity: nestedIdentity,
                                nestedWriteBackInfo: nestedWriteBackInfo)
    }

    private static func makeHierarchy(entries: [ArchiveItem]) -> ArchiveHierarchy {
        ArchiveHierarchy(records: entries.enumerated().map { itemIndex, entry in
            ArchiveHierarchyRecord(itemIndex: itemIndex,
                                   pathParts: entry.pathParts,
                                   isDirectory: entry.isDirectory)
        })
    }

    func supportsInPlaceMutation(hasConflictingNestedArchiveInstance: (FileManagerNestedArchiveIdentity) -> Bool) -> Bool {
        guard !operationGate.hasActiveLeases else {
            return false
        }

        guard temporaryDirectory == nil || nestedWriteBackInfo != nil else {
            return false
        }

        guard archive.canWrite else {
            return false
        }

        if let nestedIdentity {
            return !hasConflictingNestedArchiveInstance(nestedIdentity)
        }

        guard let topLevelArchiveURL else {
            return true
        }
        return !hasConflictingNestedArchiveInstance(
            .root(topLevelArchiveURL: topLevelArchiveURL),
        )
    }

    func mutationTarget(subdir: String? = nil,
                        hasConflictingNestedArchiveInstance: (FileManagerNestedArchiveIdentity) -> Bool) -> FileManagerArchiveMutationTarget?
    {
        guard supportsInPlaceMutation(hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance) else {
            return nil
        }

        return FileManagerArchiveMutationTarget(archive: archive,
                                                subdir: subdir ?? currentSubdir,
                                                topLevelArchiveURL: topLevelArchiveURL)
    }
}

struct FileManagerArchiveStack {
    private var levels: [FileManagerArchiveLevel] = []

    var isEmpty: Bool {
        levels.isEmpty
    }

    var count: Int {
        levels.count
    }

    var indices: Range<Array<FileManagerArchiveLevel>.Index> {
        levels.indices
    }

    var last: FileManagerArchiveLevel? {
        levels.last
    }

    var currentDisplayPathPrefix: String? {
        last?.displayPathPrefix
    }

    var currentHostDirectory: URL? {
        last?.filesystemDirectory
    }

    var parentIndexForCurrentNestedArchive: Int? {
        count >= 2 ? count - 2 : nil
    }

    subscript(index: Int) -> FileManagerArchiveLevel {
        get { levels[index] }
        set { levels[index] = newValue }
    }

    mutating func append(_ level: FileManagerArchiveLevel) {
        levels.append(level)
    }

    @discardableResult
    mutating func removeLast() -> FileManagerArchiveLevel {
        levels.removeLast()
    }

    func reversed() -> ReversedCollection<[FileManagerArchiveLevel]> {
        levels.reversed()
    }

    func map<T>(_ transform: (FileManagerArchiveLevel) throws -> T) rethrows -> [T] {
        try levels.map(transform)
    }

    func compactMap<T>(_ transform: (FileManagerArchiveLevel) throws -> T?) rethrows -> [T] {
        try levels.compactMap(transform)
    }

    mutating func replaceEntries(at index: Int,
                                 with entries: [ArchiveItem],
                                 preservingSubdir subdir: String? = nil) -> Bool
    {
        guard indices.contains(index) else { return false }
        levels[index] = levels[index].replacingEntries(entries,
                                                       preservingSubdir: subdir)
        return true
    }

    mutating func replaceCurrentSubdir(_ subdir: String) -> FileManagerArchiveLevel? {
        guard let lastIndex = levels.indices.last else { return nil }
        levels[lastIndex] = levels[lastIndex].replacingCurrentSubdir(subdir)
        return levels[lastIndex]
    }

    func archiveURL(for archive: SZArchive) -> URL? {
        for level in levels.reversed() where level.archive === archive {
            return URL(fileURLWithPath: level.archivePath).standardizedFileURL
        }

        return nil
    }

    func containsArchive(at archiveURL: URL) -> Bool {
        let standardizedURL = archiveURL.standardizedFileURL
        return levels.contains {
            URL(fileURLWithPath: $0.archivePath).standardizedFileURL == standardizedURL
        }
    }

    func coordinationSnapshots(isDirty: (FileManagerArchiveLevel) -> Bool) -> [FileManagerNestedArchiveOpenSnapshot] {
        levels.map { level in
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(level.archive),
                                                 identity: level.nestedIdentity,
                                                 isDirty: isDirty(level))
        }
    }
}

@MainActor
final class FileManagerArchiveSession {
    private var stack = FileManagerArchiveStack()
    private var allDisplayItems: [ArchiveItem] = []
    private(set) var displayItems: [ArchiveItem] = []
    private let showsHiddenFiles: () -> Bool
    let itemWorkflowService: FileManagerArchiveItemWorkflowService

    init(itemWorkflowService: FileManagerArchiveItemWorkflowService = FileManagerArchiveItemWorkflowService(),
         showsHiddenFiles: @escaping () -> Bool = { SZSettings.bool(.showHiddenFiles) })
    {
        self.itemWorkflowService = itemWorkflowService
        self.showsHiddenFiles = showsHiddenFiles
    }

    var isInsideArchive: Bool {
        !stack.isEmpty
    }

    var count: Int {
        stack.count
    }

    var currentLevel: FileManagerArchiveLevel? {
        stack.last
    }

    var currentDisplayPathPrefix: String? {
        stack.currentDisplayPathPrefix
    }

    var currentHostDirectory: URL? {
        stack.currentHostDirectory
    }

    var parentIndexForCurrentNestedArchive: Int? {
        stack.parentIndexForCurrentNestedArchive
    }

    func level(at index: Int) -> FileManagerArchiveLevel? {
        guard stack.indices.contains(index) else { return nil }
        return stack[index]
    }

    func containsLevel(at index: Int) -> Bool {
        stack.indices.contains(index)
    }

    func supportsInPlaceMutation(hasConflictingNestedArchiveInstance: (FileManagerNestedArchiveIdentity) -> Bool) -> Bool {
        guard let level = stack.last else {
            return false
        }
        return level.supportsInPlaceMutation(hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance)
    }

    func currentMutationTarget(subdir: String? = nil,
                               hasConflictingNestedArchiveInstance: (FileManagerNestedArchiveIdentity) -> Bool) -> FileManagerArchiveMutationTarget?
    {
        guard let level = stack.last else { return nil }
        return level.mutationTarget(subdir: subdir,
                                    hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance)
    }

    func mutationTarget(for level: FileManagerArchiveLevel,
                        subdir: String? = nil,
                        hasConflictingNestedArchiveInstance: (FileManagerNestedArchiveIdentity) -> Bool) -> FileManagerArchiveMutationTarget?
    {
        level.mutationTarget(subdir: subdir,
                             hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance)
    }

    /// Resolves the in-place mutation target for `archive` (revalidating that it is still the
    /// current level) and acquires an operation-gate lease for the impending write. Returns `nil`
    /// if the archive is gone, no longer current, not mutable, or already closing — keeping
    /// add/delete/rename/createFolder symmetric with extraction's `currentItemWorkflowContext`.
    func leasedMutationTarget(for archive: SZArchive,
                              subdir: String,
                              hasConflictingNestedArchiveInstance: (FileManagerNestedArchiveIdentity) -> Bool) -> FileManagerLeasedArchiveMutationTarget?
    {
        guard let archiveURL = archiveURL(for: archive),
              let level = currentLevel,
              URL(fileURLWithPath: level.archivePath).standardizedFileURL == archiveURL.standardizedFileURL,
              let target = level.mutationTarget(subdir: subdir,
                                                hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance),
              let lease = level.operationGate.acquireLease()
        else {
            return nil
        }

        return FileManagerLeasedArchiveMutationTarget(archive: target.archive,
                                                      subdir: target.subdir,
                                                      lease: lease)
    }

    func archiveURL(for archive: SZArchive) -> URL? {
        stack.archiveURL(for: archive)
    }

    func containsArchive(at archiveURL: URL) -> Bool {
        stack.containsArchive(at: archiveURL)
    }

    func coordinatedLocation() -> FileManagerCoordinatedArchiveLocation? {
        stack.last?.coordinatedLocation
    }

    func appendPreparedArchive(_ prepared: FileManagerPreparedArchiveOpen) {
        if let temporaryDirectory = prepared.temporaryDirectory {
            itemWorkflowService.register(temporaryDirectory)
        }

        let level = FileManagerArchiveLevel(
            filesystemDirectory: prepared.hostDirectory,
            archivePath: prepared.archivePath,
            displayPathPrefix: prepared.displayPathPrefix,
            archive: prepared.archive,
            operationGate: FileManagerArchiveOperationGate(),
            allEntries: prepared.entries,
            entryProperties: prepared.archive.entryProperties.map(FileManagerArchiveEntryProperty.init),
            currentSubdir: "",
            temporaryDirectory: prepared.temporaryDirectory,
            nestedIdentity: prepared.nestedIdentity,
            nestedWriteBackInfo: prepared.nestedWriteBackInfo,
        )
        stack.append(level)
        navigateSubdir("")
    }

    @discardableResult
    func navigateSubdir(_ subdir: String) -> Bool {
        guard let level = stack.replaceCurrentSubdir(subdir) else { return false }

        let subdirParts = subdir.split(separator: "/").map(String.init)
        var visibleItems: [ArchiveItem] = []

        if let directory = level.hierarchy.directory(at: subdirParts) {
            for child in directory.childrenInArchiveOrder {
                switch child {
                case let .entry(itemIndex):
                    visibleItems.append(level.allEntries[itemIndex])

                case let .directory(childDirectory):
                    if let representativeItemIndex = childDirectory.representativeItemIndex {
                        visibleItems.append(level.allEntries[representativeItemIndex])
                        continue
                    }

                    let firstEntry = level.allEntries[childDirectory.firstItemIndex]
                    let childPath = childDirectory.pathParts.joined(separator: "/")
                    let reference = level.archive.entrySnapshotIdentifier.map {
                        SZArchiveItemReference(
                            logicalDirectoryPath: childPath,
                            snapshotIdentifier: $0,
                        )
                    }
                    visibleItems.append(ArchiveItem(
                        index: -1,
                        path: childPath,
                        pathParts: childDirectory.pathParts,
                        name: childDirectory.name,
                        size: 0,
                        packedSize: 0,
                        modifiedDate: firstEntry.modifiedDate,
                        createdDate: nil,
                        accessedDate: nil,
                        crc: 0,
                        isDirectory: true,
                        isEncrypted: false,
                        isAnti: false,
                        method: "",
                        attributes: 0,
                        position: 0,
                        block: 0,
                        comment: "",
                        reference: reference,
                    ))
                }
            }
        }

        allDisplayItems = visibleItems
        applyHiddenVisibilityFilter()
        return true
    }

    func replaceEntries(at index: Int,
                        with entries: [ArchiveItem],
                        preservingSubdir subdir: String? = nil)
    {
        _ = stack.replaceEntries(at: index,
                                 with: entries,
                                 preservingSubdir: subdir)
    }

    func removeCurrentLevelIfMatching(_ level: FileManagerArchiveLevel) {
        if let currentLevel = stack.last,
           currentLevel.archive === level.archive
        {
            stack.removeLast()
        }

        if stack.isEmpty {
            allDisplayItems.removeAll()
            displayItems.removeAll()
        }
    }

    func clearDisplayItems() {
        allDisplayItems.removeAll()
        displayItems.removeAll()
    }

    func sortDisplayItems(by descriptors: [NSSortDescriptor]) {
        FileManagerItemSorting.sort(&allDisplayItems, by: descriptors)
        applyHiddenVisibilityFilter()
    }

    func applyHiddenVisibilityFilter() {
        displayItems = showsHiddenFiles() ? allDisplayItems : allDisplayItems.filter { !$0.isHidden }
    }

    func currentItemWorkflowContext(acquireLease: Bool = true,
                                    hostDirectory: URL,
                                    displayPathPrefix: String,
                                    quarantineSourceArchivePath: String?,
                                    hasConflictingNestedArchiveInstance: (FileManagerNestedArchiveIdentity) -> Bool) -> FileManagerArchiveItemWorkflowContext?
    {
        guard let level = stack.last else { return nil }
        let mutationTarget = acquireLease
            ? level.mutationTarget(hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance)
            : nil
        let lease: FileManagerArchiveOperationGate.Lease?
        if acquireLease {
            guard let acquired = level.operationGate.acquireLease() else { return nil }
            lease = acquired
        } else {
            lease = nil
        }

        return FileManagerArchiveItemWorkflowContext(archive: level.archive,
                                                     hostDirectory: hostDirectory,
                                                     displayPathPrefix: displayPathPrefix,
                                                     quarantineSourceArchivePath: quarantineSourceArchivePath,
                                                     mutationTarget: mutationTarget,
                                                     backingArchiveURL: URL(fileURLWithPath: level.archivePath),
                                                     topLevelArchiveURL: level.topLevelArchiveURL,
                                                     parentNestedIdentity: level.nestedIdentity,
                                                     archiveOperationLease: lease)
    }

    func currentExtractionContext(quarantineSourceArchivePath: String?) -> FileManagerArchiveExtractionContext? {
        guard let level = stack.last else { return nil }

        return FileManagerArchiveExtractionContext(archive: level.archive,
                                                   allEntries: level.allEntries,
                                                   currentSubdir: level.currentSubdir,
                                                   quarantineSourceArchivePath: quarantineSourceArchivePath)
    }

    func coordinationSnapshots(isDirty: (FileManagerArchiveLevel) -> Bool) -> [FileManagerNestedArchiveOpenSnapshot] {
        stack.coordinationSnapshots(isDirty: isDirty)
    }

    func preserveNestedTemporaryDirectories() -> [URL] {
        stack.compactMap { level in
            guard level.nestedWriteBackInfo != nil,
                  let temporaryDirectory = level.temporaryDirectory
            else {
                return nil
            }

            itemWorkflowService.unregister(temporaryDirectory)
            return temporaryDirectory.standardizedFileURL
        }
    }

    func preserveRemainingTemporaryDirectories(_ urls: [URL]) {
        for url in urls {
            itemWorkflowService.register(url)
        }
    }

    func cleanupTemporaryDirectory(_ url: URL?) {
        itemWorkflowService.cleanup(url)
    }

    func cleanupAllTemporaryDirectories() {
        itemWorkflowService.cleanupAll()
    }
}
