import Cocoa

@MainActor
protocol FileManagerArchiveCoordinationProviding: AnyObject {
    func archiveCoordinationSnapshots() -> [FileManagerNestedArchiveOpenSnapshot]
}

@MainActor
protocol FileManagerWindowCoordinating: FileManagerArchiveCoordinationProviding {
    func openArchiveInNewFileManager(_ url: URL) async
}

@MainActor
protocol FileManagerDocumentOpenRouting: AnyObject {
    func beginExternalArchiveOpen()
    func endExternalArchiveOpen()
    func openArchiveInNewFileManager(_ url: URL) async
}

@MainActor
final class FileManagerWindowRegistry: FileManagerWindowCoordinating {
    private var controllers: [FileManagerWindowController] = []
    private var pendingOpenControllers: [UUID: FileManagerWindowController] = [:]
    private var pendingOpenWaiters: [CheckedContinuation<Void, Never>] = []
    private var isPreparingForTermination = false

    @discardableResult
    func prepareForApplicationTermination(showError: Bool = true) async -> Bool {
        isPreparingForTermination = true

        for controller in uniquePendingOpenControllers() {
            guard await controller.prepareForClose(showError: showError) else {
                cancelTerminationPreparation()
                return false
            }
        }

        await waitForPendingOpenOperations()

        for controller in controllers {
            guard await controller.prepareForClose(showError: showError) else {
                cancelTerminationPreparation()
                return false
            }
        }
        return true
    }

    func showFileManager(_ sender: Any?) {
        guard !isPreparingForTermination else { return }
        showFileManagerWindow(reusableFileManagerWindowController() ?? makeFileManagerWindowController(),
                              sender: sender)
    }

    func openArchiveInFileManager(_ url: URL) async {
        guard !isPreparingForTermination else { return }
        let reusableController = reusableFileManagerWindowController()
        let controller = reusableController ?? makeFileManagerWindowController(register: false)
        let pendingIdentifier = beginPendingOpen(for: controller)
        defer { finishPendingOpen(pendingIdentifier) }

        if await controller.navigateToArchive(url, revealWindow: false) {
            guard !isPreparingForTermination else {
                _ = await controller.prepareForClose(showError: false)
                return
            }
            if reusableController != nil,
               !isRegisteredFileManagerWindowController(controller)
            {
                _ = await controller.prepareForClose(showError: false)
                return
            }
            if reusableController == nil {
                registerFileManagerWindowController(controller)
            }
            showFileManagerWindow(controller,
                                  sender: nil)
        }
    }

    func openArchiveInNewFileManager(_ url: URL) async {
        guard !isPreparingForTermination else { return }
        let controller = makeFileManagerWindowController(register: false)
        let pendingIdentifier = beginPendingOpen(for: controller)
        defer { finishPendingOpen(pendingIdentifier) }

        if await controller.navigateToArchive(url, revealWindow: false) {
            guard !isPreparingForTermination else {
                _ = await controller.prepareForClose(showError: false)
                return
            }
            registerFileManagerWindowController(controller)
            showFileManagerWindow(controller,
                                  sender: nil)
        }
    }

    @discardableResult
    func openFileSystemItemInNewFileManager(_ url: URL) async -> Bool {
        guard !isPreparingForTermination else { return false }
        let controller = makeFileManagerWindowController(register: false)
        let pendingIdentifier = beginPendingOpen(for: controller)
        defer { finishPendingOpen(pendingIdentifier) }

        if await controller.openFileSystemItem(url, revealWindow: false) {
            guard !isPreparingForTermination else {
                _ = await controller.prepareForClose(showError: false)
                return false
            }
            registerFileManagerWindowController(controller)
            showFileManagerWindow(controller,
                                  sender: nil)
            return true
        }

        return false
    }

    func revealFileSystemItemsInNewWindow(_ urls: [URL]) async {
        guard !isPreparingForTermination else { return }
        let controller = makeFileManagerWindowController(register: false)
        let pendingIdentifier = beginPendingOpen(for: controller)
        defer { finishPendingOpen(pendingIdentifier) }

        if await controller.revealFileSystemItems(urls, revealWindow: false) {
            guard !isPreparingForTermination else {
                _ = await controller.prepareForClose(showError: false)
                return
            }
            registerFileManagerWindowController(controller)
            showFileManagerWindow(controller,
                                  sender: nil)
        }
    }

    func archiveCoordinationSnapshots() -> [FileManagerNestedArchiveOpenSnapshot] {
        controllers.flatMap { $0.archiveCoordinationSnapshots() }
    }

    private func reusableFileManagerWindowController() -> FileManagerWindowController? {
        if let keyController = NSApp.keyWindow?.windowController as? FileManagerWindowController,
           controllers.contains(where: { $0 === keyController })
        {
            return keyController
        }

        if let mainController = NSApp.mainWindow?.windowController as? FileManagerWindowController,
           controllers.contains(where: { $0 === mainController })
        {
            return mainController
        }

        return controllers.last { $0.window?.isVisible == true } ?? controllers.last
    }

    private func makeFileManagerWindowController(register: Bool = true) -> FileManagerWindowController {
        let controller = FileManagerWindowController(windowCoordinator: self)
        controller.onWindowWillClose = { [weak self] closingController in
            self?.removeFileManagerWindowController(closingController)
        }
        if register {
            registerFileManagerWindowController(controller)
        }
        return controller
    }

    private func registerFileManagerWindowController(_ controller: FileManagerWindowController) {
        guard !isRegisteredFileManagerWindowController(controller) else { return }
        controllers.append(controller)
    }

    private func isRegisteredFileManagerWindowController(_ controller: FileManagerWindowController) -> Bool {
        controllers.contains { $0 === controller }
    }

    private func beginPendingOpen(for controller: FileManagerWindowController) -> UUID {
        let identifier = UUID()
        pendingOpenControllers[identifier] = controller
        return identifier
    }

    private func finishPendingOpen(_ identifier: UUID) {
        pendingOpenControllers[identifier] = nil
        guard pendingOpenControllers.isEmpty else { return }

        let waiters = pendingOpenWaiters
        pendingOpenWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForPendingOpenOperations() async {
        guard !pendingOpenControllers.isEmpty else { return }
        await withCheckedContinuation { continuation in
            pendingOpenWaiters.append(continuation)
        }
    }

    private func uniquePendingOpenControllers() -> [FileManagerWindowController] {
        var seen = Set<ObjectIdentifier>()
        return pendingOpenControllers.values.filter { controller in
            seen.insert(ObjectIdentifier(controller)).inserted
        }
    }

    private func cancelTerminationPreparation() {
        var seen = Set<ObjectIdentifier>()
        let affectedControllers = (controllers + Array(pendingOpenControllers.values)).filter { controller in
            seen.insert(ObjectIdentifier(controller)).inserted
        }
        for controller in affectedControllers {
            controller.cancelClosePreparation()
        }
        isPreparingForTermination = false
    }

    private func showFileManagerWindow(_ controller: FileManagerWindowController,
                                       sender: Any?)
    {
        cascadeFileManagerWindowIfNeeded(controller)
        controller.showWindow(sender)
    }

    private func cascadeFileManagerWindowIfNeeded(_ controller: FileManagerWindowController) {
        guard let window = controller.window,
              !window.isVisible,
              !window.isMiniaturized
        else { return }

        window.cascadeTopLeft(from: cascadeTopLeftPoint(for: window,
                                                        excluding: controller))
    }

    private func cascadeTopLeftPoint(for window: NSWindow,
                                     excluding controller: FileManagerWindowController) -> NSPoint
    {
        guard let sourceWindow = controllers
            .filter({ $0 !== controller })
            .compactMap(\.window)
            .last(where: { $0.isVisible })
        else {
            return NSPoint(x: window.frame.minX, y: window.frame.maxY)
        }

        let sourceTopLeftPoint = NSPoint(x: sourceWindow.frame.minX,
                                         y: sourceWindow.frame.maxY)
        return window.cascadeTopLeft(from: sourceTopLeftPoint)
    }

    private func removeFileManagerWindowController(_ controller: FileManagerWindowController) {
        controllers.removeAll { $0 === controller }
    }
}
