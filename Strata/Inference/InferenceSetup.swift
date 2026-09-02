import Foundation

// MARK: - InferenceSetupStage

enum InferenceSetupStage: Equatable, Sendable {
    case idle
    case checkingTools
    case preparingFFmpeg
    case preparingYtDlp
    case preparingNode
    case preparingWorker
    case verifying
    case succeeded
    case failed(String)

    var displayText: String {
        switch self {
        case .idle: return ""
        case .checkingTools: return "Checking tools…"
        case .preparingFFmpeg: return "Preparing FFmpeg…"
        case .preparingYtDlp: return "Preparing yt-dlp…"
        case .preparingNode: return "Preparing Node…"
        case .preparingWorker: return "Preparing worker and model…"
        case .verifying: return "Verifying setup…"
        case .succeeded: return "Strata is ready"
        case .failed(let msg): return msg
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isRunning: Bool {
        switch self {
        case .checkingTools, .preparingFFmpeg, .preparingYtDlp, .preparingNode, .preparingWorker, .verifying: return true
        case .idle, .succeeded, .failed: return false
        }
    }
}
