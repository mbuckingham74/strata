import Foundation
import AVFoundation

// MARK: - LocalAudioIngestError

enum LocalAudioIngestError: Error, Equatable, LocalizedError, Sendable {
    case invalidInput(String)
    case alreadyRunning
    case toolFailure(tool: String, exitCode: Int32, stderrTail: String?)
    case invalidCanonicalOutput(String)
    case cancelled
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let s): return "Invalid input: \(s)"
        case .alreadyRunning: return "Ingest already running"
        case .toolFailure(let tool, let code, let tail):
            if let t = tail, !t.isEmpty { return "\(tool) failed with exit \(code): \(t)" }
            return "\(tool) failed with exit \(code)"
        case .invalidCanonicalOutput(let s): return "Invalid canonical output: \(s)"
        case .cancelled: return "Cancelled"
        case .cleanupFailed(let s): return "Cleanup failed: \(s)"
        }
    }
}

// MARK: - LocalAudioIngesting seam

protocol LocalAudioIngesting: Sendable {
    func ingest(localFileURL: URL) async throws -> URL
    func cancel() async throws
}

extension LocalAudioIngestClient: LocalAudioIngesting {}

// MARK: - LocalAudioIngestClient

actor LocalAudioIngestClient {
    let ffmpegURL: URL
    let fileManager: FileManager
    private let cacheBaseOverride: URL?

    /// Effective cache base: override if provided (tests), otherwise current Scratch preference.
    var cacheBaseURL: URL {
        if let base = cacheBaseOverride { return base }
        return StorageLocationPreferences(fileManager: fileManager).localIngestCacheBaseURL()
    }

    private var activeRunDirectory: URL?
    private var cancellationRequested = false
    private let processRunner: AudioProcessRunner

    init(
        ffmpegURL: URL,
        cacheBaseURL: URL? = nil,
        fileManager: FileManager = .default,
        isRunningCheck: @escaping @Sendable (Process) -> Bool = { $0.isRunning }
    ) {
        self.ffmpegURL = ffmpegURL
        self.fileManager = fileManager
        self.cacheBaseOverride = cacheBaseURL
        self.processRunner = AudioProcessRunner(isRunningCheck: isRunningCheck)
    }

    private func isAbsoluteFileURL(_ url: URL) -> Bool {
        return url.isFileURL && url.path.hasPrefix("/") && !url.path.isEmpty
    }

    // MARK: - Public

    func ingest(localFileURL: URL) async throws -> URL {
        guard isAbsoluteFileURL(ffmpegURL) else {
            throw LocalAudioIngestError.invalidCanonicalOutput("ffmpegURL must be absolute file URL: \(ffmpegURL)")
        }

        if await processRunner.hasActiveProcess() || activeRunDirectory != nil {
            throw LocalAudioIngestError.alreadyRunning
        }

        let runDir = cacheBaseURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw LocalAudioIngestError.toolFailure(tool: "mkdir", exitCode: -1, stderrTail: error.localizedDescription)
        }
        activeRunDirectory = runDir
        cancellationRequested = false
        let stderrTail = AudioStderrTail()

        do {
            if Task.isCancelled || cancellationRequested {
                throw LocalAudioIngestError.cancelled
            }

            // Security-scoped access handling (fallback if not security-scoped, startAccess returns false)
            let didAccess = localFileURL.startAccessingSecurityScopedResource()
            defer { if didAccess { localFileURL.stopAccessingSecurityScopedResource() } }

            guard fileManager.fileExists(atPath: localFileURL.path) else {
                throw LocalAudioIngestError.invalidInput("file not found: \(localFileURL.path)")
            }
            var isDir: ObjCBool = false
            _ = fileManager.fileExists(atPath: localFileURL.path, isDirectory: &isDir)
            if isDir.boolValue {
                throw LocalAudioIngestError.invalidInput("is directory: \(localFileURL.path)")
            }

            // FFmpeg canonicalization
            let mixtureURL = runDir.appendingPathComponent("mixture.wav")
            let ffArgs = ["-nostdin", "-y", "-i", localFileURL.path, "-ar", "44100", "-ac", "2", "-c:a", "pcm_f32le", mixtureURL.path]
            let ffStatus: Int32
            do {
                ffStatus = try await processRunner.run(
                    executableURL: ffmpegURL,
                    arguments: ffArgs,
                    stderrTail: stderrTail
                )
            } catch let error as AudioProcessRunnerError {
                throw mapProcessError(error, toolName: "ffmpeg", stderrTail: stderrTail)
            }
            if ffStatus != 0 {
                throw LocalAudioIngestError.toolFailure(tool: "ffmpeg", exitCode: ffStatus, stderrTail: stderrTail.string())
            }

            if Task.isCancelled || cancellationRequested {
                throw LocalAudioIngestError.cancelled
            }

            do {
                try validateCanonicalAudioFile(at: mixtureURL, fileManager: fileManager)
            } catch let error as CanonicalAudioFileError {
                throw LocalAudioIngestError.invalidCanonicalOutput(error.reason)
            }

            // Success: keep mixture, clear active state
            activeRunDirectory = nil
            cancellationRequested = false
            // Security-scoped defer will stop access here, but file already canonicalized
            return mixtureURL

        } catch {
            if await processRunner.hasLiveProcess() {
                throw error
            }
            if fileManager.fileExists(atPath: runDir.path) {
                try? fileManager.removeItem(at: runDir)
            }
            activeRunDirectory = nil
            if error is CancellationError {
                throw LocalAudioIngestError.cancelled
            }
            throw error
        }
    }

    func cancel() async throws {
        cancellationRequested = true
        let dir = activeRunDirectory
        if !(await processRunner.hasActiveProcess()) {
            if let d = dir {
                try? fileManager.removeItem(at: d)
                activeRunDirectory = nil
            }
            return
        }

        do {
            try await processRunner.cancel()
        } catch let error as AudioProcessRunnerError {
            throw mapProcessError(error, toolName: "ffmpeg", stderrTail: nil)
        }
        if let d = dir {
            try? fileManager.removeItem(at: d)
            activeRunDirectory = nil
        }
    }

    private func mapProcessError(
        _ error: AudioProcessRunnerError,
        toolName: String,
        stderrTail: AudioStderrTail?
    ) -> LocalAudioIngestError {
        switch error {
        case .launchFailed(let message):
            return .toolFailure(tool: toolName, exitCode: -1, stderrTail: stderrTail?.string() ?? message)
        case .cancelled:
            return .cancelled
        case .cleanupFailed(let message):
            return .cleanupFailed(message)
        }
    }
}
