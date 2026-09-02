import Foundation

// MARK: - InferenceSetupStage

enum InferenceSetupStage: Equatable, Sendable {
    case idle
    case checkingTools
    case provisioning
    case finalizing
    case failed(String)

    var displayText: String {
        switch self {
        case .idle: return ""
        case .checkingTools: return "Checking tools…"
        case .provisioning: return "Setting up audio separation…"
        case .finalizing: return "Finalizing…"
        case .failed(let msg): return msg
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isRunning: Bool {
        switch self {
        case .checkingTools, .provisioning, .finalizing: return true
        case .idle, .failed: return false
        }
    }
}
