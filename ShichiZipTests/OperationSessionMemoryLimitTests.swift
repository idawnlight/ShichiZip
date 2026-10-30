import Foundation
import XCTest

#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

@MainActor
final class OperationSessionMemoryLimitTests: XCTestCase {
    func testMissingHandlerCancelsWithoutEnteringInteraction() {
        let session = SZOperationSession()

        XCTAssertNil(requestMemoryLimit(from: session))
        XCTAssertFalse(session.isWaitingForUserInteraction)
    }

    func testWorkerRequestRunsHandlerOnMainWhileWaitingForInteraction() async {
        let session = SZOperationSession()
        defer { session.memoryLimitRequestHandler = nil }
        session.memoryLimitRequestHandler = { requiredBytes, currentLimitBytes, archivePath, filePath, testMode, showRemember in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(session.snapshot().isWaitingForUserInteraction)
            XCTAssertEqual(requiredBytes, 8 << 30)
            XCTAssertEqual(currentLimitBytes, 4 << 30)
            XCTAssertEqual(archivePath, "/archive.7z")
            XCTAssertEqual(filePath, "large.bin")
            XCTAssertTrue(testMode)
            XCTAssertTrue(showRemember)

            return SZMemoryLimitPromptResult(saveLimit: true,
                                             skipArchive: false,
                                             rememberChoice: true,
                                             limitGB: 8)
        }

        let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let result = session.requestMemoryLimit(withRequiredBytes: 8 << 30,
                                                        currentLimitBytes: 4 << 30,
                                                        archivePath: "/archive.7z",
                                                        filePath: "large.bin",
                                                        testMode: true,
                                                        showRemember: true)
                continuation.resume(returning: result?.limitGB == 8
                    && result?.saveLimit == true
                    && result?.rememberChoice == true)
            }
        }

        XCTAssertTrue(accepted)
        XCTAssertFalse(session.isWaitingForUserInteraction)
    }

    func testCancellationDiscardsSelectionAndSkipsFurtherPrompts() {
        let session = SZOperationSession()
        defer { session.memoryLimitRequestHandler = nil }
        var promptCount = 0
        session.memoryLimitRequestHandler = { _, _, _, _, _, _ in
            promptCount += 1
            session.requestCancel()
            return SZMemoryLimitPromptResult(saveLimit: false,
                                             skipArchive: false,
                                             rememberChoice: false,
                                             limitGB: 8)
        }

        XCTAssertNil(requestMemoryLimit(from: session))
        XCTAssertNil(requestMemoryLimit(from: session))
        XCTAssertEqual(promptCount, 1)
        XCTAssertFalse(session.isWaitingForUserInteraction)
    }

    private func requestMemoryLimit(from session: SZOperationSession) -> SZMemoryLimitPromptResult? {
        session.requestMemoryLimit(withRequiredBytes: 8 << 30,
                                   currentLimitBytes: 4 << 30,
                                   archivePath: nil,
                                   filePath: nil,
                                   testMode: false,
                                   showRemember: false)
    }
}

@MainActor
final class OperationSessionFactoryTests: XCTestCase {
    func testAppFactoryCreatesConfiguredSessionFromWorkerWithoutPresentingUI() async {
        let originalFactory = SZOperationSession.defaultSessionFactory
        defer { SZOperationSession.defaultSessionFactory = originalFactory }
        AppOperationSessionFactory.install()

        let configuredOnWorker = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let session = SZOperationSession.makeDefault()
                continuation.resume(returning: !Thread.isMainThread
                    && session.passwordRequestHandler != nil
                    && session.choiceRequestHandler != nil
                    && session.updateEncryptionRequestHandler != nil
                    && session.memoryLimitRequestHandler != nil)
            }
        }

        XCTAssertTrue(configuredOnWorker)
    }

    func testMissingFactoryProducesSessionsWithoutUIHandlers() {
        let originalFactory = SZOperationSession.defaultSessionFactory
        defer { SZOperationSession.defaultSessionFactory = originalFactory }
        SZOperationSession.defaultSessionFactory = nil

        let session = SZOperationSession.makeDefault()

        XCTAssertNil(session.passwordRequestHandler)
        XCTAssertNil(session.choiceRequestHandler)
        XCTAssertNil(session.updateEncryptionRequestHandler)
        XCTAssertNil(session.memoryLimitRequestHandler)
    }

    func testInjectedFactoryConfiguresIndependentSessions() {
        let originalFactory = SZOperationSession.defaultSessionFactory
        defer { SZOperationSession.defaultSessionFactory = originalFactory }
        SZOperationSession.defaultSessionFactory = {
            let session = SZOperationSession()
            session.memoryLimitRequestHandler = { _, _, _, _, _, _ in
                SZMemoryLimitPromptResult(saveLimit: false,
                                          skipArchive: false,
                                          rememberChoice: false,
                                          limitGB: 8)
            }
            return session
        }

        let first = SZOperationSession.makeDefault()
        let second = SZOperationSession.makeDefault()

        XCTAssertFalse(first === second)
        XCTAssertNotNil(first.memoryLimitRequestHandler)
        XCTAssertNotNil(second.memoryLimitRequestHandler)
    }
}
