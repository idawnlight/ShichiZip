import Foundation
@testable import ShichiZipQuickActionCore
import XCTest

final class BoundedConcurrentMapTests: XCTestCase {
    @MainActor
    func testPreservesOrderAndBoundsConcurrency() async throws {
        let input = Array(0 ..< 24)
        let probe = BoundedConcurrentMapProbe()

        let output = try await shichiZipBoundedConcurrentMap(input,
                                                             maxConcurrentTasks: 4)
        { value in
            probe.begin()
            defer { probe.end() }

            try await Task.sleep(for: .milliseconds((4 - value % 4) * 2))
            return value * 2
        }

        XCTAssertEqual(output, input.map { $0 * 2 })
        XCTAssertEqual(probe.maximumInFlightCount, 4)
        XCTAssertEqual(probe.inFlightCount, 0)
    }

    @MainActor
    func testPropagatesErrorAndCancelsRemainingWork() async {
        let probe = BoundedConcurrentMapProbe()

        do {
            _ = try await shichiZipBoundedConcurrentMap(Array(0 ..< 20),
                                                        maxConcurrentTasks: 4)
            { value in
                probe.begin()
                defer { probe.end() }

                if value == 0 {
                    while probe.startedCount < 4 {
                        await Task.yield()
                    }
                    throw BoundedConcurrentMapTestError.expected
                }

                do {
                    try await Task.sleep(for: .seconds(10))
                    return value
                } catch {
                    if error is CancellationError {
                        probe.recordCancellation()
                    }
                    throw error
                }
            }
            XCTFail("The transform error should be propagated.")
        } catch BoundedConcurrentMapTestError.expected {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(probe.startedCount, 4)
        XCTAssertEqual(probe.cancelledCount, 3)
        XCTAssertEqual(probe.inFlightCount, 0)
    }
}

@MainActor
private final class BoundedConcurrentMapProbe {
    private(set) var inFlightCount = 0
    private(set) var maximumInFlightCount = 0
    private(set) var startedCount = 0
    private(set) var cancelledCount = 0

    func begin() {
        inFlightCount += 1
        startedCount += 1
        maximumInFlightCount = max(maximumInFlightCount, inFlightCount)
    }

    func end() {
        inFlightCount -= 1
    }

    func recordCancellation() {
        cancelledCount += 1
    }
}

private enum BoundedConcurrentMapTestError: Error {
    case expected
}
