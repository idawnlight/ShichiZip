import Cocoa

@MainActor
protocol FileManagerPaneSuspensionHost: AnyObject {
    var isViewLoaded: Bool { get }
    var isInsideArchive: Bool { get }
    var suspensionOverlayViews: (container: NSView, content: NSView)? { get }

    func closeAllArchives(showError: Bool) async -> Bool
    func preparePaneForSuspension()
    func reloadSuspendedDirectory() -> Bool
}

@MainActor
final class FileManagerPaneSuspensionCoordinator: NSObject {
    private weak var host: (any FileManagerPaneSuspensionHost)?
    private var suspendedOverlay: NSView?
    private(set) var isSuspended = false

    init(host: any FileManagerPaneSuspensionHost) {
        self.host = host
    }

    @discardableResult
    func prepareForClose(showError: Bool = true) async -> Bool {
        guard let host else { return false }
        guard host.isInsideArchive else { return true }

        let didClose = await host.closeAllArchives(showError: showError)
        if didClose, host.isViewLoaded {
            enterSuspendedState()
        }
        return didClose
    }

    @discardableResult
    func prepareForDeactivation(showError: Bool = true) async -> Bool {
        guard await prepareForClose(showError: showError) else {
            return false
        }

        if host?.isViewLoaded == true {
            enterSuspendedState()
        }

        return true
    }

    func prepareEmptyPaneForDeactivation() {
        guard let host else { return }
        precondition(!host.isInsideArchive,
                     "Empty-pane deactivation cannot close an archive")
        if host.isViewLoaded {
            enterSuspendedState()
        }
    }

    @discardableResult
    func reactivateIfSuspended() -> Bool {
        guard isSuspended else { return true }
        return reactivatePane()
    }

    func closeDirectory() async {
        guard let host, !isSuspended else { return }
        if host.isInsideArchive {
            _ = await host.closeAllArchives(showError: true)
        }
        if !host.isInsideArchive, host.isViewLoaded {
            enterSuspendedState()
        }
    }

    func clearSuspendedState() {
        guard isSuspended else { return }
        isSuspended = false
        suspendedOverlay?.removeFromSuperview()
        suspendedOverlay = nil
    }

    private func enterSuspendedState() {
        guard let host, !isSuspended else { return }
        isSuspended = true
        host.preparePaneForSuspension()

        guard let (containerView, scrollView) = host.suspensionOverlayViews else { return }

        let overlay = makeSuspendedOverlay()
        containerView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])

        suspendedOverlay = overlay
    }

    private func makeSuspendedOverlay() -> NSView {
        let overlay = NSView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        overlay.setAccessibilityIdentifier("fileManager.suspendedOverlay")

        let label = NSTextField(labelWithString: SZL10n.string("app.fileManager.suspendedDescription"))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        overlay.addSubview(label)

        let button = NSButton(title: SZL10n.string("app.fileManager.reactivatePane"),
                              target: self,
                              action: #selector(reactivatePaneClicked(_:)))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.setAccessibilityIdentifier("fileManager.reactivateButton")
        overlay.addSubview(button)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -12),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),
            button.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: 12),
        ])

        return overlay
    }

    @objc private func reactivatePaneClicked(_: Any?) {
        reactivatePane()
    }

    @discardableResult
    private func reactivatePane() -> Bool {
        guard isSuspended else { return true }
        let didLoad = host?.reloadSuspendedDirectory() == true
        if didLoad {
            clearSuspendedState()
        }
        return didLoad
    }
}
