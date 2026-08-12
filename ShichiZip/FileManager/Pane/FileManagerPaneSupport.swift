import Cocoa
import UniformTypeIdentifiers

enum FileManagerPaneItem {
    case parent
    case filesystem(FileSystemItem)
    case archive(ArchiveItem)

    var fileSystemItem: FileSystemItem? {
        guard case let .filesystem(item) = self else { return nil }
        return item
    }

    var archiveItem: ArchiveItem? {
        guard case let .archive(item) = self else { return nil }
        return item
    }
}

struct FileManagerPaneTableModel {
    private enum Content {
        case fileSystem([FileSystemItem])
        case archive([ArchiveItem])

        var count: Int {
            switch self {
            case let .fileSystem(items):
                items.count
            case let .archive(items):
                items.count
            }
        }

        func item(at index: Int) -> FileManagerPaneItem? {
            switch self {
            case let .fileSystem(items):
                guard index >= 0, index < items.count else { return nil }
                return .filesystem(items[index])
            case let .archive(items):
                guard index >= 0, index < items.count else { return nil }
                return .archive(items[index])
            }
        }

        var displayedArchiveItems: [ArchiveItem] {
            guard case let .archive(items) = self else { return [] }
            return items
        }
    }

    private let content: Content
    private let showsParentRow: Bool

    init(fileSystemItems: [FileSystemItem],
         showsParentRow: Bool)
    {
        content = .fileSystem(fileSystemItems)
        self.showsParentRow = showsParentRow
    }

    init(archiveItems: [ArchiveItem],
         showsParentRow: Bool)
    {
        content = .archive(archiveItems)
        self.showsParentRow = showsParentRow
    }

    var rowCount: Int {
        content.count + (showsParentRow ? 1 : 0)
    }

    func item(at row: Int) -> FileManagerPaneItem? {
        if showsParentRow, row == 0 {
            return .parent
        }

        let itemRow = row - (showsParentRow ? 1 : 0)
        return content.item(at: itemRow)
    }

    func selectedItems(in selectedRowIndexes: IndexSet) -> [FileManagerPaneItem] {
        selectedRowIndexes.compactMap { item(at: $0) }
    }

    func selectedRowsAndItems(in selectedRowIndexes: IndexSet,
                              excludingParent: Bool = false) -> [(row: Int, item: FileManagerPaneItem)]
    {
        selectedRowIndexes.compactMap { row in
            guard let item = item(at: row) else { return nil }
            if excludingParent, case .parent = item {
                return nil
            }
            return (row, item)
        }
    }

    func selectedRealItems(in selectedRowIndexes: IndexSet) -> [FileManagerPaneItem] {
        selectedItems(in: selectedRowIndexes).filter { item in
            if case .parent = item {
                return false
            }
            return true
        }
    }

    func selectedSingleRealItem(in selectedRowIndexes: IndexSet) -> FileManagerPaneItem? {
        let items = selectedRealItems(in: selectedRowIndexes)
        guard items.count == 1 else { return nil }
        return items[0]
    }

    func selectedFileSystemItems(in selectedRowIndexes: IndexSet) -> [FileSystemItem] {
        selectedItems(in: selectedRowIndexes).compactMap(\.fileSystemItem)
    }

    func selectedArchiveItems(in selectedRowIndexes: IndexSet) -> [ArchiveItem] {
        selectedItems(in: selectedRowIndexes).compactMap(\.archiveItem)
    }

    func paneItemsForSelectionOrDisplayedArchiveItems(in selectedRowIndexes: IndexSet) -> [FileManagerPaneItem] {
        let selectedItems = selectedRealItems(in: selectedRowIndexes)
        if !selectedItems.isEmpty {
            return selectedItems
        }
        return content.displayedArchiveItems.map(FileManagerPaneItem.archive)
    }

    func archiveItemsForSelectionOrDisplayedItems(in selectedRowIndexes: IndexSet) -> [ArchiveItem] {
        let selectedItems = selectedArchiveItems(in: selectedRowIndexes)
        return selectedItems.isEmpty ? content.displayedArchiveItems : selectedItems
    }
}

struct FileManagerPaneSelectionState {
    let tableModel: FileManagerPaneTableModel
    let selectedRowIndexes: IndexSet

    var items: [FileManagerPaneItem] {
        tableModel.selectedItems(in: selectedRowIndexes)
    }

    var realItems: [FileManagerPaneItem] {
        tableModel.selectedRealItems(in: selectedRowIndexes)
    }

    var singleRealItem: FileManagerPaneItem? {
        tableModel.selectedSingleRealItem(in: selectedRowIndexes)
    }

    var fileSystemItems: [FileSystemItem] {
        tableModel.selectedFileSystemItems(in: selectedRowIndexes)
    }

    var singleFileSystemFile: FileSystemItem? {
        let items = fileSystemItems
        guard items.count == 1, !items[0].isDirectory else { return nil }
        return items[0]
    }

    var archiveItems: [ArchiveItem] {
        tableModel.selectedArchiveItems(in: selectedRowIndexes)
    }

    var paneItemsForSelectionOrDisplayedItems: [FileManagerPaneItem] {
        tableModel.paneItemsForSelectionOrDisplayedArchiveItems(in: selectedRowIndexes)
    }

    var archiveItemsForSelectionOrDisplayedItems: [ArchiveItem] {
        tableModel.archiveItemsForSelectionOrDisplayedItems(in: selectedRowIndexes)
    }

    var archiveCandidateURL: URL? {
        guard fileSystemItems.count == 1,
              let item = fileSystemItems.first,
              !item.isDirectory
        else {
            return nil
        }

        return item.url
    }

    var filePaths: [String] {
        fileSystemItems.map(\.url.path)
    }

    var fileURLs: [URL] {
        fileSystemItems.map(\.url.standardizedFileURL)
    }

    func rowsAndItems(excludingParent: Bool = false) -> [(row: Int, item: FileManagerPaneItem)] {
        tableModel.selectedRowsAndItems(in: selectedRowIndexes,
                                        excludingParent: excludingParent)
    }
}

@MainActor
struct FileManagerPaneRoutingContext {
    let leftPane: FileManagerPaneController
    let rightPane: FileManagerPaneController
    let isDualPane: Bool
    let trackedActivePane: FileManagerPaneController?
    let firstResponderView: NSView?

    var activePane: FileManagerPaneController {
        if !isDualPane {
            return leftPane
        }

        if let firstResponderPane {
            return firstResponderPane
        }

        if let trackedActivePane {
            return trackedActivePane
        }

        return leftPane
    }

    var inactivePane: FileManagerPaneController? {
        guard isDualPane else { return nil }
        return activePane === leftPane ? rightPane : leftPane
    }

    func normalizedTrackedPane(for pane: FileManagerPaneController) -> FileManagerPaneController {
        pane === rightPane ? rightPane : leftPane
    }

    func targetPaneForRevealingFileSystemItems(_ standardizedURLs: [URL]) -> FileManagerPaneController {
        guard let firstURL = standardizedURLs.first else {
            return activePane
        }

        let parentDirectory = firstURL.deletingLastPathComponent().standardizedFileURL
        return paneDisplayingDirectory(parentDirectory) ?? activePane
    }

    func targetPaneForOpeningFileSystemItem(_ standardizedURL: URL,
                                            isDirectory: Bool) -> FileManagerPaneController
    {
        let displayedDirectory = isDirectory
            ? standardizedURL
            : standardizedURL.deletingLastPathComponent().standardizedFileURL

        return paneDisplayingDirectory(displayedDirectory) ?? activePane
    }

    func refreshPaneDisplayingDirectory(_ directoryURL: URL) {
        let standardizedDirectory = directoryURL.standardizedFileURL

        if !leftPane.isVirtualLocation,
           leftPane.currentDirectoryURL.standardizedFileURL == standardizedDirectory
        {
            leftPane.refresh()
        }

        if isDualPane,
           !rightPane.isVirtualLocation,
           rightPane.currentDirectoryURL.standardizedFileURL == standardizedDirectory
        {
            rightPane.refresh()
        }
    }

    private var firstResponderPane: FileManagerPaneController? {
        guard isDualPane,
              let firstResponderView
        else {
            return nil
        }

        if firstResponderView === rightPane.view || firstResponderView.isDescendant(of: rightPane.view) {
            return rightPane
        }

        if firstResponderView === leftPane.view || firstResponderView.isDescendant(of: leftPane.view) {
            return leftPane
        }

        return nil
    }

    private func paneDisplayingDirectory(_ directoryURL: URL) -> FileManagerPaneController? {
        let standardizedDirectory = directoryURL.standardizedFileURL

        if !leftPane.isVirtualLocation,
           leftPane.currentDirectoryURL.standardizedFileURL == standardizedDirectory
        {
            return leftPane
        }

        if isDualPane,
           !rightPane.isVirtualLocation,
           rightPane.currentDirectoryURL.standardizedFileURL == standardizedDirectory
        {
            return rightPane
        }

        return nil
    }
}

enum FileManagerPaneIconSource {
    case parent
    case archive(isDirectory: Bool, iconPath: String)
    case filesystem(isDirectory: Bool, iconPath: String)
}

@MainActor
final class FileManagerPaneIconProvider {
    let iconSize: NSSize
    private let iconCache = NSCache<NSString, NSImage>()

    init(iconSize: NSSize) {
        self.iconSize = iconSize
    }

    func removeAllCachedImages() {
        iconCache.removeAllObjects()
    }

    func image(for source: FileManagerPaneIconSource,
               showsRealFileIcons: Bool) -> NSImage?
    {
        switch source {
        case .parent:
            return cachedIcon(forKey: "parent") {
                let image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: SZL10n.string("view.upOneLevel"))
                image?.isTemplate = true
                return image
            }

        case let .archive(isDirectory, iconPath):
            guard showsRealFileIcons else {
                return cachedIcon(forKey: isDirectory ? "template:archive:folder" : "template:archive:file") {
                    NSImage(systemSymbolName: isDirectory ? "folder.fill" : "doc.fill",
                            accessibilityDescription: SZL10n.string(isDirectory ? "column.folder" : "menu.file"))
                }
            }

            if isDirectory {
                return cachedIcon(forKey: "real:archive:folder") {
                    NSImage(systemSymbolName: "folder.fill", accessibilityDescription: SZL10n.string("column.folder"))
                }
            }

            let fileExtension = (iconPath as NSString).pathExtension
            if let type = UTType(filenameExtension: fileExtension) {
                return cachedIcon(forKey: "real:archive:type:\(fileExtension.lowercased())") {
                    NSWorkspace.shared.icon(for: type)
                }
            }
            return cachedIcon(forKey: "real:archive:data") {
                NSWorkspace.shared.icon(for: .data)
            }

        case let .filesystem(isDirectory, iconPath):
            guard showsRealFileIcons else {
                return cachedIcon(forKey: isDirectory ? "template:filesystem:folder" : "template:filesystem:file") {
                    NSImage(systemSymbolName: isDirectory ? "folder.fill" : "doc.fill",
                            accessibilityDescription: SZL10n.string(isDirectory ? "column.folder" : "menu.file"))
                }
            }
            return cachedIcon(forKey: "real:filesystem:\(iconPath)") {
                NSWorkspace.shared.icon(forFile: iconPath)
            }
        }
    }

    func transitionImage(for source: FileManagerPaneIconSource,
                         accessibilityDescription: String?,
                         showsRealFileIcons: Bool) -> NSImage?
    {
        guard let image = image(for: source,
                                showsRealFileIcons: showsRealFileIcons)?.copy() as? NSImage
        else {
            return nil
        }

        image.size = iconSize
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private func cachedIcon(forKey key: String, builder: () -> NSImage?) -> NSImage? {
        if let cachedImage = iconCache.object(forKey: key as NSString) {
            return cachedImage
        }

        guard let rawImage = builder() else {
            return nil
        }

        let image = (rawImage.copy() as? NSImage) ?? rawImage
        image.size = iconSize
        iconCache.setObject(image, forKey: key as NSString)
        return image
    }
}

/// File-promise completion callbacks cross AppKit and archive worker queues; the handler is invoked exactly once per promise write.
private final class ArchiveDragPromiseCompletionHandler: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func finish(_ error: Error?) {
        handler(error)
    }
}

final class ArchiveDragPromise: NSObject, NSFilePromiseProviderDelegate {
    private let item: ArchiveItem
    private let context: FileManagerArchiveItemWorkflowContext
    private let operationGate: FileManagerArchiveOperationGate
    private let workflowService: FileManagerArchiveItemWorkflowService
    private weak var parentWindow: NSWindow?
    private let promiseQueue: OperationQueue

    init(item: ArchiveItem,
         context: FileManagerArchiveItemWorkflowContext,
         operationGate: FileManagerArchiveOperationGate,
         workflowService: FileManagerArchiveItemWorkflowService,
         parentWindow: NSWindow?)
    {
        self.item = item
        self.context = context
        self.operationGate = operationGate
        self.workflowService = workflowService
        self.parentWindow = parentWindow

        let queue = OperationQueue()
        queue.name = "shichizip.archive-drag-promise"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        promiseQueue = queue
    }

    static func fileType(for item: ArchiveItem) -> String {
        if item.isDirectory {
            return UTType.folder.identifier
        }

        guard !item.fileExtension.isEmpty,
              let fileType = UTType(filenameExtension: item.fileExtension)
        else {
            return UTType.data.identifier
        }
        return fileType.identifier
    }

    nonisolated func filePromiseProvider(_: NSFilePromiseProvider,
                                         fileNameForType _: String) -> String
    {
        item.name
    }

    func filePromiseProvider(_: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void)
    {
        let completion = ArchiveDragPromiseCompletionHandler(completionHandler)
        writePromiseAsync(to: url,
                          completionHandler: completion)
    }

    nonisolated func operationQueue(for _: NSFilePromiseProvider) -> OperationQueue {
        promiseQueue
    }

    private func writePromiseAsync(to url: URL,
                                   completionHandler: ArchiveDragPromiseCompletionHandler)
    {
        // File promise writes are expected to complete asynchronously. Blocking this
        // callback while the destination resolves the promised file can deadlock drag-out.
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                // Acquire the lease now, not at drag-start. The pasteboard retains
                // this promise long after the drag ends; holding a lease from creation
                // would block archive close indefinitely.
                guard let lease = self.operationGate.acquireLease() else {
                    completionHandler.finish(CocoaError(.fileWriteUnknown))
                    szPresentError(CocoaError(.fileWriteUnknown), for: self.parentWindow)
                    return
                }

                Task { @MainActor [self] in
                    do {
                        try await ArchiveOperationRunner.run(
                            operationTitle: SZL10n.string("progress.extracting"),
                            initialFileName: item.path,
                            parentWindow: parentWindow,
                            deferredDisplay: true,
                        ) { session in
                            try self.workflowService.writePromise(for: self.item,
                                                                  context: self.context,
                                                                  to: url,
                                                                  session: session)
                        }
                        withExtendedLifetime(lease) {}
                        completionHandler.finish(nil)
                    } catch {
                        withExtendedLifetime(lease) {}
                        completionHandler.finish(error)
                        szPresentError(error, for: parentWindow)
                    }
                }
            }
        }
    }
}

/// `NSFilePromiseProviderDelegate` callbacks may arrive off-main; promise writes hop back through the main actor and archive gate.
extension ArchiveDragPromise: @unchecked Sendable {}

final class FileManagerTableView: NSTableView {
    var contextMenuPreparationHandler: ((Int) -> Void)?
    var quickLookPreviewHandler: (() -> Void)?
    var shortcutEventHandler: ((NSEvent) -> Bool)?
    private var deepClickTriggered = false

    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        let clickedColumn = column(at: mouseDownPoint)
        guard clickedColumn >= 0,
              tableColumns[clickedColumn].identifier.rawValue == "name"
        else {
            return false
        }

        let clickedRow = row(at: mouseDownPoint)
        guard clickedRow >= 0, rowIndexes.contains(clickedRow) else {
            return false
        }

        return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        contextMenuPreparationHandler?(row(at: point))
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        if shortcutEventHandler?(event) == true {
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if shortcutEventHandler?(event) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func pressureChange(with event: NSEvent) {
        if event.stage < 2 {
            deepClickTriggered = false
        } else if !deepClickTriggered {
            deepClickTriggered = true
            let point = convert(event.locationInWindow, from: nil)
            let clickedRow = row(at: point)
            if clickedRow >= 0 {
                if !selectedRowIndexes.contains(clickedRow) {
                    selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
                }
                quickLookPreviewHandler?()
            }
        }

        super.pressureChange(with: event)
    }
}
