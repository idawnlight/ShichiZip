import Cocoa
import os.lock

/// Progress dialog shown during extraction/compression operations
class ProgressDialogController: NSWindowController, SZProgressDelegate {
    private static let metricsUpdateInterval: TimeInterval = 0.3
    static let deferredPresentationDelay: TimeInterval = 0.5

    private var progressBar: NSProgressIndicator!
    private var fileNameLabel: NSTextField!
    private var bytesLabel: NSTextField!
    private var operationLabel: NSTextField!
    private var cancelButton: NSButton!

    private struct ProgressState: Sendable {
        var cancelled = false
        var isWaitingForProgress = false
        var startTime: Date?
        var lastMetricsUpdateTime: TimeInterval = 0
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: ProgressState())
    private var speedLabel: NSTextField!
    private var elapsedLabel: NSTextField!
    var showRequestHandler: (() -> Void)?

    var operationTitle: String = "Working..." {
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
            defer: false
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
        contentView.addSubview(operationLabel)

        fileNameLabel = NSTextField(labelWithString: "")
        fileNameLabel.font = .systemFont(ofSize: 11)
        fileNameLabel.textColor = .secondaryLabelColor
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(fileNameLabel)

        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1.0
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progressBar)

        bytesLabel = NSTextField(labelWithString: "")
        bytesLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        bytesLabel.textColor = .secondaryLabelColor
        bytesLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bytesLabel)

        speedLabel = NSTextField(labelWithString: "")
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speedLabel.textColor = .secondaryLabelColor
        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(speedLabel)

        elapsedLabel = NSTextField(labelWithString: "")
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.alignment = .right
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(elapsedLabel)

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}" // Escape
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
        stateLock.withLock { state in
            state.isWaitingForProgress = true
            state.startTime = nil
            state.lastMetricsUpdateTime = 0
            state.cancelled = false
        }

        let applyUI = { [weak self] in
            guard let self else { return }
            self.cancelButton.isEnabled = true
            self.cancelButton.title = "Cancel"
            self.progressBar.stopAnimation(nil)
            self.progressBar.isIndeterminate = false
            self.progressBar.doubleValue = 0
            if let fileName {
                self.fileNameLabel.stringValue = fileName
            }
            self.bytesLabel.stringValue = ""
            self.speedLabel.stringValue = ""
            self.elapsedLabel.stringValue = ""
        }

        if Thread.isMainThread {
            applyUI()
        } else {
            DispatchQueue.main.async(execute: applyUI)
        }
    }

    private func ensureDeterminateProgressOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        let needsReset = stateLock.withLock { state -> Bool in
            guard state.isWaitingForProgress else { return false }
            state.isWaitingForProgress = false
            return true
        }
        guard needsReset || progressBar.isIndeterminate else { return }
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.doubleValue = 0
    }

    func showNowIfNeeded() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync {
                self.showNowIfNeeded()
            }
            return
        }

        if let showRequestHandler {
            showRequestHandler()
            return
        }

        showWindowNowIfNeeded()
    }

    func showWindowNowIfNeeded() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync {
                self.showWindowNowIfNeeded()
            }
            return
        }

        guard let window else { return }
        if !window.isVisible {
            window.center()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    @objc private func cancelClicked(_: Any?) {
        stateLock.withLock { $0.cancelled = true }
        cancelButton.isEnabled = false
        cancelButton.title = "Cancelling..."
    }

    // MARK: - SZProgressDelegate (matches ProgressDialog2.cpp)

    @objc func progressDidUpdate(_ fraction: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ensureDeterminateProgressOnMain()
            self.progressBar.doubleValue = fraction
        }
    }

    @objc func progressDidUpdateFileName(_ fileName: String) {
        DispatchQueue.main.async { [weak self] in
            self?.fileNameLabel.stringValue = fileName
        }
    }

    @objc func progressDidUpdateBytesCompleted(_ completed: UInt64, total: UInt64) {
        let metrics: (startTime: Date, lastUpdate: TimeInterval, shouldSkip: Bool) = stateLock.withLock { state in
            if state.startTime == nil { state.startTime = Date() }
            let now = Date().timeIntervalSinceReferenceDate
            let isFinalUpdate = total > 0 && completed >= total
            let shouldSkip = !isFinalUpdate && state.lastMetricsUpdateTime > 0 &&
                now - state.lastMetricsUpdateTime < Self.metricsUpdateInterval
            if !shouldSkip {
                state.lastMetricsUpdateTime = now
            }
            return (state.startTime!, state.lastMetricsUpdateTime, shouldSkip)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if total > 0 {
                self.ensureDeterminateProgressOnMain()
                self.progressBar.doubleValue = Double(completed) / Double(total)
            }

            guard !metrics.shouldSkip else { return }

            let completedStr = ByteCountFormatter.string(fromByteCount: Int64(completed), countStyle: .file)
            let totalStr = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
            let percent = total > 0 ? Int(Double(completed) / Double(total) * 100) : 0
            self.bytesLabel.stringValue = "\(completedStr) / \(totalStr) (\(percent)%)"

            let elapsed = Date().timeIntervalSince(metrics.startTime)
            if elapsed > Self.metricsUpdateInterval {
                let speed = Double(completed) / elapsed
                let speedStr = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file)
                self.speedLabel.stringValue = "Speed: \(speedStr)/s"

                let elapsedStr = self.formatDuration(elapsed)
                if total > 0, completed > 0 {
                    let remaining = elapsed * Double(total - completed) / Double(completed)
                    let remainStr = self.formatDuration(remaining)
                    self.elapsedLabel.stringValue = "Elapsed: \(elapsedStr)  Remaining: \(remainStr)"
                } else {
                    self.elapsedLabel.stringValue = "Elapsed: \(elapsedStr)"
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
        return stateLock.withLock { $0.cancelled }
    }

    func progressDidUpdateFilesCompleted(_ count: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.speedLabel.stringValue.isEmpty || self.speedLabel.stringValue.hasSuffix("processed") {
                let suffix = count == 1 ? "file" : "files"
                self.speedLabel.stringValue = "\(count) \(suffix) processed"
            }
        }
    }

    @objc func progressPrepareForUserInteraction() {
        showNowIfNeeded()
    }

    @objc func progressResetCancellationRequest() {
        stateLock.withLock { $0.cancelled = false }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cancelButton.isEnabled = false
            self.cancelButton.title = "Finalizing..."
        }
    }

    @objc func progressDidUpdateSpeed(_: Double) {
        // Could show speed in UI
    }

    @objc func progressDidUpdateCompressionRatio(_: Double) {
        // Could show ratio in UI
    }
}
