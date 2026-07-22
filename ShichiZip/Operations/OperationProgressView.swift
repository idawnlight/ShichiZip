import SwiftUI

struct OperationProgressView: View {
    @ObservedObject var model: OperationProgressModel

    var body: some View {
        Group {
            if model.isTerminalWarning {
                warningResultView
            } else {
                activeProgressView
            }
        }
        .frame(minWidth: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            if model.isTerminalWarning {
                model.close()
            } else {
                model.requestCancel()
            }
        }
    }

    private var activeProgressView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityLabel(model.displayTitle)
                    .accessibilityValue(model.displayTitle)
                    .accessibilityIdentifier("operationProgress.status")

                Spacer(minLength: 8)

                if let progress = model.progressValue {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .accessibilityIdentifier("operationProgress.percentage")
                }
            }

            if !model.snapshot.currentFileName.isEmpty {
                Text(model.snapshot.currentFileName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.snapshot.currentFileName)
                    .textSelection(.enabled)
                    .padding(.top, 4)
                    .accessibilityIdentifier("operationProgress.currentItem")
            }

            progressBar
                .padding(.top, 8)

            if model.totalIssueCount > 0 {
                Label(model.warningSummary,
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.top, 6)
                    .accessibilityIdentifier("operationProgress.issues")
            }

            HStack(alignment: .center, spacing: 7) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    metricRows(at: context.date)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(cancelTitle) {
                    model.requestCancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(!model.isCancelEnabled)
                .accessibilityIdentifier("operationProgress.cancel")
            }
            .padding(.top, 5)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var progressBar: some View {
        Group {
            if let value = model.progressValue {
                ProgressView(value: value, total: 1)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .accessibilityIdentifier("operationProgress.progress")
    }

    private func metricRows(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let bytes = model.bytesText {
                    Text(bytes)
                        .accessibilityIdentifier("operationProgress.bytes")
                }
                if let files = model.filesText {
                    if model.bytesText != nil {
                        Text("•")
                            .accessibilityHidden(true)
                    }
                    Text(files)
                        .accessibilityIdentifier("operationProgress.files")
                }
                Spacer(minLength: 8)
                if let speed = model.speedText {
                    Text(SZL10n.labelValue("progress.speed", value: speed))
                        .accessibilityIdentifier("operationProgress.speed")
                }
            }
            .frame(height: 14)

            HStack(spacing: 8) {
                if let elapsed = model.elapsedDuration(at: date) {
                    Text(SZL10n.labelValue("progress.elapsedTime", value: elapsed))
                        .accessibilityIdentifier("operationProgress.elapsed")
                }
                Spacer(minLength: 8)
                if let remaining = model.remainingDuration {
                    Text(SZL10n.labelValue("progress.remainingTime", value: remaining))
                        .accessibilityIdentifier("operationProgress.remaining")
                }
            }
            .frame(height: 14)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var warningResultView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityLabel(model.displayTitle)
                    .accessibilityValue(model.displayTitle)
                    .accessibilityIdentifier("operationProgress.status")

                Text(model.operationTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)

                Label(model.warningSummary,
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.top, 8)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.displayedIssues.enumerated()), id: \.offset) { index, issue in
                            issueRow(issue)
                                .accessibilityIdentifier("operationProgress.issue.\(index)")
                            if index + 1 < model.displayedIssues.count {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 230)
                .padding(.top, 8)
                .accessibilityIdentifier("operationProgress.issues")

                if model.issuesTruncated {
                    Text(SZL10n.labelValue(
                        "progress.processed",
                        value: "\(model.displayedIssues.count) / \(model.totalIssueCount)",
                    ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            HStack {
                Spacer()
                Button(SZL10n.string("common.close")) {
                    model.close()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("operationProgress.close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private func issueRow(_ issue: SZArchiveUpdateIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: issueSymbol(issue.stage))
                .frame(width: 16)
                .foregroundStyle(.orange)
                .help(model.issueStageText(issue.stage))
                .accessibilityLabel(model.issueStageText(issue.stage))

            VStack(alignment: .leading, spacing: 2) {
                if !issue.path.isEmpty {
                    Text(issue.path)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(issue.path)
                        .textSelection(.enabled)
                }
                Text(model.issueMessage(issue))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    private var cancelTitle: String {
        if model.snapshot.phase == .finalizing {
            return SZL10n.string("app.progress.finalizing")
        }
        if model.snapshot.isCancellationRequested || model.snapshot.phase == .cancelling {
            return SZL10n.string("app.progress.cancelling")
        }
        return SZL10n.string("common.cancel")
    }

    private func issueSymbol(_ stage: SZArchiveUpdateIssueStage) -> String {
        switch stage {
        case .scan:
            return "magnifyingglass"
        case .open:
            return "doc.badge.ellipsis"
        case .read:
            return "doc.text.magnifyingglass"
        case .update:
            return "arrow.triangle.2.circlepath"
        @unknown default:
            return "exclamationmark.circle"
        }
    }
}
