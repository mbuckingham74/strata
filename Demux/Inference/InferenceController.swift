import Foundation
import SwiftUI

// MARK: - InferenceController

@MainActor
@Observable
final class InferenceController {

    // MARK: - UI State

    enum SeparationState: Sendable, Equatable {
        case idle
        case loadingModel
        case separating
        case completed
        case failed(String)
    }

    private(set) var state: SeparationState = .idle
    private(set) var statusMessage: String = "Ready to separate"
    private(set) var result: SeparationResult?
    private(set) var errorMessage: String?

    var isSeparating: Bool {
        if case .separating = state { return true }
        if case .loadingModel = state { return true }
        return false
    }

    var canStart: Bool { !isSeparating }

    // MARK: - Ownership

    private let client: InferenceWorkerClient
    private var currentTask: Task<Void, Never>?
    private var cleanupChainTail: Task<Void, Never>?
    private var cleanupChainId: UInt64 = 0
    private var operationGeneration: UInt64 = 0
    private var latestGeneration: UInt64 = 0

#if DEBUG
    func debugHasPendingCancellationCleanup() -> Bool { cleanupChainTail != nil }
    func debugCurrentTask() -> Task<Void, Never>? { currentTask }
    func debugPendingCancellationTask() -> Task<Void, Never>? { cleanupChainTail }
    func debugCleanupChainTail() -> Task<Void, Never>? { cleanupChainTail }
#endif

    // Output base per spec: ~/Library/Caches/Demux/M3Separations/
    private let outputBaseOverride: URL?
    private var outputBaseURL: URL {
        if let override = outputBaseOverride { return override }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("Demux/M3Separations", isDirectory: true)
    }

    init(client: InferenceWorkerClient = InferenceWorkerClient()) {
        self.client = client
        self.outputBaseOverride = nil
    }

    // Convenience for testing injection — stores override for deterministic temp output in tests
    init(client: InferenceWorkerClient, outputBase: URL) {
        self.client = client
        self.outputBaseOverride = outputBase
    }

    deinit {
        // MainActor-isolated currentTask cannot be accessed from nonisolated deinit.
        // Cancellation is handled via shutdownWorker / cancel() paths; no action here.
    }

    // MARK: - Public API

    /// Start separation for a canonical WAV input URL.
    func startSeparation(inputURL: URL) {
        let generation = operationGeneration + 1
        operationGeneration = generation
        latestGeneration = generation

        // A replacement task transitively owns and joins the task it supersedes.
        // The previous handle is never discarded while it may still be running.
        let previousTask = currentTask
        previousTask?.cancel()

        // Reset UI state for new operation
        state = .loadingModel
        statusMessage = "Loading model…"
        result = nil
        errorMessage = nil

        let client = self.client
        let base = outputBaseURL

        currentTask = Task { [previousTask] in
            if let previousTask { await previousTask.value }
            await self.drainCleanupChain()

            do {
                try Task.checkCancellation()
                let separationResult = try await client.runSeparation(inputPath: inputURL, outputBaseDir: base)

                // Generation guard: old operation must not overwrite newer
                guard generation == self.latestGeneration else { return }
                guard !Task.isCancelled else { return }

                self.result = separationResult
                self.state = .completed
                self.statusMessage = "Complete — \(separationResult.stems.count) stems"
                self.errorMessage = nil

            } catch is CancellationError {
                guard generation == self.latestGeneration else { return }
                self.state = .failed("Cancelled")
                self.statusMessage = "Cancelled"
                self.errorMessage = "Cancelled"
            } catch let err as InferenceError {
                guard generation == self.latestGeneration else { return }
                if case .cancellation = err {
                    self.state = .failed("Cancelled")
                    self.statusMessage = "Cancelled"
                    self.errorMessage = "Cancelled"
                } else {
                    // Concise user-visible failure (no traceback)
                    let msg = err.localizedDescription
                    self.state = .failed(msg)
                    self.statusMessage = "Failed"
                    self.errorMessage = String(msg.prefix(500))
                }
            } catch {
                guard generation == self.latestGeneration else { return }
                let msg = error.localizedDescription
                self.state = .failed(msg)
                self.statusMessage = "Failed"
                self.errorMessage = String(msg.prefix(500))
            }
        }
    }

    /// Cancel active separation: semantically cancel Swift operation and terminate worker.
    /// Tracked cleanup — no forgotten Task, serialized via cleanup chain tail.
    func cancel() {
        let generation = operationGeneration + 1
        operationGeneration = generation
        latestGeneration = generation

        let taskToCancel = currentTask
        taskToCancel?.cancel()
        currentTask = nil

        // Repeated cancellation is serialized: B owns/joins A, C owns/joins B.
        let previousTail = cleanupChainTail
        let previousId = cleanupChainId
        let client = self.client
        let newId = previousId + 1
        cleanupChainId = newId
        let newTail = Task {
            if let prev = previousTail {
                await prev.value
            }
            await client.cancelActiveJob()
            if let t = taskToCancel { await t.value }
        }
        cleanupChainTail = newTail

        state = .failed("Cancelled")
        statusMessage = "Cancelled"
        errorMessage = "Cancelled"
    }

    /// Structured application-exit operation (Sol xHigh).
    /// Invalidates generation FIRST, cancels UI task, then awaits InferenceWorkerClient-owned lifecycle.
    /// Must not cancel cleanup chain — append and await tail transitively.
    func terminateForApplicationExit(policy: ApplicationExitPolicy = .production) async -> ApplicationExitCleanupResult {
        // Invalidate the UI generation before any suspension so no old result can publish.
        let nextGen = operationGeneration + 1
        operationGeneration = nextGen
        latestGeneration = nextGen
#if DEBUG
        // Emit before any await to guarantee recorder order: controllerGenerationInvalidated < separationTaskCancelled < sigtermSent
        let earlyTaskToCancel = currentTask
        if let handler = controllerTestEventHandler {
            handler("controllerGenerationInvalidated")
            if earlyTaskToCancel != nil { handler("separationTaskCancelled") }
        }
#endif
        let taskToCancel = currentTask
        currentTask = nil
        taskToCancel?.cancel()

        // Start the bounded client exit path immediately. The client coalesces it
        // with any cancellation cleanup already in flight for the exact Process.
        let result = await client.terminateForApplicationExit(policy: policy)
        if let taskToCancel { await taskToCancel.value }
        await drainCleanupChain()

        state = .idle
        statusMessage = "Ready to separate"
        if case .unsafeToTerminate = result {
            // Keep errorMessage nil for exit path; do not surface premature exit
            return result
        } else {
            errorMessage = nil
            // Return safe only if no cleanup-tail task survives and no separation task survives
            if cleanupChainTail != nil || currentTask != nil {
                return .unsafeToTerminate(reason: .cleanupIncomplete)
            }
            return result
        }
    }

    /// Joins a moving cancellation tail until the observed tail is still the
    /// current one after completion. This closes actor-reentrancy gaps where a
    /// newer cancel arrives while an older tail is being awaited.
    private func drainCleanupChain() async {
        while let tail = cleanupChainTail {
            let tailID = cleanupChainId
            await tail.value
            if cleanupChainId == tailID {
                cleanupChainTail = nil
                return
            }
        }
    }

#if DEBUG
    private var controllerTestEventHandler: (@Sendable (String) -> Void)?
    func setControllerTestEventHandler(_ h: @Sendable @escaping (String) -> Void) { controllerTestEventHandler = h }
    func clearControllerTestEventHandler() { controllerTestEventHandler = nil }
#endif

    /// Deterministic shutdown (called from AppLifecycleDelegate / AppTerminationCoordinator).
    /// Preserved for existing M3 tests and ordinary idle shutdown. Now delegates to structured exit without detached.
    func shutdownWorker() async {
        _ = await terminateForApplicationExit()
    }

    /// Backward-compatible shutdown with custom policy for tests that need short timing.
    func shutdownWorker(policy: ApplicationExitPolicy) async {
        _ = await terminateForApplicationExit(policy: policy)
    }

    // MARK: - Helpers for UI

    var sortedStems: [StemArtifact] {
        result?.sortedStems ?? []
    }

    var displayStatus: String {
        switch state {
        case .idle: return "Ready"
        case .loadingModel: return statusMessage
        case .separating: return statusMessage
        case .completed: return statusMessage
        case .failed(let msg): return msg
        }
    }
}
