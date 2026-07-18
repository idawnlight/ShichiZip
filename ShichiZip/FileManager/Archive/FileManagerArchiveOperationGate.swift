import Foundation

/// Shared across UI and archive worker queues; all mutable state is guarded by `condition`.
final class FileManagerArchiveOperationGate: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let gate: FileManagerArchiveOperationGate

        fileprivate init(gate: FileManagerArchiveOperationGate) {
            self.gate = gate
        }

        deinit {
            gate.releaseLease()
        }
    }

    private let condition = NSCondition()
    private var activeLeaseCount = 0
    private var isClosing = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    func acquireLease() -> Lease? {
        condition.lock()
        defer { condition.unlock() }

        guard !isClosing else {
            return nil
        }

        activeLeaseCount += 1
        return Lease(gate: self)
    }

    func beginClosing() {
        condition.lock()
        isClosing = true
        condition.unlock()
    }

    var hasActiveLeases: Bool {
        condition.lock()
        let hasActiveLeases = activeLeaseCount > 0
        condition.unlock()
        return hasActiveLeases
    }

    func beginClosingAndWaitForLeases() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            isClosing = true
            if activeLeaseCount == 0 {
                condition.unlock()
                continuation.resume()
                return
            }

            drainWaiters.append(continuation)
            condition.unlock()
        }
    }

    func cancelClosing() {
        condition.lock()
        isClosing = false
        condition.broadcast()
        condition.unlock()
    }

    private func releaseLease() {
        let waiters: [CheckedContinuation<Void, Never>]
        condition.lock()
        activeLeaseCount -= 1
        precondition(activeLeaseCount >= 0)
        if activeLeaseCount == 0 {
            condition.broadcast()
            waiters = drainWaiters
            drainWaiters.removeAll()
        } else {
            waiters = []
        }
        condition.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }
}
