import Foundation
import SwiftUI

enum EditableArtwork: Equatable, Sendable {
    case keep
    case removed
    case replaced(URL)
}

// MARK: - YouTubeIngesting seam (smallest test seam)

protocol YouTubeIngesting: Sendable {
    func ingest(youTubeURL: URL) async throws -> URL
    func ingestWithMetadata(youTubeURL: URL) async throws -> YouTubeIngestResult
    func cancel() async throws
}

extension YouTubeIngesting {
    func ingestWithMetadata(youTubeURL: URL) async throws -> YouTubeIngestResult {
        YouTubeIngestResult(
            audioURL: try await ingest(youTubeURL: youTubeURL),
            metadata: nil
        )
    }
}

extension YouTubeIngestClient: YouTubeIngesting {}

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
    private(set) var exportBaseName: String?
    private(set) var youTubeExportMetadata: YouTubeTrackMetadata?
    private(set) var youTubeExportArtworkURL: URL?
    private(set) var preparedYouTubeMP3Export: YouTubeIngestResult?

    // MARK: - Editable ID3 Metadata

    var editableTitle: String = ""
    var editableArtist: String = ""
    var editableAlbum: String = ""
    var editableAlbumArtist: String = ""
    var editableYear: String = ""
    var editableGenre: String = ""
    var editableTrackNumber: String = ""
    var editableArtwork: EditableArtwork = .keep

    var effectiveYouTubeMetadata: YouTubeTrackMetadata? {
        YouTubeTrackMetadata(
            artist: editableArtist,
            title: editableTitle,
            album: editableAlbum,
            albumArtist: editableAlbumArtist,
            year: editableYear,
            genre: editableGenre,
            trackNumber: editableTrackNumber
        )
    }

    var effectiveArtworkURL: URL? {
        switch editableArtwork {
        case .keep:
            return youTubeExportArtworkURL ?? preparedYouTubeMP3Export?.artworkURL
        case .removed:
            return nil
        case .replaced(let url):
            return url
        }
    }

    var isEditableMetadataAvailable: Bool {
        youTubeExportMetadata != nil || preparedYouTubeMP3Export != nil
    }

    private func populateEditableMetadata(from metadata: YouTubeTrackMetadata?) {
        editableTitle = metadata?.title ?? ""
        editableArtist = metadata?.artist ?? ""
        editableAlbum = metadata?.album ?? ""
        editableAlbumArtist = metadata?.albumArtist ?? ""
        editableYear = metadata?.year ?? ""
        editableGenre = metadata?.genre ?? ""
        editableTrackNumber = metadata?.trackNumber ?? ""
        editableArtwork = .keep
    }

    private func clearEditableMetadata() {
        editableTitle = ""
        editableArtist = ""
        editableAlbum = ""
        editableAlbumArtist = ""
        editableYear = ""
        editableGenre = ""
        editableTrackNumber = ""
        editableArtwork = .keep
    }

    var isSeparating: Bool {
        if case .separating = state { return true }
        if case .loadingModel = state { return true }
        return false
    }

    var canStart: Bool { !isSeparating }

    // MARK: - Ownership

    private let client: InferenceWorkerClient
    private let youTubeIngest: any YouTubeIngesting
    private var currentTask: Task<Void, Never>?
    private var cleanupChainTail: Task<Void, Never>?
    private var cleanupChainId: UInt64 = 0
    private var operationGeneration: UInt64 = 0
    private var latestGeneration: UInt64 = 0
    private var youTubeCleanupFailed: Bool = false

#if DEBUG
    func debugHasPendingCancellationCleanup() -> Bool { cleanupChainTail != nil }
    func debugCurrentTask() -> Task<Void, Never>? { currentTask }
    func debugPendingCancellationTask() -> Task<Void, Never>? { cleanupChainTail }
    func debugCleanupChainTail() -> Task<Void, Never>? { cleanupChainTail }
    func debugYouTubeCleanupFailed() -> Bool { youTubeCleanupFailed }
#endif

    // Output base per spec: ~/Library/Caches/Strata/M3Separations/
    private let outputBaseOverride: URL?
    private var outputBaseURL: URL {
        if let override = outputBaseOverride { return override }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("Strata/M3Separations", isDirectory: true)
    }

    static func makeDefaultYouTubeIngest() -> any YouTubeIngesting {
        YouTubeIngestClient(
            ytDlpURL: URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            ffmpegURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        )
    }

    init(client: InferenceWorkerClient = InferenceWorkerClient(), youTubeIngest: (any YouTubeIngesting)? = nil) {
        self.client = client
        self.outputBaseOverride = nil
        self.youTubeIngest = youTubeIngest ?? Self.makeDefaultYouTubeIngest()
    }

    // Convenience for testing injection — stores override for deterministic temp output in tests
    init(client: InferenceWorkerClient, outputBase: URL, youTubeIngest: (any YouTubeIngesting)? = nil) {
        self.client = client
        self.outputBaseOverride = outputBase
        self.youTubeIngest = youTubeIngest ?? Self.makeDefaultYouTubeIngest()
    }

    deinit {
        // MainActor-isolated currentTask cannot be accessed from nonisolated deinit.
        // Cancellation is handled via shutdownWorker / cancel() paths; no action here.
    }

    // MARK: - Public API

    /// Start separation for a canonical WAV input URL.
    func startSeparation(inputURL: URL) {
        if youTubeCleanupFailed { return }
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
        exportBaseName = nil
        youTubeExportMetadata = nil
        youTubeExportArtworkURL = nil
        preparedYouTubeMP3Export = nil
        clearEditableMetadata()

        let client = self.client
        let base = outputBaseURL

        currentTask = Task { [previousTask] in
            if let previousTask { await previousTask.value }
            await self.drainCleanupChain()
            if self.youTubeCleanupFailed { return }

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

    /// Start separation via YouTube URL → ingest → inference.
    func startSeparation(youTubeURL: URL) {
        if youTubeCleanupFailed { return }
        let generation = operationGeneration + 1
        operationGeneration = generation
        latestGeneration = generation

        let previousTask = currentTask
        previousTask?.cancel()

        state = .loadingModel
        statusMessage = "Downloading…"
        result = nil
        errorMessage = nil
        exportBaseName = nil
        youTubeExportMetadata = nil
        youTubeExportArtworkURL = nil
        preparedYouTubeMP3Export = nil
        clearEditableMetadata()

        let client = self.client
        let youTubeIngest = self.youTubeIngest
        let base = outputBaseURL

        currentTask = Task { [previousTask] in
            if let previousTask { await previousTask.value }
            await self.drainCleanupChain()
            if self.youTubeCleanupFailed { return }

            do {
                try Task.checkCancellation()
                let ingestResult = try await youTubeIngest.ingestWithMetadata(youTubeURL: youTubeURL)

                try Task.checkCancellation()
                guard generation == self.latestGeneration else { return }
                guard !Task.isCancelled else { throw CancellationError() }

                // Transition status to inference phase
                self.statusMessage = "Loading model…"

                let separationResult = try await client.runSeparation(
                    inputPath: ingestResult.audioURL,
                    outputBaseDir: base
                )

                guard generation == self.latestGeneration else { return }
                guard !Task.isCancelled else { return }

                self.result = separationResult
                self.exportBaseName = ingestResult.metadata?.exportBaseName
                self.youTubeExportMetadata = ingestResult.metadata
                self.youTubeExportArtworkURL = ingestResult.artworkURL
                self.populateEditableMetadata(from: ingestResult.metadata)
                self.state = .completed
                self.statusMessage = "Complete — \(separationResult.stems.count) stems"
                self.errorMessage = nil

            } catch is CancellationError {
                guard generation == self.latestGeneration else { return }
                self.state = .failed("Cancelled")
                self.statusMessage = "Cancelled"
                self.errorMessage = "Cancelled"
            } catch let err as YouTubeIngestError {
                if case .cleanupFailed(let msg) = err {
                    let m = "Cleanup failed: \(msg)"
                    self.state = .failed(m)
                    self.statusMessage = "Cleanup failed"
                    self.errorMessage = String(m.prefix(500))
                    self.youTubeCleanupFailed = true
                }
                guard generation == self.latestGeneration else { return }
                switch err {
                case .cancelled:
                    self.state = .failed("Cancelled")
                    self.statusMessage = "Cancelled"
                    self.errorMessage = "Cancelled"
                case .cleanupFailed:
                    break
                default:
                    let msg = err.localizedDescription
                    self.state = .failed(msg)
                    self.statusMessage = "Failed"
                    self.errorMessage = String(msg.prefix(500))
                }
            } catch let err as InferenceError {
                guard generation == self.latestGeneration else { return }
                if case .cancellation = err {
                    self.state = .failed("Cancelled")
                    self.statusMessage = "Cancelled"
                    self.errorMessage = "Cancelled"
                } else {
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

    /// Download and canonicalize YouTube audio for direct MP3 export without inference.
    func prepareYouTubeMP3Export(youTubeURL: URL) {
        if youTubeCleanupFailed { return }
        let generation = operationGeneration + 1
        operationGeneration = generation
        latestGeneration = generation

        let previousTask = currentTask
        previousTask?.cancel()

        state = .loadingModel
        statusMessage = "Downloading…"
        result = nil
        errorMessage = nil
        exportBaseName = nil
        youTubeExportMetadata = nil
        youTubeExportArtworkURL = nil
        preparedYouTubeMP3Export = nil
        clearEditableMetadata()

        let youTubeIngest = self.youTubeIngest
        currentTask = Task { [previousTask] in
            if let previousTask { await previousTask.value }
            await self.drainCleanupChain()
            if self.youTubeCleanupFailed { return }

            do {
                try Task.checkCancellation()
                let ingestResult = try await youTubeIngest.ingestWithMetadata(youTubeURL: youTubeURL)

                try Task.checkCancellation()
                guard generation == self.latestGeneration else { return }
                guard !Task.isCancelled else { throw CancellationError() }

                self.preparedYouTubeMP3Export = ingestResult
                // Also populate unified editable state for direct MP3 flow
                self.youTubeExportMetadata = ingestResult.metadata
                self.youTubeExportArtworkURL = ingestResult.artworkURL
                self.exportBaseName = ingestResult.metadata?.exportBaseName
                self.populateEditableMetadata(from: ingestResult.metadata)
                self.state = .idle
                self.statusMessage = "Ready to save MP3"
                self.errorMessage = nil

            } catch is CancellationError {
                guard generation == self.latestGeneration else { return }
                self.state = .failed("Cancelled")
                self.statusMessage = "Cancelled"
                self.errorMessage = "Cancelled"
            } catch let err as YouTubeIngestError {
                if case .cleanupFailed(let msg) = err {
                    let message = "Cleanup failed: \(msg)"
                    self.state = .failed(message)
                    self.statusMessage = "Cleanup failed"
                    self.errorMessage = String(message.prefix(500))
                    self.youTubeCleanupFailed = true
                }
                guard generation == self.latestGeneration else { return }
                switch err {
                case .cancelled:
                    self.state = .failed("Cancelled")
                    self.statusMessage = "Cancelled"
                    self.errorMessage = "Cancelled"
                case .cleanupFailed:
                    break
                default:
                    let message = err.localizedDescription
                    self.state = .failed(message)
                    self.statusMessage = "Failed"
                    self.errorMessage = String(message.prefix(500))
                }
            } catch {
                guard generation == self.latestGeneration else { return }
                let message = error.localizedDescription
                self.state = .failed(message)
                self.statusMessage = "Failed"
                self.errorMessage = String(message.prefix(500))
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
        let youTubeIngest = self.youTubeIngest
        let newId = previousId + 1
        cleanupChainId = newId
        let newTail = Task {
            if let prev = previousTail {
                await prev.value
            }
            var ytError: Error?
            do {
                try await youTubeIngest.cancel()
                await MainActor.run { self.youTubeCleanupFailed = false }
            } catch {
                ytError = error
            }
            await client.cancelActiveJob()
            if let t = taskToCancel { await t.value }
            if let e = ytError {
                await MainActor.run {
                    if let yErr = e as? YouTubeIngestError, case .cleanupFailed(let msg) = yErr {
                        let m = "Cleanup failed: \(msg)"
                        self.state = .failed(m)
                        self.statusMessage = "Cleanup failed"
                        self.errorMessage = String(m.prefix(500))
                        self.youTubeCleanupFailed = true
                    } else if let yErr = e as? YouTubeIngestError, case .cancelled = yErr {
                        // cancelled is already represented as Cancelled; keep existing state
                    } else {
                        // Generic ingest cancel error: surface as failed
                        let m = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
                        self.state = .failed(m)
                        self.statusMessage = "Cleanup failed"
                        self.errorMessage = String(m.prefix(500))
                        self.youTubeCleanupFailed = true
                    }
                }
            }
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

        var youTubeCancelThrew = false
        do {
            try await youTubeIngest.cancel()
            youTubeCleanupFailed = false
        } catch {
            youTubeCancelThrew = true
            // If cleanupFailed, mark flag for unsafe
            if let yErr = error as? YouTubeIngestError, case .cleanupFailed = yErr {
                youTubeCleanupFailed = true
            } else {
                youTubeCleanupFailed = true
            }
        }

        // Start the bounded client exit path immediately. The client coalesces it
        // with any cancellation cleanup already in flight for the exact Process.
        let result = await client.terminateForApplicationExit(policy: policy)
        if let taskToCancel { await taskToCancel.value }
        await drainCleanupChain()

        state = .idle
        statusMessage = "Ready to separate"
        if youTubeCancelThrew {
            return .unsafeToTerminate(reason: .cleanupIncomplete)
        }
        if youTubeCleanupFailed {
            // Preserve unsafe until observed; reset for next operation
            youTubeCleanupFailed = false
            return .unsafeToTerminate(reason: .cleanupIncomplete)
        }
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
