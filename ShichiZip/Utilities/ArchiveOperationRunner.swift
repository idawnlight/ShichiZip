import Cocoa

// SZOperationSession synchronizes its mutable state internally and routes UI callbacks to the main thread.
extension SZOperationSession: @unchecked Sendable {}

enum ArchiveOperationRunner {
    @MainActor
    static func runSynchronously<T>(operationTitle: String,
                                    initialFileName: String? = nil,
                                    parentWindow: NSWindow? = nil,
                                    deferredDisplay: Bool = false,
                                    work: @escaping (SZOperationSession) throws -> T) throws -> T {
        let coordinator = ArchiveOperationCoordinator(operationTitle: operationTitle,
                                                     initialFileName: initialFileName,
                                                     parentWindow: parentWindow,
                                                     deferredDisplay: deferredDisplay)
        coordinator.start()

        let resultLock = NSLock()
        var result: Result<T, Error>?
        let session = coordinator.session
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value = try work(session)
                resultLock.lock()
                result = .success(value)
                resultLock.unlock()
            } catch {
                resultLock.lock()
                result = .failure(error)
                resultLock.unlock()
            }
        }

        while true {
            resultLock.lock()
            let currentResult = result
            resultLock.unlock()

            if let currentResult {
                coordinator.finish()
                return try currentResult.get()
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    @MainActor
    static func run<T>(operationTitle: String,
                       initialFileName: String? = nil,
                       parentWindow: NSWindow? = nil,
                       deferredDisplay: Bool = false,
                       work: @escaping (SZOperationSession) throws -> T) async throws -> T {
        let coordinator = ArchiveOperationCoordinator(operationTitle: operationTitle,
                                                     initialFileName: initialFileName,
                                                     parentWindow: parentWindow,
                                                     deferredDisplay: deferredDisplay)
        coordinator.start()
        defer { coordinator.finish() }

        return try await withCheckedThrowingContinuation { continuation in
            let session = coordinator.session
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try work(session)
                    DispatchQueue.main.async {
                        continuation.resume(returning: result)
                    }
                } catch {
                    DispatchQueue.main.async {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
