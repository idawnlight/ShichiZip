import Cocoa

/// Launch-open auto-extract HUD. Shows only when the default action is extract;
/// otherwise external opens go straight to the file manager.
@MainActor
final class LaunchOpenHUDController: NSObject {
    typealias Handler = @MainActor @Sendable () -> Void
    typealias AsyncHandler = @MainActor @Sendable () async -> Void

    /// Single live HUD; subsequent opens merge into it.
    private static var activeController: LaunchOpenHUDController?

    static var configuredDelaySeconds: TimeInterval {
        SZSettings.launchOpenDelaySeconds
    }

    /// `holdAlive`/`release` bracket the delayed open so quit-on-last-window
    /// cannot terminate the app during the cancel window or extraction.
    static func present(urls: [URL],
                        holdAlive: Handler = {},
                        release: @escaping Handler = {},
                        proceed: @escaping AsyncHandler)
    {
        let seconds = configuredDelaySeconds
        // Show contents bypasses the HUD.
        let defaultAction = SZSettings.launchOpenDefaultAction
        guard defaultAction == .extract, seconds > 0, !urls.isEmpty else {
            holdAlive()
            runDefaultAction(urls: urls, proceed: proceed, release: release)
            return
        }

        holdAlive()
        if let existing = activeController {
            existing.merge(urls: urls, proceed: proceed, release: release)
            return
        }
        let controller = LaunchOpenHUDController(urls: urls, seconds: seconds)
        activeController = controller
        controller.show(proceed: proceed, release: release)
    }

    /// No-HUD path: show contents immediately, or extract while holding alive.
    @MainActor
    private static func runDefaultAction(urls: [URL],
                                         proceed: @escaping AsyncHandler,
                                         release: @escaping Handler)
    {
        switch SZSettings.launchOpenDefaultAction {
        case .browse:
            Task { @MainActor in
                await proceed()
                release()
            }
        case .extract:
            let reveal = SZSettings.launchOpenRevealAfterExtract
            runSmartExtract(urls: urls,
                            revealDestination: reveal,
                            completion: release)
        }
    }

    @MainActor
    private static func runSmartExtract(urls: [URL],
                                        revealDestination: Bool,
                                        completion: @escaping Handler)
    {
        guard !urls.isEmpty else {
            completion()
            return
        }

        let defaults = ExtractDialogController.quickActionDefaults()
        var remaining = urls.count

        func finishOne() {
            remaining -= 1
            if remaining == 0 {
                completion()
            }
        }

        for url in urls {
            SmartExtractRunner.extract(archiveURL: url,
                                       defaults: defaults,
                                       parentWindow: nil,
                                       shouldRevealDestination: { revealDestination })
            { _ in
                finishOne()
            }
        }
    }

    /// Fold another open request into the live HUD.
    private func merge(urls newURLs: [URL],
                       proceed: @escaping AsyncHandler,
                       release: @escaping Handler)
    {
        urls.append(contentsOf: newURLs)
        proceedHandlers.append(proceed)
        releaseHandlers.append(release)
        refreshTitle()
    }

    // MARK: - Instance

    private var urls: [URL]
    private let totalSeconds: TimeInterval
    private let browseModifier: LaunchOpenBrowseModifier
    private let revealAfterExtract: Bool
    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var countdownLabel: NSTextField?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var lastGlobalFlags: NSEvent.ModifierFlags = []
    private var timer: Timer?
    private var startDate: Date?
    private var didFinish = false
    private var proceedHandlers: [AsyncHandler] = []
    private var releaseHandlers: [Handler] = []

    private init(urls: [URL], seconds: TimeInterval) {
        self.urls = urls
        totalSeconds = seconds
        browseModifier = SZSettings.launchOpenBrowseModifier
        revealAfterExtract = SZSettings.launchOpenRevealAfterExtract
        super.init()
    }

    private func show(proceed: @escaping AsyncHandler, release: @escaping Handler) {
        proceedHandlers.append(proceed)
        releaseHandlers.append(release)

        let panel = makePanel()
        self.panel = panel
        positionPanel(panel)
        panel.orderFrontRegardless()

        installKeyMonitor()
        startCountdown()
    }

    private func makePanel() -> NSPanel {
        let horizontalPadding: CGFloat = 18
        let verticalPadding: CGFloat = 16
        let iconTextSpacing: CGFloat = 14
        let cornerRadius: CGFloat = 14
        let preferredWidth: CGFloat = 460

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: preferredWidth, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false

        // `maskImage` gives AppKit the real rounded window shape for shadow
        // and hit-testing.
        let blur = NSVisualEffectView()
        blur.setAccessibilityIdentifier("launchOpenHUD")
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.roundedMaskImage(cornerRadius: cornerRadius)
        blur.wantsLayer = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.cgColor
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(iconView)

        let title = NSTextField(labelWithString: titleString())
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        title.isSelectable = false
        title.setAccessibilityIdentifier("launchOpenHUD.title")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel = title

        let subtitle = NSTextField(wrappingLabelWithString: countdownSuffix(remaining: totalSeconds))
        subtitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.isSelectable = false
        subtitle.setAccessibilityIdentifier("launchOpenHUD.countdown")
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        countdownLabel = subtitle

        // Center text independently from the taller action column.
        let textBlock = NSView()
        textBlock.translatesAutoresizingMaskIntoConstraints = false
        textBlock.addSubview(title)
        textBlock.addSubview(subtitle)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: textBlock.topAnchor),
            title.leadingAnchor.constraint(equalTo: textBlock.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: textBlock.trailingAnchor),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: textBlock.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: textBlock.trailingAnchor),
            subtitle.bottomAnchor.constraint(equalTo: textBlock.bottomAnchor),
        ])

        blur.addSubview(textBlock)

        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = .separatorColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(separator)

        // The HUD only appears for auto-extract. Return extracts; the
        // configured modifier browses instead.
        let actions: [(title: String, keyCap: String?, handler: () -> Void)] = [
            (SZL10n.string("app.launchOpen.action.extractNow"), "↩", { [weak self] in self?.extractTapped() }),
            (SZL10n.string("app.launchOpen.action.browse"), browseModifier.glyph, { [weak self] in self?.browseTapped() }),
        ]

        // Plain container, not NSStackView: `.fillEqually` mangles 1pt
        // separators.
        let actionColumn = NSView()
        actionColumn.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(actionColumn)

        var actionConstraints: [NSLayoutConstraint] = []
        var previousAnchor: NSLayoutYAxisAnchor = actionColumn.topAnchor
        var actionButtons: [LaunchOpenHUDActionButton] = []

        for (index, descriptor) in actions.enumerated() {
            if index > 0 {
                let interSep = NSBox()
                interSep.boxType = .custom
                interSep.borderWidth = 0
                interSep.fillColor = .separatorColor
                interSep.translatesAutoresizingMaskIntoConstraints = false
                actionColumn.addSubview(interSep)
                actionConstraints.append(contentsOf: [
                    interSep.topAnchor.constraint(equalTo: previousAnchor),
                    interSep.leadingAnchor.constraint(equalTo: actionColumn.leadingAnchor),
                    interSep.trailingAnchor.constraint(equalTo: actionColumn.trailingAnchor),
                    interSep.heightAnchor.constraint(equalToConstant: 1),
                ])
                previousAnchor = interSep.bottomAnchor
            }

            let button = LaunchOpenHUDActionButton(title: descriptor.title, keyCap: descriptor.keyCap)
            button.setAccessibilityIdentifier(index == 0 ? "launchOpenHUD.extractNow" : "launchOpenHUD.browse")
            button.onClick = descriptor.handler
            button.translatesAutoresizingMaskIntoConstraints = false
            actionColumn.addSubview(button)
            actionButtons.append(button)

            actionConstraints.append(contentsOf: [
                button.topAnchor.constraint(equalTo: previousAnchor),
                button.leadingAnchor.constraint(equalTo: actionColumn.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: actionColumn.trailingAnchor),
            ])

            // All rows share the first button's height.
            if let first = actionButtons.first, button !== first {
                actionConstraints.append(button.heightAnchor.constraint(equalTo: first.heightAnchor))
            }

            previousAnchor = button.bottomAnchor
        }

        // Avoid circular equal-width constraints; pin to the computed max.
        let maxButtonWidth = actionButtons.map(\.intrinsicContentSize.width).max() ?? 0
        actionConstraints.append(actionColumn.widthAnchor.constraint(equalToConstant: maxButtonWidth))

        actionConstraints.append(previousAnchor.constraint(equalTo: actionColumn.bottomAnchor))
        NSLayoutConstraint.activate(actionConstraints)

        NSLayoutConstraint.activate([
            blur.widthAnchor.constraint(equalToConstant: preferredWidth),

            iconView.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: horizontalPadding),
            iconView.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),

            textBlock.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: iconTextSpacing),
            textBlock.trailingAnchor.constraint(equalTo: separator.leadingAnchor, constant: -12),
            textBlock.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            textBlock.topAnchor.constraint(greaterThanOrEqualTo: blur.topAnchor, constant: verticalPadding),
            textBlock.bottomAnchor.constraint(lessThanOrEqualTo: blur.bottomAnchor, constant: -verticalPadding),

            separator.topAnchor.constraint(equalTo: blur.topAnchor),
            separator.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            separator.trailingAnchor.constraint(equalTo: actionColumn.leadingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            actionColumn.topAnchor.constraint(equalTo: blur.topAnchor),
            actionColumn.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            actionColumn.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
        ])

        panel.contentView = blur
        blur.layoutSubtreeIfNeeded()
        panel.setContentSize(blur.fittingSize)
        panel.invalidateShadow()
        return panel
    }

    /// 9-part stretchable rounded-rect mask for `NSVisualEffectView`, so the
    /// window shape (and shadow) become truly rounded.
    private static func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
        let edge = ceil(cornerRadius * 2 + 1)
        let size = NSSize(width: edge, height: edge)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                       bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }

    private func positionPanel(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        // Anchor bottom-center of the active screen.
        let bottomInset: CGFloat = 80
        let origin = NSPoint(x: frame.midX - size.width / 2,
                             y: frame.minY + bottomInset)
        panel.setFrameOrigin(origin)
    }

    private func installKeyMonitor() {
        let modifierFlag = browseModifier.flag
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                switch event.keyCode {
                case 53: // Escape
                    cancelTapped()
                    return nil
                case 36, 76: // Return / numpad Enter
                    extractTapped()
                    return nil
                default:
                    return event
                }
            case .flagsChanged:
                // Fire on the down edge only; release also produces a
                // flagsChanged event.
                if let modifierFlag, event.modifierFlags.contains(modifierFlag) {
                    browseTapped()
                    return nil
                }
                return event
            default:
                return event
            }
        }

        // Global modifier-only monitor covers nonactivating HUDs without
        // observing foreground-app keyDown events.
        lastGlobalFlags = NSEvent.modifierFlags
        if let modifierFlag {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                guard let self else { return }
                let now = event.modifierFlags
                let pressed = now.contains(modifierFlag) && !lastGlobalFlags.contains(modifierFlag)
                lastGlobalFlags = now
                if pressed {
                    browseTapped()
                }
            }

            // Catch modifiers held before the HUD installs monitors.
            if lastGlobalFlags.contains(modifierFlag) {
                browseTapped()
            }
        }
    }

    private func startCountdown() {
        startDate = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0,
                          target: self,
                          selector: #selector(countdownTimerFired(_:)),
                          userInfo: nil,
                          repeats: true)
        // `.common` keeps the timer firing during menu/event tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func countdownTimerFired(_: Timer) {
        tick()
    }

    private func tick() {
        guard let startDate else { return }
        let elapsed = Date().timeIntervalSince(startDate)
        let remaining = max(0, totalSeconds - elapsed)
        countdownLabel?.stringValue = countdownSuffix(remaining: remaining)
        if remaining <= 0 {
            extractTapped()
        }
    }

    @objc private func cancelTapped() {
        finish(action: .cancel)
    }

    @objc private func browseTapped() {
        finish(action: .browse)
    }

    @objc private func extractTapped() {
        finish(action: .extract)
    }

    private enum FinishAction {
        case cancel
        case browse
        case extract
    }

    private func finish(action: FinishAction) {
        guard !didFinish else { return }
        didFinish = true
        timer?.invalidate()
        timer = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil

        let proceeds = proceedHandlers
        let releases = releaseHandlers
        let pendingURLs = urls
        proceedHandlers.removeAll()
        releaseHandlers.removeAll()

        // Let the panel order out before follow-up work touches the main thread.
        Task { @MainActor in
            switch action {
            case .cancel:
                for r in releases {
                    r()
                }
            case .browse:
                for p in proceeds {
                    await p()
                }
                for r in releases {
                    r()
                }
            case .extract:
                Self.runSmartExtract(urls: pendingURLs,
                                     revealDestination: revealAfterExtract)
                {
                    for r in releases {
                        r()
                    }
                }
            }
        }

        if LaunchOpenHUDController.activeController === self {
            LaunchOpenHUDController.activeController = nil
        }
    }

    // MARK: - Strings

    private func refreshTitle() {
        titleLabel?.stringValue = titleString()
        if let panel, let blur = panel.contentView {
            blur.layoutSubtreeIfNeeded()
            panel.setContentSize(blur.fittingSize)
            positionPanel(panel)
            panel.invalidateShadow()
        }
    }

    private func titleString() -> String {
        if urls.count == 1 {
            return SZL10n.string("app.launchOpen.title.one", urls[0].lastPathComponent)
        }
        return SZL10n.string("app.launchOpen.title.many", urls.count)
    }

    private func countdownSuffix(remaining: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(remaining)))
        return SZL10n.string("app.launchOpen.countdown", seconds)
    }
}

// MARK: - Action button

/// Borderless notification-style action button: centered label, optional
/// key-cap glyph, hover/press highlight.
@MainActor
final class LaunchOpenHUDActionButton: NSView {
    var onClick: (() -> Void)?

    private let label: NSTextField
    private let keyCapView: KeyCapView?
    private let verticalPadding: CGFloat = 14
    private let horizontalPadding: CGFloat = 16
    private let labelToKeyCapSpacing: CGFloat = 6
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    init(title: String, keyCap: String? = nil) {
        label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false

        if let keyCap {
            let cap = KeyCapView(text: keyCap)
            cap.translatesAutoresizingMaskIntoConstraints = false
            keyCapView = cap
        } else {
            keyCapView = nil
        }

        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        if let keyCapView {
            let row = NSStackView(views: [label, keyCapView])
            row.orientation = .horizontal
            row.spacing = labelToKeyCapSpacing
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)

            NSLayoutConstraint.activate([
                row.centerXAnchor.constraint(equalTo: centerXAnchor),
                row.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
                row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
                row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: horizontalPadding),
                row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -horizontalPadding),
            ])
        } else {
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: horizontalPadding),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -horizontalPadding),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var intrinsicContentSize: NSSize {
        // Mirror the constraint paddings exactly so the column can size to
        // the widest button.
        let labelSize = label.intrinsicContentSize
        let capWidth = keyCapView?.intrinsicContentSize.width ?? 0
        let extraWidth = keyCapView == nil ? 0 : labelToKeyCapSpacing + capWidth
        return NSSize(width: horizontalPadding * 2 + labelSize.width + extraWidth,
                      height: verticalPadding * 2 + labelSize.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovering = false
        isPressed = false
    }

    override func mouseDown(with _: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        let point = convert(event.locationInWindow, from: nil)
        if wasPressed, bounds.contains(point) {
            onClick?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_: NSRect) {
        let color: NSColor = if isPressed {
            NSColor.labelColor.withAlphaComponent(0.18)
        } else if isHovering {
            NSColor.labelColor.withAlphaComponent(0.08)
        } else {
            .clear
        }
        color.setFill()
        bounds.fill()
    }
}
