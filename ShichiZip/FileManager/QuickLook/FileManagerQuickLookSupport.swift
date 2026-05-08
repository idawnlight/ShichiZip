import Cocoa
@preconcurrency import QuickLookUI

struct FileManagerQuickLookPreparedItem {
    let url: URL
    let title: String?
    let sourceFrameOnScreen: NSRect
    let transitionImage: NSImage?
    let transitionContentRect: NSRect
}

struct FileManagerQuickLookPreparedPreview {
    let items: [FileManagerQuickLookPreparedItem]
    let temporaryDirectories: [URL]
}

struct FileManagerQuickLookItemSource {
    let frameOnScreen: NSRect
    let transitionImage: NSImage?
    let transitionContentRect: NSRect

    init(frameOnScreen: NSRect,
         transitionImage: NSImage?)
    {
        self.frameOnScreen = frameOnScreen
        self.transitionImage = transitionImage
        transitionContentRect = transitionImage.map { NSRect(origin: .zero, size: $0.size) } ?? .zero
    }
}

struct FileManagerQuickLookFileSystemSelection {
    let item: FileSystemItem
    let source: FileManagerQuickLookItemSource
}

struct FileManagerQuickLookArchiveSelection {
    let item: ArchiveItem
    let source: FileManagerQuickLookItemSource
}

enum FileManagerQuickLookSourceGeometry {
    static func frameOnScreen(forRow row: Int,
                              in tableView: NSTableView,
                              window: NSWindow?,
                              iconSize: NSSize,
                              columnIdentifier: NSUserInterfaceItemIdentifier = NSUserInterfaceItemIdentifier("name")) -> NSRect
    {
        let column = tableView.column(withIdentifier: columnIdentifier)
        guard column >= 0,
              let window
        else {
            return .zero
        }

        if let cellView = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView,
           let imageView = cellView.imageView
        {
            let rectInWindow = imageView.convert(imageView.bounds, to: nil)
            return window.convertToScreen(rectInWindow)
        }

        let cellRect = tableView.frameOfCell(atColumn: column, row: row)
        let iconRect = NSRect(x: cellRect.minX + 4,
                              y: cellRect.midY - (iconSize.height / 2),
                              width: iconSize.width,
                              height: iconSize.height)
        let rectInWindow = tableView.convert(iconRect, to: nil)
        return window.convertToScreen(rectInWindow)
    }
}

enum FileManagerQuickLookPreparation {
    static func fileSystemPreview(for selection: [FileManagerQuickLookFileSystemSelection]) throws -> FileManagerQuickLookPreparedPreview {
        let previewItems = selection.map { selection in
            FileManagerQuickLookPreparedItem(url: selection.item.url.standardizedFileURL,
                                             title: selection.item.name,
                                             sourceFrameOnScreen: selection.source.frameOnScreen,
                                             transitionImage: selection.source.transitionImage,
                                             transitionContentRect: selection.source.transitionContentRect)
        }

        guard !previewItems.isEmpty else {
            throw error(SZL10n.string("app.fileManager.quickLook.cannotPreview"))
        }

        return FileManagerQuickLookPreparedPreview(items: previewItems,
                                                   temporaryDirectories: [])
    }

    static func archivePreviewItems(for selection: [FileManagerQuickLookArchiveSelection],
                                    stagedFileURLs: [URL]) -> [FileManagerQuickLookPreparedItem]
    {
        zip(selection, stagedFileURLs).map { selection, url in
            FileManagerQuickLookPreparedItem(url: url,
                                             title: selection.item.name,
                                             sourceFrameOnScreen: selection.source.frameOnScreen,
                                             transitionImage: selection.source.transitionImage,
                                             transitionContentRect: selection.source.transitionContentRect)
        }
    }

    static func archivePhysicalSize(reportedSize: UInt64,
                                    archivePath: String,
                                    fileManager: FileManager = .default) -> UInt64
    {
        if reportedSize > 0 {
            return reportedSize
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: archivePath),
           let size = attributes[.size] as? NSNumber
        {
            return size.uint64Value
        }

        return 0
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain,
                code: CocoaError.fileReadUnknown.rawValue,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func validateArchiveItems(_ archiveItems: [ArchiveItem],
                                     archiveHasActiveOperations: Bool,
                                     isSolidArchive: Bool,
                                     archiveSizeProvider: () -> UInt64,
                                     maxArchiveItemSize: UInt64,
                                     maxArchiveCombinedSize: UInt64,
                                     maxSolidArchiveSize: UInt64) throws
    {
        guard !archiveItems.isEmpty else {
            throw error(SZL10n.string("app.fileManager.quickLook.selectArchiveFiles"))
        }

        if archiveItems.contains(where: \.isDirectory) {
            throw error(SZL10n.string("app.fileManager.quickLook.noFolderPreview"))
        }

        if let oversizedItem = archiveItems.first(where: { $0.size > maxArchiveItemSize }) {
            throw error(SZL10n.string("app.fileManager.quickLook.fileSizeLimit",
                                      formattedByteCount(maxArchiveItemSize),
                                      oversizedItem.name,
                                      formattedByteCount(oversizedItem.size)))
        }

        let combinedSize = archiveItems.reduce(into: UInt64.zero) { currentTotal, item in
            let (sum, overflow) = currentTotal.addingReportingOverflow(item.size)
            currentTotal = overflow ? .max : sum
        }
        if combinedSize > maxArchiveCombinedSize {
            throw error(SZL10n.string("app.fileManager.quickLook.combinedSizeLimit",
                                      formattedByteCount(maxArchiveCombinedSize),
                                      formattedByteCount(combinedSize)))
        }

        guard !archiveHasActiveOperations else {
            throw error(SZL10n.string("app.fileManager.quickLook.cannotPreviewArchive"))
        }

        if isSolidArchive {
            let archiveSize = archiveSizeProvider()
            if archiveSize > maxSolidArchiveSize {
                throw error(SZL10n.string("app.fileManager.quickLook.solidArchiveSizeLimit",
                                          formattedByteCount(maxSolidArchiveSize),
                                          formattedByteCount(archiveSize)))
            }
        }
    }

    private static func formattedByteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

private enum FileManagerQuickLookLimits {
    static let maxArchiveItemSize: UInt64 = 128 * 1024 * 1024
    static let maxArchiveCombinedSize: UInt64 = 256 * 1024 * 1024
    static let maxSolidArchiveSize: UInt64 = 512 * 1024 * 1024
}

enum FileManagerQuickLookKeyAction {
    case ignore
    case activateSelection
    case navigateUp
    case forwardToTable
}

enum FileManagerQuickLookEventHandling {
    static func keyAction(for event: NSEvent) -> FileManagerQuickLookKeyAction {
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return .ignore
        }

        switch event.keyCode {
        case 36, 76:
            return .activateSelection
        case 51:
            return .navigateUp
        default:
            return .forwardToTable
        }
    }
}

private struct FileManagerQuickLookGenerationCounter {
    private var value: UInt64 = 0

    mutating func next() -> UInt64 {
        value &+= 1
        return value
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == value
    }
}

@MainActor
private final class FileManagerQuickLookPreviewState {
    private(set) var items: [FileManagerQuickLookItem] = []
    private(set) weak var sourcePane: FileManagerPaneController?
    private var temporaryDirectories: [URL] = []

    var isEmpty: Bool {
        items.isEmpty
    }

    var count: Int {
        items.count
    }

    func item(at index: Int) -> FileManagerQuickLookItem? {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    func replace(with preview: FileManagerQuickLookPreparedPreview,
                 sourcePane: FileManagerPaneController)
    {
        let oldTemporaryDirectories = temporaryDirectories
        let oldSourcePane = self.sourcePane

        // Swap items before cleanup so QL never observes an empty data source.
        self.sourcePane = sourcePane
        temporaryDirectories = preview.temporaryDirectories
        items = preview.items.map(FileManagerQuickLookItem.init(preparedItem:))

        if !oldTemporaryDirectories.isEmpty {
            let cleanupPane = oldSourcePane ?? sourcePane
            cleanupPane.cleanupQuickLookTemporaryDirectories(oldTemporaryDirectories)
        }
    }

    func clear() {
        if let sourcePane {
            sourcePane.cleanupQuickLookTemporaryDirectories(temporaryDirectories)
        }
        temporaryDirectories.removeAll()
        items.removeAll()
        sourcePane = nil
    }
}

@MainActor
final class FileManagerQuickLookPanelController: NSObject {
    private let previewState = FileManagerQuickLookPreviewState()
    private var previewTask: Task<Void, Never>?
    private var generationCounter = FileManagerQuickLookGenerationCounter()

    private var sourcePane: FileManagerPaneController? {
        previewState.sourcePane
    }

    var canControlPanel: Bool {
        !previewState.isEmpty
    }

    private var isVisible: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        return QLPreviewPanel.shared()?.isVisible == true
    }

    private func replace(with preview: FileManagerQuickLookPreparedPreview,
                         sourcePane: FileManagerPaneController)
    {
        previewState.replace(with: preview,
                             sourcePane: sourcePane)
    }

    private func show(_ preview: FileManagerQuickLookPreparedPreview,
                      sourcePane: FileManagerPaneController,
                      shouldPresentPanel: Bool,
                      currentController: AnyObject)
    {
        replace(with: preview,
                sourcePane: sourcePane)
        presentPanelIfNeeded(shouldPresentPanel: shouldPresentPanel,
                             currentController: currentController)
    }

    private func requestPreview(for pane: FileManagerPaneController,
                                userInitiated: Bool,
                                currentController: AnyObject,
                                showError: @escaping @MainActor (Error) -> Void)
    {
        let shouldPresentPanel = userInitiated || isVisible
        guard pane.canQuickLookSelection else {
            if !userInitiated {
                closePreview()
            }
            return
        }

        // Fast synchronous path for local filesystem items avoids the Task hop
        // that would otherwise cause QL to flash a loading spinner.
        do {
            if let filesystemPreview = try pane.prepareQuickLookPreviewForFileSystem() {
                invalidatePendingPreview()
                show(filesystemPreview,
                     sourcePane: pane,
                     shouldPresentPanel: shouldPresentPanel,
                     currentController: currentController)
                return
            }
        } catch {
            closePreview()
            if userInitiated {
                showError(error)
            }
            return
        }

        weak var weakCurrentController: AnyObject? = currentController
        startPreviewTask { [weak self, weak pane] generation in
            guard let self,
                  let pane,
                  let currentController = weakCurrentController
            else { return }

            do {
                let preview = try await pane.prepareQuickLookPreview(maxArchiveItemSize: FileManagerQuickLookLimits.maxArchiveItemSize,
                                                                     maxArchiveCombinedSize: FileManagerQuickLookLimits.maxArchiveCombinedSize,
                                                                     maxSolidArchiveSize: FileManagerQuickLookLimits.maxSolidArchiveSize)
                guard isCurrentPreviewGeneration(generation) else {
                    pane.cleanupQuickLookTemporaryDirectories(preview.temporaryDirectories)
                    return
                }

                show(preview,
                     sourcePane: pane,
                     shouldPresentPanel: shouldPresentPanel,
                     currentController: currentController)
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentPreviewGeneration(generation) else { return }
                closePreview()
                if userInitiated {
                    showError(error)
                }
            }
        }
    }

    func openPreview(for pane: FileManagerPaneController,
                     currentController: AnyObject,
                     showError: @escaping @MainActor (Error) -> Void)
    {
        requestPreview(for: pane,
                       userInitiated: true,
                       currentController: currentController,
                       showError: showError)
    }

    func togglePreview(for pane: FileManagerPaneController,
                       currentController: AnyObject,
                       showError: @escaping @MainActor (Error) -> Void)
    {
        if isVisible,
           sourcePane === pane
        {
            closePreview()
            return
        }

        openPreview(for: pane,
                    currentController: currentController,
                    showError: showError)
    }

    func refreshPreviewIfVisible(for pane: FileManagerPaneController,
                                 currentController: AnyObject,
                                 showError: @escaping @MainActor (Error) -> Void)
    {
        guard isVisible else { return }
        requestPreview(for: pane,
                       userInitiated: false,
                       currentController: currentController,
                       showError: showError)
    }

    func retargetPreviewIfVisible(to pane: FileManagerPaneController,
                                  currentController: AnyObject,
                                  showError: @escaping @MainActor (Error) -> Void)
    {
        guard isVisible,
              sourcePane !== pane
        else { return }

        requestPreview(for: pane,
                       userInitiated: false,
                       currentController: currentController,
                       showError: showError)
    }

    private func clear() {
        previewState.clear()
    }

    func cancelAndClear() {
        invalidatePendingPreview()
        clear()
    }

    func closePreview() {
        invalidatePendingPreview()
        orderOutPanelIfVisible()
        clear()
    }

    private func invalidatePendingPreview() {
        previewTask?.cancel()
        previewTask = nil
        _ = generationCounter.next()
    }

    private func startPreviewTask(_ operation: @escaping @MainActor (UInt64) async -> Void) {
        let generation = generationCounter.next()
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            await operation(generation)
        }
    }

    private func isCurrentPreviewGeneration(_ generation: UInt64) -> Bool {
        generationCounter.isCurrent(generation)
    }

    func beginControlling(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    func endControlling(_ panel: QLPreviewPanel!) {
        if panel.dataSource as AnyObject? === self {
            panel.dataSource = nil
        }
        if panel.delegate as AnyObject? === self {
            panel.delegate = nil
        }
        clear()
    }

    private func presentPanelIfNeeded(shouldPresentPanel: Bool,
                                      currentController: AnyObject)
    {
        guard shouldPresentPanel,
              let panel = QLPreviewPanel.shared() else { return }

        panel.updateController()
        panel.orderFront(nil)
        if panel.currentController as AnyObject? === currentController {
            panel.reloadData()
        }
    }

    private func orderOutPanelIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible
        else { return }

        panel.orderOut(nil)
    }
}

extension FileManagerQuickLookPanelController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        previewState.count
    }

    func previewPanel(_: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewState.item(at: index)
    }

    func previewPanel(_: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event,
              event.type == .keyDown
        else {
            return false
        }

        guard let pane = previewState.sourcePane else {
            return false
        }
        return pane.handleQuickLookEvent(event)
    }

    func previewPanel(_: QLPreviewPanel!, sourceFrameOnScreenFor item: any QLPreviewItem) -> NSRect {
        guard let item = item as? FileManagerQuickLookItem else { return .zero }
        return item.sourceFrameOnScreen
    }

    func previewPanel(_: QLPreviewPanel!, transitionImageFor item: any QLPreviewItem, contentRect: UnsafeMutablePointer<NSRect>) -> Any! {
        guard let item = item as? FileManagerQuickLookItem else { return nil }
        contentRect.pointee = item.transitionContentRect
        return item.transitionImage
    }
}

extension FileManagerWindowController {
    override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated {
            quickLookPanelController.canControlPanel
        }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            quickLookPanelController.beginControlling(panel)
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            quickLookPanelController.endControlling(panel)
        }
    }
}

private final class FileManagerQuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    let sourceFrameOnScreen: NSRect
    let transitionImage: NSImage?
    let transitionContentRect: NSRect

    init(url: URL,
         title: String?,
         sourceFrameOnScreen: NSRect,
         transitionImage: NSImage?,
         transitionContentRect: NSRect)
    {
        previewItemURL = url
        previewItemTitle = title
        self.sourceFrameOnScreen = sourceFrameOnScreen
        self.transitionImage = transitionImage
        self.transitionContentRect = transitionContentRect
    }

    convenience init(preparedItem item: FileManagerQuickLookPreparedItem) {
        self.init(url: item.url,
                  title: item.title,
                  sourceFrameOnScreen: item.sourceFrameOnScreen,
                  transitionImage: item.transitionImage,
                  transitionContentRect: item.transitionContentRect)
    }
}
