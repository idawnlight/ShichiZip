import XCTest
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

@MainActor
final class OperationProgressModelTests: XCTestCase {
    func testDisplayTitleUsesOneLineAndOnlyTransientPhaseOverridesOperation() {
        let session = SZOperationSession()
        let model = OperationProgressModel(
            operationTitle: SZL10n.string("progress.updating"),
            initialFileName: nil,
            session: session,
        )
        session.reportPhase(.updating)
        model.apply(session.snapshot())

        XCTAssertEqual(model.displayTitle,
                       SZL10n.string("progress.updating"))

        session.reportPhase(.scanning)
        model.apply(session.snapshot())
        XCTAssertEqual(model.displayTitle,
                       SZL10n.string("progress.scanning"))
    }

    func testModelSwitchesFromIndeterminateToDeterminateProgress() {
        let session = SZOperationSession()
        let model = OperationProgressModel(operationTitle: "Compressing",
                                           initialFileName: nil,
                                           session: session)

        XCTAssertNil(model.progressValue)
        session.reportBytesCompleted(25, total: 100)
        model.apply(session.snapshot())

        XCTAssertEqual(model.progressValue, 0.25)
        XCTAssertNotNil(model.bytesText)
    }

    func testModelCalculatesSpeedAndRemainingTimeWithInjectedClock() throws {
        var currentTime: TimeInterval = 10
        let session = SZOperationSession()
        let model = OperationProgressModel(operationTitle: "Compressing",
                                           initialFileName: nil,
                                           session: session,
                                           now: { currentTime })

        session.reportBytesCompleted(0, total: 1_000)
        model.apply(session.snapshot())
        currentTime = 12
        session.reportBytesCompleted(500, total: 1_000)
        model.apply(session.snapshot())

        XCTAssertEqual(try XCTUnwrap(model.speedBytesPerSecond),
                       250,
                       accuracy: 0.001)
        XCTAssertNotNil(model.speedText)
        XCTAssertNotNil(model.elapsedDuration())
    }

    func testModelCoalescesRoutineProgressIntoLatestScheduledSnapshot() throws {
        var scheduledUpdate: (() -> Void)?
        let session = SZOperationSession()
        let model = OperationProgressModel(
            operationTitle: "Compressing",
            initialFileName: nil,
            session: session,
            snapshotUpdateScheduler: { action in
                var isCancelled = false
                scheduledUpdate = {
                    guard !isCancelled else { return }
                    action()
                }
                return {
                    isCancelled = true
                }
            },
        )

        session.reportBytesCompleted(10, total: 100)
        XCTAssertFalse(model.receive(session.snapshot()))
        session.reportBytesCompleted(75, total: 100)
        XCTAssertFalse(model.receive(session.snapshot()))

        XCTAssertNil(model.progressValue)
        try XCTUnwrap(scheduledUpdate)()
        XCTAssertEqual(model.progressValue, 0.75)
        XCTAssertEqual(model.snapshot.bytesCompleted, 75)
    }

    func testModelAppliesCancellationWithoutWaitingForScheduledProgress() throws {
        var scheduledUpdate: (() -> Void)?
        let session = SZOperationSession()
        let model = OperationProgressModel(
            operationTitle: "Extracting",
            initialFileName: nil,
            session: session,
            snapshotUpdateScheduler: { action in
                var isCancelled = false
                scheduledUpdate = {
                    guard !isCancelled else { return }
                    action()
                }
                return {
                    isCancelled = true
                }
            },
        )

        session.reportProgressFraction(0.5)
        XCTAssertFalse(model.receive(session.snapshot()))
        let staleScheduledUpdate = try XCTUnwrap(scheduledUpdate)

        session.requestCancel()
        XCTAssertTrue(model.receive(session.snapshot()))
        XCTAssertEqual(model.snapshot.phase, .cancelling)
        XCTAssertTrue(model.snapshot.isCancellationRequested)

        staleScheduledUpdate()
        XCTAssertEqual(model.snapshot.phase, .cancelling)
    }

    func testModelEntersTerminalWarningState() {
        let session = SZOperationSession()
        let model = OperationProgressModel(operationTitle: "Compressing",
                                           initialFileName: nil,
                                           session: session)
        session.report(
            SZArchiveUpdateIssue(stage: .open,
                                 path: "/tmp/missing",
                                 errorCode: Int32(ENOENT),
                                 message: "No such file"),
        )

        model.complete(updateOutcome: nil)

        XCTAssertTrue(model.isTerminalWarning)
        XCTAssertFalse(model.isCancelEnabled)
        XCTAssertEqual(model.snapshot.totalIssueCount, 1)
    }

    func testExplicitOutcomeCanDriveTerminalWarningWithoutLiveIssueDelivery() {
        let session = SZOperationSession()
        let model = OperationProgressModel(operationTitle: "Compressing",
                                           initialFileName: nil,
                                           session: session)
        let issue = SZArchiveUpdateIssue(stage: .scan,
                                         path: "/tmp/missing",
                                         errorCode: Int32(ENOENT),
                                         message: "No such file")
        let outcome = SZArchiveUpdateOutcome(completion: .completedWithWarnings,
                                             archiveCommitted: true,
                                             issues: [issue],
                                             totalIssueCount: 1,
                                             issuesTruncated: false)

        model.complete(updateOutcome: outcome)

        XCTAssertTrue(model.isTerminalWarning)
        XCTAssertEqual(model.totalIssueCount, 1)
        XCTAssertEqual(model.displayedIssues.first?.path, "/tmp/missing")
    }

    func testCancelRequestsSessionImmediately() {
        let session = SZOperationSession()
        let model = OperationProgressModel(operationTitle: "Extracting",
                                           initialFileName: nil,
                                           session: session)

        model.requestCancel()

        XCTAssertTrue(session.shouldCancel())
        XCTAssertEqual(model.snapshot.phase, .cancelling)
        XCTAssertFalse(model.isCancelEnabled)
    }

    func testLocalizedLabelValueRespectsColonWidth() {
        XCTAssertEqual(
            SZL10n.labelValue(label: "Speed:", value: "1 MB/s"),
            "Speed: 1 MB/s",
        )
        XCTAssertEqual(
            SZL10n.labelValue(label: "速度：", value: "1 MB/s"),
            "速度：1 MB/s",
        )
        XCTAssertEqual(
            SZL10n.labelValue(label: "速度：  ", value: "1 MB/s"),
            "速度：1 MB/s",
        )
        XCTAssertEqual(
            SZL10n.labelValue(label: "速度:", value: "1 MB/s"),
            "速度: 1 MB/s",
        )
    }

    func testFinalizingDisablesCancellation() {
        let session = SZOperationSession()
        let model = OperationProgressModel(operationTitle: "Updating",
                                           initialFileName: nil,
                                           session: session)
        session.beginFinalizing()
        model.apply(session.snapshot())

        XCTAssertFalse(model.isCancelEnabled)
        XCTAssertEqual(model.snapshot.phase, .finalizing)
    }
}
