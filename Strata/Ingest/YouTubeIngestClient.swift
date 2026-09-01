import Foundation
import AVFoundation

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
    let channel: String?

    init?(
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        year: String? = nil,
        genre: String? = nil,
        trackNumber: String? = nil,
        channel: String? = nil
    ) {
        self.artist = Self.metadataValue(artist)
        self.title = Self.metadataValue(title)
        self.album = Self.metadataValue(album)
        self.albumArtist = Self.metadataValue(albumArtist)
        self.year = Self.yearValue(year)
        self.genre = Self.metadataValue(genre)
        self.trackNumber = Self.trackNumberValue(trackNumber)
        self.channel = Self.metadataValue(channel)

        guard self.artist != nil
                || self.title != nil
                || self.album != nil
                || self.albumArtist != nil
                || self.year != nil
                || self.genre != nil
                || self.trackNumber != nil
                || self.channel != nil else {
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
    let title: String?
    let album: String?
    let albumArtist: String?
    let releaseYear: Int?
    let genre: String?
    let trackNumber: Int?
    let channel: String?
    let uploader: String?
    let channelName: String?
    let duration: Double?
    let artists: [String]?
    let creator: String?
    let creators: [String]?

    private enum CodingKeys: String, CodingKey {
        case artist
        case track
        case title
        case album
        case albumArtist = "album_artist"
        case releaseYear = "release_year"
        case genre
        case trackNumber = "track_number"
        case channel
        case uploader
        case channelName = "channel_name"
        case duration
        case artists
        case creator
        case creators
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artist = try? container.decode(String.self, forKey: .artist)
        track = try? container.decode(String.self, forKey: .track)
        title = try? container.decode(String.self, forKey: .title)
        album = try? container.decode(String.self, forKey: .album)
        albumArtist = try? container.decode(String.self, forKey: .albumArtist)
        releaseYear = Self.integer(forKey: .releaseYear, in: container)
        genre = try? container.decode(String.self, forKey: .genre)
        trackNumber = Self.integer(forKey: .trackNumber, in: container)
        channel = try? container.decode(String.self, forKey: .channel)
        uploader = try? container.decode(String.self, forKey: .uploader)
        channelName = try? container.decode(String.self, forKey: .channelName)
        duration = Self.double(forKey: .duration, in: container)
        artists = try? container.decode([String].self, forKey: .artists)
        creator = try? container.decode(String.self, forKey: .creator)
        creators = try? container.decode([String].self, forKey: .creators)
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

    private static func double(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}

struct YouTubePreviewResult: Sendable, Equatable {
    let metadata: YouTubeTrackMetadata?
    let artworkURL: URL?
    let duration: TimeInterval?
}

// MARK: - YouTubeIngestClient

actor YouTubeIngestClient {
    let ytDlpURL: URL
    let ffmpegURL: URL
    let cacheBaseURL: URL
    let fileManager: FileManager

    private var activeRunDirectory: URL?
    private var cancellationRequested = false
    private let processRunner: AudioProcessRunner

    init(ytDlpURL: URL, ffmpegURL: URL, cacheBaseURL: URL? = nil, fileManager: FileManager = .default, isRunningCheck: @escaping @Sendable (Process) -> Bool = { $0.isRunning }) {
        self.ytDlpURL = ytDlpURL
        self.ffmpegURL = ffmpegURL
        self.fileManager = fileManager
        self.processRunner = AudioProcessRunner(isRunningCheck: isRunningCheck)
        if let base = cacheBaseURL {
            self.cacheBaseURL = base
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.cacheBaseURL = caches.appendingPathComponent("Strata/M4Ingest", isDirectory: true)
        }
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
        if await processRunner.hasActiveProcess() || activeRunDirectory != nil {
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
        let stderrTail = AudioStderrTail()

        do {
            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }

            // yt-dlp (audio-only, strict bestaudio - never request video streams)
            let outputTemplate = runDir.appendingPathComponent("source.%(ext)s").path
            let ytArgs = [
                youTubeURL.absoluteString,
                "-f", "bestaudio",
                "-o", outputTemplate,
                "--no-playlist",
                "--write-info-json",
                "--write-thumbnail",
                "--ffmpeg-location", "/opt/homebrew/bin/ffmpeg",
                "--js-runtimes", "node:/opt/homebrew/bin/node",
            ]
            let ytStatus = try await runTool(
                toolName: "yt-dlp",
                executableURL: ytDlpURL,
                arguments: ytArgs,
                stderrTail: stderrTail
            )
            if ytStatus != 0 {
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: stderrTail.string())
            }

            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }

            // Locate single downloaded file
            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil, options: [])
            } catch {
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: stderrTail.string())
            }
            let infoURLs = contents.filter { $0.lastPathComponent.hasSuffix(".info.json") }
            let thumbnailURLs = contents.filter(isThumbnailFile)
            let candidates = contents.filter {
                $0.lastPathComponent != "mixture.wav"
                    && !$0.lastPathComponent.hasSuffix(".info.json")
                    && !isThumbnailFile($0)
            }
            guard candidates.count == 1 else {
                let tail = stderrTail.string()
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
            let ffStatus = try await runTool(
                toolName: "ffmpeg",
                executableURL: ffmpegURL,
                arguments: ffArgs,
                stderrTail: stderrTail
            )
            if ffStatus != 0 {
                throw YouTubeIngestError.toolFailure(tool: "ffmpeg", exitCode: ffStatus, stderrTail: stderrTail.string())
            }

            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }

            do {
                try validateCanonicalAudioFile(at: mixtureURL, fileManager: fileManager)
            } catch let error as CanonicalAudioFileError {
                throw YouTubeIngestError.invalidCanonicalOutput(error.reason)
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
            cancellationRequested = false
            return YouTubeIngestResult(
                audioURL: mixtureURL,
                metadata: metadata,
                artworkURL: artworkURL
            )

        } catch {
            // If owned process still alive, retain ownership/state and surface failure — do not remove directory or clear state
            if await processRunner.hasLiveProcess() {
                if error is CancellationError {
                    throw YouTubeIngestError.cancelled
                }
                throw error
            }
            // No live process: safe to clean entire runDirectory on any failure or cancellation
            if fileManager.fileExists(atPath: runDir.path) {
                try? fileManager.removeItem(at: runDir)
            }
            activeRunDirectory = nil
            // Map Swift CancellationError to our cancelled
            if error is CancellationError {
                throw YouTubeIngestError.cancelled
            }
            throw error
        }
    }

    func fetchPreview(youTubeURL: URL) async throws -> YouTubePreviewResult {
        guard let scheme = youTubeURL.scheme?.lowercased(), scheme == "https",
              let host = youTubeURL.host?.lowercased(),
              host.contains("youtube.com") || host.contains("youtu.be") else {
            throw YouTubeIngestError.invalidYouTubeURL(youTubeURL.absoluteString)
        }
        guard isAbsoluteFileURL(ytDlpURL) else {
            throw YouTubeIngestError.invalidCanonicalOutput("ytDlpURL must be absolute file URL: \(ytDlpURL)")
        }
        if await processRunner.hasActiveProcess() || activeRunDirectory != nil {
            throw YouTubeIngestError.alreadyRunning
        }
        let runDir = cacheBaseURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw YouTubeIngestError.toolFailure(tool: "mkdir", exitCode: -1, stderrTail: error.localizedDescription)
        }
        activeRunDirectory = runDir
        cancellationRequested = false
        let stderrTail = AudioStderrTail()
        do {
            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }
            let outputTemplate = runDir.appendingPathComponent("source.%(ext)s").path
            let ytArgs = [
                youTubeURL.absoluteString,
                "-o", outputTemplate,
                "--skip-download",
                "--no-playlist",
                "--write-info-json",
                "--write-thumbnail",
                "--js-runtimes", "node:/opt/homebrew/bin/node",
            ]
            let ytStatus = try await runTool(
                toolName: "yt-dlp",
                executableURL: ytDlpURL,
                arguments: ytArgs,
                stderrTail: stderrTail
            )
            if ytStatus != 0 {
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: stderrTail.string())
            }
            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }
            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil, options: [])
            } catch {
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: stderrTail.string())
            }
            let infoURLs = contents.filter { $0.lastPathComponent.hasSuffix(".info.json") }
            let thumbnailURLs = contents.filter(isThumbnailFile)
            let candidates = contents.filter {
                $0.lastPathComponent != "mixture.wav"
                    && !$0.lastPathComponent.hasSuffix(".info.json")
                    && !isThumbnailFile($0)
            }
            if candidates.count != 0 {
                let tail = stderrTail.string()
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: tail)
            }
            guard infoURLs.count == 1 else {
                let tail = stderrTail.string()
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: tail)
            }
            let metadata = metadata(from: infoURLs)
            let artworkURL = artwork(from: thumbnailURLs)
            let previewDuration = duration(from: infoURLs)
            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }
            for url in infoURLs {
                try? fileManager.removeItem(at: url)
            }
            for url in thumbnailURLs where url != artworkURL {
                try? fileManager.removeItem(at: url)
            }
            activeRunDirectory = nil
            cancellationRequested = false
            return YouTubePreviewResult(metadata: metadata, artworkURL: artworkURL, duration: previewDuration)
        } catch {
            if await processRunner.hasLiveProcess() {
                if error is CancellationError {
                    throw YouTubeIngestError.cancelled
                }
                throw error
            }
            if fileManager.fileExists(atPath: runDir.path) {
                try? fileManager.removeItem(at: runDir)
            }
            activeRunDirectory = nil
            if error is CancellationError {
                throw YouTubeIngestError.cancelled
            }
            throw error
        }
    }

    func downloadAudioOnly(youTubeURL: URL) async throws -> YouTubeIngestResult {
        guard let scheme = youTubeURL.scheme?.lowercased(), scheme == "https",
              let host = youTubeURL.host?.lowercased(),
              host.contains("youtube.com") || host.contains("youtu.be") else {
            throw YouTubeIngestError.invalidYouTubeURL(youTubeURL.absoluteString)
        }
        guard isAbsoluteFileURL(ytDlpURL) else {
            throw YouTubeIngestError.invalidCanonicalOutput("ytDlpURL must be absolute file URL: \(ytDlpURL)")
        }
        guard isAbsoluteFileURL(ffmpegURL) else {
            throw YouTubeIngestError.invalidCanonicalOutput("ffmpegURL must be absolute file URL: \(ffmpegURL)")
        }
        if await processRunner.hasActiveProcess() || activeRunDirectory != nil {
            throw YouTubeIngestError.alreadyRunning
        }
        let runDir = cacheBaseURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw YouTubeIngestError.toolFailure(tool: "mkdir", exitCode: -1, stderrTail: error.localizedDescription)
        }
        activeRunDirectory = runDir
        cancellationRequested = false
        let stderrTail = AudioStderrTail()
        do {
            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }
            let outputTemplate = runDir.appendingPathComponent("source.%(ext)s").path
            let ytArgs = [
                youTubeURL.absoluteString,
                "-f", "bestaudio",
                "-o", outputTemplate,
                "--no-playlist",
                "--write-info-json",
                "--write-thumbnail",
                "--ffmpeg-location", "/opt/homebrew/bin/ffmpeg",
                "--js-runtimes", "node:/opt/homebrew/bin/node",
            ]
            let ytStatus = try await runTool(
                toolName: "yt-dlp",
                executableURL: ytDlpURL,
                arguments: ytArgs,
                stderrTail: stderrTail
            )
            if ytStatus != 0 {
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: stderrTail.string())
            }
            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }
            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil, options: [])
            } catch {
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: stderrTail.string())
            }
            let infoURLs = contents.filter { $0.lastPathComponent.hasSuffix(".info.json") }
            let thumbnailURLs = contents.filter(isThumbnailFile)
            let candidates = contents.filter {
                $0.lastPathComponent != "mixture.wav"
                    && !$0.lastPathComponent.hasSuffix(".info.json")
                    && !isThumbnailFile($0)
            }
            guard candidates.count == 1 else {
                let tail = stderrTail.string()
                throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: ytStatus, stderrTail: tail)
            }
            let sourceURL = candidates[0]
            let metadata = metadata(from: infoURLs)
            let artworkURL = artwork(from: thumbnailURLs)
            if Task.isCancelled || cancellationRequested {
                throw YouTubeIngestError.cancelled
            }
            for url in infoURLs {
                try? fileManager.removeItem(at: url)
            }
            for url in thumbnailURLs where url != artworkURL {
                try? fileManager.removeItem(at: url)
            }
            activeRunDirectory = nil
            cancellationRequested = false
            return YouTubeIngestResult(audioURL: sourceURL, metadata: metadata, artworkURL: artworkURL)
        } catch {
            if await processRunner.hasLiveProcess() {
                if error is CancellationError {
                    throw YouTubeIngestError.cancelled
                }
                throw error
            }
            if fileManager.fileExists(atPath: runDir.path) {
                try? fileManager.removeItem(at: runDir)
            }
            activeRunDirectory = nil
            if error is CancellationError {
                throw YouTubeIngestError.cancelled
            }
            throw error
        }
    }

    func cancel() async throws {
        cancellationRequested = true
        let dir = activeRunDirectory
        if !(await processRunner.hasActiveProcess()) {
            // No active process; safe to remove directory if present (no child running)
            if let d = dir {
                try? fileManager.removeItem(at: d)
                activeRunDirectory = nil
            }
            return
        }

        do {
            try await processRunner.cancel()
        } catch let error as AudioProcessRunnerError {
            throw mapProcessError(error, toolName: "process")
        }
        // Proven dead — clear ownership and remove directory
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

        // MARK: Metadata precedence (conservative)

        // Helper: mirrors YouTubeTrackMetadata.metadataValue — trim, reject empty / "n/a" / "na"
        func sanitized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.lowercased() != "n/a",
                  trimmed.lowercased() != "na" else {
                return nil
            }
            return trimmed
        }

        // Normalize for comparison: trim, strip " - Topic" suffix, lowercased
        func normalizedForComparison(_ value: String) -> String {
            var t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasSuffix(" - Topic") {
                t = String(t.dropLast(" - Topic".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return t.lowercased()
        }

        // Channel for display (preview card) — keep legacy candidates only
        let rawChannel: String? = {
            for candidate in [info.channel, info.uploader, info.channelName] {
                if let c = sanitized(candidate) { return c }
            }
            return nil
        }()

        // Artist precedence:
        // a. First non-empty sanitized among artist, artists.first, creator, creators.first
        // b. If found, use it
        // c. Else try channel-corroborated split inference
        // d. Else nil
        let structuredArtist: String? = {
            let candidates: [String?] = [info.artist, info.artists?.first, info.creator, info.creators?.first]
            for c in candidates {
                if let s = sanitized(c) { return s }
            }
            return nil
        }()

        let structuredTrack: String? = sanitized(info.track)

        // Fallback inference: only when structured insufficient.
        // Split raw video title on first " - " and corroborate left side against channel/creator identity.
        func inferredSplit() -> (left: String, right: String)? {
            guard let rawTitle = info.title else { return nil }
            let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { return nil }
            guard let range = trimmedTitle.range(of: " - ") else { return nil }
            let left = String(trimmedTitle[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(trimmedTitle[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !left.isEmpty, !right.isEmpty else { return nil }
            let normalizedLeft = normalizedForComparison(left)
            guard !normalizedLeft.isEmpty else { return nil }
            // Build set of normalized identities: channel/creator + structuredArtist
            var normalizedCandidates = Set<String>()
            let identityCandidates: [String?] = [info.channel, info.uploader, info.channelName, info.creator, info.creators?.first]
            for cand in identityCandidates {
                guard let s = sanitized(cand) else { continue }
                let n = normalizedForComparison(s)
                if !n.isEmpty { normalizedCandidates.insert(n) }
            }
            if let s = structuredArtist {
                let n = normalizedForComparison(s)
                if !n.isEmpty { normalizedCandidates.insert(n) }
            }
            guard normalizedCandidates.contains(normalizedLeft) else { return nil }
            return (left, right)
        }

        let inferred = inferredSplit()

        // Final artist: structured wins, otherwise inferred left
        let finalArtist: String? = structuredArtist ?? inferred?.left

        // Title precedence:
        // a. Structured track if present
        // b. Else if raw title has corroborated "Artist - Title" (left matches structuredArtist or channel/creator), use right side
        // c. Else raw video title
        let finalTitle: String? = {
            if let t = structuredTrack { return t }
            if let inf = inferred {
                return inf.right
            }
            return sanitized(info.title)
        }()

        return YouTubeTrackMetadata(
            artist: finalArtist,
            title: finalTitle,
            album: info.album,
            albumArtist: info.albumArtist,
            year: info.releaseYear.map(String.init),
            genre: info.genre,
            trackNumber: info.trackNumber.map(String.init),
            channel: rawChannel
        )
    }

    private func duration(from infoURLs: [URL]) -> TimeInterval? {
        guard infoURLs.count == 1,
              let data = try? Data(contentsOf: infoURLs[0]),
              let info = try? JSONDecoder().decode(YTDLPInfo.self, from: data),
              let d = info.duration, d > 0 else {
            return nil
        }
        return d
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

    private func runTool(
        toolName: String,
        executableURL: URL,
        arguments: [String],
        stderrTail: AudioStderrTail
    ) async throws -> Int32 {
        if Task.isCancelled || cancellationRequested {
            throw YouTubeIngestError.cancelled
        }
        do {
            return try await processRunner.run(
                executableURL: executableURL,
                arguments: arguments,
                stderrTail: stderrTail
            )
        } catch let error as AudioProcessRunnerError {
            throw mapProcessError(error, toolName: toolName)
        }
    }

    private func mapProcessError(_ error: AudioProcessRunnerError, toolName: String) -> YouTubeIngestError {
        switch error {
        case .launchFailed(let message):
            return .toolFailure(tool: toolName, exitCode: -1, stderrTail: message)
        case .cancelled:
            return .cancelled
        case .cleanupFailed(let message):
            return .cleanupFailed(message)
        }
    }
}
