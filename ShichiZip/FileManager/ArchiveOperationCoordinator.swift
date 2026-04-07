import Cocoa

@MainActor
final class ArchiveOperationCoordinator {
    private static let updateInterval: TimeInterval = 0.2

    let session: SZOperationSession

    private let progressController: ProgressDialogController
    private weak var parentWindow: NSWindow?
    private let deferredDisplay: Bool
    private let showDeadline: Date?
    private var timer: Timer?
    private var isSheetVisible = false

    init(operationTitle: String,
         initialFileName: String? = nil,
         parentWindow: NSWindow? = nil,
         deferredDisplay: Bool = false) {
        session = SZOperationSession()
        progressController = ProgressDialogController()
        progressController.operationTitle = operationTitle
        progressController.beginWaitingMode(fileName: initialFileName)
        session.progressDelegate = progressController

        self.parentWindow = parentWindow
        self.deferredDisplay = deferredDisplay
        self.showDeadline = deferredDisplay
            ? Date().addingTimeInterval(ProgressDialogController.deferredPresentationDelay)
            : nil

        session.passwordRequestHandler = { [weak self] title, message, initialValue, passwordPointer in
            self?.prepareForPromptIfNeeded()

            guard let password = szPromptForPasswordSync(title: title,
                                                        message: message,
                                                        initialValue: initialValue) else {
                return false
            }

            passwordPointer?.pointee = password as NSString
            return true
        }

        session.choiceRequestHandler = { [weak self] style, title, message, buttonTitles in
            self?.prepareForPromptIfNeeded()
            return szRunChoiceDialog(title: title,
                                     message: message ?? "",
                                     style: szDialogStyle(for: style),
                                     buttons: buttonTitles)
        }
    }

    func start() {
        let timer = Timer(timeInterval: Self.updateInterval,
                          target: self,
                          selector: #selector(updateFromSession),
                          userInfo: nil,
                          repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)

        if let parentWindow, let progressWindow = progressController.window {
            parentWindow.beginSheet(progressWindow) { _ in }
            isSheetVisible = true
        } else if !deferredDisplay {
            progressController.showNowIfNeeded()
        }

        updateFromSession()
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        updateFromSession()

        if isSheetVisible,
           let parentWindow,
           let progressWindow = progressController.window {
            parentWindow.endSheet(progressWindow)
            isSheetVisible = false
        } else {
            progressController.hideIfVisible()
        }
    }

    func requestChoice(style: SZOperationPromptStyle,
                       title: String,
                       message: String,
                       buttonTitles: [String]) -> Int {
        session.requestChoice(with: style,
                              title: title,
                              message: message,
                              buttonTitles: buttonTitles)
    }

    @objc private func updateFromSession() {
        let snapshot = session.snapshot()

        if progressController.progressShouldCancel() && !snapshot.isCancellationRequested {
            session.requestCancel()
        }

        if shouldShowProgress(for: snapshot) {
            progressController.showNowIfNeeded()
        }

        if !snapshot.currentFileName.isEmpty {
            progressController.progressDidUpdateFileName(snapshot.currentFileName)
        }
        if snapshot.hasReportedProgress {
            progressController.progressDidUpdate(snapshot.progressFraction)
        }
        if snapshot.bytesTotal > 0 {
            progressController.progressDidUpdateBytesCompleted(snapshot.bytesCompleted,
                                                              total: snapshot.bytesTotal)
        }
    }

    private func prepareForPromptIfNeeded() {
        if deferredDisplay || (parentWindow == nil && !isSheetVisible) {
            progressController.showNowIfNeeded()
        }
    }

    private func shouldShowProgress(for snapshot: SZOperationSnapshot) -> Bool {
        if snapshot.isWaitingForUserInteraction {
            return true
        }

        guard deferredDisplay, let showDeadline else {
            return false
        }
        return Date() >= showDeadline
    }
}