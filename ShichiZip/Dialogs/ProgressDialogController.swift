import Cocoa

/// Progress dialog shown during extraction/compression operations
class ProgressDialogController: NSWindowController, SZProgressDelegate {

    private var progressBar: NSProgressIndicator!
    private var fileNameLabel: NSTextField!
    private var bytesLabel: NSTextField!
    private var operationLabel: NSTextField!
    private var cancelButton: NSButton!

    private var cancelled = false
    var operationTitle: String = "Working..." {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.operationLabel?.stringValue = self?.operationTitle ?? ""
            }
        }
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "ShichiZip"
        window.isMovableByWindowBackground = true
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        operationLabel = NSTextField(labelWithString: operationTitle)
        operationLabel.font = .boldSystemFont(ofSize: 13)
        operationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(operationLabel)

        fileNameLabel = NSTextField(labelWithString: "")
        fileNameLabel.font = .systemFont(ofSize: 11)
        fileNameLabel.textColor = .secondaryLabelColor
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(fileNameLabel)

        progressBar = NSProgressIndicator()
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

            cancelButton.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 4),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    @objc private func cancelClicked(_ sender: Any?) {
        cancelled = true
        cancelButton.isEnabled = false
        cancelButton.title = "Cancelling..."
    }

    // MARK: - SZProgressDelegate

    @objc func progressDidUpdate(_ fraction: Double) {
        progressBar.doubleValue = fraction
    }

    @objc func progressDidUpdateFileName(_ fileName: String) {
        fileNameLabel.stringValue = fileName
    }

    @objc func progressDidUpdateBytesCompleted(_ completed: UInt64, total: UInt64) {
        let completedStr = ByteCountFormatter.string(fromByteCount: Int64(completed), countStyle: .file)
        let totalStr = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        let percent = total > 0 ? Int(Double(completed) / Double(total) * 100) : 0
        bytesLabel.stringValue = "\(completedStr) / \(totalStr) (\(percent)%)"
    }

    @objc func progressShouldCancel() -> Bool {
        return cancelled
    }

    @objc func progressDidUpdateSpeed(_ bytesPerSecond: Double) {
        // Could show speed in UI
    }

    @objc func progressDidUpdateCompressionRatio(_ ratio: Double) {
        // Could show ratio in UI
    }
}
