import Cocoa
import Darwin

class BenchmarkWindowController: NSWindowController, NSWindowDelegate {

    private struct DictionaryOption {
        let size: UInt64
        let title: String
    }

    private var dictPopup: NSPopUpButton!
    private var threadsPopup: NSPopUpButton!
    private var passesPopup: NSPopUpButton!
    private var memLabel: NSTextField!

    private var cCurSize: NSTextField!; private var cCurSpeed: NSTextField!
    private var cCurUsage: NSTextField!; private var cCurRpu: NSTextField!; private var cCurRating: NSTextField!
    private var cResSize: NSTextField!; private var cResSpeed: NSTextField!
    private var cResUsage: NSTextField!; private var cResRpu: NSTextField!; private var cResRating: NSTextField!

    private var dCurSize: NSTextField!; private var dCurSpeed: NSTextField!
    private var dCurUsage: NSTextField!; private var dCurRpu: NSTextField!; private var dCurRating: NSTextField!
    private var dResSize: NSTextField!; private var dResSpeed: NSTextField!
    private var dResUsage: NSTextField!; private var dResRpu: NSTextField!; private var dResRating: NSTextField!

    private var totUsage: NSTextField!; private var totRpu: NSTextField!; private var totRating: NSTextField!

    private var elapsedL: NSTextField!; private var passesL: NSTextField!
    private var logView: NSTextView!
    private var restartBtn: NSButton!; private var stopBtn: NSButton!

    private var elapsedTimer: Timer?
    private var startTime: Date?
    private var isRunningBenchmark = false
    private var isStoppingBenchmark = false
    private var pendingRestart = false

    private var dictOptions: [DictionaryOption] = []
    private var threadOptions: [UInt32] = []
    private var passOptions: [UInt32] = []

    private var logicalCPUCount: Int { max(1, ProcessInfo.processInfo.processorCount) }
    private var physicalMemoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }
    private var memoryLimitBytes: UInt64 { (physicalMemoryBytes / 16) * 15 }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Benchmark"
        window.minSize = NSSize(width: 720, height: 500)
        window.center()
        self.init(window: window)
        window.delegate = self
        setupUI()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(nil)
        if !isRunningBenchmark {
            startBenchmark()
        }
    }

    func windowWillClose(_ notification: Notification) {
        cancelBenchmark()
    }

    private func metricField(_ text: String = "...") -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .right
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 85).isActive = true
        return field
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func formLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        return field
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func controlRow(title: String, control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let titleLabel = formLabel(title)
        titleLabel.widthAnchor.constraint(equalToConstant: 116).isActive = true
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(control)
        return row
    }

    private func appVersionString() -> String? {
        AppBuildInfo.displayVersion()
    }

    private func benchmarkSystemSummary() -> String {
        let appName = AppBuildInfo.appDisplayName()
        let versionedAppName = if let appVersion = appVersionString() {
            "\(appName) \(appVersion)"
        } else {
            appName
        }
        let memoryText = ByteCountFormatter.string(fromByteCount: Int64(physicalMemoryBytes), countStyle: .memory)
        return "\(versionedAppName) (\(AppBuildInfo.archiveCoreName()) core \(SZArchive.sevenZipVersionString())) | \(Self.cpuModel()) | \(logicalCPUCount) threads | \(memoryText)"
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        dictOptions = Self.makeDictionaryOptions()
        threadOptions = Self.makeThreadOptions(forCPUCount: logicalCPUCount)
        passOptions = Self.makePassOptions()

        let physMB = Self.displayMegabytes(physicalMemoryBytes)
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        contentView.addSubview(stack)

        dictPopup = NSPopUpButton()
        dictOptions.forEach { dictPopup.addItem(withTitle: $0.title) }
        dictPopup.target = self
        dictPopup.action = #selector(paramChanged(_:))
        dictPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        threadsPopup = NSPopUpButton()
        threadOptions.forEach { threadsPopup.addItem(withTitle: "\($0)") }
        threadsPopup.target = self
        threadsPopup.action = #selector(paramChanged(_:))
        threadsPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true

        passesPopup = NSPopUpButton()
        passOptions.forEach { passesPopup.addItem(withTitle: "\($0)") }
        passesPopup.target = self
        passesPopup.action = #selector(paramChanged(_:))
        passesPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        memLabel = NSTextField(labelWithString: "--- MB / \(physMB) MB")
        memLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)

        restartBtn = NSButton(title: "Restart", target: self, action: #selector(restartClicked(_:)))
        restartBtn.widthAnchor.constraint(equalToConstant: 92).isActive = true

        stopBtn = NSButton(title: "Stop", target: self, action: #selector(stopClicked(_:)))
        stopBtn.isEnabled = false
        stopBtn.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let threadsControl = NSStackView()
        threadsControl.orientation = .horizontal
        threadsControl.alignment = .centerY
        threadsControl.spacing = 4
        threadsControl.addArrangedSubview(threadsPopup)
        threadsControl.addArrangedSubview(secondaryLabel("/ \(logicalCPUCount)"))

        let controlsColumn = NSStackView()
        controlsColumn.orientation = .vertical
        controlsColumn.alignment = .leading
        controlsColumn.spacing = 8
        controlsColumn.addArrangedSubview(controlRow(title: "Dictionary size", control: dictPopup))
        controlsColumn.addArrangedSubview(controlRow(title: "CPU threads", control: threadsControl))
        controlsColumn.addArrangedSubview(controlRow(title: "Passes", control: passesPopup))
        controlsColumn.setContentHuggingPriority(.required, for: .horizontal)

        let memoryGroup = NSStackView()
        memoryGroup.orientation = .vertical
        memoryGroup.alignment = .leading
        memoryGroup.spacing = 3
        memoryGroup.addArrangedSubview(secondaryLabel("Estimated memory"))
        memoryGroup.addArrangedSubview(memLabel)
        memoryGroup.addArrangedSubview(secondaryLabel("Usable limit: \(Self.displayMegabytes(memoryLimitBytes)) MB"))
        memoryGroup.setContentHuggingPriority(.required, for: .horizontal)

        let actionGroup = NSStackView()
        actionGroup.orientation = .vertical
        actionGroup.alignment = .trailing
        actionGroup.spacing = 6
        actionGroup.addArrangedSubview(restartBtn)
        actionGroup.addArrangedSubview(stopBtn)
        actionGroup.setContentHuggingPriority(.required, for: .horizontal)

        let trailingGroup = NSStackView()
        trailingGroup.orientation = .horizontal
        trailingGroup.alignment = .top
        trailingGroup.spacing = 14
        trailingGroup.addArrangedSubview(memoryGroup)
        trailingGroup.addArrangedSubview(actionGroup)
        trailingGroup.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.alignment = .top
        topBar.spacing = 16
        topBar.distribution = .fill
        topBar.addArrangedSubview(controlsColumn)
        topBar.addArrangedSubview(spacer)
        topBar.addArrangedSubview(trailingGroup)
        stack.addArrangedSubview(topBar)
        topBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        stack.addArrangedSubview(topSeparator)
        topSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let grid = NSGridView(numberOfColumns: 7, rows: 0)
        grid.columnSpacing = 10
        grid.rowSpacing = 3
        grid.column(at: 0).xPlacement = .leading

        let headers = ["", "", "Size", "Speed", "CPU Usage", "Rating / Usage", "Rating"]
        let headerRow = headers.map { title -> NSTextField in
            let view = NSTextField(labelWithString: title)
            view.font = .boldSystemFont(ofSize: 11)
            view.alignment = .right
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 85).isActive = true
            return view
        }
        headerRow[0].alignment = .left
        headerRow[1].alignment = .left
        grid.addRow(with: headerRow)

        cCurSize = metricField(); cCurSpeed = metricField(); cCurUsage = metricField(); cCurRpu = metricField(); cCurRating = metricField()
        cResSize = metricField(); cResSpeed = metricField(); cResUsage = metricField(); cResRpu = metricField(); cResRating = metricField()
        let compressTitle = label("Compressing")
        compressTitle.font = .boldSystemFont(ofSize: 11)
        grid.addRow(with: [compressTitle, label("Current"), cCurSize, cCurSpeed, cCurUsage, cCurRpu, cCurRating])
        grid.addRow(with: [NSView(), label("Resulting"), cResSize, cResSpeed, cResUsage, cResRpu, cResRating])

        grid.addRow(with: (0..<7).map { _ in NSView() })

        dCurSize = metricField(); dCurSpeed = metricField(); dCurUsage = metricField(); dCurRpu = metricField(); dCurRating = metricField()
        dResSize = metricField(); dResSpeed = metricField(); dResUsage = metricField(); dResRpu = metricField(); dResRating = metricField()
        let decompressTitle = label("Decompressing")
        decompressTitle.font = .boldSystemFont(ofSize: 11)
        grid.addRow(with: [decompressTitle, label("Current"), dCurSize, dCurSpeed, dCurUsage, dCurRpu, dCurRating])
        grid.addRow(with: [NSView(), label("Resulting"), dResSize, dResSpeed, dResUsage, dResRpu, dResRating])

        stack.addArrangedSubview(grid)

        let totalSeparator = NSBox()
        totalSeparator.boxType = .separator
        stack.addArrangedSubview(totalSeparator)
        totalSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        totUsage = metricField()
        totRpu = metricField()
        totRating = metricField()
        let totalGrid = NSGridView(numberOfColumns: 7, rows: 0)
        totalGrid.columnSpacing = 10
        let totalTitle = label("Total Rating")
        totalTitle.font = .boldSystemFont(ofSize: 12)
        totalGrid.addRow(with: [totalTitle, NSView(), NSView(), NSView(), totUsage, totRpu, totRating])
        for index in 2...6 {
            totalGrid.column(at: index).width = 85
        }
        stack.addArrangedSubview(totalGrid)

        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        stack.addArrangedSubview(bottomSeparator)
        bottomSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let statusRow = NSStackView()
        statusRow.spacing = 8
        statusRow.distribution = .fill

        let elapsedRow = NSStackView()
        elapsedRow.spacing = 4
        elapsedL = metricField("0 s")
        elapsedRow.addArrangedSubview(label("Elapsed time:"))
        elapsedRow.addArrangedSubview(elapsedL)

        let passesRow = NSStackView()
        passesRow.spacing = 4
        passesL = metricField("0 / 1")
        passesRow.addArrangedSubview(label("Passes:"))
        passesRow.addArrangedSubview(passesL)

        statusRow.addArrangedSubview(elapsedRow)
        statusRow.addArrangedSubview(NSView())
        statusRow.addArrangedSubview(passesRow)
        stack.addArrangedSubview(statusRow)
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        logView = NSTextView()
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 0, height: 2)
        logScroll.documentView = logView
        stack.addArrangedSubview(logScroll)
        logScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let bottomRow = NSStackView()
        bottomRow.spacing = 8
        let systemLabel = label(benchmarkSystemSummary())
        systemLabel.font = .systemFont(ofSize: 11)
        systemLabel.textColor = .secondaryLabelColor
        bottomRow.addArrangedSubview(systemLabel)
        bottomRow.addArrangedSubview(NSView())
        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeClicked(_:)))
        closeBtn.keyEquivalent = "\u{1b}"
        bottomRow.addArrangedSubview(closeBtn)
        stack.addArrangedSubview(bottomRow)
        bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])

        applyDefaultSelections()
        resetState()
        updateMemUsage()
    }

    private func applyDefaultSelections() {
        if let threadIndex = threadOptions.firstIndex(of: Self.defaultThreadCount(forCPUCount: logicalCPUCount)) {
            threadsPopup.selectItem(at: threadIndex)
        }

        let defaultDict = defaultDictionarySize(forThreads: currentThreads())
        if let dictIndex = dictOptions.lastIndex(where: { $0.size <= defaultDict }) {
            dictPopup.selectItem(at: dictIndex)
        } else {
            dictPopup.selectItem(at: 0)
        }

        if let passIndex = passOptions.firstIndex(of: 1) {
            passesPopup.selectItem(at: passIndex)
        }
    }

    @objc private func paramChanged(_ sender: Any?) {
        updateMemUsage()
        if isRunningBenchmark {
            requestRestart()
        }
    }

    private func updateMemUsage() {
        let usage = SZArchive.benchMemoryUsage(forThreads: currentThreads(), dictionary: currentDictionarySize())
        let usageMB = Self.displayMegabytes(usage)
        let totalMB = Self.displayMegabytes(physicalMemoryBytes)
        memLabel.stringValue = "\(usageMB) MB / \(totalMB) MB"
        memLabel.textColor = isMemoryUsageOK(usage) ? .labelColor : .systemRed
    }

    @objc private func restartClicked(_ sender: Any?) {
        requestRestart()
    }

    @objc private func stopClicked(_ sender: Any?) {
        pendingRestart = false
        guard isRunningBenchmark, !isStoppingBenchmark else { return }
        isStoppingBenchmark = true
        restartBtn.isEnabled = false
        stopBtn.isEnabled = false
        SZArchive.stopBenchmark()
    }

    @objc private func closeClicked(_ sender: Any?) {
        cancelBenchmark()
        window?.close()
    }

    private func requestRestart() {
        guard window?.isVisible == true else { return }
        if isRunningBenchmark {
            pendingRestart = true
            if !isStoppingBenchmark {
                isStoppingBenchmark = true
                restartBtn.isEnabled = false
                stopBtn.isEnabled = false
                SZArchive.stopBenchmark()
            }
            return
        }
        startBenchmark()
    }

    private func cancelBenchmark() {
        pendingRestart = false
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if isRunningBenchmark && !isStoppingBenchmark {
            isStoppingBenchmark = true
            SZArchive.stopBenchmark()
        }
    }

    private func resetState() {
        let allFields = [
            cCurSize, cCurSpeed, cCurUsage, cCurRpu, cCurRating,
            cResSize, cResSpeed, cResUsage, cResRpu, cResRating,
            dCurSize, dCurSpeed, dCurUsage, dCurRpu, dCurRating,
            dResSize, dResSpeed, dResUsage, dResRpu, dResRating,
            totUsage, totRpu, totRating
        ]
        allFields.forEach { $0?.stringValue = "..." }
        elapsedL?.stringValue = "0 s"
        passesL?.stringValue = "0 / \(currentPasses())"
        logView?.string = ""
    }

    private func startBenchmark() {
        let dict = currentDictionarySize()
        let threads = currentThreads()
        let passes = currentPasses()
        let memUsage = SZArchive.benchMemoryUsage(forThreads: threads, dictionary: dict)

        guard isMemoryUsageOK(memUsage) else {
            showMemoryAlert(required: memUsage)
            return
        }

        pendingRestart = false
        isStoppingBenchmark = false
        isRunningBenchmark = true
        restartBtn.isEnabled = false
        stopBtn.isEnabled = true
        resetState()
        passesL.stringValue = "0 / \(passes)"

        startTime = Date()
        startElapsedTimer()

        SZArchive.runBenchmark(
            withDictionary: dict,
            threads: threads,
            passes: passes,
            progress: { [weak self] snapshot in
                self?.apply(snapshot: snapshot)
            },
            completion: { [weak self] success, errorMessage in
                self?.finishBenchmark(success: success, errorMessage: errorMessage)
            }
        )
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let startTime = self.startTime else { return }
            self.elapsedL.stringValue = "\(Int(Date().timeIntervalSince(startTime))) s"
        }
    }

    private func finishBenchmark(success: Bool, errorMessage: String?) {
        isRunningBenchmark = false
        let restartRequested = pendingRestart
        pendingRestart = false
        isStoppingBenchmark = false

        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if let startTime {
            elapsedL.stringValue = String(format: "%.3f s", Date().timeIntervalSince(startTime))
        }

        restartBtn.isEnabled = true
        stopBtn.isEnabled = false

        if restartRequested, window?.isVisible == true {
            startBenchmark()
            return
        }

        if !success, let errorMessage, window?.isVisible == true {
            let alert = NSAlert()
            alert.messageText = "Benchmark Error"
            alert.informativeText = errorMessage
            alert.alertStyle = .warning
            if let window {
                alert.beginSheetModal(for: window)
            }
        }
    }

    private func apply(snapshot: SZBenchSnapshot) {
        apply(row: snapshot.encodeCurrent, size: cCurSize, speed: cCurSpeed, usage: cCurUsage, rpu: cCurRpu, rating: cCurRating)
        apply(row: snapshot.encodeResult, size: cResSize, speed: cResSpeed, usage: cResUsage, rpu: cResRpu, rating: cResRating)
        apply(row: snapshot.decodeCurrent, size: dCurSize, speed: dCurSpeed, usage: dCurUsage, rpu: dCurRpu, rating: dCurRating)
        apply(row: snapshot.decodeResult, size: dResSize, speed: dResSpeed, usage: dResUsage, rpu: dResRpu, rating: dResRating)

        if let total = snapshot.totalResult {
            totUsage.stringValue = total.usageText
            totRpu.stringValue = total.rpuText
            totRating.stringValue = total.ratingText
        } else {
            totUsage.stringValue = "..."
            totRpu.stringValue = "..."
            totRating.stringValue = "..."
        }

        passesL.stringValue = "\(snapshot.passesCompleted) / \(snapshot.passesTotal)"
        if logView.string != snapshot.logText {
            logView.string = snapshot.logText
            logView.scrollToEndOfDocument(nil)
        }
    }

    private func apply(row: SZBenchDisplayRow?, size: NSTextField, speed: NSTextField, usage: NSTextField, rpu: NSTextField, rating: NSTextField) {
        guard let row else { return }
        size.stringValue = row.sizeText
        speed.stringValue = row.speedText
        usage.stringValue = row.usageText
        rpu.stringValue = row.rpuText
        rating.stringValue = row.ratingText
    }

    private func currentDictionarySize() -> UInt64 {
        let index = max(0, dictPopup.indexOfSelectedItem)
        guard index < dictOptions.count else { return dictOptions.first?.size ?? (UInt64(1) << 20) }
        return dictOptions[index].size
    }

    private func currentThreads() -> UInt32 {
        let index = max(0, threadsPopup.indexOfSelectedItem)
        guard index < threadOptions.count else { return 1 }
        return threadOptions[index]
    }

    private func currentPasses() -> UInt32 {
        let index = max(0, passesPopup.indexOfSelectedItem)
        guard index < passOptions.count else { return 1 }
        return passOptions[index]
    }

    private func defaultDictionarySize(forThreads threads: UInt32) -> UInt64 {
        var dictLog = 25
        while dictLog > 18 {
            let dictSize = UInt64(1) << UInt64(dictLog)
            let usage = SZArchive.benchMemoryUsage(forThreads: threads, dictionary: dictSize)
            if isMemoryUsageOK(usage) {
                break
            }
            dictLog -= 1
        }
        return UInt64(1) << UInt64(dictLog)
    }

    private func isMemoryUsageOK(_ usage: UInt64) -> Bool {
        usage + (UInt64(1) << 20) <= memoryLimitBytes
    }

    private func showMemoryAlert(required: UInt64) {
        isRunningBenchmark = false
        isStoppingBenchmark = false
        restartBtn.isEnabled = true
        stopBtn.isEnabled = false

        let alert = NSAlert()
        alert.messageText = "Insufficient Memory"
        alert.informativeText = "The selected benchmark settings require \(Self.displayMegabytes(required)) MB, but the usable RAM limit is \(Self.displayMegabytes(memoryLimitBytes)) MB out of \(Self.displayMegabytes(physicalMemoryBytes)) MB installed."
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        }
    }

    private static func makeDictionaryOptions() -> [DictionaryOption] {
        let maxDictSize = UInt64(1) << UInt64(22 + (MemoryLayout<UInt>.size / 4 * 5))
        var options: [DictionaryOption] = []
        var step = (18 - 1) * 2

        while step <= (32 - 1) * 2 {
            let size = UInt64(2 + (step & 1)) << UInt64(step / 2)
            let title: String
            if size >= (UInt64(1) << 31) {
                title = "\(size >> 30) GB"
            } else if size >= (UInt64(1) << 21) {
                title = "\(size >> 20) MB"
            } else {
                title = "\(size >> 10) KB"
            }
            options.append(DictionaryOption(size: size, title: title))
            if size >= maxDictSize {
                break
            }
            step += 1
        }

        return options
    }

    private static func makeThreadOptions(forCPUCount cpuCount: Int) -> [UInt32] {
        let maxThreads = max(1, cpuCount * 2)
        let preferred = defaultThreadCount(forCPUCount: cpuCount)
        var options: [UInt32] = []
        var value: UInt32 = 1

        while value <= UInt32(maxThreads) {
            options.append(value)
            let next = value + (value < 2 ? 1 : 2)
            if value <= preferred, (preferred < next || next > UInt32(maxThreads)) {
                if value != preferred {
                    options.append(preferred)
                }
            }
            value = next
        }

        return options.reduce(into: []) { partialResult, option in
            if !partialResult.contains(option) {
                partialResult.append(option)
            }
        }
    }

    private static func makePassOptions() -> [UInt32] {
        var options: [UInt32] = []
        var value: UInt32 = 1

        while true {
            options.append(value)
            if value >= 10_000_000 {
                break
            }

            if value < 2 {
                value = 2
            } else if value < 5 {
                value = 5
            } else if value < 10 {
                value = 10
            } else {
                value *= 10
            }
        }

        return options
    }

    private static func defaultThreadCount(forCPUCount cpuCount: Int) -> UInt32 {
        var threads = UInt32(max(1, cpuCount))
        threads &= ~UInt32(1)
        if threads == 0 {
            threads = 1
        }
        return min(threads, UInt32(1 << 14))
    }

    private static func displayMegabytes(_ bytes: UInt64) -> UInt64 {
        (bytes + (UInt64(1) << 20) - 1) >> 20
    }

    private static func arch() -> String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        return "Intel (x86_64)"
        #else
        return "Unknown"
        #endif
    }

    private static func cpuModel() -> String {
        if let brandString = sysctlString(named: "machdep.cpu.brand_string"), !brandString.isEmpty {
            return brandString
        }

        if let hardwareModel = sysctlString(named: "hw.model"), !hardwareModel.isEmpty {
            return hardwareModel
        }

        return arch()
    }

    private static func sysctlString(named name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: Int(size))
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
