import SwiftUI

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
            } else if controller.isSetupInProgress {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.secondary)
                        .accessibilityIdentifier("SetupProgressIndicator")
                    Text(stageText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("SetupStageText")
                    Spacer()
                }
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

    private var stageText: String {
        switch controller.setupStage {
        case .idle:
            return "Ready"
        case .checkingTools:
            return "Checking tools…"
        case .preparingFFmpeg:
            return "Preparing FFmpeg…"
        case .preparingYtDlp:
            return "Preparing yt-dlp…"
        case .preparingNode:
            return "Preparing Node…"
        case .preparingWorker:
            return "Preparing worker and model…"
        case .verifying:
            return "Verifying setup…"
        case .succeeded:
            return "Strata is ready"
        case .failed(let msg):
            return msg
        }
    }
}
