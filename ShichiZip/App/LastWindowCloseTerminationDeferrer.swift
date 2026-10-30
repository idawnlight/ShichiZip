import AppKit

@MainActor
final class LastWindowCloseTerminationDeferrer: NSObject {
    private weak var mostRecentClosingWindow: NSWindow?
    private var isObservingWindowWillClose = false
    private var pendingAnimationWindow: NSWindow?
    private var animationTimeoutTask: Task<Void, Never>?

    private let notificationCenter: NotificationCenter
    private let shouldTerminate: @MainActor () -> Bool
    private let terminate: @MainActor () -> Void

    /// Undocumented AppKit notification posted after macOS 26's window-close animation orders the window off-screen.
    private static let windowDidOrderOffScreenAndFinishAnimatingNotification =
        Notification.Name("NSWindowDidOrderOffScreenAndFinishAnimatingNotification")

    init(notificationCenter: NotificationCenter = .default,
         shouldTerminate: @escaping @MainActor () -> Bool,
         terminate: @escaping @MainActor () -> Void)
    {
        self.notificationCenter = notificationCenter
        self.shouldTerminate = shouldTerminate
        self.terminate = terminate
    }

    func startObservingClosingWindows() {
        guard !isObservingWindowWillClose else { return }
        notificationCenter.addObserver(self,
                                       selector: #selector(windowWillClose(_:)),
                                       name: NSWindow.willCloseNotification,
                                       object: nil)
        isObservingWindowWillClose = true
    }

    /// Returns true when termination is deferred until the close animation finishes or times out.
    /// Returns false when there is no visible closing window to wait for, so the caller
    /// should allow immediate termination.
    func deferTerminationUntilCloseAnimationFinishes() -> Bool {
        clearPendingAnimationObserver()

        guard let closingWindow = mostRecentClosingWindow else {
            return false
        }
        pendingAnimationWindow = closingWindow
        mostRecentClosingWindow = nil

        // Retain and filter to the window that triggered AppKit's last-window-close decision
        // so unrelated order-off animations cannot complete the pending termination.
        notificationCenter.addObserver(self,
                                       selector: #selector(windowDidOrderOffScreenAndFinishAnimating(_:)),
                                       name: Self.windowDidOrderOffScreenAndFinishAnimatingNotification,
                                       object: pendingAnimationWindow)
        animationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.terminateIfStillNeeded()
        }
        return true
    }

    func stop() {
        clearPendingAnimationObserver()
        if isObservingWindowWillClose {
            notificationCenter.removeObserver(self,
                                              name: NSWindow.willCloseNotification,
                                              object: nil)
            isObservingWindowWillClose = false
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard !Self.shouldIgnoreCloseAnimationWindow(window) else {
            // Do not let an older close candidate drive a newer last-window-close
            // decision when AppKit's latest notification is already off-screen.
            mostRecentClosingWindow = nil
            return
        }

        mostRecentClosingWindow = window
    }

    @objc private func windowDidOrderOffScreenAndFinishAnimating(_: Notification) {
        terminateIfStillNeeded()
    }

    private func terminateIfStillNeeded() {
        clearPendingAnimationObserver()
        guard shouldTerminate() else { return }
        terminate()
    }

    private func clearPendingAnimationObserver() {
        animationTimeoutTask?.cancel()
        animationTimeoutTask = nil
        guard let window = pendingAnimationWindow else { return }
        notificationCenter.removeObserver(self,
                                          name: Self.windowDidOrderOffScreenAndFinishAnimatingNotification,
                                          object: window)
        pendingAnimationWindow = nil
    }

    private static func shouldIgnoreCloseAnimationWindow(_ window: NSWindow) -> Bool {
        // macOS can post a close notification for an already invisible private
        // window, such as TUINSWindow after modal cancellation. Such windows do
        // not emit the private close-animation-finished notification, so waiting
        // on them prevents quit-on-last-close.
        !window.isVisible
    }
}
