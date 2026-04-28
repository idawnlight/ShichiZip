import Cocoa

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
    private let promiseQueue: OperationQueue

    init(item: ArchiveItem,
         context: FileManagerArchiveItemWorkflowContext,
         operationGate: FileManagerArchiveOperationGate,
         workflowService: FileManagerArchiveItemWorkflowService)
    {
        self.item = item
        self.context = context
        self.operationGate = operationGate
        self.workflowService = workflowService

        let queue = OperationQueue()
        queue.name = "shichizip.archive-drag-promise"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        promiseQueue = queue
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
                    return
                }

                let coordinator = ArchiveOperationCoordinator(operationTitle: SZL10n.string("progress.extracting"),
                                                              initialFileName: self.item.path,
                                                              deferredDisplay: true)
                coordinator.start()
                let session = coordinator.session

                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let result: Result<Void, Error> = Result {
                        try self.workflowService.writePromise(for: self.item,
                                                              context: self.context,
                                                              to: url,
                                                              session: session)
                    }

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            coordinator.finish()
                            withExtendedLifetime(lease) {}

                            switch result {
                            case .success:
                                completionHandler.finish(nil)
                            case let .failure(error):
                                completionHandler.finish(error)
                            }
                        }
                    }
                }
            }
        }
    }
}

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
