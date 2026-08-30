import Foundation
import CryptoKit
import AVFoundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - ApplicationExit Lifecycle Types

enum ApplicationExitCleanupResult: Sendable, Equatable {
    case safeToTerminate
    case unsafeToTerminate(reason: UnsafeReason)

    enum UnsafeReason: Sendable, Equatable {
        case workerStillRunning
        case cleanupIncomplete
        case deadlineExpired
    }
}

struct ApplicationExitPolicy: Sendable, Equatable {
    let totalBudget: Duration
    let idleGrace: Duration
    let sigtermGrace: Duration
    let sigkillGrace: Duration
    let cleanupReserve: Duration

    static let production = ApplicationExitPolicy(
        totalBudget: .seconds(4),
        idleGrace: .milliseconds(1500),
        sigtermGrace: .milliseconds(750),
        sigkillGrace: .seconds(1),
        cleanupReserve: .milliseconds(500)
    )

    init(totalBudget: Duration, idleGrace: Duration, sigtermGrace: Duration, sigkillGrace: Duration, cleanupReserve: Duration) {
        self.totalBudget = totalBudget
        self.idleGrace = idleGrace
        self.sigtermGrace = sigtermGrace
        self.sigkillGrace = sigkillGrace
        self.cleanupReserve = cleanupReserve
    }

    /// Short policy for tests.
    static func testShort(total: Duration = .milliseconds(500), idle: Duration = .milliseconds(100), sigterm: Duration = .milliseconds(100), sigkill: Duration = .milliseconds(100), reserve: Duration = .milliseconds(50)) -> ApplicationExitPolicy {
        ApplicationExitPolicy(totalBudget: total, idleGrace: idle, sigtermGrace: sigterm, sigkillGrace: sigkill, cleanupReserve: reserve)
    }

    /// Ordinary termination policy: ~5s SIGTERM + 1s SIGKILL + reserve, single deadline.
    static let ordinary = ApplicationExitPolicy(
        totalBudget: .milliseconds(6500),
        idleGrace: .zero,
        sigtermGrace: .seconds(5),
        sigkillGrace: .seconds(1),
        cleanupReserve: .milliseconds(500)
    )
}

#if DEBUG
struct WorkerLifecycleDebugSnapshot: Sendable, Equatable {
    let generation: UInt64
    let processIdentifier: Int32?
    let hasProcess: Bool
    let isProcessRunning: Bool
    let hasStdoutTask: Bool
    let hasStderrTask: Bool
    let hasTerminationObservationTask: Bool
    let hasSessionCleanupTask: Bool
    let hasReadyWait: Bool
    let hasStartedWait: Bool
    let hasResultWait: Bool

    var hasOwnedLifecycleWork: Bool {
        hasProcess
            || hasStdoutTask
            || hasStderrTask
            || hasTerminationObservationTask
            || hasSessionCleanupTask
            || hasReadyWait
            || hasStartedWait
            || hasResultWait
    }
}
#endif

// MARK: - InferenceWorkerClient

/// Sole owner of Process, pipes, generation, I/O, state machine, job tracking.
/// There must never be two live worker processes owned by one client.
/// Uses monotonically increasing process generation to guard stale callbacks.
actor InferenceWorkerClient {

    typealias ValidationStateCompletion = @Sendable (
        inout InferenceWorkerStateMachine,
        ReadyMetadata
    ) throws -> Void

    // MARK: - Generation & Process Ownership

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    private var processGeneration: UInt64 = 0
    private var stateMachine = InferenceWorkerStateMachine()

    // Bounded stderr tail for diagnostics
    private var stderrTail = Data()
    private let maxStderrTailBytes = 32 * 1024
    private let maxLineBytes = 64 * 1024

    // Concurrency — per-generation lifecycle (Sol xHigh reader tracking)
    private var stdoutTask: Task<Void, Never>? // exactly one tracked stdout consumer
    private var stderrTask: Task<Void, Never>? // exactly one tracked stderr consumer
    private var terminationObservationTask: Task<Void, Never>? // exactly one tracked termination observer
    private var sessionCleanupTask: Task<ApplicationExitCleanupResult, Never>?
    private var sessionCleanupID: UInt64 = 0
    private var sessionCleanupGeneration: UInt64?
    private var sessionCleanupProcess: Process?
    private var stdoutStream: AsyncStream<Data>?
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var stderrStream: AsyncStream<Data>?
    private var stderrContinuation: AsyncStream<Data>.Continuation?
    private var terminationStream: AsyncStream<Int32>?
    private var terminationContinuation: AsyncStream<Int32>.Continuation?
    private var invalidatedGenerations: Set<UInt64> = []
    private var observedTerminationStatus: [UInt64: Int32] = [:]

    // Job tracking
    private var separationReserved = false
    private var activeJob: JobInfo?
    private var activeJobGeneration: UInt64 = 0
    private var receivedStems: [StemName: URL] = [:]
    private var activeManifestPath: String?
    private var readyMetadata: ReadyMetadata?
    private var activeExpectedInputSHA256: String?

    // Structured one-shot signals. The waiting task owns the stream iteration;
    // the actor owns only the matching ingress continuation until that wait ends.
    private var readyWaitGeneration: UInt64?
    private var readyWaitContinuation: AsyncThrowingStream<Void, Error>.Continuation?
    private var startedWaitJobID: String?
    private var startedWaitContinuation: AsyncThrowingStream<Void, Error>.Continuation?
    private var resultWaitJobID: String?
    private var resultWaitContinuation: AsyncThrowingStream<SeparationResult, Error>.Continuation?

#if DEBUG
    private var resultWaitCompletionCount = 0
#endif

    // Test hook: capture every decoded event in order for integration assertions
    var testHook_onEvent: (@Sendable (InferenceEvent) -> Void)?
    func setTestHook(_ hook: @escaping @Sendable (InferenceEvent) -> Void) {
        testHook_onEvent = hook
    }
    func clearTestHook() {
        testHook_onEvent = nil
    }

    // Time bounds (M3)
    private let readinessTimeout: Duration
    private let startedTimeout: Duration
    private let separationTimeout: Duration
    private let validationStateCompletion: ValidationStateCompletion
    private let terminationTimeout: Duration = .seconds(5)

    // Explicit worker directory override for test isolation (avoids process-global setenv races)
    private var workerDirectoryOverride: URL?

    // MARK: - Init

    init(
        readinessTimeout: Duration = .seconds(120),
        startedTimeout: Duration = .seconds(30),
        separationTimeout: Duration = .seconds(300),
        workerDirectory: URL? = nil,
        validationStateCompletion: @escaping ValidationStateCompletion = { stateMachine, metadata in
            try stateMachine.completeValidation(with: metadata)
        }
    ) {
        self.readinessTimeout = readinessTimeout
        self.startedTimeout = startedTimeout
        self.separationTimeout = separationTimeout
        self.workerDirectoryOverride = workerDirectory
        self.validationStateCompletion = validationStateCompletion
    }

    /// Update worker directory for subsequent generations (used by tests that need generation swap without global env).
    func setWorkerDirectory(_ url: URL?) {
        workerDirectoryOverride = url
    }

    deinit {
        // Actor deinit cannot await; process termination is best-effort via synchronous cleanup
        // Actual deterministic cleanup is via shutdown() / AppLifecycleDelegate
    }

    // MARK: - Public API

    /// Separate a canonical mixture.wav via the long-lived Python worker.
    /// Creates base output directory before sending separate.
    func separate(inputPath: URL, outputBaseDir: URL) async throws -> SeparationResult {
        try await runSeparationImpl(inputPath: inputPath, outputBaseDir: outputBaseDir)
    }

    /// Backward-compatible entry used by the controller and M3 tests.
    func separateWithJobTracking(inputPath: URL, outputBaseDir: URL) async throws -> SeparationResult {
        try await runSeparationImpl(inputPath: inputPath, outputBaseDir: outputBaseDir)
    }

    func runSeparation(inputPath: URL, outputBaseDir: URL) async throws -> SeparationResult {
        try await runSeparationImpl(inputPath: inputPath, outputBaseDir: outputBaseDir)
    }

    private func runSeparationImpl(inputPath: URL, outputBaseDir: URL) async throws -> SeparationResult {
        guard !separationReserved, activeJob == nil else { throw InferenceError.alreadyRunningJob }
        separationReserved = true
        defer { separationReserved = false }

        let fm = FileManager.default
        guard fm.fileExists(atPath: inputPath.path) else {
            throw InferenceError.manifestValidationFailure("input not found: \(inputPath.path)")
        }

        let expectedInputSHA256: String
        do {
            expectedInputSHA256 = try sha256File(at: inputPath)
        } catch {
            throw InferenceError.manifestValidationFailure("input sha capture failed: \(error)")
        }

        do {
            try fm.createDirectory(at: outputBaseDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw InferenceError.outputDirectoryCreation(error.localizedDescription)
        }

        try await ensureWorkerReady()

        let jobId = UUID().uuidString.lowercased()
        let jobDir = outputBaseDir.appendingPathComponent(jobId, isDirectory: true)
        if fm.fileExists(atPath: jobDir.path) {
            throw InferenceError.manifestValidationFailure("final job directory already exists: \(jobDir.path)")
        }

        let job = JobInfo(jobId: jobId, inputPath: inputPath.path, outputDir: outputBaseDir.path)
        try stateMachine.beginJob(job: job)
        activeJob = job
        activeJobGeneration = processGeneration
        receivedStems = [:]
        activeManifestPath = nil
        activeExpectedInputSHA256 = expectedInputSHA256

        let command: SeparateCommand
        do {
            command = try SeparateCommand.make(jobId: jobId, inputPath: inputPath.path, outputDir: outputBaseDir.path)
        } catch {
            clearActiveJobIfMatching(jobID: jobId, generation: processGeneration)
            throw error
        }

        let generation = processGeneration
        do {
            // Both streams are installed before the command write, so an immediate
            // started/done response cannot beat native result registration.
            return try await sendCommandAndWaitForResult(
                command.encodeNDJSON(),
                job: job,
                generation: generation
            )
        } catch {
            clearActiveJobIfMatching(jobID: jobId, generation: generation)
            await settleWorkerAfterSeparationFailure(error, generation: generation)
            throw error
        }
    }

    /// Idle shutdown: send shutdown NDJSON, wait for exit 0, escalate if needed.
    func shutdown() async throws {
        await awaitCurrentSessionCleanup()
        guard let proc = process else {
            guard await cleanupResidualResourcesWithoutProcess() else {
                throw InferenceError.shutdownTimeout
            }
            return
        }
        if !proc.isRunning {
            let gen = processGeneration
            let ok = await finalizeCleanupAfterProvenDeath(generation: gen, snapshot: proc)
            if !ok {
                throw InferenceError.startupFailure("cleanup incomplete for dead process pid \(proc.processIdentifier)", stderrTail: stderrTailString())
            }
            if proc.terminationStatus != 0 {
                stateMachine = InferenceWorkerStateMachine(initialState: .failed(WorkerFailure(message: "shutdown exit \(proc.terminationStatus)", stderrTail: stderrTailString())), sessionGeneration: gen)
                throw InferenceError.prematureProcessExit(proc.terminationStatus, stderrTail: stderrTailString())
            }
            return
        }
        let gen = processGeneration
        let attemptGraceful: Bool
        switch stateMachine.state {
        case .ready:
            attemptGraceful = true
        case .processing:
            throw InferenceError.illegalTransition("shutdown in \(stateMachine.state)")
        case .starting, .loadingModel, .stopping, .stopped, .failed:
            attemptGraceful = false
        }
        let result = await terminateOwnedSession(
            snapshot: proc,
            generation: gen,
            policy: .ordinary,
            attemptGraceful: attemptGraceful
        )
        switch result {
        case .safeToTerminate:
            if process != nil {
                throw InferenceError.shutdownTimeout
            }
            return
        case .unsafeToTerminate:
            throw InferenceError.shutdownTimeout
        }
    }

    /// Cancellation: terminate direct Python worker, bounded wait + escalate to hard kill
    func cancelActiveJob() async {
        let gen = processGeneration
        failPendingWaits(with: .cancellation, generation: gen)
        if let job = activeJob {
            clearActiveJobIfMatching(jobID: job.jobId, generation: gen)
        }
        stateMachine.handleCancellationRequested(generation: gen)

        guard let proc = process else {
            _ = await cleanupResidualResourcesWithoutProcess()
            stateMachine.handleCancellation(generation: gen)
            return
        }

        let result = await terminateOwnedSession(
            snapshot: proc,
            generation: gen,
            policy: .ordinary,
            attemptGraceful: false
        )
        switch result {
        case .safeToTerminate:
            stateMachine.handleCancellation(generation: gen)
        case .unsafeToTerminate:
            stateMachine = InferenceWorkerStateMachine(
                initialState: .failed(WorkerFailure(message: "cancellation cleanup incomplete", stderrTail: stderrTailString())),
                sessionGeneration: gen
            )
        }
    }

    /// Non-running check for controller shutdown branching (idle vs active)
    func isProcessing() -> Bool {
        switch stateMachine.state {
        case .processing: return true
        default: return false
        }
    }

    func currentState() -> WorkerState { stateMachine.state }

#if DEBUG
    // Test-only event handler for temporal ordering tests
    private var appExitEventHandler: (@Sendable (String) -> Void)?
    func setAppExitEventHandler(_ handler: @Sendable @escaping (String) -> Void) {
        appExitEventHandler = handler
    }
    func clearAppExitEventHandler() { appExitEventHandler = nil }
    private func emitAppExitEvent(_ name: String) {
        if let h = appExitEventHandler { h(name) }
    }
#else
    @inline(__always) private func emitAppExitEvent(_ name: String) {}
#endif

    // MARK: - Application-Exit Lifecycle (Sol xHigh)

    /// Structured worker-exit lifecycle owned by InferenceWorkerClient.
    /// Snapshot exact Process/generation, use ONE absolute deadline, escalate SIGTERM->SIGKILL, verify death, retain ownership on deadline expiry.
    func terminateForApplicationExit(policy: ApplicationExitPolicy = .production) async -> ApplicationExitCleanupResult {
        let capturedProcess = process
        let capturedGeneration = processGeneration
        let preState = stateMachine.state
        failPendingWaits(with: .cancellation, generation: capturedGeneration)
        if let job = activeJob {
            clearActiveJobIfMatching(jobID: job.jobId, generation: capturedGeneration)
        }

        guard let proc = capturedProcess else {
            return await cleanupResidualResourcesWithoutProcess()
                ? .safeToTerminate
                : .unsafeToTerminate(reason: .cleanupIncomplete)
        }
        let gen = capturedGeneration
        if !proc.isRunning {
            let finalized = await finalizeCleanupAfterProvenDeath(generation: gen, snapshot: proc)
            return finalized ? .safeToTerminate : .unsafeToTerminate(reason: .cleanupIncomplete)
        }

        let hasActiveJob = activeJob != nil
            || startedWaitJobID != nil
            || resultWaitJobID != nil
            || readyWaitGeneration != nil
            || isProcessing()
        if hasActiveJob {
            stateMachine.handleCancellationRequested(generation: gen)
            emitAppExitEvent("separationTaskCancelled")
        }
        let wasIdleReady: Bool = {
            if case .ready = preState { return true } else { return false }
        }()
        return await terminateOwnedSession(
            snapshot: proc,
            generation: gen,
            policy: policy,
            attemptGraceful: wasIdleReady
        )
    }

    // MARK: - Worker Start & Ensure Ready

    private func ensureNoRetainedProcessBeforeLaunch() async throws {
        await awaitCurrentSessionCleanup()
        guard let existing = process else { return }
        // Actual retained ownership check — not just protocol state
        // If any Process is retained, must not launch replacement over potentially live Process
        let gen = processGeneration
        // If process is already dead but still retained, finalize cleanup without signals
        if !existing.isRunning {
            let finalized = await finalizeCleanupAfterProvenDeath(generation: gen, snapshot: existing)
            if !finalized || process != nil {
                throw InferenceError.startupFailure("cleanup incomplete for dead process pid \(existing.processIdentifier)", stderrTail: stderrTailString())
            }
            return
        }
        // Live retained Process — attempt bounded proven termination with ordinary policy
        let result = await terminateOwnedSession(
            snapshot: existing,
            generation: gen,
            policy: .ordinary,
            attemptGraceful: false
        )
        if case .unsafeToTerminate(let reason) = result {
            throw InferenceError.startupFailure("cannot launch replacement while previous worker still owned gen \(gen) pid \(existing.processIdentifier) reason \(reason)", stderrTail: stderrTailString())
        }
        if process != nil {
            throw InferenceError.startupFailure("ownership not released after termination gen \(gen)", stderrTail: stderrTailString())
        }
    }

    private func ensureWorkerReady() async throws {
        // Gate every launch on actual retained ownership, not just protocol state
        if let existing = process, existing.isRunning || process != nil {
            // If already ready and healthy, reuse — do not terminate healthy reusable worker
            if case .ready = stateMachine.state, existing.isRunning {
                return
            }
            // If stopped/failed but process still retained, gate must clean before launch
            // This will be handled in launch path, but we pre-check here for starting/loading races
        }
        switch stateMachine.state {
        case .ready:
            // Reuse same worker — verify process still alive
            if let p = process, !p.isRunning {
                // Protocol says ready but process dead — treat as failed and launch anew via gating
                try await ensureNoRetainedProcessBeforeLaunch()
                try await launchWorkerAndWaitReady()
                return
            }
            return
        case .stopped, .failed:
            try await ensureNoRetainedProcessBeforeLaunch()
            try await launchWorkerAndWaitReady()
            return
        case .starting, .loadingModel:
            try await waitForReady(generation: processGeneration)
            return
        case .processing, .stopping:
            throw InferenceError.illegalTransition("cannot start while \(stateMachine.state)")
        }
    }

    private func launchWorkerAndWaitReady() async throws {
        // Gate retained Process before advancing generation — operate on Process ownership, not merely .stopped/.failed
        try await ensureNoRetainedProcessBeforeLaunch()
        guard !hasResidualLifecycleResources else {
            throw InferenceError.startupFailure("previous worker lifecycle resources are not drained", stderrTail: stderrTailString())
        }
        // Only after ownership completely cleared may generation advance
        let generation = processGeneration + 1
        processGeneration = generation
        stateMachine = InferenceWorkerStateMachine(initialState: .stopped, sessionGeneration: generation)
        do {
            try stateMachine.startSession(generation: generation)
        } catch {
            throw error
        }

        let config: WorkerLaunchConfiguration
        do {
            if let override = workerDirectoryOverride {
                config = try WorkerLaunchConfiguration.resolved(workerDirectoryOverride: override.path, isDebug: true)
            } else {
                config = try WorkerLaunchConfiguration.resolved()
            }
        } catch {
            stateMachine = InferenceWorkerStateMachine(initialState: .failed(WorkerFailure(message: "\(error)", stderrTail: nil)), sessionGeneration: generation)
            throw error
        }

        // Create pipes
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        let proc = Process()
        proc.executableURL = config.processExecutableURL
        proc.arguments = config.processArguments
        proc.currentDirectoryURL = config.processCurrentDirectoryURL
        proc.environment = config.processEnvironment
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Retain snapshot before run to protect generation ownership
        // Do not overwrite stored process until proven termination above succeeded; now safe to retain new
        process = proc
        stdinPipe = inPipe
        stdoutPipe = outPipe
        stderrPipe = errPipe
        stdinHandle = inPipe.fileHandleForWriting
        stdoutHandle = outPipe.fileHandleForReading
        stderrHandle = errPipe.fileHandleForReading
        stderrTail = Data()
        invalidatedGenerations.remove(generation)

        // Observe termination via tracked stream/observation task (no untracked Task in handler)
        let terminationGen = generation
        let (tStream, tCont) = AsyncStream<Int32>.makeStream()
        terminationStream = tStream
        terminationContinuation = tCont
        proc.terminationHandler = { p in
            // Synchronous yield into per-generation stream — no Task creation
            let status = p.terminationStatus
            tCont.yield(status)
            tCont.finish()
        }
        terminationObservationTask = Task { [tStream] in
            for await status in tStream {
                await self.handleProcessTermination(generation: terminationGen, status: status)
            }
        }

        do {
            try proc.run()
        } catch {
            await resetForUnlaunchedProcess(generation: generation, snapshot: proc)
            stateMachine = InferenceWorkerStateMachine(initialState: .failed(WorkerFailure(message: "launch failed: \(error)", stderrTail: nil)), sessionGeneration: generation)
            throw InferenceError.startupFailure("launch failed: \(error)", stderrTail: nil)
        }

        // Start async readers concurrently
        startStdoutReader(generation: generation)
        startStderrReader(generation: generation)

        // Wait for ready with timeout 120s
        do {
            try await waitForReady(generation: generation)
        } catch {
            // On timeout or failure, terminate worker
            await terminateWorker(generation: generation)
            throw error
        }
    }

    private func waitForReady(generation: UInt64) async throws {
        if case .ready(let session, _) = stateMachine.state, session == generation { return }
        if case .failed(let failure) = stateMachine.state {
            throw InferenceError.startupFailure(failure.message, stderrTail: failure.stderrTail)
        }
        if invalidatedGenerations.contains(generation) { throw InferenceError.cancellation }
        guard readyWaitContinuation == nil else {
            throw InferenceError.illegalTransition("duplicate readiness waiter for generation \(generation)")
        }

        let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        readyWaitGeneration = generation
        readyWaitContinuation = continuation
        defer {
            continuation.finish()
            if readyWaitGeneration == generation {
                readyWaitGeneration = nil
                readyWaitContinuation = nil
            }
        }

        let timeout = readinessTimeout
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()
                    guard try await iterator.next() != nil else {
                        throw InferenceError.cancellation
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw InferenceError.startupTimeout
                }
                defer { group.cancelAll() }
                guard try await group.next() != nil else {
                    throw InferenceError.startupTimeout
                }
            }
        } catch is CancellationError {
            throw InferenceError.cancellation
        }
    }

    // MARK: - Stdout Reader

    private var stdoutBuffer = Data()
    private var stdoutBufferGeneration: UInt64 = 0

    private func startStdoutReader(generation: UInt64) {
        guard let handle = stdoutHandle else { return }
        precondition(stdoutTask == nil && stdoutContinuation == nil)
        stdoutBuffer = Data()
        stdoutBufferGeneration = generation
        let (stream, cont) = AsyncStream<Data>.makeStream()
        stdoutStream = stream
        stdoutContinuation = cont
        // Readability callbacks synchronously yield into per-generation stream — no Task {}
        let capturedCont = cont
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                capturedCont.finish()
                return
            }
            capturedCont.yield(data)
        }
        // Exactly one tracked stdout consumer task
        let gen = generation
        stdoutTask = Task { [stream] in
            for await chunk in stream {
                await self.handleStdoutData(chunk, generation: gen)
            }
            await self.handleStdoutEOF(generation: gen)
        }
    }

    private func handleStdoutData(_ data: Data, generation: UInt64) async {
        if invalidatedGenerations.contains(generation) { return }
        guard generation == processGeneration else { return }
        guard generation == stdoutBufferGeneration else { return }
        stdoutBuffer.append(data)
        // Process complete lines
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.prefix(upTo: newlineIndex)
            if lineData.count > maxLineBytes {
                stdoutBuffer.removeAll()
                await handleProtocolError(InferenceError.malformedProtocol("line exceeds 64 KiB"), generation: generation)
                return
            }
            stdoutBuffer.removeSubrange(...newlineIndex)
            if lineData.isEmpty {
                await handleProtocolError(InferenceError.malformedProtocol("blank stdout line"), generation: generation)
                continue
            }
            await handleStdoutLine(lineData, generation: generation)
        }
        if stdoutBuffer.count > maxLineBytes {
            await handleProtocolError(InferenceError.malformedProtocol("line exceeds 64 KiB without newline"), generation: generation)
            return
        }
    }

    private func startStderrReader(generation: UInt64) {
        guard let handle = stderrHandle else { return }
        precondition(stderrTask == nil && stderrContinuation == nil)
        let (stream, cont) = AsyncStream<Data>.makeStream()
        stderrStream = stream
        stderrContinuation = cont
        let capturedCont = cont
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                capturedCont.finish()
                return
            }
            capturedCont.yield(data)
        }
        let gen = generation
        stderrTask = Task { [stream] in
            for await chunk in stream {
                await self.appendStderr(chunk, generation: gen)
            }
        }
    }

    private func appendStderr(_ data: Data, generation: UInt64) async {
        if invalidatedGenerations.contains(generation) { return }
        guard generation == processGeneration else { return }
        stderrTail.append(data)
        if stderrTail.count > maxStderrTailBytes {
            // Keep only tail
            stderrTail = stderrTail.suffix(maxStderrTailBytes)
        }
    }

    private func stderrTailString() -> String? {
        guard !stderrTail.isEmpty else { return nil }
        return String(data: stderrTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "<non-utf8 \(stderrTail.count) bytes>"
    }

    // MARK: - Stdout Line Handling

    private func handleStdoutLine(_ data: Data, generation: UInt64) async {
        if invalidatedGenerations.contains(generation) { return }
        guard generation == processGeneration else { return }
        let event: InferenceEvent
        do {
            event = try decodeEvent(from: data)
        } catch let e as InferenceError {
            await handleProtocolError(e, generation: generation)
            return
        } catch {
            await handleProtocolError(.malformedProtocol("\(error)"), generation: generation)
            return
        }

        // State machine handling
        do {
            testHook_onEvent?(event)

            try stateMachine.handle(event: event)

            // After successful handle, update tracking and signal structured waiters.
            switch event {
            case .loadingModel:
                // nothing else
                break
            case .ready(let e):
                readyMetadata = ReadyMetadata(backend: e.backend, device: e.device, checkpointSHA256: e.checkpoint_sha256, model: nil)
                stateMachine.setReadyMetadata(readyMetadata!)

                if readyWaitGeneration == generation {
                    readyWaitContinuation?.yield(())
                    readyWaitContinuation?.finish()
                }
            case .started(let e):
                guard e.job_id == activeJob?.jobId else { break }
                if startedWaitJobID == e.job_id {
                    startedWaitContinuation?.yield(())
                    startedWaitContinuation?.finish()
                }
            case .stem(let e):
                guard e.job_id == activeJob?.jobId else { break }
                receivedStems[e.name] = URL(fileURLWithPath: e.path)
            case .done(let e):
                guard let job = activeJob, e.job_id == job.jobId else { break }
                activeManifestPath = e.output_manifest
                // Transition is to validatingResult; now validate
                await validateAndComplete(job: job, manifestPath: e.output_manifest, generation: generation)
            case .error:
                break
            }
        } catch let err as InferenceError {
            switch err {
            case .workerReportedJobError:
                if case .ready(let session, _) = stateMachine.state, let metadata = readyMetadata {
                    stateMachine = InferenceWorkerStateMachine(
                        initialState: .ready(session: session, metadata: metadata),
                        sessionGeneration: session
                    )
                }
                failPendingWaits(with: err, generation: generation)
                if let job = activeJob {
                    clearActiveJobIfMatching(jobID: job.jobId, generation: generation)
                }
            default:
                failWorkerSession(error: err, generation: generation)
            }
        } catch {
            failWorkerSession(error: .malformedProtocol("\(error)"), generation: generation)
        }
    }

    private func handleProtocolError(_ error: InferenceError, generation: UInt64) async {
        if invalidatedGenerations.contains(generation) { return }
        guard generation == processGeneration else { return }
        failWorkerSession(error: error, generation: generation)
    }

    private func failWorkerSession(error: InferenceError, generation: UInt64) {
        if invalidatedGenerations.contains(generation) { return }
        guard generation == processGeneration else { return }
        let failure = WorkerFailure(message: "\(error)", stderrTail: stderrTailString())
        stateMachine = InferenceWorkerStateMachine(initialState: .failed(failure), sessionGeneration: generation)
        failPendingWaits(with: error, generation: generation)
    }

    private func handleStdoutEOF(generation: UInt64) async {
        if invalidatedGenerations.contains(generation) { return }
        guard generation == processGeneration else { return }
        // Unexpected EOF unless we are in stopping/shutdown
        switch stateMachine.state {
        case .stopping:
            // Expected idle shutdown EOF
            // Check exit status later via termination handler
            break
        case .stopped:
            break
        default:
            // Unexpected
            do {
                try stateMachine.handleUnexpectedEOF(generation: generation)
            } catch {}
            let tail = stderrTailString()
            let err = InferenceError.unexpectedEOF("stdout EOF in \(stateMachine.state) \(tail ?? "")")
            failWorkerSession(error: err, generation: generation)
        }
    }

    private func handleProcessTermination(generation: UInt64, status: Int32) async {
        // Must consult invalidatedGenerations — stale generation must not mutate current state
        if invalidatedGenerations.contains(generation) { return }
        guard generation == processGeneration else { return }
        // Record observed termination for outer owner — do not finalize inline and do not await self
        observedTerminationStatus[generation] = status
        emitAppExitEvent("processExitObserved")
        let stateBeforeExit = stateMachine.state
        let tail = stderrTailString()
        do {
            try stateMachine.handleProcessExit(code: status, generation: generation, stderrTail: tail)
        } catch {}
        let error: InferenceError
        if case .stopping(_, .cancellation) = stateBeforeExit {
            error = .cancellation
        } else {
            error = .prematureProcessExit(status, stderrTail: tail)
        }
        failPendingWaits(with: error, generation: generation)
    }

    // MARK: - Stdin Write

    private func writeCommand(_ data: Data, generation: UInt64) throws {
        guard generation == processGeneration else { throw InferenceError.mismatchedJob(expected: "\(processGeneration)", received: "\(generation)") }
        guard let handle = stdinHandle else { throw InferenceError.stdinWriteFailure("no stdin handle") }
        guard let proc = process, proc.isRunning else {
            throw InferenceError.prematureProcessExit(nil, stderrTail: stderrTailString())
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw InferenceError.stdinWriteFailure(error.localizedDescription)
        }
    }

    // MARK: - Result Validation & Waiting

    private func sendCommandAndWaitForResult(
        _ data: Data,
        job: JobInfo,
        generation: UInt64
    ) async throws -> SeparationResult {
        guard generation == processGeneration, !invalidatedGenerations.contains(generation) else {
            throw InferenceError.cancellation
        }
        guard startedWaitContinuation == nil, resultWaitContinuation == nil else {
            throw InferenceError.alreadyRunningJob
        }

        let (startedStream, startedContinuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let (resultStream, resultContinuation) = AsyncThrowingStream<SeparationResult, Error>.makeStream()
        startedWaitJobID = job.jobId
        startedWaitContinuation = startedContinuation
        resultWaitJobID = job.jobId
        resultWaitContinuation = resultContinuation
        defer {
            startedContinuation.finish()
            if startedWaitJobID == job.jobId {
                startedWaitJobID = nil
                startedWaitContinuation = nil
            }
            if resultWaitJobID == job.jobId {
                resultWaitJobID = nil
                resultWaitContinuation = nil
                resultContinuation.finish()
            }
        }

        let overallDeadline = ContinuousClock.now + separationTimeout
        try writeCommand(data, generation: generation)
        try await waitForStartedSignal(startedStream, timeout: startedTimeout)

        let remaining = ContinuousClock.now < overallDeadline
            ? overallDeadline - ContinuousClock.now
            : Duration.zero
        guard remaining > .zero else { throw InferenceError.startupTimeout }
        return try await waitForResultSignal(resultStream, timeout: remaining)
    }

    private func waitForStartedSignal(
        _ stream: AsyncThrowingStream<Void, Error>,
        timeout: Duration
    ) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()
                    guard try await iterator.next() != nil else {
                        throw InferenceError.cancellation
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw InferenceError.startupTimeout
                }
                defer { group.cancelAll() }
                guard try await group.next() != nil else { throw InferenceError.startupTimeout }
            }
        } catch is CancellationError {
            throw InferenceError.cancellation
        }
    }

    private func waitForResultSignal(
        _ stream: AsyncThrowingStream<SeparationResult, Error>,
        timeout: Duration
    ) async throws -> SeparationResult {
        do {
            return try await withThrowingTaskGroup(of: SeparationResult.self) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()
                    guard let result = try await iterator.next() else {
                        throw InferenceError.cancellation
                    }
                    return result
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw InferenceError.startupTimeout
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw InferenceError.startupTimeout }
                return result
            }
        } catch is CancellationError {
            throw InferenceError.cancellation
        }
    }

    private func failPendingWaits(with error: InferenceError, generation: UInt64) {
        if readyWaitGeneration == generation {
            readyWaitContinuation?.finish(throwing: error)
        }
        if activeJobGeneration == generation {
            startedWaitContinuation?.finish(throwing: error)
            if let jobID = resultWaitJobID {
                finishResultWait(jobID: jobID, with: .failure(error))
            }
        }
    }

    private func finishResultWait(
        jobID: String,
        with outcome: Result<SeparationResult, InferenceError>
    ) {
        guard resultWaitJobID == jobID, let continuation = resultWaitContinuation else { return }
        resultWaitJobID = nil
        resultWaitContinuation = nil
#if DEBUG
        resultWaitCompletionCount += 1
#endif
        switch outcome {
        case .success(let result):
            continuation.yield(result)
            continuation.finish()
        case .failure(let error):
            continuation.finish(throwing: error)
        }
    }

    private func clearActiveJobIfMatching(jobID: String, generation: UInt64) {
        guard activeJobGeneration == generation, activeJob?.jobId == jobID else { return }
        activeJob = nil
        receivedStems = [:]
        activeManifestPath = nil
        activeExpectedInputSHA256 = nil
    }

    private func settleWorkerAfterSeparationFailure(_ error: Error, generation: UInt64) async {
        guard generation == processGeneration else { return }
        if let inferenceError = error as? InferenceError {
            switch inferenceError {
            case .workerReportedJobError, .manifestValidationFailure:
                return
            case .cancellation:
                // Explicit cancel/application-exit records this intent before it
                // fails the waiter. That owner is solely responsible for the
                // exact Process cleanup; a waiter waking after an unsafe/deadline
                // result must not start a new ordinary cleanup task.
                if case .stopping(_, .cancellation) = stateMachine.state {
                    return
                }
                stateMachine.handleCancellationRequested(generation: generation)
            default:
                if case .failed = stateMachine.state {} else {
                    stateMachine = InferenceWorkerStateMachine(
                        initialState: .failed(WorkerFailure(message: "\(inferenceError)", stderrTail: stderrTailString())),
                        sessionGeneration: generation
                    )
                }
            }
        }
        await terminateWorker(generation: generation)
    }

    // MARK: - Validation

    private func validateAndComplete(job: JobInfo, manifestPath: String, generation: UInt64) async {
        if invalidatedGenerations.contains(generation) { return }
        guard generation == processGeneration else { return }
        guard generation == activeJobGeneration else { return }

        // Retrieve metadata
        guard let meta = readyMetadata else {
            let err = InferenceError.manifestValidationFailure("missing ready metadata")
            finishResultWait(jobID: job.jobId, with: .failure(err))
            return
        }

        // Capture expected input SHA for this generation (trusted native identity)
        let expectedInputSHA = activeExpectedInputSHA256
        do {
            let result = try await performValidation(
                job: job,
                manifestPath: manifestPath,
                receivedStems: receivedStems,
                metadata: meta,
                generation: generation,
                expectedInputSHA256: expectedInputSHA
            )
            try validationStateCompletion(&stateMachine, meta)
            // Cleanup job state
            activeJob = nil
            receivedStems = [:]
            activeManifestPath = nil
            activeExpectedInputSHA256 = nil
            finishResultWait(jobID: job.jobId, with: .success(result))
        } catch {
            let validationError = (error as? InferenceError)
                ?? InferenceError.manifestValidationFailure("validation failed: \(error)")
            activeJob = nil
            receivedStems = [:]
            activeManifestPath = nil
            activeExpectedInputSHA256 = nil
            // The result is invalid, but a protocol-healthy worker can accept a
            // later job after its per-job state is discarded.
            if case .processing(let s, _, .validatingResult, _) = stateMachine.state {
                stateMachine = InferenceWorkerStateMachine(initialState: .ready(session: s, metadata: meta), sessionGeneration: s)
            }
            finishResultWait(jobID: job.jobId, with: .failure(validationError))
        }
    }

    private func performValidation(
        job: JobInfo,
        manifestPath: String,
        receivedStems: [StemName: URL],
        metadata: ReadyMetadata,
        generation: UInt64,
        expectedInputSHA256: String? = nil
    ) async throws -> SeparationResult {
        // Delegate to canonical validator which enforces 44.1k stereo but not a fixed 882k; frame count is validated as positive and consistent with manifest/inputMetadata/stems.
        let manifestURL = URL(fileURLWithPath: manifestPath)
        return try SeparationValidator.validatedResult(
            manifestURL: manifestURL,
            job: job,
            readyMetadata: metadata,
            receivedStems: receivedStems,
            expectedInputSHA256: expectedInputSHA256
        )
    }

    // MARK: - Central Proven-Death Termination Primitive (Sol xHigh §1)

    /// Coalesces every termination request for one exact Process/generation into
    /// one retained task. Concurrent cancel, shutdown, app-exit, and launch-gate
    /// callers join this task instead of running competing signal/finalizer paths.
    private func terminateOwnedSession(
        snapshot: Process,
        generation: UInt64,
        policy: ApplicationExitPolicy,
        attemptGraceful: Bool
    ) async -> ApplicationExitCleanupResult {
        if let existingTask = sessionCleanupTask {
            let existingID = sessionCleanupID
            let matches = sessionCleanupGeneration == generation && sessionCleanupProcess === snapshot
            let result = await existingTask.value
            if sessionCleanupID == existingID {
                sessionCleanupTask = nil
                sessionCleanupGeneration = nil
                sessionCleanupProcess = nil
            }
            if matches { return result }
        }

        guard generation == processGeneration, process === snapshot else {
            return .unsafeToTerminate(reason: .cleanupIncomplete)
        }

        sessionCleanupID &+= 1
        let cleanupID = sessionCleanupID
        let task = Task {
            await self.performProvenTermination(
                snapshot: snapshot,
                generation: generation,
                policy: policy,
                attemptGraceful: attemptGraceful
            )
        }
        sessionCleanupGeneration = generation
        sessionCleanupProcess = snapshot
        sessionCleanupTask = task

        let result = await task.value
        if sessionCleanupID == cleanupID {
            sessionCleanupTask = nil
            sessionCleanupGeneration = nil
            sessionCleanupProcess = nil
        }
        return result
    }

    private func awaitCurrentSessionCleanup() async {
        guard let task = sessionCleanupTask else { return }
        let cleanupID = sessionCleanupID
        _ = await task.value
        if sessionCleanupID == cleanupID {
            sessionCleanupTask = nil
            sessionCleanupGeneration = nil
            sessionCleanupProcess = nil
        }
    }

    /// Single raw termination implementation. It is invoked only by the owned
    /// session task above.
    private func performProvenTermination(
        snapshot: Process,
        generation: UInt64,
        policy: ApplicationExitPolicy,
        attemptGraceful: Bool
    ) async -> ApplicationExitCleanupResult {
        guard generation == processGeneration, process === snapshot else {
            return .unsafeToTerminate(reason: .cleanupIncomplete)
        }
        if !snapshot.isRunning {
            return await finalizeTerminationResult(generation: generation, snapshot: snapshot)
        }

        let deadline = ContinuousClock.now + max(policy.totalBudget, .zero)
        func remaining() -> Duration {
            let now = ContinuousClock.now
            return now >= deadline ? .zero : deadline - now
        }
        func pollForExit(timeout: Duration) async -> Bool {
            if timeout <= .zero { return !snapshot.isRunning }
            let pollDeadline = min(ContinuousClock.now + timeout, deadline)
            while ContinuousClock.now < pollDeadline {
                guard generation == processGeneration, process === snapshot else { return false }
                if !snapshot.isRunning {
                    emitAppExitEvent("processExitObserved")
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return !snapshot.isRunning
        }

        // Optional graceful attempt only when legal and requested
        if attemptGraceful && snapshot.isRunning {
            if case .ready = stateMachine.state {
                do {
                    try stateMachine.handleShutdownRequested()
                    let cmd = ShutdownCommand()
                    let data = try cmd.encodeNDJSON()
                    if remaining() <= .zero {
                        return .unsafeToTerminate(reason: .deadlineExpired)
                    }
                    try writeCommand(data, generation: generation)
                    emitAppExitEvent("shutdownSent")
                    let rem = remaining()
                    if rem <= .zero {
                        return .unsafeToTerminate(reason: .deadlineExpired)
                    }
                    let avail = rem > policy.cleanupReserve ? rem - policy.cleanupReserve : rem
                    let wait = min(policy.idleGrace, avail)
                    if wait > .zero {
                        let exited = await pollForExit(timeout: wait)
                        if exited && !snapshot.isRunning {
                            return await finalizeTerminationResult(generation: generation, snapshot: snapshot)
                        }
                    } else if !snapshot.isRunning {
                        return await finalizeTerminationResult(generation: generation, snapshot: snapshot)
                    }
                } catch {
                    // graceful failed — fall through to SIGTERM
                }
            }
        }

        // SIGTERM phase
        guard generation == processGeneration, process === snapshot else {
            return .unsafeToTerminate(reason: .cleanupIncomplete)
        }
        if snapshot.isRunning {
            let rem = remaining()
            if rem <= .zero {
                return .unsafeToTerminate(reason: .deadlineExpired)
            }
            snapshot.terminate()
            emitAppExitEvent("sigtermSent")
            let rem2 = remaining()
            if rem2 <= .zero {
                return snapshot.isRunning
                    ? .unsafeToTerminate(reason: .workerStillRunning)
                    : await finalizeTerminationResult(generation: generation, snapshot: snapshot)
            }
            let avail = rem2 > policy.cleanupReserve ? rem2 - policy.cleanupReserve : rem2
            let wait = min(policy.sigtermGrace, avail)
            if wait > .zero {
                let exited = await pollForExit(timeout: wait)
                if exited && !snapshot.isRunning {
                    return await finalizeTerminationResult(generation: generation, snapshot: snapshot)
                }
            } else {
                if !snapshot.isRunning {
                    return await finalizeTerminationResult(generation: generation, snapshot: snapshot)
                }
                if snapshot.isRunning {
                    return .unsafeToTerminate(reason: .deadlineExpired)
                }
            }
        } else if !snapshot.isRunning {
            return await finalizeTerminationResult(generation: generation, snapshot: snapshot)
        }

        // SIGKILL phase
        guard generation == processGeneration, process === snapshot else {
            return .unsafeToTerminate(reason: .cleanupIncomplete)
        }
        if snapshot.isRunning {
            let rem = remaining()
            if rem <= .zero {
                return .unsafeToTerminate(reason: .deadlineExpired)
            }
            let pid = snapshot.processIdentifier
#if canImport(Darwin)
            Darwin.kill(pid, SIGKILL)
#endif
            emitAppExitEvent("sigkillSent")
            let rem2 = remaining()
            if rem2 <= .zero {
                if snapshot.isRunning {
                    return .unsafeToTerminate(reason: .workerStillRunning)
                } else {
                    return await finalizeTerminationResult(generation: generation, snapshot: snapshot)
                }
            }
            let avail = rem2 > policy.cleanupReserve ? rem2 - policy.cleanupReserve : rem2
            let wait = min(policy.sigkillGrace, avail)
            let exited: Bool
            if wait > .zero {
                exited = await pollForExit(timeout: wait)
            } else {
                exited = !snapshot.isRunning
            }
            if exited && !snapshot.isRunning {
                return await finalizeTerminationResult(generation: generation, snapshot: snapshot)
            } else {
                return .unsafeToTerminate(reason: .workerStillRunning)
            }
        }

        if !snapshot.isRunning {
            return await finalizeTerminationResult(generation: generation, snapshot: snapshot)
        } else {
            return .unsafeToTerminate(reason: .workerStillRunning)
        }
    }

    private func finalizeTerminationResult(
        generation: UInt64,
        snapshot: Process
    ) async -> ApplicationExitCleanupResult {
        guard generation == processGeneration, process === snapshot, !snapshot.isRunning else {
            return .unsafeToTerminate(reason: snapshot.isRunning ? .workerStillRunning : .cleanupIncomplete)
        }
        let finalized = await finalizeCleanupAfterProvenDeath(generation: generation, snapshot: snapshot)
        guard finalized, process == nil, !hasResidualLifecycleResourcesExcludingSessionTask else {
            return .unsafeToTerminate(reason: .cleanupIncomplete)
        }
        return .safeToTerminate
    }

    /// Generation-G cleanup complete only after 10 steps and proven death.
    /// Narrowly named unlaunched-process reset — for proc.run failure only.
    /// May clear locally created pipes/handlers/tasks only after proving Process was never launched and is not running.
    /// Do not represent this as ordinary post-launch process cleanup.
    private func resetForUnlaunchedProcess(generation: UInt64, snapshot: Process) async {
        guard generation == processGeneration else { return }
        guard !snapshot.isRunning else { return }
        guard process === snapshot else { return }
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutContinuation?.finish()
        stderrContinuation?.finish()
        terminationContinuation?.finish()
        failPendingWaits(with: .cancellation, generation: generation)
        invalidatedGenerations.insert(generation)
        let st = stdoutTask
        let et = stderrTask
        let tt = terminationObservationTask
        if let t = st { await t.value }
        if let t = et { await t.value }
        if let t = tt { await t.value }
        stdoutTask = nil
        stderrTask = nil
        terminationObservationTask = nil
        stdoutStream = nil; stdoutContinuation = nil; stderrStream = nil; stderrContinuation = nil; terminationStream = nil; terminationContinuation = nil
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        process?.terminationHandler = nil
        process = nil; stdinPipe = nil; stdoutPipe = nil; stderrPipe = nil; stdinHandle = nil; stdoutHandle = nil; stderrHandle = nil
        // Do not emit cleanupComplete as ordinary post-launch cleanup; this is unlaunched reset
    }

    /// Death-preconditioned finalizer — truthful cleanupComplete only after proven death.
    /// Verifies at entry that exact Process is no longer running and stored Process if present is that exact object.
    /// Refuses without emitting if death not proven, never performs additional independent death waiting.
    private func finalizeCleanupAfterProvenDeath(generation: UInt64, snapshot: Process) async -> Bool {
        guard !snapshot.isRunning else { return false }
        guard process === snapshot, generation == processGeneration else { return false }

        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        terminationContinuation?.finish()
        invalidatedGenerations.insert(generation)
        stdoutContinuation?.finish()
        stderrContinuation?.finish()
        failPendingWaits(with: .cancellation, generation: generation)

        let st = stdoutTask
        let et = stderrTask
        let tt = terminationObservationTask
        if let t = st { await t.value }
        if let t = et { await t.value }
        if let t = tt { await t.value }

        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()

        stdoutTask = nil
        stderrTask = nil
        terminationObservationTask = nil
        stdoutStream = nil
        stdoutContinuation = nil
        stderrStream = nil
        stderrContinuation = nil
        terminationStream = nil
        terminationContinuation = nil
        observedTerminationStatus.removeValue(forKey: generation)

        if readyWaitGeneration == generation {
            readyWaitGeneration = nil
            readyWaitContinuation = nil
        }
        if activeJobGeneration == generation {
            startedWaitJobID = nil
            startedWaitContinuation = nil
            resultWaitJobID = nil
            resultWaitContinuation = nil
            activeJob = nil
            receivedStems = [:]
            activeManifestPath = nil
            activeExpectedInputSHA256 = nil
        }

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        readyMetadata = nil
        stateMachine.resetToStopped()

        emitAppExitEvent("cleanupComplete")
        if invalidatedGenerations.count > 64 {
            let sorted = invalidatedGenerations.sorted()
            let toRemove = sorted.prefix(invalidatedGenerations.count - 32)
            for g in toRemove { invalidatedGenerations.remove(g) }
        }
        return true
    }

    private func terminateWorker(generation: UInt64) async {
        guard generation == processGeneration else { return }
        guard let snapshot = process else {
            _ = await cleanupResidualResourcesWithoutProcess()
            return
        }
        if !snapshot.isRunning {
            _ = await finalizeCleanupAfterProvenDeath(generation: generation, snapshot: snapshot)
            return
        }
        _ = await terminateOwnedSession(
            snapshot: snapshot,
            generation: generation,
            policy: .ordinary,
            attemptGraceful: false
        )
    }

    private func cleanupResidualResourcesWithoutProcess() async -> Bool {
        await awaitCurrentSessionCleanup()
        guard process == nil else { return false }

        let hadResources = hasResidualLifecycleResourcesExcludingSessionTask
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutContinuation?.finish()
        stderrContinuation?.finish()
        terminationContinuation?.finish()
        failPendingWaits(with: .cancellation, generation: processGeneration)
        invalidatedGenerations.insert(processGeneration)

        let st = stdoutTask
        let et = stderrTask
        let tt = terminationObservationTask
        if let t = st { await t.value }
        if let t = et { await t.value }
        if let t = tt { await t.value }

        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdoutTask = nil
        stderrTask = nil
        terminationObservationTask = nil
        stdoutStream = nil
        stdoutContinuation = nil
        stderrStream = nil
        stderrContinuation = nil
        terminationStream = nil
        terminationContinuation = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        readyWaitGeneration = nil
        readyWaitContinuation = nil
        startedWaitJobID = nil
        startedWaitContinuation = nil
        resultWaitJobID = nil
        resultWaitContinuation = nil
        activeJob = nil
        receivedStems = [:]
        activeManifestPath = nil
        activeExpectedInputSHA256 = nil
        readyMetadata = nil
        observedTerminationStatus.removeAll()
        stateMachine.resetToStopped()
        if hadResources { emitAppExitEvent("cleanupComplete") }
        return !hasResidualLifecycleResourcesExcludingSessionTask
    }

    private var hasResidualLifecycleResources: Bool {
        sessionCleanupTask != nil || hasResidualLifecycleResourcesExcludingSessionTask
    }

    private var hasResidualLifecycleResourcesExcludingSessionTask: Bool {
        process != nil
            || stdinPipe != nil || stdoutPipe != nil || stderrPipe != nil
            || stdinHandle != nil || stdoutHandle != nil || stderrHandle != nil
            || stdoutTask != nil || stderrTask != nil || terminationObservationTask != nil
            || stdoutStream != nil || stdoutContinuation != nil
            || stderrStream != nil || stderrContinuation != nil
            || terminationStream != nil || terminationContinuation != nil
            || readyWaitGeneration != nil || readyWaitContinuation != nil
            || startedWaitJobID != nil || startedWaitContinuation != nil
            || resultWaitJobID != nil || resultWaitContinuation != nil
    }

    // MARK: - DEBUG-only startup seam (M3 startup proof)

#if DEBUG
    /// Minimal DEBUG seam to invoke existing worker-readiness path without duplicating startup logic.
    /// Exercises: WorkerLaunchConfiguration, Foundation Process, NDJSON protocol, state machine.
    func startupForTesting() async throws {
        try await ensureWorkerReady()
    }

    func debugReadyMetadata() async -> ReadyMetadata? {
        readyMetadata
    }

    func debugProcessInfo() async -> (executable: URL?, arguments: [String]?, cwd: URL?, pid: Int32?, isRunning: Bool) {
        guard let p = process else { return (nil, nil, nil, nil, false) }
        return (p.executableURL, p.arguments, p.currentDirectoryURL, p.processIdentifier, p.isRunning)
    }

    func debugIsRunning() async -> Bool {
        process?.isRunning ?? false
    }

    func debugProcessIdentifier() async -> Int32? {
        process?.processIdentifier
    }

    func debugProcess() async -> Process? {
        process
    }

    func debugHasProcessReference() async -> Bool {
        process != nil
    }

    func debugLifecycleSnapshot() -> WorkerLifecycleDebugSnapshot {
        WorkerLifecycleDebugSnapshot(
            generation: processGeneration,
            processIdentifier: process?.processIdentifier,
            hasProcess: process != nil,
            isProcessRunning: process?.isRunning ?? false,
            hasStdoutTask: stdoutTask != nil,
            hasStderrTask: stderrTask != nil,
            hasTerminationObservationTask: terminationObservationTask != nil,
            hasSessionCleanupTask: sessionCleanupTask != nil,
            hasReadyWait: readyWaitGeneration != nil || readyWaitContinuation != nil,
            hasStartedWait: startedWaitJobID != nil || startedWaitContinuation != nil,
            hasResultWait: resultWaitJobID != nil || resultWaitContinuation != nil
        )
    }

    func debugResultWaitCompletionCount() -> Int {
        resultWaitCompletionCount
    }
#endif
}

// MARK: - InferenceError helpers for missing cases

extension InferenceError {
    static func from(_ error: Error) -> InferenceError {
        if let e = error as? InferenceError { return e }
        return .malformedProtocol("\(error)")
    }
}
