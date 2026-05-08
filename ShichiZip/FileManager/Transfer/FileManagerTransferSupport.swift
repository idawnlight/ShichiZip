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

        if let ownerWindow {
            panel.beginSheetModal(for: ownerWindow) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.pathField?.stringValue = szNormalizedDestinationDisplayPath(url.standardizedFileURL.path)
            }
            return
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathField?.stringValue = szNormalizedDestinationDisplayPath(url.standardizedFileURL.path)
    }

    private func suggestedDirectoryURL() -> URL {
        guard let pathField else {
            return baseDirectory
        }

        let currentValue = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentValue.isEmpty else {
            return baseDirectory
        }

        let expandedPath = NSString(string: currentValue).expandingTildeInPath
        let candidateURL = if NSString(string: expandedPath).isAbsolutePath {
            URL(fileURLWithPath: expandedPath)
        } else {
            URL(fileURLWithPath: expandedPath, relativeTo: baseDirectory)
        }

        var probeURL = candidateURL.standardizedFileURL

        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: probeURL.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? probeURL : probeURL.deletingLastPathComponent()
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
        .standard
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

        let expandedPath = NSString(string: enteredPath).expandingTildeInPath
        let candidateURL = if NSString(string: expandedPath).isAbsolutePath {
            URL(fileURLWithPath: expandedPath)
        } else {
            URL(fileURLWithPath: expandedPath, relativeTo: baseDirectory)
        }

        let standardizedURL = candidateURL.standardizedFileURL

        if let archiveTarget = try resolveArchiveTarget(from: standardizedURL) {
            return archiveTarget
        }

        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
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
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
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
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: prefixPath, isDirectory: &isDirectory) else {
                continue
            }

            guard !isDirectory.boolValue else {
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

enum FileOperationFileSystemTransfer {
    static func perform(_ urls: [URL],
                        to destinationDirectory: URL,
                        operation: NSDragOperation,
                        session: SZOperationSession) throws
    {
        let standardizedURLs = urls.map(\.standardizedFileURL)
        let standardizedDestinationDirectory = destinationDirectory.standardizedFileURL
        let fileManager = FileManager.default
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

            if fileManager.fileExists(atPath: destinationFileURL.path) {
                if skipAll { continue }
                if !overwriteAll {
                    let choice = session.requestChoice(with: .warning,
                                                       title: SZL10n.string("replace.confirmTitle"),
                                                       message: overwritePromptMessage(sourceURL: sourceURL,
                                                                                       destinationURL: destinationFileURL,
                                                                                       fileManager: fileManager),
                                                       buttonTitles: [SZL10n.string("common.yes"),
                                                                      SZL10n.string("common.yesToAll"),
                                                                      SZL10n.string("common.no"),
                                                                      SZL10n.string("common.noToAll"),
                                                                      SZL10n.string("common.cancel")])
                    switch choice {
                    case 0:
                        break
                    case 1:
                        overwriteAll = true
                    case 2:
                        continue
                    case 3:
                        skipAll = true
                        continue
                    default:
                        return
                    }
                }

                try fileManager.removeItem(at: destinationFileURL)
            }

            if operation == .move {
                try moveItemPreservingMetadata(from: sourceURL, to: destinationFileURL)
            } else {
                try copyItemPreservingMetadata(from: sourceURL, to: destinationFileURL)
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

    private static func moveItemPreservingMetadata(from sourceURL: URL,
                                                   to destinationURL: URL) throws
    {
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return
        } catch {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                throw error
            }
        }

        try copyItemPreservingMetadata(from: sourceURL, to: destinationURL)
        try FileManager.default.removeItem(at: sourceURL)
    }

    private static func copyItemPreservingMetadata(from sourceURL: URL,
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

        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
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

                FileManagerArchiveChangeCoordinator.publish(
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

    func run() -> FileOperationDestinationTarget? {
        let title = move ? SZL10n.string("toolbar.move") : SZL10n.string("toolbar.copy")
        let actionTitle = move ? SZL10n.string("toolbar.move") : SZL10n.string("toolbar.copy")
        let labelTitle = move ? SZL10n.string("fileop.moveTo") : SZL10n.string("fileop.copyTo")
        let historyEntries = FileOperationDestinationHistory.entries()

        while true {
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

            defer {
                destinationPicker = nil
            }

            guard controller.runModal() == 1 else {
                return nil
            }

            let enteredPath = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                let destinationTarget = try FileOperationDestinationResolver.resolveTarget(from: enteredPath,
                                                                                           relativeTo: sourcePane.currentDirectoryURL,
                                                                                           createDirectoryIfNeeded: false)
                guard validateDestination(destinationTarget) else {
                    continue
                }
                FileOperationDestinationHistory.record(destinationTarget.displayPath)
                return destinationTarget
            } catch {
                // This prompt reopens in a retry loop, so avoid stacking the error beneath it.
                szPresentError(error, for: nil)
            }
        }
    }
}
