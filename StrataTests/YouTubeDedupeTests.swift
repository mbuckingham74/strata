import XCTest
@testable import Strata
import Foundation
import AVFoundation

// MARK: - Local fakes (file-private to avoid collisions)

@MainActor
private final class DedupFakeTransport: AudioTransport {
    var duration: TimeInterval = 120
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var onCompletion: (() -> Void)?
    func load(url: URL) throws { currentTime = 0; isPlaying = false }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to time: TimeInterval) { currentTime = time }
    func stop() { isPlaying = false; currentTime = 0 }
}

@MainActor
private final class DedupFakeStemTransport: StemAudioTransport {
    var duration: TimeInterval = 120
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var mutedStems: Set<StemName> = []
    var soloedStems: Set<StemName> = []
    var stemGains: [StemName: Float] = [:]
    var onCompletion: (() -> Void)?
    func load(result: SeparationResult) throws {
        for s in StemName.allCases { stemGains[s] = 1.0 }
        currentTime = 0; isPlaying = false
    }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to time: TimeInterval) { currentTime = time }
    func stop() { isPlaying = false; currentTime = 0 }
    func setMuted(_ muted: Bool, for stem: StemName) {
        if muted { mutedStems.insert(stem) } else { mutedStems.remove(stem) }
    }
    func setSoloed(_ soloed: Bool, for stem: StemName) {
        if soloed { soloedStems.insert(stem) } else { soloedStems.remove(stem) }
    }
    func gain(for stem: StemName) -> Float { stemGains[stem] ?? 1.0 }
    func setGain(_ gain: Float, for stem: StemName) { stemGains[stem] = min(max(gain, 0), 1) }
}

// Fake YouTube ingest for actual preview/MP3-export flows (no network, no worker).
private actor DedupFakeYouTubeIngest: YouTubeIngesting {
    let preview: YouTubePreviewResult
    let ingestResult: YouTubeIngestResult?

    init(preview: YouTubePreviewResult, ingestResult: YouTubeIngestResult? = nil) {
        self.preview = preview
        self.ingestResult = ingestResult
    }

    func ingest(youTubeURL: URL) async throws -> URL {
        guard let r = ingestResult else {
            throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: 1, stderrTail: "no ingestResult configured")
        }
        return r.audioURL
    }

    func ingestWithMetadata(youTubeURL: URL, onProgress: @Sendable (YouTubeIngestPhase) -> Void) async throws -> YouTubeIngestResult {
        guard let r = ingestResult else {
            throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: 1, stderrTail: "no ingestResult configured")
        }
        return r
    }

    func fetchPreview(youTubeURL: URL) async throws -> YouTubePreviewResult { preview }

    func downloadAudioOnly(youTubeURL: URL) async throws -> YouTubeIngestResult {
        guard let r = ingestResult else {
            throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: 1, stderrTail: "no ingestResult configured")
        }
        return r
    }

    func cancel() async throws {}
}

private func makeDedupWAV(at url: URL, frames: UInt32) throws {    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for ch in 0..<2 {
        let ptr = buffer.floatChannelData![ch]
        for i in 0..<Int(frames) { ptr[i] = sin(Float(i) * 0.01) * 0.1 + Float(ch) * 0.01 }
    }
    try file.write(from: buffer)
}

@MainActor
private func makeDedupResult(frames: UInt32 = 1024) throws -> (scratch: URL, result: SeparationResult) {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let mixture = scratch.appendingPathComponent("mixture.wav")
    try makeDedupWAV(at: mixture, frames: frames)
    let inputSHA = try sha256File(at: mixture)
    let jobId = UUID().uuidString.lowercased()
    let jobDir = scratch.appendingPathComponent(jobId, isDirectory: true)
    try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
    var stemURLs: [StemName: URL] = [:]
    var records: [[String: Any]] = []
    for stem in StemName.allCases {
        let url = jobDir.appendingPathComponent("\(stem.rawValue).wav")
        try makeDedupWAV(at: url, frames: frames)
        let hash = try sha256File(at: url)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        stemURLs[stem] = url
        records.append(["name": stem.rawValue, "path": url.path, "sha256": hash, "file_size": size, "frame_count": UInt64(frames), "channels": 2, "sample_rate": 44100])
    }
    let manifest: [String: Any] = [
        "job_id": jobId,
        "model": TrustedInferenceIdentity.model,
        "checkpoint_sha256": TrustedInferenceIdentity.checkpointSHA256,
        "backend": TrustedInferenceIdentity.backend,
        "device": TrustedInferenceIdentity.device,
        "input_path": mixture.path,
        "output_dir": scratch.path,
        "input_sha256": inputSHA,
        "input_metadata": ["sample_rate": 44100, "channels": 2, "frames": UInt64(frames), "duration": Double(frames) / 44100.0, "sha256": inputSHA],
        "stems": records
    ]
    let manifestURL = jobDir.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]).write(to: manifestURL)
    let job = JobInfo(jobId: jobId, inputPath: mixture.path, outputDir: scratch.path)
    let ready = ReadyMetadata(backend: TrustedInferenceIdentity.backend, device: TrustedInferenceIdentity.device, checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256, model: nil)
    let result = try SeparationValidator.validatedResult(manifestURL: manifestURL, job: job, readyMetadata: ready, receivedStems: stemURLs)
    return (scratch, result)
}

@MainActor
private func makeDedupReseparationResult(persistedMixtureURL: URL, frames: UInt32 = 1024) throws -> (scratch: URL, result: SeparationResult) {
    // Simulates re-separating a reopened project: the persisted mixture is reused
    // as input (under Projects root) while fresh outputs land in scratch.
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("StrataReseparate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let inputSHA = try sha256File(at: persistedMixtureURL)
    let jobId = UUID().uuidString.lowercased()
    let jobDir = scratch.appendingPathComponent(jobId, isDirectory: true)
    try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
    var stemURLs: [StemName: URL] = [:]
    var records: [[String: Any]] = []
    for stem in StemName.allCases {
        let url = jobDir.appendingPathComponent("\(stem.rawValue).wav")
        try makeDedupWAV(at: url, frames: frames)
        let hash = try sha256File(at: url)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        stemURLs[stem] = url
        records.append(["name": stem.rawValue, "path": url.path, "sha256": hash, "file_size": size, "frame_count": UInt64(frames), "channels": 2, "sample_rate": 44100])
    }
    let manifest: [String: Any] = [
        "job_id": jobId,
        "model": TrustedInferenceIdentity.model,
        "checkpoint_sha256": TrustedInferenceIdentity.checkpointSHA256,
        "backend": TrustedInferenceIdentity.backend,
        "device": TrustedInferenceIdentity.device,
        "input_path": persistedMixtureURL.path,
        "output_dir": scratch.path,
        "input_sha256": inputSHA,
        "input_metadata": ["sample_rate": 44100, "channels": 2, "frames": UInt64(frames), "duration": Double(frames) / 44100.0, "sha256": inputSHA],
        "stems": records
    ]
    let manifestURL = jobDir.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]).write(to: manifestURL)
    let job = JobInfo(jobId: jobId, inputPath: persistedMixtureURL.path, outputDir: scratch.path)
    let ready = ReadyMetadata(backend: TrustedInferenceIdentity.backend, device: TrustedInferenceIdentity.device, checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256, model: nil)
    let result = try SeparationValidator.validatedResult(manifestURL: manifestURL, job: job, readyMetadata: ready, receivedStems: stemURLs)
    return (scratch, result)
}

private func persistedManifestJobId(persistence: StrataProjectPersistence, projectId: String) throws -> String {
    let data = try Data(contentsOf: persistence.projectDirectory(for: projectId).appendingPathComponent("separation/manifest.json"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return json?["job_id"] as? String ?? ""
}

@MainActor
final class YouTubeDedupeTests: XCTestCase {

    // 1. Preview / load-only YouTube source creates NO project.
    func testPreviewOnlyCreatesNoProject() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupPreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let store = SessionStore(persistence: persistence)
        // Simulate typing/previewing a YouTube URL without completing a separation.
        store.draftYouTubeURLString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        XCTAssertEqual(store.projects.count, 0)
        XCTAssertEqual(persistence.enumerateProjects().count, 0)
    }

    // 2. Completed separation creates one project.
    func testCompletedSeparationCreatesOneProject() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupOne-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let store = SessionStore(persistence: persistence)
        let playback = PlaybackController(transport: DedupFakeTransport())
        let stem = StemPlaybackController(transport: DedupFakeStemTransport())
        let inference = InferenceController()
        inference.editableArtist = "Artist"
        inference.editableTitle = "Title"
        store.draftYouTubeURLString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let (scratch, result) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch) }
        playback.load(url: URL(fileURLWithPath: "/tmp/yt.mp3"), displayTitle: "Artist - Title")
        _ = try store.persistCompletedSeparation(result: result, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(persistence.enumerateProjects().count, 1)
    }

    // 3. Repeating completion for the same YouTube video leaves exactly one project (assets updated, same id).
    func testRepeatSameYouTubeSourceUpdatesInPlace() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupRepeat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let store = SessionStore(persistence: persistence)
        let playback = PlaybackController(transport: DedupFakeTransport())
        let stem = StemPlaybackController(transport: DedupFakeStemTransport())
        let inference = InferenceController()
        inference.editableArtist = "Artist"
        inference.editableTitle = "Title"
        playback.load(url: URL(fileURLWithPath: "/tmp/yt.mp3"), displayTitle: "Artist - Title")

        store.draftYouTubeURLString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let (scratch1, result1) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch1) }
        let first = try store.persistCompletedSeparation(result: result1, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)

        // Same video, different URL shape + extra params + host casing.
        store.draftYouTubeURLString = "HTTPS://youtu.be/dQw4w9WgXcQ?t=42&list=xyz"
        let (scratch2, result2) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch2) }
        let second = try store.persistCompletedSeparation(result: result2, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)

        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(persistence.enumerateProjects().count, 1)
        XCTAssertEqual(second.id, first.id, "Repeat must preserve the project id")
        XCTAssertEqual(store.selectedProjectID, first.id)
        // Persisted assets must be replaced by the repeat (manifest tracks the new job).
        let manifestData = try Data(contentsOf: persistence.projectDirectory(for: first.id).appendingPathComponent("separation/manifest.json"))
        let manifestJSON = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        XCTAssertEqual(manifestJSON?["job_id"] as? String, result2.jobId)
    }

    // 4. A different YouTube video creates a second project.
    func testDifferentYouTubeSourceCreatesSecondProject() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupTwo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let store = SessionStore(persistence: persistence)
        let playback = PlaybackController(transport: DedupFakeTransport())
        let stem = StemPlaybackController(transport: DedupFakeStemTransport())
        let inference = InferenceController()
        inference.editableArtist = "Artist"
        inference.editableTitle = "Title"
        playback.load(url: URL(fileURLWithPath: "/tmp/yt.mp3"), displayTitle: "Artist - Title")

        store.draftYouTubeURLString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let (scratch1, result1) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch1) }
        _ = try store.persistCompletedSeparation(result: result1, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)

        store.draftYouTubeURLString = "https://www.youtube.com/watch?v=9bZkp7q19f0"
        let (scratch2, result2) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch2) }
        _ = try store.persistCompletedSeparation(result: result2, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)

        XCTAssertEqual(store.projects.count, 2)
        XCTAssertEqual(persistence.enumerateProjects().count, 2)
    }

    // Canonical identity covers the required URL shapes.
    func testCanonicalIdentityShapes() {
        let id = "dQw4w9WgXcQ"
        let variants = [
            "https://www.youtube.com/watch?v=\(id)",
            "https://youtube.com/watch?v=\(id)&list=PL123&t=10s",
            "HTTPS://WWW.YOUTUBE.COM/watch?v=\(id)",
            "https://youtu.be/\(id)",
            "https://youtu.be/\(id)?t=42",
            "https://www.youtube.com/shorts/\(id)",
            "https://www.youtube.com/embed/\(id)",
            "https://music.youtube.com/watch?v=\(id)"
        ]
        for v in variants {
            XCTAssertEqual(YouTubeCanonicalIdentity.videoID(from: v), id, "Failed for \(v)")
        }
        XCTAssertEqual(
            YouTubeCanonicalIdentity.dedupeKey(for: variants[0]),
            YouTubeCanonicalIdentity.dedupeKey(for: variants[3])
        )
        XCTAssertNotEqual(
            YouTubeCanonicalIdentity.dedupeKey(for: "https://www.youtube.com/watch?v=\(id)"),
            YouTubeCanonicalIdentity.dedupeKey(for: "https://www.youtube.com/watch?v=9bZkp7q19f0")
        )
    }

    // Finding 5: suffix lookalikes are not YouTube hosts.
    func testFalseHostnamesNotTreatedAsYouTube() {
        let falseHosts = [
            "https://evil-youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtube.com.evil.com/watch?v=dQw4w9WgXcQ",
            "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
            "https://fakeyoutu.be/dQw4w9WgXcQ",
            "https://youtube.com.evil.com/shorts/dQw4w9WgXcQ"
        ]
        for url in falseHosts {
            XCTAssertNil(YouTubeCanonicalIdentity.videoID(from: url), "Must reject \(url)")
            XCTAssertFalse(YouTubeCanonicalIdentity.isYouTubeURL(url), "Must reject \(url)")
        }
        let genuineHosts = [
            "https://youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"
        ]
        for url in genuineHosts {
            XCTAssertTrue(YouTubeCanonicalIdentity.isYouTubeURL(url), "Must accept \(url)")
            XCTAssertEqual(YouTubeCanonicalIdentity.videoID(from: url), "dQw4w9WgXcQ", "Must extract ID from \(url)")
        }
        // A false hostname never collides with a genuine video key.
        XCTAssertNotEqual(
            YouTubeCanonicalIdentity.dedupeKey(for: falseHosts[0]),
            YouTubeCanonicalIdentity.dedupeKey(for: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        )
    }

    // Finding 1: reopen → re-separate (input is the persisted mixture) reaches
    // dedupe/replacement through the auto-persist trigger: one project, same ID.
    func testReopenThenReseparateUpdatesSameProject() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupReseparate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let store = SessionStore(persistence: persistence)
        let playback = PlaybackController(transport: DedupFakeTransport())
        let stem = StemPlaybackController(transport: DedupFakeStemTransport())
        let inference = InferenceController()
        inference.editableArtist = "Artist"
        inference.editableTitle = "Title"
        playback.load(url: URL(fileURLWithPath: "/tmp/yt.mp3"), displayTitle: "Artist - Title")
        store.draftYouTubeURLString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let (scratch1, result1) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch1) }
        let first = try store.persistCompletedSeparation(result: result1, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)

        // Reopen into fresh controllers, then re-separate from the persisted mixture.
        let playback2 = PlaybackController(transport: DedupFakeTransport())
        let stem2 = StemPlaybackController(transport: DedupFakeStemTransport())
        let inference2 = InferenceController()
        try store.reopen(projectID: first.id, playbackController: playback2, inferenceController: inference2, stemPlaybackController: stem2)
        XCTAssertEqual(store.projects.count, 1)
        let persistedMixture = persistence.projectDirectory(for: first.id).appendingPathComponent("source/mixture.wav")
        let (scratch2, result2) = try makeDedupReseparationResult(persistedMixtureURL: persistedMixture)
        defer { try? FileManager.default.removeItem(at: scratch2) }
        // Mirror the view handoff: new result is loaded into stem playback first.
        stem2.load(result: result2, displayName: "Artist - Title")
        store.handleCompletedSeparation(result: result2, playbackController: playback2, inferenceController: inference2, stemPlaybackController: stem2)

        XCTAssertEqual(store.projects.count, 1, "Re-separation must not create a duplicate row")
        XCTAssertEqual(store.projects.first?.id, first.id, "Re-separation must preserve the project id")
        XCTAssertEqual(store.selectedProjectID, first.id)
        XCTAssertEqual(try persistedManifestJobId(persistence: persistence, projectId: first.id), result2.jobId, "Persisted assets must be replaced")
        XCTAssertNil(store.lastError)
    }

    // Finding 2a: replacement preserves persisted metadata/artwork/gains when the
    // new separation supplies none of them.
    func testUpdatePreservesMetadataArtworkGains() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupPreserve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let store = SessionStore(persistence: persistence)
        let playback = PlaybackController(transport: DedupFakeTransport())
        let stem = StemPlaybackController(transport: DedupFakeStemTransport())
        let inference = InferenceController()
        inference.editableArtist = "Artist"
        inference.editableTitle = "Title"
        inference.editableAlbum = "Album"
        let artScratch = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupArt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artScratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artScratch) }
        let artFile = artScratch.appendingPathComponent("art.jpg")
        try Data("artwork".utf8).write(to: artFile)
        inference.editableArtwork = .replaced(artFile)
        playback.load(url: URL(fileURLWithPath: "/tmp/yt.mp3"), displayTitle: "Artist - Title")
        store.draftYouTubeURLString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let (scratch1, result1) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch1) }
        stem.load(result: result1, displayName: "Artist - Title")
        stem.setGain(0.2, for: .bass)
        stem.setGain(0.9, for: .vocals)
        let first = try store.persistCompletedSeparation(result: result1, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)
        // Note: the returned value predates artwork-path assignment; verify persisted state.
        XCTAssertEqual(try persistence.load(projectID: first.id).artworkPath, "source/artwork.jpg")

        // Repeat with bare controllers: no metadata, no artwork, default gains.
        let playback2 = PlaybackController(transport: DedupFakeTransport())
        let stem2 = StemPlaybackController(transport: DedupFakeStemTransport())
        let inference2 = InferenceController()
        playback2.load(url: URL(fileURLWithPath: "/tmp/yt.mp3"), displayTitle: "Artist - Title")
        let (scratch2, result2) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch2) }
        stem2.load(result: result2, displayName: "Artist - Title")
        let second = try store.persistCompletedSeparation(result: result2, playbackController: playback2, inferenceController: inference2, stemPlaybackController: stem2)

        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(second.id, first.id)
        let reloaded = try persistence.load(projectID: first.id)
        XCTAssertEqual(reloaded.source.metadata?.artist, "Artist", "Persisted metadata must survive")
        XCTAssertEqual(reloaded.source.metadata?.album, "Album", "Persisted metadata must survive")
        XCTAssertEqual(reloaded.artworkPath, "source/artwork.jpg", "Artwork reference must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.projectDirectory(for: first.id).appendingPathComponent("source/artwork.jpg").path))
        XCTAssertEqual(reloaded.gains[.bass] ?? -1, 0.2, accuracy: 0.001, "Saved gains must survive")
        XCTAssertEqual(reloaded.gains[.vocals] ?? -1, 0.9, accuracy: 0.001, "Saved gains must survive")
        XCTAssertEqual(try persistedManifestJobId(persistence: persistence, projectId: first.id), result2.jobId, "Assets must still be replaced")
    }

    // Finding 2b: freshly supplied metadata/artwork/gains replace the persisted ones.
    func testUpdateTakesSuppliedReplacements() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupReplace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let store = SessionStore(persistence: persistence)
        let playback = PlaybackController(transport: DedupFakeTransport())
        let stem = StemPlaybackController(transport: DedupFakeStemTransport())
        let inference = InferenceController()
        inference.editableArtist = "Artist"
        inference.editableTitle = "Title"
        let artScratch = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupArt2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artScratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artScratch) }
        let oldArt = artScratch.appendingPathComponent("old.jpg")
        try Data("old".utf8).write(to: oldArt)
        inference.editableArtwork = .replaced(oldArt)
        playback.load(url: URL(fileURLWithPath: "/tmp/yt.mp3"), displayTitle: "Artist - Title")
        store.draftYouTubeURLString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let (scratch1, result1) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch1) }
        stem.load(result: result1, displayName: "Artist - Title")
        stem.setGain(0.2, for: .bass)
        let first = try store.persistCompletedSeparation(result: result1, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)

        // Repeat with fresh values everywhere.
        let playback2 = PlaybackController(transport: DedupFakeTransport())
        let stem2 = StemPlaybackController(transport: DedupFakeStemTransport())
        let inference2 = InferenceController()
        inference2.editableArtist = "NewArtist"
        inference2.editableTitle = "NewTitle"
        let newArt = artScratch.appendingPathComponent("new.png")
        try Data("new".utf8).write(to: newArt)
        inference2.editableArtwork = .replaced(newArt)
        playback2.load(url: URL(fileURLWithPath: "/tmp/yt.mp3"), displayTitle: "NewArtist - NewTitle")
        let (scratch2, result2) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch2) }
        stem2.load(result: result2, displayName: "NewArtist - NewTitle")
        for s in StemName.allCases { stem2.setGain(0.7, for: s) }
        let second = try store.persistCompletedSeparation(result: result2, playbackController: playback2, inferenceController: inference2, stemPlaybackController: stem2)

        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(second.id, first.id)
        let reloaded = try persistence.load(projectID: first.id)
        XCTAssertEqual(reloaded.source.metadata?.artist, "NewArtist")
        XCTAssertEqual(reloaded.artworkPath, "source/artwork.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.projectDirectory(for: first.id).appendingPathComponent("source/artwork.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.projectDirectory(for: first.id).appendingPathComponent("source/artwork.jpg").path), "Obsolete artwork extension must be removed")
        for s in StemName.allCases {
            XCTAssertEqual(reloaded.gains[s] ?? -1, 0.7, accuracy: 0.001)
        }
        _ = result2
    }

    // Finding 3: replacing with source == destination (persisted assets reused as
    // input) must not delete assets before copying; the project stays intact.
    func testPersistAssetsSelfReplacementIsSafe() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupSelf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let (scratch, result) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let artFile = scratch.appendingPathComponent("art.jpg")
        try Data("artwork".utf8).write(to: artFile)
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 0.5 }
        let project = try StrataProject(schemaVersion: 1, id: UUID().uuidString.lowercased(), createdAt: Date(), lastOpenedAt: Date(), displayTitle: "Self", source: StrataProjectSource(kind: .localFile, locator: "/tmp/self.wav", metadata: nil), gains: gains)
        try persistence.persistCompletedSeparation(project: project, result: result, artworkSourceURL: artFile)
        let dir = persistence.projectDirectory(for: project.id)
        let mixtureBefore = try Data(contentsOf: dir.appendingPathComponent("source/mixture.wav"))

        // Re-persist using the persisted files themselves as sources.
        let loaded = try persistence.load(projectID: project.id)
        var stemURLs: [StemName: URL] = [:]
        for s in StemName.allCases {
            stemURLs[s] = dir.appendingPathComponent(StrataProject.stemRelativePath(for: s))
        }
        XCTAssertNoThrow(try persistence.persistAssets(
            for: loaded,
            mixtureSourceURL: dir.appendingPathComponent("source/mixture.wav"),
            manifestSourceURL: dir.appendingPathComponent("separation/manifest.json"),
            stemSourceURLs: stemURLs,
            artworkSourceURL: dir.appendingPathComponent("source/artwork.jpg")
        ))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("source/mixture.wav")), mixtureBefore, "Self-replacement must leave assets intact")
        let reloaded = try persistence.load(projectID: project.id)
        XCTAssertEqual(reloaded.artworkPath, "source/artwork.jpg")
        XCTAssertNoThrow(try persistence.loadSeparationResult(for: project.id))
    }

    // Finding 4: replacing artwork with a different extension leaves no stale file.
    func testArtworkExtensionChangeRemovesStaleFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupArtExt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let (scratch, result) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let oldArt = scratch.appendingPathComponent("old.jpg")
        try Data("old".utf8).write(to: oldArt)
        let newArt = scratch.appendingPathComponent("new.png")
        try Data("new".utf8).write(to: newArt)
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 0.5 }
        let project = try StrataProject(schemaVersion: 1, id: UUID().uuidString.lowercased(), createdAt: Date(), lastOpenedAt: Date(), displayTitle: "Art", source: StrataProjectSource(kind: .localFile, locator: "/tmp/art.wav", metadata: nil), gains: gains)
        try persistence.persistCompletedSeparation(project: project, result: result, artworkSourceURL: oldArt)
        let dir = persistence.projectDirectory(for: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("source/artwork.jpg").path))

        let loaded = try persistence.load(projectID: project.id)
        var stemURLs: [StemName: URL] = [:]
        for s in StemName.allCases { stemURLs[s] = result.stems[s]!.url }
        try persistence.persistAssets(
            for: loaded,
            mixtureSourceURL: result.inputURL,
            manifestSourceURL: result.manifestURL,
            stemSourceURLs: stemURLs,
            artworkSourceURL: newArt
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("source/artwork.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("source/artwork.jpg").path), "Obsolete artwork file must be removed")
        XCTAssertEqual(try persistence.load(projectID: project.id).artworkPath, "source/artwork.png")
    }

    // Actual preview flow (loadYouTubeSource via fake ingest) creates no project.
    func testActualPreviewFlowCreatesNoProject() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupActualPreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let store = SessionStore(persistence: persistence)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupActualPreviewWork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artworkURL = directory.appendingPathComponent("thumb.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: artworkURL)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(artist: "Artist", title: "Title", channel: "Channel"))
        let preview = YouTubePreviewResult(metadata: metadata, artworkURL: artworkURL, duration: 123.4)
        let ingest = DedupFakeYouTubeIngest(preview: preview)
        let controller = InferenceController(client: InferenceWorkerClient(), outputBase: directory, youTubeIngest: ingest)

        controller.loadYouTubeSource(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        let loadTask = try XCTUnwrap(controller.debugCurrentTask())
        await loadTask.value

        XCTAssertTrue(controller.isYouTubeSourceLoaded)
        XCTAssertNil(controller.result, "Preview must not start separation")
        XCTAssertEqual(store.projects.count, 0)
        XCTAssertEqual(persistence.enumerateProjects().count, 0)
    }

    // Actual MP3-export flow (prepareYouTubeMP3Export via fake) creates no project.
    func testActualMP3ExportFlowCreatesNoProject() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupActualMP3-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let store = SessionStore(persistence: persistence)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupActualMP3Work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artworkURL = directory.appendingPathComponent("thumb.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: artworkURL)
        let audioFile = directory.appendingPathComponent("source.m4a")
        try Data(repeating: 0, count: 2048).write(to: audioFile)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(artist: "Artist", title: "Title", channel: "Channel"))
        let preview = YouTubePreviewResult(metadata: metadata, artworkURL: artworkURL, duration: 99.9)
        let audioResult = YouTubeIngestResult(audioURL: audioFile, metadata: metadata, artworkURL: artworkURL)
        let ingest = DedupFakeYouTubeIngest(preview: preview, ingestResult: audioResult)
        let controller = InferenceController(client: InferenceWorkerClient(), outputBase: directory, youTubeIngest: ingest)

        controller.prepareYouTubeMP3Export(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        let exportTask = try XCTUnwrap(controller.debugCurrentTask())
        await exportTask.value

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.result, "MP3 export must not create separation results")
        XCTAssertEqual(store.projects.count, 0)
        XCTAssertEqual(persistence.enumerateProjects().count, 0)
        // The StemExporter MP3 path is file export only and never touches the Library.
        XCTAssertEqual(StemExporter.defaultYouTubeMP3Filename(metadata: metadata), "Artist - Title.mp3")
        XCTAssertEqual(store.projects.count, 0)
    }

    // Local files sharing only a filename never dedupe: two completions, two projects.
    func testLocalFilesWithSameFilenameCreateTwoProjects() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataDedupLocal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let store = SessionStore(persistence: persistence)
        let playback = PlaybackController(transport: DedupFakeTransport())
        let stem = StemPlaybackController(transport: DedupFakeStemTransport())
        let inference = InferenceController()

        // Both inputs share the filename "mixture.wav" but live at distinct locators.
        let (scratch1, result1) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch1) }
        let (scratch2, result2) = try makeDedupResult()
        defer { try? FileManager.default.removeItem(at: scratch2) }
        XCTAssertEqual(result1.inputURL.lastPathComponent, result2.inputURL.lastPathComponent)
        XCTAssertNotEqual(result1.inputURL.path, result2.inputURL.path)

        playback.load(url: result1.inputURL, displayTitle: "First")
        let first = try store.persistCompletedSeparation(result: result1, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)
        playback.load(url: result2.inputURL, displayTitle: "Second")
        let second = try store.persistCompletedSeparation(result: result2, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)

        XCTAssertEqual(first.source.kind, .localFile)
        XCTAssertEqual(second.source.kind, .localFile)
        XCTAssertEqual(store.projects.count, 2)
        XCTAssertEqual(persistence.enumerateProjects().count, 2)
        XCTAssertNotEqual(first.id, second.id)
    }
}
