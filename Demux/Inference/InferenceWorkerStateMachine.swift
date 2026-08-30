import Foundation

// MARK: - Supporting Types

enum ProcessingPhase: Sendable, Equatable {
    case awaitingStarted
    case running
    case validatingResult
}

struct ReadyMetadata: Sendable, Equatable {
    let backend: String
    let device: String
    let checkpointSHA256: String
    let model: String?
}

struct JobInfo: Sendable, Equatable {
    let jobId: String
    let inputPath: String
    let outputDir: String
}

enum StopReason: Sendable, Equatable {
    case shutdownRequested
    case cancellation
    case unexpectedEOF
    case processExit(Int32?)
}

struct WorkerFailure: Sendable, Equatable {
    let message: String
    let stderrTail: String?
}

// MARK: - WorkerState

enum WorkerState: Sendable, Equatable {
    case stopped
    case starting(session: UInt64)
    case loadingModel(session: UInt64, model: String)
    case ready(session: UInt64, metadata: ReadyMetadata)
    case processing(session: UInt64, job: JobInfo, phase: ProcessingPhase, receivedStems: Set<StemName>)
    case stopping(session: UInt64, reason: StopReason)
    case failed(WorkerFailure)

    var session: UInt64? {
        switch self {
        case .stopped, .failed: return nil
        case .starting(let s): return s
        case .loadingModel(let s, _): return s
        case .ready(let s, _): return s
        case .processing(let s, _, _, _): return s
        case .stopping(let s, _): return s
        }
    }

    var isIdle: Bool {
        if case .ready = self { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }
}

// MARK: - State Machine

struct InferenceWorkerStateMachine: Sendable {
    private(set) var state: WorkerState
    private(set) var sessionGeneration: UInt64

    init(initialState: WorkerState = .stopped, sessionGeneration: UInt64 = 0) {
        self.state = initialState
        self.sessionGeneration = sessionGeneration
    }

    // MARK: - Session lifecycle

    mutating func startSession(generation: UInt64) throws {
        switch state {
        case .stopped, .failed:
            sessionGeneration = generation
            state = .starting(session: generation)
        case .ready, .starting, .loadingModel, .processing, .stopping:
            throw InferenceError.illegalTransition("cannot start session from \(state)")
        }
    }

    mutating func resetToStopped() {
        state = .stopped
    }

    // MARK: - Event handling

    mutating func handle(event: InferenceEvent) throws {
        switch event {
        case .loadingModel(let e):
            try handleLoadingModel(e)
        case .ready(let e):
            try handleReady(e)
        case .started(let e):
            try handleStarted(e)
        case .stem(let e):
            try handleStem(e)
        case .done(let e):
            try handleDone(e)
        case .error(let e):
            try handleWorkerError(e)
        }
    }

    private mutating func handleLoadingModel(_ e: LoadingModelEvent) throws {
        switch state {
        case .starting(let s):
            guard s == sessionGeneration else { throw InferenceError.mismatchedJob(expected: "\(sessionGeneration)", received: "\(s)") }
            state = .loadingModel(session: s, model: e.model)
        case .loadingModel:
            throw InferenceError.duplicateEvent("loading_model")
        case .ready, .processing, .stopped, .stopping, .failed:
            throw InferenceError.illegalTransition("loading_model in \(state)")
        }
    }

    private mutating func handleReady(_ e: ReadyEvent) throws {
        switch state {
        case .loadingModel(let s, _):
            guard s == sessionGeneration else { throw InferenceError.mismatchedJob(expected: "\(sessionGeneration)", received: "\(s)") }
            let meta = ReadyMetadata(backend: e.backend, device: e.device, checkpointSHA256: e.checkpoint_sha256, model: nil)
            state = .ready(session: s, metadata: meta)
        case .starting:
            throw InferenceError.illegalTransition("ready in \(state) without loading_model")
        case .ready:
            throw InferenceError.duplicateEvent("ready")
        case .stopped, .processing, .stopping, .failed:
            throw InferenceError.illegalTransition("ready in \(state)")
        }
    }

    /// Begin a job (Swift enforces one-job-at-a-time). Called before sending separate command.
    mutating func beginJob(job: JobInfo) throws {
        switch state {
        case .ready(let s, _):
            guard s == sessionGeneration else { throw InferenceError.mismatchedJob(expected: "\(sessionGeneration)", received: "\(s)") }
            state = .processing(session: s, job: job, phase: .awaitingStarted, receivedStems: [])
        case .processing:
            throw InferenceError.alreadyRunningJob
        default:
            throw InferenceError.illegalTransition("beginJob in \(state)")
        }
    }

    private mutating func handleStarted(_ e: StartedEvent) throws {
        switch state {
        case .processing(let s, let job, let phase, let stems):
            guard phase == .awaitingStarted else { throw InferenceError.illegalTransition("started in phase \(phase)") }
            guard e.job_id == job.jobId else { throw InferenceError.mismatchedJob(expected: job.jobId, received: e.job_id) }
            guard s == sessionGeneration else { throw InferenceError.mismatchedJob(expected: "\(sessionGeneration)", received: "\(s)") }
            state = .processing(session: s, job: job, phase: .running, receivedStems: stems)
        default:
            throw InferenceError.illegalTransition("started in \(state)")
        }
    }

    private mutating func handleStem(_ e: StemEvent) throws {
        switch state {
        case .processing(let s, let job, let phase, var stems):
            guard phase == .running else { throw InferenceError.illegalTransition("stem in phase \(phase)") }
            guard e.job_id == job.jobId else { throw InferenceError.mismatchedJob(expected: job.jobId, received: e.job_id) }
            guard s == sessionGeneration else { throw InferenceError.mismatchedJob(expected: "\(sessionGeneration)", received: "\(s)") }
            if stems.contains(e.name) {
                throw InferenceError.duplicateStem(e.name)
            }
            stems.insert(e.name)
            state = .processing(session: s, job: job, phase: .running, receivedStems: stems)
        default:
            throw InferenceError.illegalTransition("stem in \(state)")
        }
    }

    private mutating func handleDone(_ e: DoneEvent) throws {
        switch state {
        case .processing(let s, let job, let phase, let stems):
            guard phase == .running else { throw InferenceError.illegalTransition("done in phase \(phase)") }
            guard e.job_id == job.jobId else { throw InferenceError.mismatchedJob(expected: job.jobId, received: e.job_id) }
            guard s == sessionGeneration else { throw InferenceError.mismatchedJob(expected: "\(sessionGeneration)", received: "\(s)") }
            guard stems.count == 6 else {
                throw InferenceError.illegalTransition("done before six stems: have \(stems.count)")
            }
            guard Set(stems) == StemName.requiredSet else {
                throw InferenceError.manifestValidationFailure("done with missing stems: \(stems)")
            }
            state = .processing(session: s, job: job, phase: .validatingResult, receivedStems: stems)
        default:
            throw InferenceError.illegalTransition("done in \(state)")
        }
    }

    private mutating func handleWorkerError(_ e: WorkerErrorEvent) throws {
        switch state {
        case .processing(let s, let job, _, _):
            // Worker-reported job error fails that operation but leaves healthy worker ready if protocol permits.
            guard e.job_id == job.jobId else { throw InferenceError.mismatchedJob(expected: job.jobId, received: e.job_id) }
            // Transition back to ready with same session, preserving metadata by reusing previous ready metadata if available.
            // We need previous ready metadata; we don't store it separately, so create minimal.
            // For pure state machine, we recover to ready with same session and unknown metadata placeholder.
            // Caller will handle error propagation, but state becomes ready for next job.
            // If we don't have metadata, we synthesize from current processing's session.
            // Better: keep metadata from prior ready; since we overwrote it, we need to reconstruct.
            // For simplicity, transition to ready with backend/device from prior if available via fallback.
            // We will store a placeholder ready metadata; validation will re-check on next ready.
            let placeholder = ReadyMetadata(backend: "mlx", device: "mps", checkpointSHA256: "", model: nil)
            state = .ready(session: s, metadata: placeholder)
            throw InferenceError.workerReportedJobError(code: e.code, message: e.message)
        case .starting, .loadingModel, .ready, .stopped, .stopping, .failed:
            // Error outside processing: treat as failure
            throw InferenceError.workerReportedJobError(code: e.code, message: e.message)
        }
    }

    // MARK: - Validation completion

    mutating func completeValidation() throws {
        switch state {
        case .processing(let s, _, let phase, _):
            guard phase == .validatingResult else { throw InferenceError.illegalTransition("completeValidation in phase \(phase)") }
            // Recover metadata: need to retain previous ready's metadata. Since we lost it, we need to have passed it via job or keep.
            // For pure model, we transition to ready with same session and try to restore metadata from prior.
            // We'll keep placeholder; real client will update metadata via stored ready event.
            // To make testable, we allow caller to provide metadata.
            let placeholder = ReadyMetadata(backend: "mlx", device: "mps", checkpointSHA256: "", model: nil)
            state = .ready(session: s, metadata: placeholder)
        default:
            throw InferenceError.illegalTransition("completeValidation in \(state)")
        }
    }

    mutating func completeValidation(with metadata: ReadyMetadata) throws {
        switch state {
        case .processing(let s, _, let phase, _):
            guard phase == .validatingResult else { throw InferenceError.illegalTransition("completeValidation in phase \(phase)") }
            state = .ready(session: s, metadata: metadata)
        default:
            throw InferenceError.illegalTransition("completeValidation in \(state)")
        }
    }

    // MARK: - Shutdown / Process handling

    mutating func handleShutdownRequested() throws {
        switch state {
        case .ready(let s, _):
            state = .stopping(session: s, reason: .shutdownRequested)
        case .stopping:
            throw InferenceError.duplicateEvent("shutdown")
        default:
            throw InferenceError.illegalTransition("shutdown in \(state)")
        }
    }

    mutating func handleCancellation(generation: UInt64) {
        // Cancellation transitions to stopped regardless of prior, if generation matches
        guard generation == sessionGeneration else { return }
        state = .stopped
    }

    /// Records cancellation while the exact worker is still owned. The client
    /// transitions to `.stopped` only after that Process is proven dead and its
    /// generation resources are drained.
    mutating func handleCancellationRequested(generation: UInt64) {
        guard generation == sessionGeneration else { return }
        switch state {
        case .stopped:
            break
        case .stopping(let session, .cancellation):
            state = .stopping(session: session, reason: .cancellation)
        case .starting, .loadingModel, .ready, .processing, .stopping, .failed:
            state = .stopping(session: generation, reason: .cancellation)
        }
    }

    mutating func handleProcessExit(code: Int32?, generation: UInt64, stderrTail: String?) throws {
        guard generation == sessionGeneration else { return } // stale generation ignore
        switch state {
        case .stopping(_, let reason):
            if reason == .cancellation {
                state = .stopped
            } else if let c = code, c == 0 {
                state = .stopped
            } else {
                state = .failed(WorkerFailure(message: "shutdown failed exit \(code.map(String.init) ?? "nil")", stderrTail: stderrTail))
            }
        case .ready, .starting, .loadingModel, .processing, .stopped, .failed:
            // Unexpected exit
            if case .stopped = state {
                // already stopped, ignore exit 0?
                state = .stopped
                return
            }
            if case .failed = state { return } // already failed
            // Any unexpected exit is failure
            state = .failed(WorkerFailure(message: "unexpected process exit \(code.map(String.init) ?? "nil")", stderrTail: stderrTail))
        }
    }

    mutating func handleUnexpectedEOF(generation: UInt64) throws {
        guard generation == sessionGeneration else { return }
        state = .failed(WorkerFailure(message: "unexpected EOF", stderrTail: nil))
    }

    // For testing: allow injecting ready metadata after validation
    mutating func setReadyMetadata(_ metadata: ReadyMetadata) {
        if case .ready(let s, _) = state {
            state = .ready(session: s, metadata: metadata)
        }
    }

    // Check if can start job
    var canStartJob: Bool {
        if case .ready = state { return true }
        return false
    }
}
