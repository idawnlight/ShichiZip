// OperationSessionProgressThrottlingTests.swift
//
// Covers progress throttling and terminal update delivery in
// SZOperationSession.

import AppKit
import XCTest

@MainActor
final class OperationSessionChoiceRequestTests: XCTestCase {
    func testDialogKeyboardRolesDoNotDependOnButtonOrderOrTitle() throws {
        let controller = SZModalDialogController(
            style: .warning,
            title: "Replace?",
            message: nil,
            actions: [
                SZDialogAction(title: "Cancel", roles: []),
                SZDialogAction(title: "Proceed", roles: .default),
                SZDialogAction(title: "Localized Abort", roles: .cancel),
            ],
            accessoryView: nil,
            preferredFirstResponder: nil,
        )
        let window = try XCTUnwrap(controller.window)
        let defaultButton = try XCTUnwrap(button(titled: "Proceed", in: window))
        XCTAssertTrue(window.defaultButtonCell === defaultButton.cell)

        var selectedIndices: [Int] = []
        controller.shouldFinishHandler = { index in
            selectedIndices.append(index)
            return false
        }

        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent(character: "\r", keyCode: 36, window: window)))
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent(character: "\u{1b}", keyCode: 53, window: window)))
        XCTAssertEqual(selectedIndices, [1, 2])
    }

    func testSingleActionCanHandleReturnAndEscape() throws {
        let controller = SZModalDialogController(
            style: .informational,
            title: "Complete",
            message: nil,
            actions: [
                SZDialogAction(title: "OK", roles: [.default, .cancel]),
            ],
            accessoryView: nil,
            preferredFirstResponder: nil,
        )
        let window = try XCTUnwrap(controller.window)
        let button = try XCTUnwrap(button(titled: "OK", in: window))
        XCTAssertTrue(window.defaultButtonCell === button.cell)

        var selectedIndices: [Int] = []
        controller.shouldFinishHandler = { index in
            selectedIndices.append(index)
            return false
        }

        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent(character: "\r", keyCode: 36, window: window)))
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent(character: "\u{1b}", keyCode: 53, window: window)))
        XCTAssertEqual(selectedIndices, [0, 0])
    }

    func testMissingOrInvalidChoiceHandlerResponseFallsBackToCancel() {
        let request = SZOperationChoiceRequest(
            style: .warning,
            title: "Replace?",
            message: nil,
            buttonTitles: ["Yes", "No", "Cancel"],
            defaultButtonIndex: 0,
            cancelButtonIndex: 2,
        )
        let session = SZOperationSession()

        XCTAssertEqual(session.requestChoice(request), 2)

        session.choiceRequestHandler = { _ in 99 }
        XCTAssertEqual(session.requestChoice(request), 2)
    }

    func testChoiceHandlerReceivesExplicitKeyboardSemantics() {
        let request = SZOperationChoiceRequest(
            style: .critical,
            title: "Question",
            message: "Details",
            buttonTitles: ["Continue", "Stop"],
            defaultButtonIndex: 0,
            cancelButtonIndex: 1,
        )
        let session = SZOperationSession()
        session.choiceRequestHandler = { receivedRequest in
            XCTAssertTrue(receivedRequest === request)
            XCTAssertEqual(receivedRequest.defaultButtonIndex, 0)
            XCTAssertEqual(receivedRequest.cancelButtonIndex, 1)
            return receivedRequest.defaultButtonIndex
        }

        XCTAssertEqual(session.requestChoice(request), 0)
    }

    private func button(titled title: String, in window: NSWindow) -> NSButton? {
        guard let rootView = window.contentViewController?.view else { return nil }
        return button(titled: title, in: rootView)
    }

    private func button(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let button = button(titled: title, in: subview) {
                return button
            }
        }
        return nil
    }

    private func keyEvent(character: String,
                          keyCode: UInt16,
                          window: NSWindow) -> NSEvent
    {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: [],
                         timestamp: 0,
                         windowNumber: window.windowNumber,
                         context: nil,
                         characters: character,
                         charactersIgnoringModifiers: character,
                         isARepeat: false,
                         keyCode: keyCode)!
    }
}

@MainActor
final class OperationSessionProgressThrottlingTests: XCTestCase {
    func testRapidReportsAreCoalescedIntoLatestSnapshot() {
        let session = SZOperationSession()
        var snapshots: [SZOperationSnapshot] = []
        session.snapshotHandler = { snapshots.append($0) }

        for index in 1 ... 100 {
            session.reportCurrentFileName("file-\(index).txt")
            session.reportProgressFraction(Double(index) / 100)
        }

        XCTAssertEqual(session.currentFileName, "file-100.txt")
        drainMainQueue(for: 0.12)

        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertLessThanOrEqual(snapshots.count, 10)
        XCTAssertEqual(snapshots.last?.currentFileName, "file-100.txt")
        XCTAssertEqual(snapshots.last?.progressFraction, 1)
    }

    func testFractionIsClampedInSnapshot() {
        let session = SZOperationSession()
        session.reportProgressFraction(-1)
        XCTAssertEqual(session.snapshot().progressFraction, 0)

        session.reportProgressFraction(42)
        XCTAssertEqual(session.snapshot().progressFraction, 1)
    }

    func testRapidByteReportsDeliverTerminalState() {
        let session = SZOperationSession()
        var snapshots: [SZOperationSnapshot] = []
        session.snapshotHandler = { snapshots.append($0) }

        let total: UInt64 = 1000
        for completed in 0 ... total {
            session.reportBytesCompleted(completed, total: total)
        }
        drainMainQueue(for: 0.12)

        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertLessThanOrEqual(snapshots.count, 15)
        XCTAssertEqual(snapshots.last?.bytesCompleted, total)
        XCTAssertEqual(snapshots.last?.bytesTotal, total)
        XCTAssertEqual(snapshots.last?.progressFraction, 1)
    }

    func testSnapshotAfterThrottleWindowIsDelivered() {
        let session = SZOperationSession()
        var fractions: [Double] = []
        session.snapshotHandler = { fractions.append($0.progressFraction) }

        session.reportProgressFraction(0.1)
        drainMainQueue()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.07))
        session.reportProgressFraction(0.3)
        drainMainQueue()

        XCTAssertTrue(fractions.contains(0.1))
        XCTAssertTrue(fractions.contains(0.3))
    }

    func testCancellationAndFinalizationAreExplicitSnapshotStates() {
        let session = SZOperationSession()
        session.requestCancel()

        var snapshot = session.snapshot()
        XCTAssertTrue(snapshot.isCancellationRequested)
        XCTAssertTrue(snapshot.isCancellationAllowed)
        XCTAssertEqual(snapshot.phase, .cancelling)

        session.beginFinalizing()
        snapshot = session.snapshot()
        XCTAssertFalse(snapshot.isCancellationRequested)
        XCTAssertFalse(snapshot.isCancellationAllowed)
        XCTAssertEqual(snapshot.phase, .finalizing)

        session.requestCancel()
        XCTAssertFalse(session.shouldCancel())
    }

    func testIssueDetailsAreBoundedButTotalIsPreserved() {
        let session = SZOperationSession()
        for index in 0 ..< 300 {
            session.report(
                SZArchiveUpdateIssue(
                    stage: .scan,
                    path: "/tmp/input-\(index)",
                    errorCode: Int32(EACCES),
                    message: "Permission denied",
                ),
            )
        }

        let snapshot = session.snapshot()
        XCTAssertEqual(snapshot.totalIssueCount, 300)
        XCTAssertEqual(snapshot.issues.count, 256)
        XCTAssertTrue(snapshot.areIssuesTruncated)
    }

    func testClearingSnapshotHandlerStopsFurtherDelivery() {
        let session = SZOperationSession()
        var snapshots: [SZOperationSnapshot] = []
        session.snapshotHandler = { snapshots.append($0) }
        session.reportProgressFraction(0.1)
        drainMainQueue()

        session.snapshotHandler = nil
        let deliveredBeforeClear = snapshots.count
        session.reportProgressFraction(0.8)
        drainMainQueue(for: 0.08)

        XCTAssertEqual(snapshots.count, deliveredBeforeClear)
        XCTAssertEqual(session.snapshot().progressFraction, 0.8)
    }

    private func drainMainQueue(for seconds: TimeInterval = 0.02) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}
