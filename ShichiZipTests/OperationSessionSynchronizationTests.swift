import Foundation
import os
import XCTest
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

@MainActor
final class OperationSessionSynchronizationTests: XCTestCase {
    func testConcurrentReportsAndCancellationKeepSnapshotsCoherent() async {
        let session = SZOperationSession()
        let finished = expectation(description: "concurrent access finishes")
        let violations = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 100) { index in
                if index.isMultiple(of: 2) {
                    session.reportBytesCompleted(UInt64(index + 1), total: UInt64(index + 1) * 2)
                } else {
                    session.requestCancel()
                    session.clearCancellationRequest()
                }
                let snapshot = session.snapshot()
                if snapshot.bytesTotal != snapshot.bytesCompleted * 2
                    || snapshot.progressFraction != (snapshot.bytesTotal == 0 ? 0 : 0.5)
                    || (snapshot.isCancellationRequested && snapshot.phase != .cancelling)
                {
                    violations.withLock { $0 += 1 }
                }
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(violations.withLock { $0 }, 0)
    }

    func testSnapshotCallbackAllowsWorkerReentry() async {
        let session = SZOperationSession()
        let finished = expectation(description: "snapshot callback finishes")
        defer { session.snapshotHandler = nil }
        session.snapshotHandler = { _ in
            XCTAssertTrue(Self.workerCompletes {
                session.snapshotHandler = nil
                session.reportBytesCompleted(1, total: 2)
                _ = session.snapshot()
            })
            finished.fulfill()
        }
        session.reportProgressFraction(0.5)
        await fulfillment(of: [finished], timeout: 5)
    }

    func testWorkerMemoryPromptRunsOnMainAndRestoresInteractionState() async {
        let session = SZOperationSession()
        let finished = expectation(description: "memory request finishes")
        defer { session.memoryLimitRequestHandler = nil }
        session.memoryLimitRequestHandler = { required, current, archive, file, testMode, remember in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual([required, current], [8 << 30, 4 << 30])
            XCTAssertEqual([archive, file], ["/archive.7z", "large.bin"])
            XCTAssertTrue(testMode && remember)
            XCTAssertTrue(Self.workerCompletes { XCTAssertTrue(session.isWaitingForUserInteraction) })
            return SZMemoryLimitPromptResult(saveLimit: true, skipArchive: false, rememberChoice: true, limitGB: 8)
        }
        DispatchQueue.global().async {
            let result = Self.requestMemoryLimit(from: session)
            XCTAssertEqual(result?.limitGB, 8)
            XCTAssertEqual(result?.saveLimit, true)
            XCTAssertEqual(result?.rememberChoice, true)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(session.isWaitingForUserInteraction)
    }

    func testMissingAndCancelledMemoryHandlersDoNotLeaveInteractionActive() {
        let session = SZOperationSession()
        XCTAssertNil(Self.requestMemoryLimit(from: session))
        XCTAssertFalse(session.isWaitingForUserInteraction)
        var prompts = 0
        defer { session.memoryLimitRequestHandler = nil }
        session.memoryLimitRequestHandler = { _, _, _, _, _, _ in
            prompts += 1
            XCTAssertTrue(Self.workerCompletes { session.requestCancel() })
            return SZMemoryLimitPromptResult(saveLimit: false, skipArchive: false, rememberChoice: false, limitGB: 8)
        }
        XCTAssertNil(Self.requestMemoryLimit(from: session))
        XCTAssertNil(Self.requestMemoryLimit(from: session))
        XCTAssertEqual(prompts, 1)
        XCTAssertFalse(session.isWaitingForUserInteraction)
    }

    func testWorkerChoiceAllowsReentryAndRestoresInteractionState() async {
        let session = SZOperationSession()
        let finished = expectation(description: "choice request finishes")
        defer { session.choiceRequestHandler = nil }
        session.choiceRequestHandler = { _ in
            XCTAssertTrue(Self.workerCompletes { XCTAssertTrue(session.isWaitingForUserInteraction) })
            return 0
        }
        DispatchQueue.global().async {
            let request = SZOperationChoiceRequest(style: .warning, title: "Continue?", message: nil,
                                                   buttonTitles: ["Continue", "Cancel"],
                                                   defaultButtonIndex: 0, cancelButtonIndex: 1)
            XCTAssertEqual(session.requestChoice(request), 0)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(session.isWaitingForUserInteraction)
    }

    func testDefaultFactoryConfiguresWorkerSessionsAndMissingFactoryHasNoUIHandlers() async {
        let original = SZOperationSession.defaultSessionFactory
        defer { SZOperationSession.defaultSessionFactory = original }
        AppOperationSessionFactory.install()
        let finished = expectation(description: "factory request finishes")
        DispatchQueue.global().async {
            let session = SZOperationSession.makeDefault()
            XCTAssertNotNil(session.passwordRequestHandler)
            XCTAssertNotNil(session.choiceRequestHandler)
            XCTAssertNotNil(session.updateEncryptionRequestHandler)
            XCTAssertNotNil(session.memoryLimitRequestHandler)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        SZOperationSession.defaultSessionFactory = nil
        let session = SZOperationSession.makeDefault()
        XCTAssertNil(session.passwordRequestHandler)
        XCTAssertNil(session.choiceRequestHandler)
        XCTAssertNil(session.updateEncryptionRequestHandler)
        XCTAssertNil(session.memoryLimitRequestHandler)
    }

    private nonisolated static func workerCompletes(_ work: @escaping @Sendable () -> Void) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            work()
            finished.signal()
        }
        return finished.wait(timeout: .now() + 2) == .success
    }

    private nonisolated static func requestMemoryLimit(from session: SZOperationSession) -> SZMemoryLimitPromptResult? {
        session.requestMemoryLimit(withRequiredBytes: 8 << 30, currentLimitBytes: 4 << 30,
                                   archivePath: "/archive.7z", filePath: "large.bin", testMode: true, showRemember: true)
    }
}
