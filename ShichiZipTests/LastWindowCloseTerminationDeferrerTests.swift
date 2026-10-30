import AppKit
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class LastWindowCloseTerminationDeferrerTests: XCTestCase {
    private static let animationFinishedNotification =
        Notification.Name("NSWindowDidOrderOffScreenAndFinishAnimatingNotification")

    func testInvisibleCloseNotificationDoesNotDeferTermination() {
        let notificationCenter = NotificationCenter()
        var didTerminate = false
        let deferrer = LastWindowCloseTerminationDeferrer(notificationCenter: notificationCenter,
                                                          shouldTerminate: { true },
                                                          terminate: { didTerminate = true })
        deferrer.startObservingClosingWindows()

        let window = VisibilityTestWindow(isVisible: false)
        notificationCenter.post(name: NSWindow.willCloseNotification, object: window)

        XCTAssertFalse(deferrer.deferTerminationUntilCloseAnimationFinishes())
        XCTAssertFalse(didTerminate)
    }

    func testInvisibleCloseNotificationClearsStaleVisibleCandidate() {
        let notificationCenter = NotificationCenter()
        let deferrer = LastWindowCloseTerminationDeferrer(notificationCenter: notificationCenter,
                                                          shouldTerminate: { true },
                                                          terminate: {})
        deferrer.startObservingClosingWindows()

        let visibleWindow = VisibilityTestWindow(isVisible: true)
        let invisibleWindow = VisibilityTestWindow(isVisible: false)
        notificationCenter.post(name: NSWindow.willCloseNotification, object: visibleWindow)
        notificationCenter.post(name: NSWindow.willCloseNotification, object: invisibleWindow)

        XCTAssertFalse(deferrer.deferTerminationUntilCloseAnimationFinishes())
    }

    func testMissingAnimationNotificationFallsBackToTermination() async {
        let notificationCenter = NotificationCenter()
        let terminated = expectation(description: "termination after animation timeout")
        let deferrer = LastWindowCloseTerminationDeferrer(notificationCenter: notificationCenter,
                                                          shouldTerminate: { true },
                                                          terminate: { terminated.fulfill() })
        defer { deferrer.stop() }
        deferrer.startObservingClosingWindows()
        let window = VisibilityTestWindow(isVisible: true)
        notificationCenter.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertTrue(deferrer.deferTerminationUntilCloseAnimationFinishes())
        await fulfillment(of: [terminated], timeout: 2)
    }

    func testVisibleCloseDefersUntilAnimationFinishedNotification() {
        let notificationCenter = NotificationCenter()
        var didTerminate = false
        let deferrer = LastWindowCloseTerminationDeferrer(notificationCenter: notificationCenter,
                                                          shouldTerminate: { true },
                                                          terminate: { didTerminate = true })
        deferrer.startObservingClosingWindows()

        let window = VisibilityTestWindow(isVisible: true)
        notificationCenter.post(name: NSWindow.willCloseNotification, object: window)

        XCTAssertTrue(deferrer.deferTerminationUntilCloseAnimationFinishes())
        XCTAssertFalse(didTerminate)

        notificationCenter.post(name: Self.animationFinishedNotification, object: window)

        XCTAssertTrue(didTerminate)
    }
}

private final class VisibilityTestWindow: NSWindow {
    private let forcedIsVisible: Bool

    init(isVisible: Bool) {
        forcedIsVisible = isVisible
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.titled],
                   backing: .buffered,
                   defer: false)
    }

    override var isVisible: Bool {
        forcedIsVisible
    }
}
