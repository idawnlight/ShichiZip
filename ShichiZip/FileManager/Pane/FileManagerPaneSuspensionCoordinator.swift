import Cocoa

@MainActor
final class FileManagerPaneSuspensionCoordinator: NSObject {
    private let isViewLoaded: () -> Bool
    private let isInsideArchive: () -> Bool
    private let closeAllArchives: (Bool) async -> Bool
    private let prepareDirectoryForSuspension: () -> Void
    private let cancelPendingArchiveRefresh: () -> Void
    private let clearArchiveDisplayItems: () -> Void
    private let clearStatusText: () -> Void
    private let containerView: () -> NSView?
    private let scrollView: () -> NSView?
    private let currentDirectory: () -> URL
    private let canReactivate: () -> Bool
    private let loadDirectory: (URL, Bool) -> Bool

    private var suspendedOverlay: NSView?
    private(set) var isSuspended = false

    init(isViewLoaded: @escaping () -> Bool,
         isInsideArchive: @escaping () -> Bool,
         closeAllArchives: @escaping (Bool) async -> Bool,
         prepareDirectoryForSuspension: @escaping () -> Void,
         cancelPendingArchiveRefresh: @escaping () -> Void,
         clearArchiveDisplayItems: @escaping () -> Void,
         clearStatusText: @escaping () -> Void,
         containerView: @escaping () -> NSView?,
         scrollView: @escaping () -> NSView?,
         currentDirectory: @escaping () -> URL,
         canReactivate: @escaping () -> Bool = { true },
         loadDirectory: @escaping (URL, Bool) -> Bool)
    {
        self.isViewLoaded = isViewLoaded
        self.isInsideArchive = isInsideArchive
        self.closeAllArchives = closeAllArchives
        self.prepareDirectoryForSuspension = prepareDirectoryForSuspension
        self.cancelPendingArchiveRefresh = cancelPendingArchiveRefresh
        self.clearArchiveDisplayItems = clearArchiveDisplayItems
        self.clearStatusText = clearStatusText
        self.containerView = containerView
        self.scrollView = scrollView
        self.currentDirectory = currentDirectory
        self.canReactivate = canReactivate
        self.loadDirectory = loadDirectory
    }

    @discardableResult
    func prepareForClose(showError: Bool = true) async -> Bool {
        guard isInsideArchive() else {
            return true
        }

        let didClose = await closeAllArchives(showError)
        if didClose, isViewLoaded() {
            enterSuspendedState()
        }
        return didClose
    }

    @discardableResult
    func prepareForDeactivation(showError: Bool = true) async -> Bool {
        guard await prepareForClose(showError: showError) else {
            return false
        }

        if isViewLoaded() {
            enterSuspendedState()
        }

        return true
    }

    func prepareEmptyPaneForDeactivation() {
        precondition(!isInsideArchive(),
                     "Empty-pane deactivation cannot close an archive")
        if isViewLoaded() {
            enterSuspendedState()
        }
    }

    @discardableResult
    func reactivateIfSuspended() -> Bool {
        guard isSuspended else { return true }
        return reactivatePane()
    }

    func closeDirectory() async {
        guard !isSuspended else { return }
        if isInsideArchive() {
            _ = await closeAllArchives(true)
        }
        if !isInsideArchive(), isViewLoaded() {
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
        guard !isSuspended else { return }
        isSuspended = true

        prepareDirectoryForSuspension()
        cancelPendingArchiveRefresh()
        clearArchiveDisplayItems()
        clearStatusText()

        guard let containerView = containerView(),
              let scrollView = scrollView()
        else {
            return
        }

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
        guard canReactivate() else { return false }
        guard isSuspended else { return true }
        let didLoad = loadDirectory(currentDirectory(), true)
        if didLoad {
            clearSuspendedState()
        }
        return didLoad
    }
}
