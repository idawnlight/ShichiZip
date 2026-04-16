// OperationSessionProgressThrottlingTests.swift
//
// Covers the progress coalescing added in 584bc90 + f3f2c2e:
//
//   * Per-tick SetCompleted calls from 7-Zip are gated to ~50 ms so
//     the main queue is not swamped during long operations.
//   * Terminal updates (fraction >= 1.0, or completed >= total) are
//     always delivered so the UI does not freeze at 99%.
//   * The throttle uses a monotonic clock (CACurrentMediaTime), so
//     wall-clock NTP steps do not starve the delegate.
//
// The session dispatches delegate calls to the main queue via
// dispatch_async. Tests run on the XCTest main thread, so we drain
// the queue with `RunLoop.main.run(until:)` between bursts of report
// calls.

import XCTest

@MainActor
final class OperationSessionProgressThrottlingTests: XCTestCase {
    private final class RecordingDelegate: NSObject, SZProgressDelegate {
        nonisolated(unsafe) var fractionUpdates: [Double] = []
        nonisolated(unsafe) var bytesUpdates: [(UInt64, UInt64)] = []

        func progressDidUpdate(_ fraction: Double) {
            fractionUpdates.append(fraction)
        }

        func progressDidUpdateFileName(_: String) {}
        func progressDidUpdateBytesCompleted(_ completed: UInt64, total: UInt64) {
            bytesUpdates.append((completed, total))
        }

        func progressShouldCancel() -> Bool {
            false
        }
    }

    private func drainMainQueue(for seconds: TimeInterval = 0.02) {
        // dispatch_async(main) blocks can only run when the main
        // runloop is spun. 20 ms is long enough to pick up any
        // already-queued blocks but short enough to stay fast.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    // MARK: - Fraction throttling

    func testRapidProgressReportsAreCoalesced() {
        let delegate = RecordingDelegate()
        let session = SZOperationSession()
        session.progressDelegate = delegate

        // Fire 100 updates back-to-back with no wait between them.
        // The only ones that should actually reach the delegate are
        // the first report (special-cased "flush the first tick")
        // and the terminal 1.0. The 98 reports in between land
        // inside the 50 ms throttle window.
        for i in 1 ... 98 {
            session.reportProgressFraction(Double(i) / 100.0)
        }
        // Terminal update is always delivered.
        session.reportProgressFraction(1.0)

        drainMainQueue(for: 0.1)

        // Be generous to account for future throttling tweaks: any
        // value from 2 (first + terminal) to 5 (first + a couple
        // intermediate timer boundaries + terminal) is acceptable on
        // a fast machine. The important check is that we are nowhere
        // near 99.
        XCTAssertGreaterThanOrEqual(delegate.fractionUpdates.count, 2,
                                    "first and terminal updates must always be delivered")
        XCTAssertLessThanOrEqual(delegate.fractionUpdates.count, 10,
                                 "rapid intermediate updates must be coalesced, got \(delegate.fractionUpdates.count)")

        XCTAssertEqual(delegate.fractionUpdates.last, 1.0,
                       "last delegate call must carry the terminal fraction")
    }

    func testTerminalFractionIsAlwaysDelivered() {
        let delegate = RecordingDelegate()
        let session = SZOperationSession()
        session.progressDelegate = delegate

        // First update primes the throttle; the following 1.0 must
        // still reach the delegate despite landing immediately after.
        session.reportProgressFraction(0.5)
        session.reportProgressFraction(1.0)
        drainMainQueue()

        XCTAssertTrue(delegate.fractionUpdates.contains(1.0),
                      "terminal 1.0 must always be delivered, got \(delegate.fractionUpdates)")
    }

    func testFractionIsClampedToUnitInterval() {
        let delegate = RecordingDelegate()
        let session = SZOperationSession()
        session.progressDelegate = delegate

        session.reportProgressFraction(-1.0)
        drainMainQueue()
        session.reportProgressFraction(42.0)
        drainMainQueue()

        for value in delegate.fractionUpdates {
            XCTAssertGreaterThanOrEqual(value, 0.0)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
        // The 42.0 report clamps to 1.0 and is therefore treated as
        // terminal -> delegate must have seen both clamped edges.
        XCTAssertTrue(delegate.fractionUpdates.contains(0.0))
        XCTAssertTrue(delegate.fractionUpdates.contains(1.0))
    }

    // MARK: - Bytes throttling

    func testRapidBytesReportsAreCoalescedAndTerminalArrives() {
        let delegate = RecordingDelegate()
        let session = SZOperationSession()
        session.progressDelegate = delegate

        let total: UInt64 = 1000
        for completed in stride(from: 0, through: 999, by: 1) {
            session.reportBytesCompleted(UInt64(completed), total: total)
        }
        // Completion -> always flushed.
        session.reportBytesCompleted(total, total: total)

        drainMainQueue(for: 0.1)

        XCTAssertGreaterThanOrEqual(delegate.bytesUpdates.count, 2,
                                    "first and terminal byte updates must always be delivered")
        XCTAssertLessThanOrEqual(delegate.bytesUpdates.count, 15,
                                 "rapid intermediate byte updates must be coalesced, got \(delegate.bytesUpdates.count)")
        XCTAssertEqual(delegate.bytesUpdates.last?.0, total,
                       "terminal byte update must carry completed == total")
    }

    // MARK: - 50 ms window opens up after wait

    func testDelegateReceivesSecondUpdateAfter50msGap() {
        let delegate = RecordingDelegate()
        let session = SZOperationSession()
        session.progressDelegate = delegate

        session.reportProgressFraction(0.1) // primes the throttle timestamp
        drainMainQueue()

        // Intermediate report inside the 50 ms window -> throttled out.
        session.reportProgressFraction(0.2)
        drainMainQueue(for: 0.005)

        // Wait past the 50 ms boundary and send a non-terminal
        // update. This one must make it through.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.07))
        session.reportProgressFraction(0.3)
        drainMainQueue()

        XCTAssertTrue(delegate.fractionUpdates.contains(0.1),
                      "first update should always pass")
        XCTAssertTrue(delegate.fractionUpdates.contains(0.3),
                      "update after the throttle window should be delivered")
    }
}
