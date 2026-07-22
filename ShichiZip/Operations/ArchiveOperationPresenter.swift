import AppKit
import SwiftUI

@MainActor
final class ArchiveOperationPresenter: NSObject, NSWindowDelegate {
    static let deferredPresentationDelay: Duration = .milliseconds(500)
    private static let standardContentSize = NSSize(width: 500, height: 160)
    private static let activeWarningContentSize = NSSize(width: 500, height: 185)
    private static let warningResultWidth: CGFloat = 560
    private static let warningResultMinimumHeight: CGFloat = 220
    private static let warningResultMaximumHeight: CGFloat = 390

    let session: SZOperationSession
    let model: OperationProgressModel

    private let windowController: NSWindowController
    private weak var requestedParentWindow: NSWindow?
    private weak var activeSheetParent: NSWindow?
    private let deferredDisplay: Bool
    private var deferredPresentationTask: Task<Void, Never>?
    private var warningContinuation: CheckedContinuation<Void, Never>?
    private var isSheetVisible = false
    private var isDismissing = false
    private var isFinished = false

    init(operationTitle: String,
         initialFileName: String?,
         parentWindow: NSWindow?,
         deferredDisplay: Bool)
    {
        session = SZOperationSession()
        model = OperationProgressModel(operationTitle: operationTitle,
                                       initialFileName: initialFileName,
                                       session: session)
        requestedParentWindow = parentWindow
        self.deferredDisplay = deferredDisplay

        let hostingController = NSHostingController(
            rootView: OperationProgressView(model: model),
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = AppBuildInfo.appDisplayName()
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(Self.standardContentSize)
        window.minSize = NSSize(width: 460, height: 145)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = true
        window.center()
        windowController = NSWindowController(window: window)

        super.init()

        window.delegate = self
        model.closeAction = { [weak self] in
            self?.acknowledgeWarnings()
        }
        session.snapshotHandler = { [weak self] snapshot in
            MainActor.assumeIsolated {
                self?.receive(snapshot)
            }
        }
        session.passwordRequestHandler = { [weak self] title, message, initialValue, passwordPointer in
            MainActor.assumeIsolated {
                self?.showProgressIfNeeded()
            }

            guard let password = szPromptForPasswordSync(title: title,
                                                         message: message,
                                                         initialValue: initialValue)
            else {
                return false
            }

            passwordPointer?.pointee = password as NSString
            return true
        }
        session.choiceRequestHandler = { [weak self] request in
            MainActor.assumeIsolated {
                self?.showProgressIfNeeded()
            }
            return szRunChoiceDialog(request)
        }
    }

    func start() {
        guard !isFinished else { return }
        if deferredDisplay {
            deferredPresentationTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: Self.deferredPresentationDelay)
                } catch {
                    return
                }
                self?.showProgressIfNeeded()
            }
        } else {
            showProgressIfNeeded()
        }
        receive(session.snapshot())
    }

    func finishSuccessfully(updateOutcome: SZArchiveUpdateOutcome?) async {
        guard !isFinished else { return }
        deferredPresentationTask?.cancel()
        deferredPresentationTask = nil
        model.complete(updateOutcome: updateOutcome)
        updateWindowSizeForContent()

        if model.isTerminalWarning {
            showProgressIfNeeded()
            await withCheckedContinuation { continuation in
                warningContinuation = continuation
            }
        } else {
            dismiss()
        }
        finishTeardown()
    }

    func finishWithFailure() {
        guard !isFinished else { return }
        deferredPresentationTask?.cancel()
        deferredPresentationTask = nil
        dismiss()
        finishTeardown()
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        if isDismissing {
            return true
        }
        if model.isTerminalWarning {
            acknowledgeWarnings()
        } else {
            model.requestCancel()
        }
        return false
    }

    private func receive(_ snapshot: SZOperationSnapshot) {
        guard !isFinished else { return }
        model.apply(snapshot)
        updateWindowSizeForContent()
        if snapshot.isWaitingForUserInteraction
            || snapshot.isCancellationRequested
            || snapshot.totalIssueCount > 0
        {
            showProgressIfNeeded()
        }
    }

    private func updateWindowSizeForContent() {
        guard let window = windowController.window else { return }
        let targetSize: NSSize
        if model.isTerminalWarning {
            let issueHeight = CGFloat(model.displayedIssues.count) * 36
            let height = min(
                max(Self.warningResultMinimumHeight, 175 + issueHeight),
                Self.warningResultMaximumHeight,
            )
            targetSize = NSSize(width: Self.warningResultWidth, height: height)
        } else if model.totalIssueCount > 0 {
            targetSize = Self.activeWarningContentSize
        } else {
            targetSize = Self.standardContentSize
        }
        window.minSize = model.isTerminalWarning
            ? NSSize(width: 500, height: Self.warningResultMinimumHeight)
            : NSSize(width: 460, height: 145)
        guard window.contentLayoutRect.size != targetSize else { return }
        window.setContentSize(targetSize)
    }

    private func showProgressIfNeeded() {
        guard !isFinished,
              !isSheetVisible,
              let window = windowController.window,
              !window.isVisible
        else {
            return
        }

        deferredPresentationTask?.cancel()
        deferredPresentationTask = nil

        if let parent = szSheetParentWindow(requestedParentWindow),
           parent !== window
        {
            activeSheetParent = parent
            parent.beginSheet(window) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isDismissing else { return }
                    if self.model.isTerminalWarning {
                        self.acknowledgeWarnings()
                    } else {
                        self.model.requestCancel()
                    }
                }
            }
            isSheetVisible = true
            return
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func acknowledgeWarnings() {
        guard model.isTerminalWarning else { return }
        dismiss()
        let continuation = warningContinuation
        warningContinuation = nil
        continuation?.resume()
    }

    private func dismiss() {
        guard let window = windowController.window else { return }
        isDismissing = true
        if isSheetVisible, let activeSheetParent {
            activeSheetParent.endSheet(window)
            isSheetVisible = false
        }
        window.orderOut(nil)
        isDismissing = false
    }

    private func finishTeardown() {
        guard !isFinished else { return }
        isFinished = true
        session.snapshotHandler = nil
        session.passwordRequestHandler = nil
        session.choiceRequestHandler = nil
        model.closeAction = nil
        requestedParentWindow = nil
        activeSheetParent = nil
    }
}
