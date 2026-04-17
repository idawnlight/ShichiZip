import Cocoa

/// Progress dialog shown during extraction/compression operations
class ProgressDialogController: NSWindowController, SZProgressDelegate {
    private static let metricsUpdateInterval: TimeInterval = 0.3
    static let deferredPresentationDelay: TimeInterval = 0.5

    private var progressBar: NSProgressIndicator!
    private var fileNameLabel: NSTextField!
    private var bytesLabel: NSTextField!
    private var operationLabel: NSTextField!
    private var cancelButton: NSButton!

    private var cancelled = false
    private var startTime: Date?

    /// Tracks whether `speedLabel` is showing throughput or file counts.
    private enum SpeedLabelMode {
        case empty
        case speed
        case filesProcessed
    }

    private var speedLabelMode: SpeedLabelMode = .empty
    private var speedLabel: NSTextField!
    private var elapsedLabel: NSTextField!
    private var isWaitingForProgress = false
    private var lastMetricsUpdateTime: TimeInterval = 0
    var showRequestHandler: (() -> Void)?

    var operationTitle: String = SZL10n.string("app.progress.working") {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.operationLabel?.stringValue = self?.operationTitle ?? ""
            }
        }
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 175),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        window.title = AppBuildInfo.appDisplayName()
        window.isMovableByWindowBackground = true
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        operationLabel = NSTextField(labelWithString: operationTitle)
        operationLabel.font = .boldSystemFont(ofSize: 13)
        operationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        operationLabel.translatesAutoresizingMaskIntoConstraints = false
        operationLabel.setAccessibilityIdentifier("progress.operationLabel")
        contentView.addSubview(operationLabel)

        fileNameLabel = NSTextField(labelWithString: "")
        fileNameLabel.font = .systemFont(ofSize: 11)
        fileNameLabel.textColor = .secondaryLabelColor
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.setAccessibilityIdentifier("progress.fileName")
        contentView.addSubview(fileNameLabel)

        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1.0
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.setAccessibilityIdentifier("progress.progressBar")
        contentView.addSubview(progressBar)

        bytesLabel = NSTextField(labelWithString: "")
        bytesLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        bytesLabel.textColor = .secondaryLabelColor
        bytesLabel.translatesAutoresizingMaskIntoConstraints = false
        bytesLabel.setAccessibilityIdentifier("progress.bytes")
        contentView.addSubview(bytesLabel)

        speedLabel = NSTextField(labelWithString: "")
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speedLabel.textColor = .secondaryLabelColor
        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        speedLabel.setAccessibilityIdentifier("progress.speed")
        contentView.addSubview(speedLabel)

        elapsedLabel = NSTextField(labelWithString: "")
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.alignment = .right
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedLabel.setAccessibilityIdentifier("progress.elapsed")
        contentView.addSubview(elapsedLabel)

        cancelButton = NSButton(title: SZL10n.string("common.cancel"), target: self, action: #selector(cancelClicked(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        cancelButton.setAccessibilityIdentifier("progress.cancelButton")
        contentView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            operationLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            operationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            operationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            fileNameLabel.topAnchor.constraint(equalTo: operationLabel.bottomAnchor, constant: 4),
            fileNameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            fileNameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            progressBar.topAnchor.constraint(equalTo: fileNameLabel.bottomAnchor, constant: 8),
            progressBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            bytesLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 4),
            bytesLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            speedLabel.topAnchor.constraint(equalTo: bytesLabel.bottomAnchor, constant: 2),
            speedLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            elapsedLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 4),
            elapsedLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -100),

            cancelButton.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 4),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    func beginWaitingMode(fileName: String? = nil) {
        isWaitingForProgress = true
        startTime = nil
        lastMetricsUpdateTime = 0
        cancelled = false
        cancelButton.isEnabled = true
        cancelButton.title = SZL10n.string("common.cancel")
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.doubleValue = 0
        if let fileName {
            fileNameLabel.stringValue = fileName
        }
        bytesLabel.stringValue = ""
        speedLabel.stringValue = ""
        speedLabelMode = .empty
        elapsedLabel.stringValue = ""
    }

    private func ensureDeterminateProgress() {
        guard progressBar.isIndeterminate || isWaitingForProgress else { return }
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.doubleValue = 0
        isWaitingForProgress = false
    }

    func showNowIfNeeded() {
        // SZOperationSession delivers delegate callbacks on the main queue.
        dispatchPrecondition(condition: .onQueue(.main))

        if let showRequestHandler {
            showRequestHandler()
            return
        }

        showWindowNowIfNeeded()
    }

    func showWindowNowIfNeeded() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard let window else { return }
        if !window.isVisible {
            window.center()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    @objc private func cancelClicked(_: Any?) {
        cancelled = true
        cancelButton.isEnabled = false
        cancelButton.title = SZL10n.string("app.progress.cancelling")
    }

    // MARK: - SZProgressDelegate (matches ProgressDialog2.cpp)

    @objc func progressDidUpdate(_ fraction: Double) {
        ensureDeterminateProgress()
        progressBar.doubleValue = fraction
    }

    @objc func progressDidUpdateFileName(_ fileName: String) {
        fileNameLabel.stringValue = fileName
    }

    @objc func progressDidUpdateBytesCompleted(_ completed: UInt64, total: UInt64) {
        if total > 0 {
            ensureDeterminateProgress()
            progressBar.doubleValue = Double(completed) / Double(total)
        }
        if startTime == nil { startTime = Date() }

        let now = Date().timeIntervalSinceReferenceDate
        let isFinalUpdate = total > 0 && completed >= total
        if !isFinalUpdate && lastMetricsUpdateTime > 0 &&
            now - lastMetricsUpdateTime < Self.metricsUpdateInterval
        {
            return
        }
        lastMetricsUpdateTime = now

        let completedStr = ByteCountFormatter.string(fromByteCount: Int64(completed), countStyle: .file)
        let totalStr = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        let percent = total > 0 ? Int(Double(completed) / Double(total) * 100) : 0
        bytesLabel.stringValue = "\(completedStr) / \(totalStr) (\(percent)%)"

        // Speed and ETA calculation (like ProgressDialog2.cpp)
        if let start = startTime {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > Self.metricsUpdateInterval {
                let speed = Double(completed) / elapsed
                let speedStr = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file)
                speedLabel.stringValue = SZL10n.string("progress.speed") + " \(speedStr)/s"
                speedLabelMode = .speed

                let elapsedStr = formatDuration(elapsed)
                if total > 0, completed > 0 {
                    let remaining = elapsed * Double(total - completed) / Double(completed)
                    let remainStr = formatDuration(remaining)
                    elapsedLabel.stringValue = SZL10n.string("progress.elapsedTime") + " \(elapsedStr)  " + SZL10n.string("progress.remainingTime") + " \(remainStr)"
                } else {
                    elapsedLabel.stringValue = SZL10n.string("progress.elapsedTime") + " \(elapsedStr)"
                }
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    @objc func progressShouldCancel() -> Bool {
        cancelled
    }

    func progressDidUpdateFilesCompleted(_ count: UInt64) {
        // Do not overwrite a live speed/ETA string with file counts.
        switch speedLabelMode {
        case .empty, .filesProcessed:
            let suffix = count == 1 ? "file" : "files"
            speedLabel.stringValue = "\(count) \(suffix) processed"
            speedLabelMode = .filesProcessed
        case .speed:
            break
        }
    }

    @objc func progressPrepareForUserInteraction() {
        showNowIfNeeded()
    }

    @objc func progressResetCancellationRequest() {
        cancelled = false
        cancelButton.isEnabled = false
        cancelButton.title = SZL10n.string("app.progress.finalizing")
    }

    @objc func progressDidUpdateSpeed(_: Double) {
        // Could show speed in UI
    }

    @objc func progressDidUpdateCompressionRatio(_: Double) {
        // Could show ratio in UI
    }
}
