import Cocoa

final class ShortcutRecorderButton: NSButton {
    var shortcut: FileManagerShortcut? {
        didSet {
            if !isRecording {
                updateAppearance()
            }
        }
    }

    var onShortcutChanged: ((FileManagerShortcut?) -> Void)?

    private var recordingMonitor: Any?
    private var isRecording = false {
        didSet {
            updateAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording(_:))
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        stopRecording()
    }

    @objc private func toggleRecording(_: Any?) {
        if isRecording {
            cancelRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard recordingMonitor == nil else { return }

        isRecording = true
        window?.makeFirstResponder(self)
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isRecording else {
                return event
            }

            return capture(event)
        }
    }

    private func cancelRecording() {
        stopRecording()
    }

    private func stopRecording() {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
            self.recordingMonitor = nil
        }
        isRecording = false
    }

    private func capture(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            cancelRecording()
            return nil
        }

        guard let shortcut = FileManagerShortcut(event: event) else {
            NSSound.beep()
            return nil
        }

        self.shortcut = shortcut
        stopRecording()
        onShortcutChanged?(shortcut)
        return nil
    }

    private func updateAppearance() {
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        if isRecording {
            attributedTitle = NSAttributedString(
                string: SZL10n.string("app.settings.typeShortcut"),
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.controlAccentColor,
                ],
            )
            return
        }

        if let shortcut {
            attributedTitle = NSAttributedString(
                string: shortcut.displayName,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ],
            )
            return
        }

        let placeholderFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        attributedTitle = NSAttributedString(
            string: SZL10n.string("app.settings.recordShortcut"),
            attributes: [
                .font: placeholderFont,
                .foregroundColor: NSColor.placeholderTextColor,
            ],
        )
    }
}
