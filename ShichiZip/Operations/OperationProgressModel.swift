import Combine
import Foundation

@MainActor
final class OperationProgressModel: ObservableObject {
    enum CompletionState: Equatable {
        case running
        case completedWithWarnings
    }

    let operationTitle: String

    @Published private(set) var snapshot: SZOperationSnapshot
    @Published private(set) var completionState = CompletionState.running
    @Published private(set) var speedBytesPerSecond: Double?
    @Published private(set) var updateOutcome: SZArchiveUpdateOutcome?

    var closeAction: (() -> Void)?

    private let session: SZOperationSession
    private let now: () -> TimeInterval
    private var metricsStartTime: TimeInterval?
    private var metricsStartBytes: UInt64 = 0

    init(operationTitle: String,
         initialFileName: String?,
         session: SZOperationSession,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime })
    {
        self.operationTitle = operationTitle
        self.session = session
        self.now = now

        if let initialFileName, !initialFileName.isEmpty {
            session.reportCurrentFileName(initialFileName)
        }
        snapshot = session.snapshot()
    }

    func apply(_ snapshot: SZOperationSnapshot) {
        updateMetrics(using: snapshot)
        self.snapshot = snapshot
    }

    func complete(updateOutcome: SZArchiveUpdateOutcome?) {
        let finalSnapshot = session.snapshot()
        apply(finalSnapshot)
        self.updateOutcome = updateOutcome
        if finalSnapshot.totalIssueCount > 0 || updateOutcome?.hasWarnings == true {
            completionState = .completedWithWarnings
        }
    }

    func requestCancel() {
        guard isCancelEnabled else { return }
        session.requestCancel()
        apply(session.snapshot())
    }

    func close() {
        closeAction?()
    }

    var isTerminalWarning: Bool {
        completionState == .completedWithWarnings
    }

    var isCancelEnabled: Bool {
        completionState == .running
            && snapshot.isCancellationAllowed
            && !snapshot.isCancellationRequested
    }

    var phaseText: String {
        if isTerminalWarning {
            return SZL10n.string("app.progress.completedWithWarnings")
        }
        if snapshot.isCancellationRequested || snapshot.phase == .cancelling {
            return SZL10n.string("app.progress.cancelling")
        }

        switch snapshot.phase {
        case .waiting:
            return SZL10n.string("app.progress.working")
        case .scanning:
            return SZL10n.string("progress.scanning")
        case .opening:
            return SZL10n.string("progress.opening")
        case .reading:
            return SZL10n.string("progress.analyzing")
        case .compressing:
            return SZL10n.string("progress.compressing")
        case .extracting:
            return SZL10n.string("progress.extracting")
        case .updating:
            return SZL10n.string("progress.updating")
        case .deleting:
            return SZL10n.string("progress.deleting")
        case .movingArchive:
            return SZL10n.string("progress.repacking")
        case .cancelling:
            return SZL10n.string("app.progress.cancelling")
        case .finalizing:
            return SZL10n.string("app.progress.finalizing")
        @unknown default:
            return SZL10n.string("app.progress.working")
        }
    }

    var displayTitle: String {
        if isTerminalWarning {
            return phaseText
        }

        switch snapshot.phase {
        case .scanning, .opening, .movingArchive, .cancelling, .finalizing:
            return phaseText
        default:
            return operationTitle
        }
    }

    var progressValue: Double? {
        guard snapshot.hasReportedProgress else { return nil }
        return min(max(snapshot.progressFraction, 0), 1)
    }

    var bytesText: String? {
        guard snapshot.bytesTotal > 0 else { return nil }
        let completed = Self.byteString(snapshot.bytesCompleted)
        let total = Self.byteString(snapshot.bytesTotal)
        let percentage = Int(min(max(snapshot.progressFraction, 0), 1) * 100)
        return "\(completed) / \(total) (\(percentage)%)"
    }

    var filesText: String? {
        if snapshot.filesTotal > 0 {
            return "\(snapshot.filesCompleted) / \(snapshot.filesTotal)"
        }
        guard snapshot.filesCompleted > 0 else { return nil }
        return String(snapshot.filesCompleted)
    }

    var speedText: String? {
        guard let speedBytesPerSecond, speedBytesPerSecond > 0 else { return nil }
        let displaySpeed = UInt64(
            min(speedBytesPerSecond, Double(Int64.max)),
        )
        return "\(Self.byteString(displaySpeed))/s"
    }

    var displayedIssues: [SZArchiveUpdateIssue] {
        if snapshot.totalIssueCount > 0 {
            return snapshot.issues
        }
        return updateOutcome?.issues ?? []
    }

    var totalIssueCount: UInt64 {
        if snapshot.totalIssueCount > 0 {
            return snapshot.totalIssueCount
        }
        return updateOutcome?.totalIssueCount ?? 0
    }

    var issuesTruncated: Bool {
        if snapshot.totalIssueCount > 0 {
            return snapshot.areIssuesTruncated
        }
        return updateOutcome?.areIssuesTruncated ?? false
    }

    var warningSummary: String {
        "\(SZL10n.string("column.warningFlags")): \(totalIssueCount)"
    }

    func elapsedDuration(at time: Date = Date()) -> String? {
        guard let metricsStartTime else { return nil }
        let elapsed = max(now() - metricsStartTime, 0)
        guard elapsed >= 0.3 else { return nil }
        _ = time
        return Self.durationString(elapsed)
    }

    var remainingDuration: String? {
        guard snapshot.bytesTotal > snapshot.bytesCompleted,
              let speedBytesPerSecond,
              speedBytesPerSecond > 0
        else {
            return nil
        }
        let remainingBytes = snapshot.bytesTotal - snapshot.bytesCompleted
        return Self.durationString(Double(remainingBytes) / speedBytesPerSecond)
    }

    func issueStageText(_ stage: SZArchiveUpdateIssueStage) -> String {
        switch stage {
        case .scan:
            SZL10n.string("progress.scanning")
        case .open:
            SZL10n.string("progress.opening")
        case .read:
            SZL10n.string("progress.analyzing")
        case .update:
            SZL10n.string("progress.updating")
        @unknown default:
            SZL10n.string("progress.errors")
        }
    }

    func issueMessage(_ issue: SZArchiveUpdateIssue) -> String {
        if let message = issue.message, !message.isEmpty {
            return message
        }
        return String(format: "0x%08X", UInt32(bitPattern: issue.errorCode))
    }

    private func updateMetrics(using snapshot: SZOperationSnapshot) {
        guard snapshot.bytesTotal > 0 else { return }
        let currentTime = now()
        if metricsStartTime == nil {
            metricsStartTime = currentTime
            metricsStartBytes = snapshot.bytesCompleted
            return
        }
        guard let metricsStartTime else { return }
        let elapsed = currentTime - metricsStartTime
        guard elapsed > 0.3,
              snapshot.bytesCompleted >= metricsStartBytes
        else {
            return
        }
        speedBytesPerSecond = Double(snapshot.bytesCompleted - metricsStartBytes) / elapsed
    }

    private static func byteString(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(value, UInt64(Int64.max))),
            countStyle: .file,
        )
    }

    private static func durationString(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(Int(seconds), 0)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        if totalSeconds < 3600 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        return "\(totalSeconds / 3600)h \((totalSeconds % 3600) / 60)m"
    }
}
