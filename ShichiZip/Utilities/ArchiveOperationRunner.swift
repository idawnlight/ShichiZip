import Cocoa

/// SZOperationSession synchronizes its mutable state internally and routes UI callbacks to the main thread.
extension SZOperationSession: @unchecked Sendable {}

/// SZArchive access is coordinated by callers before being handed to background archive workers.
extension SZArchive: @unchecked Sendable {}

/// Wraps archive work for dispatch queues. Callers coordinate archive/session ownership before dispatch.
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
        let coordinator = ArchiveOperationCoordinator(operationTitle: operationTitle,
                                                      initialFileName: initialFileName,
                                                      parentWindow: parentWindow,
                                                      deferredDisplay: deferredDisplay)
        coordinator.start()
        defer { coordinator.finish() }
        let session = coordinator.session

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    session.requestCancel()
                }

                let operation = ArchiveOperationWork(body: work)
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try operation(session)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            session.requestCancel()
        }
    }
}
