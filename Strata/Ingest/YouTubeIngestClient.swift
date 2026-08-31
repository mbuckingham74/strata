import Foundation
import AVFoundation
import Darwin

// MARK: - YouTubeIngestError

enum YouTubeIngestError: Error, Equatable, LocalizedError, Sendable {
    case invalidYouTubeURL(String)
    case alreadyRunning
    case toolFailure(tool: String, exitCode: Int32, stderrTail: String?)
    case invalidCanonicalOutput(String)
    case cancelled
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidYouTubeURL(let s): return "Invalid YouTube URL: \(s)"
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

struct YouTubeTrackMetadata: Sendable, Equatable {
    let artist: String
    let title: String

    init?(artist: String?, title: String?) {
        guard let artist = Self.filenameComponent(artist),
              let title = Self.filenameComponent(title) else {
            return nil
        }
        self.artist = artist
        self.title = title
    }

    var exportBaseName: String {
        "\(artist) - \(title)"
    }

    private static func filenameComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let metadataValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard metadataValue.lowercased() != "n/a" else { return nil }
        let unsafeCharacters = CharacterSet(charactersIn: "/:")
            .union(.controlCharacters)
        let sanitized = value
            .components(separatedBy: unsafeCharacters)
            .joined(separator: "-")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !sanitized.isEmpty, sanitized.lowercased() != "na" else { return nil }
        return sanitized
    }
}

struct YouTubeIngestResult: Sendable, Equatable {
    let audioURL: URL
    let metadata: YouTubeTrackMetadata?
}

private struct YTDLPInfo: Decodable {
    let artist: String?
    let track: String?
}

// MARK: - TailBox

private final class TailBox: @unchecked Sendable {
    private var data = Data()
    private let maxBytes = 32 * 1024

    func append(_ d: Data) {
        guard !d.isEmpty else { return }
        data.append(d)
        if data.count > maxBytes {
            data = data.suffix(maxBytes)
        }
    }

    func string() -> String? {
        guard !data.isEmpty else { return nil }
        // Keep last 32 KiB already bounded
        if let s = String(data: data, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return "<non-utf8 \(data.count) bytes>"
    }

    func reset() { data = Data() }
}

// MARK: - YouTubeIngestClient

actor YouTubeIngestClient {
    let ytDlpURL: URL
    let ffmpegURL: URL
    let cacheBaseURL: URL
    let fileManager: FileManager

    private var activeProcess: Process?
    private var activeRunDirectory: URL?
    private var cancellationRequested = false
    private let isRunningCheck: @Sendable (Process) -> Bool

    init(ytDlpURL: URL, ffmpegURL: URL, cacheBaseURL: URL? = nil, fileManager: FileManager = .default, isRunningCheck: @escaping @Sendable (Process) -> Bool = { $0.isRunning }) {
        self.ytDlpURL = ytDlpURL
        self.ffmpegURL = ffmpegURL
        self.fileManager = fileManager
        self.isRunningCheck = isRunningCheck
        if let base = cacheBaseURL {
            self.cacheBaseURL = base
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.cacheBaseURL = caches.appendingPathComponent("Strata/M4Ingest", isDirectory: true)
        }
    }

    private func isAlive(_ p: Process) -> Bool {
        isRunningCheck(p)
    }

    // MARK: - Public

    func ingest(youTubeURL: URL) async throws -> URL {
        try await ingestWithMetadata(youTubeURL: youTubeURL).audioURL
    }

    func ingestWithMetadata(youTubeURL: URL) async throws -> YouTubeIngestResult {
        // Validate YouTube URL
        guard let scheme = youTubeURL.scheme?.lowercased(), scheme == "https",
              let host = youTubeURL.host?.lowercased(),
              host.contains("youtube.com") || host.contains("youtu.be") else {
            throw YouTubeIngestError.invalidYouTubeURL(youTubeURL.absoluteString)
        }

        // Validate tool URLs are absolute file URLs
        guard isAbsoluteFileURL(ytDlpURL) else {
            throw YouTubeIngestError.invalidCanonicalOutput("ytDlpURL must be absolute file URL: \(ytDlpURL)")
        }
        guard isAbsoluteFileURL(ffmpegURL) else {
            throw YouTubeIngestError.invalidCanonicalOutput("ffmpegURL must be absolute file URL: \(ffmpegURL)")
        }

        // Already running guard
        if activeProcess != nil || activeRunDirectory != nil {
            throw YouTubeIngestError.alreadyRunning
        }

        // Create unique run dir
        let runDir = cacheBaseURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw YouTubeIngestError.toolFailure(tool: "mkdir", exitCode: -1, stderrTail: error.localizedDescription)
        }
        activeRunDirectory = runDir
        cancellationRequested = false
        let tailBox = TailBox()

        do {
            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }

            // yt-dlp
            let outputTemplate = runDir.appendingPathComponent("source.%(ext)s").path
            let ytArgs = [
                youTubeURL.absoluteString,
                "-o", outputTemplate,
                "--no-playlist",
                "--write-info-json",
            ]
            let ytStatus = try await runTool(toolName: "yt-dlp", executableURL: ytDlpURL, arguments: ytArgs, tailBox: tailBox)
            if ytStatus != 0 {
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: tailBox.string())
            }

            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }

            // Locate single downloaded file
            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil, options: [])
            } catch {
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: tailBox.string())
            }
            let infoURLs = contents.filter { $0.lastPathComponent.hasSuffix(".info.json") }
            let candidates = contents.filter {
                $0.lastPathComponent != "mixture.wav"
                    && !$0.lastPathComponent.hasSuffix(".info.json")
            }
            guard candidates.count == 1 else {
                let tail = tailBox.string()
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: tail)
            }
            let sourceURL = candidates[0]
            let metadata = metadata(from: infoURLs)

            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }

            // FFmpeg
            let mixtureURL = runDir.appendingPathComponent("mixture.wav")
            let ffArgs = ["-nostdin", "-y", "-i", sourceURL.path, "-ar", "44100", "-ac", "2", "-c:a", "pcm_f32le", mixtureURL.path]
            let ffStatus = try await runTool(toolName: "ffmpeg", executableURL: ffmpegURL, arguments: ffArgs, tailBox: tailBox)
            if ffStatus != 0 {
                throw YouTubeIngestError.toolFailure(tool: "ffmpeg", exitCode: ffStatus, stderrTail: tailBox.string())
            }

            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }

            // Validate mixture.wav canonical
            guard fileManager.fileExists(atPath: mixtureURL.path) else {
                throw YouTubeIngestError.invalidCanonicalOutput("mixture.wav missing at \(mixtureURL.path)")
            }
            var isDir: ObjCBool = false
            _ = fileManager.fileExists(atPath: mixtureURL.path, isDirectory: &isDir)
            if isDir.boolValue {
                throw YouTubeIngestError.invalidCanonicalOutput("mixture.wav is directory")
            }

            let audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(forReading: mixtureURL)
            } catch {
                throw YouTubeIngestError.invalidCanonicalOutput("AVAudioFile open failed: \(error.localizedDescription)")
            }
            let fmt = audioFile.processingFormat
            guard fmt.sampleRate == 44100 else {
                throw YouTubeIngestError.invalidCanonicalOutput("sampleRate \(fmt.sampleRate) != 44100")
            }
            guard fmt.channelCount == 2 else {
                throw YouTubeIngestError.invalidCanonicalOutput("channelCount \(fmt.channelCount) != 2")
            }
            guard fmt.commonFormat == .pcmFormatFloat32 else {
                throw YouTubeIngestError.invalidCanonicalOutput("format not Float32: \(fmt.commonFormat)")
            }
            guard audioFile.length > 0 else {
                throw YouTubeIngestError.invalidCanonicalOutput("frame count 0")
            }

            // Success: remove intermediate source file(s) but keep mixture.wav
            for url in candidates {
                try? fileManager.removeItem(at: url)
            }
            for url in infoURLs {
                try? fileManager.removeItem(at: url)
            }

            // Keep runDir containing only mixture.wav, clear active state
            activeRunDirectory = nil
            activeProcess = nil
            cancellationRequested = false
            return YouTubeIngestResult(audioURL: mixtureURL, metadata: metadata)

        } catch {
            // If owned process still alive, retain ownership/state and surface failure — do not remove directory or clear state
            if let p = activeProcess, isAlive(p) {
                if error is CancellationError {
                    throw YouTubeIngestError.cancelled
                }
                throw error
            }
            // No live process: safe to clean entire runDirectory on any failure or cancellation
            if fileManager.fileExists(atPath: runDir.path) {
                try? fileManager.removeItem(at: runDir)
            }
            activeProcess = nil
            activeRunDirectory = nil
            // Map Swift CancellationError to our cancelled
            if error is CancellationError {
                throw YouTubeIngestError.cancelled
            }
            throw error
        }
    }

    func cancel() async throws {
        cancellationRequested = true
        let proc = activeProcess
        let dir = activeRunDirectory
        guard let p = proc else {
            // No active process; safe to remove directory if present (no child running)
            if let d = dir {
                try? fileManager.removeItem(at: d)
                activeRunDirectory = nil
            }
            return
        }
        // Has active process — attempt bounded escalation only if still alive
        if isAlive(p) {
            p.terminate()
            let deadline = ContinuousClock.now + .milliseconds(500)
            while isAlive(p) && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if isAlive(p) {
                kill(p.processIdentifier, SIGKILL)
                let deadline2 = ContinuousClock.now + .milliseconds(500)
                while isAlive(p) && ContinuousClock.now < deadline2 {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
        if isAlive(p) {
            // Still running after escalation — retain ownership and surface failure, do not remove directory
            throw YouTubeIngestError.cleanupFailed("Process \(p.processIdentifier) still running after SIGTERM/SIGKILL")
        }
        // Proven dead — clear ownership and remove directory
        activeProcess = nil
        if let d = dir {
            try? fileManager.removeItem(at: d)
            activeRunDirectory = nil
        }
        // Leave cancellationRequested = true for active ingest to observe.
        // Next ingest will reset it to false at start. If this was an idle cancel (no dir/proc),
        // the flag will be cleared on next ingest start, so no stale block.
    }

    // MARK: - Helpers

    private func isAbsoluteFileURL(_ url: URL) -> Bool {
        return url.isFileURL && url.path.hasPrefix("/") && !url.path.isEmpty
    }

    private func metadata(from infoURLs: [URL]) -> YouTubeTrackMetadata? {
        guard infoURLs.count == 1,
              let data = try? Data(contentsOf: infoURLs[0]),
              let info = try? JSONDecoder().decode(YTDLPInfo.self, from: data) else {
            return nil
        }
        return YouTubeTrackMetadata(artist: info.artist, title: info.track)
    }

    private func runTool(toolName: String, executableURL: URL, arguments: [String], tailBox: TailBox) async throws -> Int32 {
        if Task.isCancelled || cancellationRequested {
            throw YouTubeIngestError.cancelled
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        let handle = stderrPipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty {
                tailBox.append(d)
            }
        }

        activeProcess = process
        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            activeProcess = nil
            throw YouTubeIngestError.toolFailure(tool: toolName, exitCode: -1, stderrTail: tailBox.string() ?? error.localizedDescription)
        }

        while isAlive(process) {
            if Task.isCancelled || cancellationRequested {
                process.terminate()
                let deadline = ContinuousClock.now + .milliseconds(500)
                while isAlive(process) && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if isAlive(process) {
                    kill(process.processIdentifier, SIGKILL)
                    let deadline2 = ContinuousClock.now + .milliseconds(500)
                    while isAlive(process) && ContinuousClock.now < deadline2 {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                handle.readabilityHandler = nil
                let remaining = handle.availableData
                if !remaining.isEmpty { tailBox.append(remaining) }
                if isAlive(process) {
                    // Retain ownership, do not clear activeProcess, surface cleanup failure
                    throw YouTubeIngestError.cleanupFailed("Process \(process.processIdentifier) still running after SIGTERM/SIGKILL during \(toolName)")
                }
                activeProcess = nil
                throw YouTubeIngestError.cancelled
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        handle.readabilityHandler = nil
        let remaining = handle.availableData
        if !remaining.isEmpty { tailBox.append(remaining) }
        if let d = try? handle.readToEnd(), !d.isEmpty {
            tailBox.append(d)
        }
        let status = process.terminationStatus
        activeProcess = nil
        if cancellationRequested || Task.isCancelled {
            throw YouTubeIngestError.cancelled
        }
        return status
    }
}
