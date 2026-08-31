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

struct YouTubeTrackMetadata: Sendable, Equatable, Codable {
    let artist: String?
    let title: String?
    let album: String?
    let albumArtist: String?
    let year: String?
    let genre: String?
    let trackNumber: String?

    init?(
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        year: String? = nil,
        genre: String? = nil,
        trackNumber: String? = nil
    ) {
        self.artist = Self.metadataValue(artist)
        self.title = Self.metadataValue(title)
        self.album = Self.metadataValue(album)
        self.albumArtist = Self.metadataValue(albumArtist)
        self.year = Self.yearValue(year)
        self.genre = Self.metadataValue(genre)
        self.trackNumber = Self.trackNumberValue(trackNumber)

        guard self.artist != nil
                || self.title != nil
                || self.album != nil
                || self.albumArtist != nil
                || self.year != nil
                || self.genre != nil
                || self.trackNumber != nil else {
            return nil
        }
    }

    var exportBaseName: String? {
        guard let artist = Self.filenameComponent(artist),
              let title = Self.filenameComponent(title) else {
            return nil
        }
        return "\(artist) - \(title)"
    }

    private static func metadataValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let metadataValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !metadataValue.isEmpty,
              metadataValue.lowercased() != "n/a",
              metadataValue.lowercased() != "na" else {
            return nil
        }
        return metadataValue
    }

    private static func filenameComponent(_ value: String?) -> String? {
        guard let metadataValue = metadataValue(value) else { return nil }
        let unsafeCharacters = CharacterSet(charactersIn: "/:")
            .union(.controlCharacters)
        let sanitized = metadataValue
            .components(separatedBy: unsafeCharacters)
            .joined(separator: "-")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !sanitized.isEmpty else { return nil }
        return sanitized
    }

    private static func yearValue(_ value: String?) -> String? {
        guard let value = metadataValue(value),
              value.count == 4,
              value.allSatisfy(\.isNumber),
              let numericYear = Int(value),
              numericYear > 0 else {
            return nil
        }
        return value
    }

    private static func trackNumberValue(_ value: String?) -> String? {
        guard let value = metadataValue(value) else { return nil }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count),
              components.allSatisfy({ component in
                  guard let number = Int(component) else { return false }
                  return number > 0
              }) else {
            return nil
        }
        return value
    }
}

struct YouTubeIngestResult: Sendable, Equatable {
    let audioURL: URL
    let metadata: YouTubeTrackMetadata?
    let artworkURL: URL?

    init(audioURL: URL, metadata: YouTubeTrackMetadata?, artworkURL: URL? = nil) {
        self.audioURL = audioURL
        self.metadata = metadata
        self.artworkURL = artworkURL
    }
}

private struct YTDLPInfo: Decodable {
    let artist: String?
    let track: String?
    let album: String?
    let albumArtist: String?
    let releaseYear: Int?
    let genre: String?
    let trackNumber: Int?

    private enum CodingKeys: String, CodingKey {
        case artist
        case track
        case album
        case albumArtist = "album_artist"
        case releaseYear = "release_year"
        case genre
        case trackNumber = "track_number"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artist = try? container.decode(String.self, forKey: .artist)
        track = try? container.decode(String.self, forKey: .track)
        album = try? container.decode(String.self, forKey: .album)
        albumArtist = try? container.decode(String.self, forKey: .albumArtist)
        releaseYear = Self.integer(forKey: .releaseYear, in: container)
        genre = try? container.decode(String.self, forKey: .genre)
        trackNumber = Self.integer(forKey: .trackNumber, in: container)
    }

    private static func integer(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
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
                "--write-thumbnail",
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
            let thumbnailURLs = contents.filter(isThumbnailFile)
            let candidates = contents.filter {
                $0.lastPathComponent != "mixture.wav"
                    && !$0.lastPathComponent.hasSuffix(".info.json")
                    && !isThumbnailFile($0)
            }
            guard candidates.count == 1 else {
                let tail = tailBox.string()
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: tail)
            }
            let sourceURL = candidates[0]
            let metadata = metadata(from: infoURLs)
            let artworkURL = artwork(from: thumbnailURLs)

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
            for url in thumbnailURLs where url != artworkURL {
                try? fileManager.removeItem(at: url)
            }

            // Keep the canonical mixture and any usable artwork, then clear active state.
            activeRunDirectory = nil
            activeProcess = nil
            cancellationRequested = false
            return YouTubeIngestResult(
                audioURL: mixtureURL,
                metadata: metadata,
                artworkURL: artworkURL
            )

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
        return YouTubeTrackMetadata(
            artist: info.artist,
            title: info.track,
            album: info.album,
            albumArtist: info.albumArtist,
            year: info.releaseYear.map(String.init),
            genre: info.genre,
            trackNumber: info.trackNumber.map(String.init)
        )
    }

    private func isThumbnailFile(_ url: URL) -> Bool {
        ["avif", "bmp", "gif", "jpeg", "jpg", "png", "webp"]
            .contains(url.pathExtension.lowercased())
    }

    private func artwork(from thumbnailURLs: [URL]) -> URL? {
        let usableURLs = thumbnailURLs.filter(isUsableArtwork)
        guard usableURLs.count == 1 else { return nil }
        return usableURLs[0]
    }

    private func isUsableArtwork(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return true
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return true
        }
        if bytes.starts(with: Array("GIF8".utf8)) || bytes.starts(with: Array("BM".utf8)) {
            return true
        }
        return bytes.count >= 12
            && bytes[0..<4].elementsEqual("RIFF".utf8)
            && bytes[8..<12].elementsEqual("WEBP".utf8)
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
