import Foundation
import os
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerArchiveOperationGateTests: XCTestCase {
    func testReportsActiveLeases() throws {
        let gate = FileManagerArchiveOperationGate()
        XCTAssertFalse(gate.hasActiveLeases)

        var firstLease: FileManagerArchiveOperationGate.Lease? = try XCTUnwrap(gate.acquireLease())
        XCTAssertNotNil(firstLease)
        XCTAssertTrue(gate.hasActiveLeases)

        var secondLease: FileManagerArchiveOperationGate.Lease? = try XCTUnwrap(gate.acquireLease())
        XCTAssertNotNil(secondLease)
        XCTAssertTrue(gate.hasActiveLeases)

        firstLease = nil
        XCTAssertTrue(gate.hasActiveLeases)

        secondLease = nil
        XCTAssertFalse(gate.hasActiveLeases)
    }

    func testRejectsNewLeaseAfterClosingBegins() throws {
        let gate = FileManagerArchiveOperationGate()
        let lease = try XCTUnwrap(gate.acquireLease())

        gate.beginClosing()

        XCTAssertNil(gate.acquireLease())

        gate.cancelClosing()
        XCTAssertNotNil(gate.acquireLease())
        withExtendedLifetime(lease) {}
    }

    func testWaitsForActiveLeaseBeforeClosing() async throws {
        let gate = FileManagerArchiveOperationGate()
        var lease: FileManagerArchiveOperationGate.Lease? = try XCTUnwrap(gate.acquireLease())
        XCTAssertNotNil(lease)
        let didFinish = OSAllocatedUnfairLock(initialState: false)
        let closeFinished = expectation(description: "archive operation gate close finished")

        let closeTask = Task {
            await gate.beginClosingAndWaitForLeases()
            didFinish.withLock { $0 = true }
            closeFinished.fulfill()
        }

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(didFinish.withLock { $0 })

        lease = nil
        await fulfillment(of: [closeFinished], timeout: 1)
        await closeTask.value
    }

    func testResumesAllCloseWaitersWhenLeasesDrain() async throws {
        let gate = FileManagerArchiveOperationGate()
        var lease: FileManagerArchiveOperationGate.Lease? = try XCTUnwrap(gate.acquireLease())
        XCTAssertNotNil(lease)

        let firstWaiter = Task {
            await gate.beginClosingAndWaitForLeases()
            return true
        }
        let secondWaiter = Task {
            await gate.beginClosingAndWaitForLeases()
            return true
        }

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(gate.acquireLease())

        lease = nil
        let firstFinished = await firstWaiter.value
        let secondFinished = await secondWaiter.value
        XCTAssertTrue(firstFinished)
        XCTAssertTrue(secondFinished)
    }
}
