import AppKit

/// SZOperationSession synchronizes its mutable state internally and delivers
/// immutable presentation snapshots on the main queue.
extension SZOperationSession: @unchecked Sendable {}

/// SZArchive access is coordinated by callers before being handed to background archive workers.
extension SZArchive: @unchecked Sendable {}

protocol ArchiveOperationPresentationResult {
    var archiveUpdateOutcomeForPresentation: SZArchiveUpdateOutcome? { get }
}

extension SZArchiveUpdateOutcome: ArchiveOperationPresentationResult {
    var archiveUpdateOutcomeForPresentation: SZArchiveUpdateOutcome? {
        self
    }
}

private struct ArchiveOperationWork<Value>: @unchecked Sendable {
    let body: (SZOperationSession) throws -> Value

    func callAsFunction(_ session: SZOperationSession) throws -> Value {
        try body(session)
    }
}

enum ArchiveOperationRunner {
    @MainActor
    static func run<T>(operationTitle: String,
                       initialFileName: String? = nil,
                       parentWindow: NSWindow? = nil,
                       deferredDisplay: Bool = false,
                       work: @escaping (SZOperationSession) throws -> T) async throws -> T
    {
        let presenter = ArchiveOperationPresenter(operationTitle: operationTitle,
                                                  initialFileName: initialFileName,
                                                  parentWindow: parentWindow,
                                                  deferredDisplay: deferredDisplay)
        presenter.start()
        let session = presenter.session

        do {
            let value = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        session.requestCancel()
                    }

                    let operation = ArchiveOperationWork(body: work)
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try continuation.resume(returning: operation(session))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                session.requestCancel()
            }

            let updateOutcome = (value as? any ArchiveOperationPresentationResult)?
                .archiveUpdateOutcomeForPresentation
            await presenter.finishSuccessfully(updateOutcome: updateOutcome)
            return value
        } catch {
            presenter.finishWithFailure()
            throw error
        }
    }
}
