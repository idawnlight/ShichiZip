import Cocoa

final class ArchiveOpenCoordinator {
    private static let updateInterval: TimeInterval = 0.2

    let session: SZOperationSession

    private let progressController: ProgressDialogController
    private let showDeadline: Date
    private var timer: Timer?

    init(displayPath: String) {
        session = SZOperationSession()
        progressController = ProgressDialogController()
        progressController.operationTitle = "Opening archive..."
        progressController.beginWaitingMode(fileName: displayPath)
        showDeadline = Date().addingTimeInterval(ProgressDialogController.deferredPresentationDelay)

        session.passwordRequestHandler = { [weak self] title, message, initialValue, passwordPointer in
            guard let self else { return false }
            self.showProgressNowIfNeeded()

            if let password = szPromptForPasswordSync(title: title,
                                                     message: message,
                                                     initialValue: initialValue) {
                passwordPointer?.pointee = password as NSString
                return true
            }
            return false
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
        updateFromSession()
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        updateFromSession()
        progressController.hideIfVisible()
    }

    @objc private func updateFromSession() {
        let snapshot = session.snapshot()

        if progressController.progressShouldCancel() && !snapshot.isCancellationRequested {
            session.requestCancel()
        }

        if snapshot.isWaitingForUserInteraction || Date() >= showDeadline {
            showProgressNowIfNeeded()
        }

        if !snapshot.currentFileName.isEmpty {
            progressController.progressDidUpdateFileName(snapshot.currentFileName)
        }
        if snapshot.hasReportedProgress {
            progressController.progressDidUpdate(snapshot.progressFraction)
        }
        if snapshot.bytesTotal > 0 {
            progressController.progressDidUpdateBytesCompleted(snapshot.bytesCompleted, total: snapshot.bytesTotal)
        }
    }

    private func showProgressNowIfNeeded() {
        progressController.showNowIfNeeded()
    }
}