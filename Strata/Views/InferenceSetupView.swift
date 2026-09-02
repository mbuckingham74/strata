import SwiftUI

// MARK: - Setup checklist (presentation-only mapping over InferenceSetupStage)

/// Ordered first-run steps shown together while setup runs.
/// Provisioning order and readiness definitions live in InferenceController/RuntimeReadiness;
/// this type only maps the current stage to row states for display.
enum SetupChecklistStep: String, CaseIterable, Sendable {
    case ffmpeg
    case ytdlp
    case node
    case worker
    case model
    case final

    var title: String {
        switch self {
        case .ffmpeg: return "FFmpeg"
        case .ytdlp: return "yt-dlp"
        case .node: return "Node"
        case .worker: return "Separation engine"
        case .model: return "Model"
        case .final: return "Final check"
        }
    }
}

enum SetupChecklistRowState: Equatable, Sendable {
    case completed
    case current
    case pending
    case failed
}

enum SetupChecklist {
    /// Row states aligned with SetupChecklistStep.allCases.
    /// Skipped stages (already-resolved tools) count as completed/ready.
    static func rowStates(for stage: InferenceSetupStage, failedStep: SetupChecklistStep?) -> [SetupChecklistRowState] {
        switch stage {
        case .idle:
            return Array(repeating: .pending, count: SetupChecklistStep.allCases.count)
        case .checkingTools:
            // checkingTools prepares uv, not any checklist tool: no row is active.
            return Array(repeating: .pending, count: SetupChecklistStep.allCases.count)
        case .preparingFFmpeg:
            return states(current: .ffmpeg)
        case .preparingYtDlp:
            return states(current: .ytdlp)
        case .preparingNode:
            return states(current: .node)
        case .preparingWorker:
            return states(current: .worker)
        case .verifying:
            return states(current: .final)
        case .succeeded:
            return Array(repeating: .completed, count: SetupChecklistStep.allCases.count)
        case .failed:
            guard let failedStep else {
                // Fallback: without a remembered step, leave rows pending and
                // let the generic error text below carry the details.
                return Array(repeating: .pending, count: SetupChecklistStep.allCases.count)
            }
            return states(failed: failedStep)
        }
    }

    /// Truthful active text for the current row, matching stage wording.
    static func activeText(for step: SetupChecklistStep, stage: InferenceSetupStage) -> String {
        switch (step, stage) {
        case (.final, .verifying): return "Verifying…"
        default: return "Preparing…"
        }
    }

    private static func states(current: SetupChecklistStep) -> [SetupChecklistRowState] {
        let order = SetupChecklistStep.allCases
        guard let currentIndex = order.firstIndex(of: current) else {
            return Array(repeating: .pending, count: order.count)
        }
        return order.indices.map { $0 < currentIndex ? .completed : ($0 == currentIndex ? .current : .pending) }
    }

    private static func states(failed: SetupChecklistStep) -> [SetupChecklistRowState] {
        let order = SetupChecklistStep.allCases
        guard let failedIndex = order.firstIndex(of: failed) else {
            return Array(repeating: .pending, count: order.count)
        }
        return order.indices.map { $0 < failedIndex ? .completed : ($0 == failedIndex ? .failed : .pending) }
    }
}

struct InferenceSetupView: View {
    @Bindable var controller: InferenceController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Set Up Strata", systemImage: "arrow.down.circle.dotted")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            Text("First launch prepares what Strata needs to run on your Mac. This may take a few minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let message) = controller.setupStage {
                checklist
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("SetupErrorText")
                    Button {
                        Task { await controller.runSetup() }
                    } label: {
                        Label("Try Again", systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                    .accessibilityIdentifier("SetupTryAgainButton")
                }
            } else if controller.setupStage == .succeeded {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Strata is ready")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("SetupSuccessText")
                    Spacer()
                }
                checklist
            } else if controller.isSetupInProgress {
                if controller.setupStage == .checkingTools {
                    HStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.secondary)
                        Text("Preparing tools…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("SetupStageText")
                        Spacer()
                    }
                }
                checklist
            } else {
                Button {
                    Task { await controller.runSetup() }
                } label: {
                    Label("Set Up", systemImage: "arrow.down.circle")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityIdentifier("SetupStartButton")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        )
        .accessibilityIdentifier("InferenceSetupView")
    }

    @ViewBuilder
    private var checklist: some View {
        let states = SetupChecklist.rowStates(for: controller.setupStage, failedStep: controller.setupFailedStep)
        let steps = SetupChecklistStep.allCases
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                checklistRow(step: step, state: states[index])
            }
        }
        .accessibilityIdentifier("SetupChecklist")
    }

    @ViewBuilder
    private func checklistRow(step: SetupChecklistStep, state: SetupChecklistRowState) -> some View {
        HStack(spacing: 8) {
            Group {
                switch state {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.green)
                case .current:
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.secondary)
                        .frame(width: 12, height: 12)
                case .pending:
                    Image(systemName: "circle")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .opacity(0.55)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 12, height: 12)

            Text(step.title)
                .font(state == .current ? .caption.weight(.semibold) : .caption2.weight(.medium))
                .foregroundStyle(colorForChecklistRow(state: state))
                .opacity(state == .pending ? 0.42 : 1.0)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(statusText(step: step, state: state))
                .font(.caption2.weight(.medium))
                .foregroundStyle(state == .failed ? .red.opacity(0.9) : .secondary)
                .opacity(state == .pending ? 0.42 : 1.0)
                .lineLimit(1)
        }
        .opacity(state == .pending ? 0.45 : 1.0)
        .accessibilityIdentifier("SetupChecklistRow-\(step.title)")
    }

    private func colorForChecklistRow(state: SetupChecklistRowState) -> Color {
        switch state {
        case .completed: return Color.primary.opacity(0.85)
        case .current: return Color.primary
        case .pending: return Color.secondary
        case .failed: return Color.primary
        }
    }

    private func statusText(step: SetupChecklistStep, state: SetupChecklistRowState) -> String {
        switch state {
        case .completed:
            return "Ready"
        case .current:
            return SetupChecklist.activeText(for: step, stage: controller.setupStage)
        case .pending:
            return "Pending"
        case .failed:
            return "Couldn't finish"
        }
    }
}
