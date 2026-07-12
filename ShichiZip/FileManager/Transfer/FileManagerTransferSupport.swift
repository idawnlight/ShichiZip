import AppKit
import os

func szPresentTransferAncestryConflict(_ conflict: FileManagerTransferPathValidation.Conflict,
                                       move: Bool,
                                       for window: NSWindow?)
{
    let action = move ? "move" : "copy"

    if !conflict.sourceIsDirectory {
        szPresentMessage(title: SZL10n.string("app.fileManager.cannotActionOntoItself", action),
                         message: SZL10n.string("app.fileManager.chooseDifferentDestination"),
                         style: .warning,
                         for: window)
        return
    }

    let sourceFolderName = conflict.sourceURL.lastPathComponent.isEmpty
        ? conflict.sourceURL.path
        : conflict.sourceURL.lastPathComponent
    let title = conflict.kind == .sameDestination
        ? SZL10n.string("app.fileManager.cannotActionIntoSelf", action)
        : SZL10n.string("app.fileManager.cannotActionIntoDescendant", action)

    szPresentMessage(title: title,
                     message: SZL10n.string("app.fileManager.chooseOutside", sourceFolderName),
                     style: .warning,
                     for: window)
}

func szPresentTransferArchiveSelfConflict(move: Bool,
                                          for window: NSWindow?)
{
    let action = move ? "move" : "copy"
    szPresentMessage(title: SZL10n.string("app.fileManager.cannotActionArchiveIntoSelf", action),
                     message: SZL10n.string("app.fileManager.chooseDifferentArchive"),
                     style: .warning,
                     for: window)
}

@MainActor
final class FileOperationDestinationPicker: NSObject {
    private weak var ownerWindow: NSWindow?
    private weak var pathField: NSComboBox?
    private let baseDirectory: URL

    init(ownerWindow: NSWindow?,
         pathField: NSComboBox,
         baseDirectory: URL)
    {
        self.ownerWindow = ownerWindow
        self.pathField = pathField
        self.baseDirectory = baseDirectory.standardizedFileURL
    }

    @objc func browse(_: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = SZL10n.string("app.choose")
        panel.message = SZL10n.string("app.chooseDestination")
        panel.directoryURL = suggestedDirectoryURL()

        panel.szBeginSheetOrRunModal(for: ownerWindow) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.pathField?.stringValue = szNormalizedDestinationDisplayPath(url.standardizedFileURL.path)
        }
    }

    private func suggestedDirectoryURL() -> URL {
        guard let pathField else {
            return baseDirectory
        }

        let currentValue = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentValue.isEmpty else {
            return baseDirectory
        }

        var probeURL = szStandardizedFileURL(fromUserPath: currentValue,
                                             relativeTo: baseDirectory)

        while true {
            if let itemKind = FileManager.default.szExistingItemKind(at: probeURL) {
                return itemKind == .directory ? probeURL : probeURL.deletingLastPathComponent()
            }

            let parentURL = probeURL.deletingLastPathComponent().standardizedFileURL
            if parentURL.path == probeURL.path {
                return baseDirectory
            }

            probeURL = parentURL
        }
    }
}

func szNormalizedDestinationDisplayPath(_ path: String) -> String {
    guard !path.isEmpty, path != "/" else {
        return path.isEmpty ? "/" : path
    }
    return path.hasSuffix("/") ? path : path + "/"
}

enum FileOperationDestinationHistory {
    private static var defaults: UserDefaults {
        SZSharedUserDefaults.defaults
    }

    private static let entriesKey = "FileManager.CopyMoveDestinationHistory"
    private static let maxEntries = 20

    static func entries() -> [String] {
        defaults.stringArray(forKey: entriesKey) ?? []
    }

    static func record(_ path: String) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let displayPath = szNormalizedDestinationDisplayPath(normalizedPath)
        var updatedEntries = entries().filter {
            URL(fileURLWithPath: $0).standardizedFileURL.path != normalizedPath
        }
        updatedEntries.insert(displayPath, at: 0)
        if updatedEntries.count > maxEntries {
            updatedEntries.removeSubrange(maxEntries ..< updatedEntries.count)
        }
        defaults.set(updatedEntries, forKey: entriesKey)
    }
}

enum FileOperationDestinationTarget {
    case directory(URL)
    case archive(archiveURL: URL, subdir: String)

    var displayPath: String {
        switch self {
        case let .directory(url):
            return szNormalizedDestinationDisplayPath(url.standardizedFileURL.path)
        case let .archive(archiveURL, subdir):
            let archivePath = archiveURL.standardizedFileURL.path
            let combinedPath = subdir.isEmpty ? archivePath : archivePath + "/" + subdir
            return szNormalizedDestinationDisplayPath(combinedPath)
        }
    }
}

enum FileManagerTransferDestinationValidation {
    enum Conflict: Equatable {
        case archiveSelf(URL)
        case ancestry(FileManagerTransferPathValidation.Conflict)
    }

    static func conflict(sourceURLs: [URL],
                         destinationTarget: FileOperationDestinationTarget) -> Conflict?
    {
        switch destinationTarget {
        case let .directory(destinationURL):
            fileSystemConflict(sourceURLs: sourceURLs,
                               destinationURL: destinationURL)
        case let .archive(archiveURL, _):
            archiveConflict(sourceURLs: sourceURLs,
                            archiveURL: archiveURL)
        }
    }

    static func fileSystemConflict(sourceURLs: [URL],
                                   destinationURL: URL) -> Conflict?
    {
        FileManagerTransferPathValidation.ancestryConflict(sourceURLs: sourceURLs,
                                                           destinationURL: destinationURL.standardizedFileURL)
            .map(Conflict.ancestry)
    }

    static func archiveConflict(sourceURLs: [URL],
                                archiveURL: URL?) -> Conflict?
    {
        guard let archiveURL else { return nil }

        let standardizedArchiveURL = archiveURL.standardizedFileURL
        let standardizedSourceURLs = Set(sourceURLs.map(\.standardizedFileURL))
        guard !standardizedSourceURLs.contains(standardizedArchiveURL) else {
            return .archiveSelf(standardizedArchiveURL)
        }

        return FileManagerTransferPathValidation.ancestryConflict(sourceURLs: sourceURLs,
                                                                  destinationURL: standardizedArchiveURL)
            .map(Conflict.ancestry)
    }

    @MainActor
    static func canMoveOrCopyFileSystemItems(_ urls: [URL],
                                             to destinationURL: URL,
                                             operation: NSDragOperation,
                                             presentingIn window: NSWindow?) -> Bool
    {
        guard let conflict = fileSystemConflict(sourceURLs: urls,
                                                destinationURL: destinationURL)
        else {
            return true
        }

        present(conflict,
                operation: operation,
                in: window)
        return false
    }

    @MainActor
    static func canMoveOrCopyFileSystemItemsToArchive(_ urls: [URL],
                                                      archiveURL: URL?,
                                                      operation: NSDragOperation,
                                                      presentingIn window: NSWindow?) -> Bool
    {
        guard let conflict = archiveConflict(sourceURLs: urls,
                                             archiveURL: archiveURL)
        else {
            return true
        }

        present(conflict,
                operation: operation,
                in: window)
        return false
    }

    @MainActor
    static func present(_ conflict: Conflict,
                        operation: NSDragOperation,
                        in window: NSWindow?)
    {
        switch conflict {
        case .archiveSelf:
            szPresentTransferArchiveSelfConflict(move: operation == .move,
                                                 for: window)
        case let .ancestry(conflict):
            szPresentTransferAncestryConflict(conflict,
                                              move: operation == .move,
                                              for: window)
        }
    }
}

enum FileOperationDestinationResolver {
    static func resolveTarget(from enteredPath: String,
                              relativeTo baseDirectory: URL,
                              createDirectoryIfNeeded: Bool = true) throws -> FileOperationDestinationTarget
    {
        guard !enteredPath.isEmpty else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileNoSuchFileError,
                          userInfo: [NSLocalizedDescriptionKey: "Enter a destination folder or archive."])
        }

        let standardizedURL = szStandardizedFileURL(fromUserPath: enteredPath,
                                                    relativeTo: baseDirectory)

        if let archiveTarget = try resolveArchiveTarget(from: standardizedURL) {
            return archiveTarget
        }

        if let itemKind = FileManager.default.szExistingItemKind(at: standardizedURL) {
            guard itemKind == .directory else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteInvalidFileNameError,
                              userInfo: [
                                  NSFilePathErrorKey: standardizedURL.path,
                                  NSLocalizedDescriptionKey: "The destination path must be a folder or archive.",
                              ])
            }
            return .directory(standardizedURL)
        }

        if containsArchiveLikePathComponent(standardizedURL.path) {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileNoSuchFileError,
                          userInfo: [
                              NSFilePathErrorKey: standardizedURL.path,
                              NSLocalizedDescriptionKey: "The destination archive does not exist. Use Add to create a new archive.",
                          ])
        }

        guard createDirectoryIfNeeded else {
            return .directory(standardizedURL)
        }

        try FileManager.default.createDirectory(at: standardizedURL, withIntermediateDirectories: true)
        return .directory(standardizedURL)
    }

    static func prepare(_ destinationTarget: FileOperationDestinationTarget) throws -> FileOperationDestinationTarget {
        switch destinationTarget {
        case .archive:
            return destinationTarget
        case let .directory(destinationURL):
            if let itemKind = FileManager.default.szExistingItemKind(at: destinationURL) {
                guard itemKind == .directory else {
                    throw NSError(domain: NSCocoaErrorDomain,
                                  code: NSFileWriteInvalidFileNameError,
                                  userInfo: [
                                      NSFilePathErrorKey: destinationURL.path,
                                      NSLocalizedDescriptionKey: "The destination path must be a folder or archive.",
                                  ])
                }
                return destinationTarget
            }

            try FileManager.default.createDirectory(at: destinationURL,
                                                    withIntermediateDirectories: true)
            return .directory(destinationURL)
        }
    }

    private static func resolveArchiveTarget(from standardizedURL: URL) throws -> FileOperationDestinationTarget? {
        let pathComponents = standardizedURL.pathComponents

        for componentCount in stride(from: pathComponents.count, through: 1, by: -1) {
            let prefixPath = NSString.path(withComponents: Array(pathComponents.prefix(componentCount)))
            guard let itemKind = FileManager.default.szExistingItemKind(at: URL(fileURLWithPath: prefixPath)) else {
                continue
            }

            guard itemKind != .directory else {
                continue
            }

            let archiveURL = URL(fileURLWithPath: prefixPath).standardizedFileURL
            guard isArchiveFile(at: archiveURL) else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteInvalidFileNameError,
                              userInfo: [
                                  NSFilePathErrorKey: prefixPath,
                                  NSLocalizedDescriptionKey: "The destination path must be a folder or archive.",
                              ])
            }

            let subdir = Array(pathComponents.dropFirst(componentCount)).joined(separator: "/")
            return .archive(archiveURL: archiveURL, subdir: subdir)
        }

        return nil
    }

    private static func isArchiveFile(at url: URL) -> Bool {
        let archive = SZArchive()

        do {
            try archive.open(atPath: url.path)
            archive.close()
            return true
        } catch {
            let nsError = error as NSError
            return nsError.domain == SZArchiveErrorDomain && nsError.code == -12
        }
    }

    private static func containsArchiveLikePathComponent(_ path: String) -> Bool {
        let supportedExtensions = Set(
            SZArchive.supportedFormats()
                .flatMap(\.extensions)
                .map { $0.lowercased() },
        )

        return URL(fileURLWithPath: path).standardizedFileURL.pathComponents.contains { component in
            let ext = URL(fileURLWithPath: component).pathExtension.lowercased()
            return !ext.isEmpty && supportedExtensions.contains(ext)
        }
    }
}

enum FileOperationArchiveTransferSelection {
    static func selectionPaths(for sourceURLs: [URL], targetSubdir: String) -> [String] {
        let normalizedTargetSubdir = szNormalizedArchiveTransferPath(targetSubdir)
        var seenPaths = Set<String>()
        var selectionPaths: [String] = []

        for url in sourceURLs {
            let leafName = url.lastPathComponent
            guard !leafName.isEmpty else { continue }

            let path = normalizedTargetSubdir.isEmpty ? leafName : normalizedTargetSubdir + "/" + leafName
            let normalizedPath = szNormalizedArchiveTransferPath(path)
            guard seenPaths.insert(normalizedPath).inserted else { continue }
            selectionPaths.append(normalizedPath)
        }

        return selectionPaths
    }
}

struct FileOperationArchiveTransferConfirmation {
    let title: String
    let message: String

    init(sourceURLs: [URL],
         archiveName: String,
         targetSubdir: String,
         operation: NSDragOperation)
    {
        title = Self.title(for: sourceURLs,
                           operation: operation)
        message = Self.message(archiveName: archiveName,
                               targetSubdir: targetSubdir,
                               operation: operation)
    }

    private static func title(for sourceURLs: [URL],
                              operation: NSDragOperation) -> String
    {
        if sourceURLs.count == 1 {
            return operation == .move
                ? SZL10n.string("app.fileManager.archiveTransfer.moveSingle", sourceURLs[0].lastPathComponent)
                : SZL10n.string("app.fileManager.archiveTransfer.addSingle", sourceURLs[0].lastPathComponent)
        }
        return operation == .move
            ? SZL10n.string("app.fileManager.archiveTransfer.moveMultiple", sourceURLs.count)
            : SZL10n.string("app.fileManager.archiveTransfer.addMultiple", sourceURLs.count)
    }

    private static func message(archiveName: String,
                                targetSubdir: String,
                                operation: NSDragOperation) -> String
    {
        let normalizedSubdir = szNormalizedArchiveTransferPath(targetSubdir)
        var lines = [SZL10n.string("app.fileManager.archiveTransfer.archive", archiveName)]
        if !normalizedSubdir.isEmpty {
            lines.append(SZL10n.string("app.fileManager.archiveTransfer.folder", normalizedSubdir))
        }
        lines.append("")
        lines.append(SZL10n.string("app.fileManager.archiveTransfer.replaceWarning"))
        if operation == .move {
            lines.append("")
            lines.append(SZL10n.string("app.fileManager.archiveTransfer.sourceRemovalWarning"))
        }
        return lines.joined(separator: "\n")
    }
}

private func szNormalizedArchiveTransferPath(_ path: String) -> String {
    var normalized = path
    while normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    return normalized
}

enum FileOperationDropTargetResolver {
    static func fileSystemDestination(currentDirectory: URL,
                                      dropOperation: NSTableView.DropOperation,
                                      item: FileSystemItem?) -> URL?
    {
        if dropOperation != .on {
            return currentDirectory.standardizedFileURL
        }

        guard let item else {
            return currentDirectory.standardizedFileURL
        }

        guard item.isDirectory else {
            return nil
        }

        return item.url.standardizedFileURL
    }

    static func archiveDestinationSubdir(currentSubdir: String,
                                         dropOperation: NSTableView.DropOperation,
                                         item: ArchiveItem?) -> String?
    {
        if dropOperation != .on {
            return szNormalizedArchiveTransferPath(currentSubdir)
        }

        guard let item else {
            return szNormalizedArchiveTransferPath(currentSubdir)
        }

        guard item.isDirectory else {
            return nil
        }

        return szNormalizedArchiveTransferPath(item.path)
    }
}

enum FileOperationDropResolver {
    static var promisedFilePasteboardTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func containsFilePromises(in pasteboard: NSPasteboard) -> Bool {
        let promisedTypes = Set(promisedFilePasteboardTypes)
        return pasteboard.types?.contains(where: promisedTypes.contains) ?? false
    }

    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return []
        }
        return urls.map(\.standardizedFileURL)
    }

    static func promiseReceivers(in pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
    }

    static func fileSystemDropOperation(sourceMask: NSDragOperation,
                                        containsFilePromises: Bool,
                                        droppedFileURLs: [URL],
                                        destinationDirectory: URL,
                                        volumeURLProvider: (URL) -> URL? = defaultVolumeURL) -> NSDragOperation
    {
        if containsFilePromises {
            return .copy
        }

        let canCopy = sourceMask.contains(.copy)
        let canMove = sourceMask.contains(.move)

        switch (canCopy, canMove) {
        case (false, false):
            return []
        case (true, false):
            return .copy
        case (false, true):
            return .move
        case (true, true):
            guard !droppedFileURLs.isEmpty else {
                return .move
            }
            return shouldPreferMoveForDroppedURLs(droppedFileURLs,
                                                  destinationDirectory: destinationDirectory,
                                                  volumeURLProvider: volumeURLProvider) ? .move : .copy
        }
    }

    static func archiveDropOperation(sourceMask: NSDragOperation,
                                     containsFilePromises: Bool) -> NSDragOperation
    {
        if containsFilePromises {
            return .copy
        }

        let canCopy = sourceMask.contains(.copy)
        let canMove = sourceMask.contains(.move)

        switch (canCopy, canMove) {
        case (false, false):
            return []
        case (true, false):
            return .copy
        case (false, true):
            return .move
        case (true, true):
            return .copy
        }
    }

    private static func shouldPreferMoveForDroppedURLs(_ urls: [URL],
                                                       destinationDirectory: URL,
                                                       volumeURLProvider: (URL) -> URL?) -> Bool
    {
        guard let destinationVolumeURL = volumeURLProvider(destinationDirectory) else {
            return false
        }

        return urls.allSatisfy { volumeURLProvider($0) == destinationVolumeURL }
    }

    private static func defaultVolumeURL(for url: URL) -> URL? {
        try? url.resourceValues(forKeys: [.volumeURLKey]).volume?.standardizedFileURL
    }
}

struct FileManagerPaneTransferLocation {
    let isVirtualLocation: Bool
    let currentDirectoryURL: URL
    let presentationWindow: NSWindow?
}

struct FileManagerPaneArchiveDragContext {
    let itemWorkflowContext: FileManagerArchiveItemWorkflowContext
    let operationGate: FileManagerArchiveOperationGate
    let workflowService: FileManagerArchiveItemWorkflowService
}

struct FileManagerPaneArchiveTransferTarget {
    let archive: SZArchive
    let subdir: String
    let archiveURL: URL

    var archiveName: String {
        archiveURL.lastPathComponent.isEmpty ? "archive" : archiveURL.lastPathComponent
    }
}

@MainActor
protocol FileManagerPaneTransferSourceHost: AnyObject {
    var transferLocation: FileManagerPaneTransferLocation { get }

    func transferRefresh()
}

extension FileManagerPaneTransferSourceHost {
    var transferIdentity: ObjectIdentifier {
        ObjectIdentifier(self)
    }
}

@MainActor
protocol FileManagerPaneTransferHost: FileManagerPaneTransferSourceHost {
    func transferItem(at row: Int) -> FileManagerPaneItem?
    func transferArchiveDragContext(acquireLease: Bool) -> FileManagerPaneArchiveDragContext?
    func transferCurrentArchiveMutationTarget() -> FileManagerPaneArchiveTransferTarget?
    func transferArchiveMutationTarget(for archive: SZArchive, subdir: String) -> FileManagerPaneArchiveTransferTarget?
    func transferLeasedArchiveMutationTarget(for archive: SZArchive, subdir: String) -> FileManagerLeasedArchiveMutationTarget?
    func transferDidMutateArchive(targetSubdir: String?, selectingPaths paths: [String])
    func transferShowReadOnlyArchiveMutationAlert(action: String)
    func transferShowError(_ error: Error)
}

struct FileOperationPromisedFileReception {
    let fileURLs: [URL]
    let firstError: Error?
}

enum FileOperationPromisedFileReceiver {
    static func receive(_ promiseReceivers: [NSFilePromiseReceiver],
                        at destinationDirectory: URL,
                        completion: @escaping @MainActor (FileOperationPromisedFileReception) -> Void)
    {
        let operationQueue = OperationQueue()
        operationQueue.qualityOfService = .userInitiated

        let completionGroup = DispatchGroup()
        let state = OSAllocatedUnfairLock(initialState: (fileURLs: [URL](), firstError: nil as Error?))

        for promiseReceiver in promiseReceivers {
            completionGroup.enter()
            promiseReceiver.receivePromisedFiles(atDestination: destinationDirectory,
                                                 options: [:],
                                                 operationQueue: operationQueue)
            { @Sendable fileURL, error in
                state.withLock { reception in
                    reception.fileURLs.append(fileURL.standardizedFileURL)
                    if let error, reception.firstError == nil {
                        reception.firstError = error
                    }
                }
                completionGroup.leave()
            }
        }

        completionGroup.notify(queue: .main) {
            let reception = state.withLock {
                FileOperationPromisedFileReception(fileURLs: $0.fileURLs,
                                                   firstError: $0.firstError)
            }
            MainActor.assumeIsolated {
                completion(reception)
            }
        }
    }
}

@MainActor
final class FileManagerPaneTransferCoordinator {
    private var pendingDropOperation: (sequenceNumber: Int, operation: NSDragOperation)?

    func pasteboardWriter(forRow row: Int,
                          host: any FileManagerPaneTransferHost) -> (any NSPasteboardWriting)?
    {
        guard let paneItem = host.transferItem(at: row) else { return nil }

        switch paneItem {
        case .parent:
            return nil

        case let .archive(item):
            guard let context = host.transferArchiveDragContext(acquireLease: false) else { return nil }

            let promise = ArchiveDragPromise(item: item,
                                             context: context.itemWorkflowContext,
                                             operationGate: context.operationGate,
                                             workflowService: context.workflowService,
                                             parentWindow: host.transferLocation.presentationWindow)
            let provider = NSFilePromiseProvider(fileType: ArchiveDragPromise.fileType(for: item),
                                                 delegate: promise)
            provider.userInfo = promise
            return provider

        case let .filesystem(item):
            return item.url as NSURL
        }
    }

    func validateDrop(_ info: any NSDraggingInfo,
                      proposedRow row: Int,
                      dropOperation: NSTableView.DropOperation,
                      in tableView: NSTableView,
                      host: any FileManagerPaneTransferHost) -> NSDragOperation
    {
        if host.transferLocation.isVirtualLocation {
            guard sourceHost(for: info)?.transferLocation.isVirtualLocation != true,
                  archiveDropMutationTarget(for: row,
                                            dropOperation: dropOperation,
                                            host: host) != nil
            else {
                pendingDropOperation = nil
                return []
            }

            setDropRow(row,
                       dropOperation: dropOperation,
                       in: tableView)
            let operation = resolvedArchiveDropOperation(for: info)
            pendingDropOperation = operation.isEmpty ? nil : (info.draggingSequenceNumber, operation)
            return operation
        }

        guard let destinationDirectory = dropDestinationDirectory(for: row,
                                                                  dropOperation: dropOperation,
                                                                  host: host)
        else {
            pendingDropOperation = nil
            return []
        }

        setDropRow(row,
                   dropOperation: dropOperation,
                   in: tableView)
        let operation = resolvedDropOperation(for: info,
                                              destinationDirectory: destinationDirectory)
        pendingDropOperation = operation.isEmpty ? nil : (info.draggingSequenceNumber, operation)
        return operation
    }

    func acceptDrop(_ info: any NSDraggingInfo,
                    row: Int,
                    dropOperation: NSTableView.DropOperation,
                    host: any FileManagerPaneTransferHost) -> Bool
    {
        let sourceHost = sourceHost(for: info)

        if host.transferLocation.isVirtualLocation {
            guard sourceHost?.transferLocation.isVirtualLocation != true,
                  let target = archiveDropMutationTarget(for: row,
                                                         dropOperation: dropOperation,
                                                         host: host)
            else {
                pendingDropOperation = nil
                return false
            }

            let operation = takeResolvedArchiveDropOperation(for: info)
            let promiseReceivers = FileOperationDropResolver.promiseReceivers(in: info.draggingPasteboard)
            if !promiseReceivers.isEmpty {
                receivePromisedFiles(promiseReceivers,
                                     intoArchive: target,
                                     sourceHost: sourceHost,
                                     host: host)
                return true
            }

            guard !operation.isEmpty else { return false }
            let urls = FileOperationDropResolver.fileURLs(in: info.draggingPasteboard)
            guard !urls.isEmpty else { return false }

            return beginArchiveTransfer(urls,
                                        to: target,
                                        operation: operation,
                                        sourceHost: sourceHost,
                                        host: host,
                                        requiresConfirmation: true)
        }

        guard let destinationDirectory = dropDestinationDirectory(for: row,
                                                                  dropOperation: dropOperation,
                                                                  host: host)
        else {
            pendingDropOperation = nil
            return false
        }
        let operation = takeResolvedDropOperation(for: info,
                                                  destinationDirectory: destinationDirectory)

        let promiseReceivers = FileOperationDropResolver.promiseReceivers(in: info.draggingPasteboard)
        if !promiseReceivers.isEmpty {
            receivePromisedFiles(promiseReceivers,
                                 at: destinationDirectory,
                                 host: host)
            return true
        }

        guard !operation.isEmpty else { return false }
        let urls = FileOperationDropResolver.fileURLs(in: info.draggingPasteboard)
        guard !urls.isEmpty else { return false }

        guard FileManagerTransferDestinationValidation.canMoveOrCopyFileSystemItems(urls,
                                                                                    to: destinationDirectory,
                                                                                    operation: operation,
                                                                                    presentingIn: host.transferLocation.presentationWindow)
        else {
            return false
        }

        beginDroppedFileTransfer(urls,
                                 to: destinationDirectory,
                                 operation: operation,
                                 sourceHost: sourceHost,
                                 host: host)
        return true
    }

    @discardableResult
    func beginArchiveTransfer(_ urls: [URL],
                              to target: (archive: SZArchive, subdir: String),
                              operation: NSDragOperation,
                              sourceHost: (any FileManagerPaneTransferSourceHost)?,
                              host: any FileManagerPaneTransferHost,
                              cleanupDirectory: URL? = nil,
                              parentWindow: NSWindow? = nil,
                              requiresConfirmation: Bool = false,
                              operationTitle: String? = nil) -> Bool
    {
        guard !urls.isEmpty else {
            Self.removeCleanupDirectory(cleanupDirectory)
            return false
        }

        guard let transferTarget = host.transferArchiveMutationTarget(for: target.archive,
                                                                      subdir: target.subdir)
        else {
            Self.removeCleanupDirectory(cleanupDirectory)
            Self.showUnavailableArchiveTransferAlert(operation: operation,
                                                     host: host)
            return false
        }

        return beginArchiveTransfer(urls,
                                    to: transferTarget,
                                    operation: operation,
                                    sourceHost: sourceHost,
                                    host: host,
                                    cleanupDirectory: cleanupDirectory,
                                    parentWindow: parentWindow,
                                    requiresConfirmation: requiresConfirmation,
                                    operationTitle: operationTitle)
    }

    @discardableResult
    func beginArchiveTransfer(_ urls: [URL],
                              to target: FileManagerPaneArchiveTransferTarget,
                              operation: NSDragOperation,
                              sourceHost: (any FileManagerPaneTransferSourceHost)?,
                              host: any FileManagerPaneTransferHost,
                              cleanupDirectory: URL? = nil,
                              parentWindow: NSWindow? = nil,
                              requiresConfirmation: Bool = false,
                              operationTitle: String? = nil) -> Bool
    {
        guard !urls.isEmpty else {
            Self.removeCleanupDirectory(cleanupDirectory)
            return false
        }

        guard FileManagerTransferDestinationValidation.canMoveOrCopyFileSystemItemsToArchive(urls,
                                                                                             archiveURL: target.archiveURL,
                                                                                             operation: operation,
                                                                                             presentingIn: parentWindow ?? host.transferLocation.presentationWindow)
        else {
            Self.removeCleanupDirectory(cleanupDirectory)
            return false
        }

        guard requiresConfirmation else {
            beginDroppedArchiveTransfer(urls,
                                        to: target,
                                        operation: operation,
                                        sourceHost: sourceHost,
                                        host: host,
                                        cleanupDirectory: cleanupDirectory,
                                        operationTitle: operationTitle)
            return true
        }

        guard let window = parentWindow ?? host.transferLocation.presentationWindow else {
            beginDroppedArchiveTransfer(urls,
                                        to: target,
                                        operation: operation,
                                        sourceHost: sourceHost,
                                        host: host,
                                        cleanupDirectory: cleanupDirectory,
                                        operationTitle: operationTitle)
            return true
        }

        let confirmation = FileOperationArchiveTransferConfirmation(sourceURLs: urls,
                                                                    archiveName: target.archiveName,
                                                                    targetSubdir: target.subdir,
                                                                    operation: operation)
        let confirmTitle = operation == .move ? SZL10n.string("toolbar.move") : SZL10n.string("toolbar.add")
        szBeginConfirmation(on: window,
                            title: confirmation.title,
                            message: confirmation.message,
                            confirmTitle: confirmTitle)
        { [weak self, weak host, weak sourceHost] confirmed in
            guard let self,
                  let host
            else {
                Self.removeCleanupDirectory(cleanupDirectory)
                return
            }

            guard confirmed else {
                Self.removeCleanupDirectory(cleanupDirectory)
                return
            }

            beginDroppedArchiveTransfer(urls,
                                        to: target,
                                        operation: operation,
                                        sourceHost: sourceHost,
                                        host: host,
                                        cleanupDirectory: cleanupDirectory,
                                        operationTitle: operationTitle)
        }

        return true
    }

    private func setDropRow(_ row: Int,
                            dropOperation: NSTableView.DropOperation,
                            in tableView: NSTableView)
    {
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }
    }

    private func dropDestinationDirectory(for row: Int,
                                          dropOperation: NSTableView.DropOperation,
                                          host: any FileManagerPaneTransferHost) -> URL?
    {
        guard !host.transferLocation.isVirtualLocation else { return nil }
        return FileOperationDropTargetResolver.fileSystemDestination(currentDirectory: host.transferLocation.currentDirectoryURL,
                                                                     dropOperation: dropOperation,
                                                                     item: host.transferItem(at: row)?.fileSystemItem)
    }

    private func archiveDropMutationTarget(for row: Int,
                                           dropOperation: NSTableView.DropOperation,
                                           host: any FileManagerPaneTransferHost) -> FileManagerPaneArchiveTransferTarget?
    {
        guard let target = host.transferCurrentArchiveMutationTarget() else {
            return nil
        }

        guard let targetSubdir = FileOperationDropTargetResolver.archiveDestinationSubdir(currentSubdir: target.subdir,
                                                                                          dropOperation: dropOperation,
                                                                                          item: host.transferItem(at: row)?.archiveItem)
        else {
            return nil
        }
        return host.transferArchiveMutationTarget(for: target.archive,
                                                  subdir: targetSubdir)
    }

    private func resolvedDropOperation(for info: any NSDraggingInfo,
                                       destinationDirectory: URL) -> NSDragOperation
    {
        FileOperationDropResolver.fileSystemDropOperation(sourceMask: info.draggingSourceOperationMask,
                                                          containsFilePromises: FileOperationDropResolver.containsFilePromises(in: info.draggingPasteboard),
                                                          droppedFileURLs: FileOperationDropResolver.fileURLs(in: info.draggingPasteboard),
                                                          destinationDirectory: destinationDirectory)
    }

    private func takeResolvedDropOperation(for info: any NSDraggingInfo,
                                           destinationDirectory: URL) -> NSDragOperation
    {
        defer { pendingDropOperation = nil }

        if let pendingDropOperation,
           pendingDropOperation.sequenceNumber == info.draggingSequenceNumber
        {
            return pendingDropOperation.operation
        }

        return resolvedDropOperation(for: info,
                                     destinationDirectory: destinationDirectory)
    }

    private func resolvedArchiveDropOperation(for info: any NSDraggingInfo) -> NSDragOperation {
        FileOperationDropResolver.archiveDropOperation(sourceMask: info.draggingSourceOperationMask,
                                                       containsFilePromises: FileOperationDropResolver.containsFilePromises(in: info.draggingPasteboard))
    }

    private func takeResolvedArchiveDropOperation(for info: any NSDraggingInfo) -> NSDragOperation {
        defer { pendingDropOperation = nil }

        if let pendingDropOperation,
           pendingDropOperation.sequenceNumber == info.draggingSequenceNumber
        {
            return pendingDropOperation.operation
        }

        return resolvedArchiveDropOperation(for: info)
    }

    private static func revalidatedArchiveMutationTarget(for target: FileManagerPaneArchiveTransferTarget,
                                                         host: any FileManagerPaneTransferHost) -> FileManagerLeasedArchiveMutationTarget?
    {
        host.transferLeasedArchiveMutationTarget(for: target.archive,
                                                 subdir: target.subdir)
    }

    private func sourceHost(for info: any NSDraggingInfo) -> (any FileManagerPaneTransferSourceHost)? {
        guard let sourceTableView = info.draggingSource as? NSTableView else {
            return nil
        }

        return sourceTableView.delegate as? any FileManagerPaneTransferSourceHost
    }

    private func beginDroppedFileTransfer(_ urls: [URL],
                                          to destinationDirectory: URL,
                                          operation: NSDragOperation,
                                          sourceHost: (any FileManagerPaneTransferSourceHost)?,
                                          host: any FileManagerPaneTransferHost)
    {
        let operationTitle = operation == .move ? SZL10n.string("fileop.moving") : SZL10n.string("fileop.copying")

        Task { @MainActor [weak host, weak sourceHost] in
            guard let host else { return }
            defer {
                host.transferRefresh()
                if operation == .move,
                   let sourceHost,
                   sourceHost.transferIdentity != host.transferIdentity
                {
                    sourceHost.transferRefresh()
                }
            }

            do {
                try await ArchiveOperationRunner.run(operationTitle: operationTitle,
                                                     parentWindow: host.transferLocation.presentationWindow,
                                                     deferredDisplay: true)
                { session in
                    try FileOperationFileSystemTransfer.perform(urls,
                                                                to: destinationDirectory,
                                                                operation: operation,
                                                                session: session)
                }

            } catch {
                host.transferShowError(error)
            }
        }
    }

    private func beginDroppedArchiveTransfer(_ urls: [URL],
                                             to target: FileManagerPaneArchiveTransferTarget,
                                             operation: NSDragOperation,
                                             sourceHost: (any FileManagerPaneTransferSourceHost)?,
                                             host: any FileManagerPaneTransferHost,
                                             cleanupDirectory: URL? = nil,
                                             operationTitle: String? = nil)
    {
        let defaultOperationTitle = operation == .move ? SZL10n.string("fileop.moving") : SZL10n.string("fileop.copying")
        let resolvedOperationTitle = operationTitle ?? defaultOperationTitle

        Task { @MainActor [weak host, weak sourceHost] in
            defer {
                Self.removeCleanupDirectory(cleanupDirectory)
            }

            guard let host else { return }
            guard let currentTarget = Self.revalidatedArchiveMutationTarget(for: target,
                                                                            host: host)
            else {
                host.transferShowReadOnlyArchiveMutationAlert(action: operation == .move ? SZL10n.string("app.fileManager.action.movingFilesIntoArchive") : SZL10n.string("app.fileManager.action.addingFilesToArchive"))
                return
            }

            let selectionPaths = FileOperationArchiveTransferSelection.selectionPaths(for: urls,
                                                                                      targetSubdir: currentTarget.subdir)

            do {
                try await ArchiveOperationRunner.run(operationTitle: resolvedOperationTitle,
                                                     parentWindow: host.transferLocation.presentationWindow,
                                                     deferredDisplay: true)
                { session in
                    try currentTarget.archive.addPaths(urls.map(\.path),
                                                       toArchiveSubdir: currentTarget.subdir,
                                                       moveMode: operation == .move,
                                                       session: session)
                }

                host.transferDidMutateArchive(targetSubdir: currentTarget.subdir,
                                              selectingPaths: selectionPaths)
                if operation == .move,
                   let sourceHost,
                   sourceHost.transferIdentity != host.transferIdentity
                {
                    sourceHost.transferRefresh()
                }
            } catch {
                host.transferShowError(error)
            }
        }
    }

    private func receivePromisedFiles(_ promiseReceivers: [NSFilePromiseReceiver],
                                      at destinationDirectory: URL,
                                      host: any FileManagerPaneTransferHost)
    {
        FileOperationPromisedFileReceiver.receive(promiseReceivers,
                                                  at: destinationDirectory)
        { [weak host] reception in
            host?.transferRefresh()
            if let error = reception.firstError {
                host?.transferShowError(error)
            }
        }
    }

    private func receivePromisedFiles(_ promiseReceivers: [NSFilePromiseReceiver],
                                      intoArchive target: FileManagerPaneArchiveTransferTarget,
                                      sourceHost: (any FileManagerPaneTransferSourceHost)?,
                                      host: any FileManagerPaneTransferHost)
    {
        let stagingDirectory: URL
        do {
            stagingDirectory = try FileManagerTemporaryDirectorySupport.makeTemporaryDirectory(prefix: FileManagerTemporaryDirectorySupport.stagingPrefix)
        } catch {
            host.transferShowError(error)
            return
        }

        FileOperationPromisedFileReceiver.receive(promiseReceivers,
                                                  at: stagingDirectory)
        { [weak self, weak host, weak sourceHost] reception in
            guard let self,
                  let host
            else {
                Self.removeCleanupDirectory(stagingDirectory)
                return
            }

            if let firstError = reception.firstError {
                Self.removeCleanupDirectory(stagingDirectory)
                host.transferShowError(firstError)
                return
            }

            guard !reception.fileURLs.isEmpty else {
                Self.removeCleanupDirectory(stagingDirectory)
                return
            }

            beginArchiveTransfer(reception.fileURLs,
                                 to: target,
                                 operation: .copy,
                                 sourceHost: sourceHost,
                                 host: host,
                                 cleanupDirectory: stagingDirectory,
                                 requiresConfirmation: true)
        }
    }

    private static func removeCleanupDirectory(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func showUnavailableArchiveTransferAlert(operation: NSDragOperation,
                                                            host: any FileManagerPaneTransferHost)
    {
        host.transferShowReadOnlyArchiveMutationAlert(action: operation == .move
            ? SZL10n.string("app.fileManager.action.movingFilesIntoArchive")
            : SZL10n.string("app.fileManager.action.addingFilesToArchive"))
    }
}

enum FileOperationFileSystemTransfer {
    static func perform(_ urls: [URL],
                        to destinationDirectory: URL,
                        operation: NSDragOperation,
                        session: SZOperationSession) throws
    {
        let standardizedURLs = urls.map(\.standardizedFileURL)
        let standardizedDestinationDirectory = destinationDirectory.standardizedFileURL
        let fileManager = FileManager.default
        let transferEngine = FileSystemTransferEngine(fileManager: fileManager)
        var skipAll = false
        var overwriteAll = false

        for (index, sourceURL) in standardizedURLs.enumerated() {
            if session.shouldCancel() {
                return
            }

            let destinationFileURL = standardizedDestinationDirectory
                .appendingPathComponent(sourceURL.lastPathComponent)
                .standardizedFileURL

            if sourceURL == destinationFileURL {
                continue
            }

            let fraction = Double(index) / Double(standardizedURLs.count)
            session.reportProgressFraction(fraction)
            session.reportCurrentFileName(sourceURL.lastPathComponent)

            let outcome = try transferEngine.transfer(
                from: sourceURL,
                to: destinationFileURL,
                operation: operation == .move ? .move : .copy,
                session: session,
            ) { conflictingSourceURL, conflictingDestinationURL in
                if skipAll {
                    return .skip
                }
                if !overwriteAll {
                    let choice = session.requestChoice(with: .warning,
                                                       title: SZL10n.string("replace.confirmTitle"),
                                                       message: overwritePromptMessage(sourceURL: conflictingSourceURL,
                                                                                       destinationURL: conflictingDestinationURL,
                                                                                       fileManager: fileManager),
                                                       buttonTitles: [SZL10n.string("common.yes"),
                                                                      SZL10n.string("common.yesToAll"),
                                                                      SZL10n.string("common.no"),
                                                                      SZL10n.string("common.noToAll"),
                                                                      SZL10n.string("common.cancel")])
                    switch choice {
                    case 0:
                        return .overwrite
                    case 1:
                        overwriteAll = true
                        return .overwrite
                    case 2:
                        return .skip
                    case 3:
                        skipAll = true
                        return .skip
                    default:
                        return .cancel
                    }
                }
                return .overwrite
            }
            if outcome == .cancelled {
                return
            }
        }

        session.reportProgressFraction(1.0)
    }

    private static func overwritePromptMessage(sourceURL: URL,
                                               destinationURL: URL,
                                               fileManager: FileManager) -> String
    {
        let sourceAttributes = try? fileManager.attributesOfItem(atPath: sourceURL.path)
        let destinationAttributes = try? fileManager.attributesOfItem(atPath: destinationURL.path)
        let sourceSize = (sourceAttributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let destinationSize = (destinationAttributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let sourceDate = sourceAttributes?[.modificationDate] as? Date
        let destinationDate = destinationAttributes?[.modificationDate] as? Date
        let dateFormatter = FileManagerViewPreferences.makeDateFormatter(dateStyle: .medium,
                                                                         timeStyle: .medium)
        let modifiedTitle = SZL10n.string("column.modified")
        let destinationDescription = replacementFileDescription(fileName: destinationURL.lastPathComponent,
                                                                size: destinationSize,
                                                                modifiedDate: destinationDate,
                                                                modifiedTitle: modifiedTitle,
                                                                dateFormatter: dateFormatter)
        let sourceDescription = replacementFileDescription(fileName: sourceURL.lastPathComponent,
                                                           size: sourceSize,
                                                           modifiedDate: sourceDate,
                                                           modifiedTitle: modifiedTitle,
                                                           dateFormatter: dateFormatter)

        return """
        \(SZL10n.string("replace.alreadyContains"))

        \(SZL10n.string("replace.wouldYouLike"))
        \(destinationDescription)

        \(SZL10n.string("replace.withThisOne"))
        \(sourceDescription)
        """
    }

    private static func replacementFileDescription(fileName: String,
                                                   size: UInt64,
                                                   modifiedDate: Date?,
                                                   modifiedTitle: String,
                                                   dateFormatter: DateFormatter) -> String
    {
        let bytesText = SZL10n.string("replace.bytes")
            .replacingOccurrences(of: "{0}", with: NumberFormatter.localizedString(from: NSNumber(value: size), number: .decimal))
        let modifiedText = modifiedDate.map { dateFormatter.string(from: $0) } ?? "—"

        return """
        \(fileName)
        \(bytesText)  \(modifiedTitle): \(modifiedText)
        """
    }
}

@MainActor
enum FileOperationArchiveDestinationTransfer {
    static func perform(_ sourceURLs: [URL],
                        from sourcePane: FileManagerPaneController,
                        toArchiveURL archiveURL: URL,
                        subdir: String,
                        move: Bool,
                        candidatePanes: [FileManagerPaneController],
                        parentWindow: NSWindow?,
                        showError: @escaping @MainActor (Error) -> Void)
    {
        let operation: NSDragOperation = move ? .move : .copy

        if let (pane, target) = archiveDestinationTarget(in: candidatePanes,
                                                         archiveURL: archiveURL,
                                                         subdir: subdir)
        {
            pane.beginArchiveTransfer(sourceURLs,
                                      to: target,
                                      operation: operation,
                                      sourcePane: sourcePane,
                                      parentWindow: parentWindow,
                                      requiresConfirmation: false)
            return
        }

        let operationTitle = SZL10n.string(move ? "fileop.moving" : "fileop.copying")
        let selectionPaths = FileOperationArchiveTransferSelection.selectionPaths(for: sourceURLs,
                                                                                  targetSubdir: subdir)

        Task { @MainActor [weak sourcePane, weak parentWindow] in
            guard let parentWindow else { return }
            do {
                try await ArchiveOperationRunner.run(operationTitle: operationTitle,
                                                     parentWindow: parentWindow)
                { session in
                    let archive = SZArchive()
                    try archive.open(atPath: archiveURL.path, session: session)
                    defer { archive.close() }
                    try archive.addPaths(sourceURLs.map(\.path),
                                         toArchiveSubdir: subdir,
                                         moveMode: move,
                                         session: session)
                }

                FileManagerArchiveChangeBus.publish(
                    FileManagerArchiveChange(archiveURL: archiveURL,
                                             targetSubdir: subdir,
                                             selectingPaths: selectionPaths),
                )
                if move {
                    sourcePane?.refresh()
                }
            } catch {
                showError(error)
            }
        }
    }

    private static func archiveDestinationTarget(in panes: [FileManagerPaneController],
                                                 archiveURL: URL,
                                                 subdir: String) -> (pane: FileManagerPaneController, target: (archive: SZArchive, subdir: String))?
    {
        for pane in panes {
            if let target = pane.currentArchiveMutationTarget(for: archiveURL, subdir: subdir) {
                return (pane, target)
            }
        }

        return nil
    }
}

@MainActor
final class FileOperationDestinationPrompt {
    private var destinationPicker: FileOperationDestinationPicker?
    private let move: Bool
    private let sourcePane: FileManagerPaneController
    private let defaultPath: String
    private let infoText: String
    private let validateDestination: (FileOperationDestinationTarget) -> Bool

    init(move: Bool,
         sourcePane: FileManagerPaneController,
         defaultPath: String,
         infoText: String,
         validateDestination: @escaping (FileOperationDestinationTarget) -> Bool)
    {
        self.move = move
        self.sourcePane = sourcePane
        self.defaultPath = defaultPath
        self.infoText = infoText
        self.validateDestination = validateDestination
    }

    func run(for parentWindow: NSWindow?) async -> FileOperationDestinationTarget? {
        let title = move ? SZL10n.string("toolbar.move") : SZL10n.string("toolbar.copy")
        let actionTitle = move ? SZL10n.string("toolbar.move") : SZL10n.string("toolbar.copy")
        let labelTitle = move ? SZL10n.string("fileop.moveTo") : SZL10n.string("fileop.copyTo")
        let historyEntries = FileOperationDestinationHistory.entries()
        let sourcePane = sourcePane
        let validateDestination = validateDestination
        var resolvedDestinationTarget: FileOperationDestinationTarget?

        let pathField = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        pathField.isEditable = true
        pathField.usesDataSource = false
        pathField.completes = false
        pathField.addItems(withObjectValues: historyEntries)
        pathField.stringValue = defaultPath
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.setAccessibilityIdentifier("fileOperation.destinationPath")

        let browseButton = NSButton(title: SZL10n.string("compress.browse"), target: nil, action: nil)
        browseButton.bezelStyle = .rounded
        browseButton.setContentHuggingPriority(.required, for: .horizontal)
        browseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        browseButton.setAccessibilityIdentifier("fileOperation.browseButton")

        let label = NSTextField(labelWithString: labelTitle)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.setContentHuggingPriority(.required, for: .vertical)

        let inputRow = NSStackView(views: [pathField, browseButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 8
        inputRow.distribution = .fill

        let stack = NSStackView(views: [label, inputRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let controller = SZModalDialogController(style: .informational,
                                                 title: title,
                                                 message: infoText,
                                                 buttonTitles: [SZL10n.string("common.cancel"), actionTitle],
                                                 accessoryView: stack,
                                                 preferredFirstResponder: pathField,
                                                 cancelButtonIndex: 0)

        let windowBoundPicker = FileOperationDestinationPicker(ownerWindow: controller.window,
                                                               pathField: pathField,
                                                               baseDirectory: sourcePane.currentDirectoryURL)
        destinationPicker = windowBoundPicker
        browseButton.target = windowBoundPicker
        browseButton.action = #selector(FileOperationDestinationPicker.browse(_:))

        controller.shouldFinishHandler = { buttonIndex in
            guard buttonIndex == 1 else {
                return true
            }

            let enteredPath = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                let destinationTarget = try FileOperationDestinationResolver.resolveTarget(from: enteredPath,
                                                                                           relativeTo: sourcePane.currentDirectoryURL,
                                                                                           createDirectoryIfNeeded: false)
                guard validateDestination(destinationTarget) else {
                    return false
                }
                resolvedDestinationTarget = destinationTarget
                return true
            } catch {
                szPresentError(error, for: controller.window)
                return false
            }
        }

        defer {
            controller.shouldFinishHandler = nil
            destinationPicker = nil
        }

        guard await controller.modalResult(for: parentWindow) == 1,
              let destinationTarget = resolvedDestinationTarget
        else {
            return nil
        }

        FileOperationDestinationHistory.record(destinationTarget.displayPath)
        return destinationTarget
    }
}
