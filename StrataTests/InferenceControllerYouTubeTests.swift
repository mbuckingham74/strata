import XCTest
@testable import Strata
import Foundation
import AVFoundation
import CryptoKit

// MARK: - Mocks

private actor MockYouTubeSuccess: YouTubeIngesting {
    let mixtureURL: URL
    private(set) var ingestCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var ingestedURLs: [URL] = []

    init(mixtureURL: URL) { self.mixtureURL = mixtureURL }

    func ingest(youTubeURL: URL) async throws -> URL {
        ingestCallCount += 1
        ingestedURLs.append(youTubeURL)
        try Task.checkCancellation()
        return mixtureURL
    }

    func cancel() async throws {
        cancelCallCount += 1
    }
}

private actor MockYouTubeMetadataSuccess: YouTubeIngesting {
    let result: YouTubeIngestResult
    private(set) var ingestCallCount = 0
    private(set) var ingestedURLs: [URL] = []

    init(result: YouTubeIngestResult) {
        self.result = result
    }

    func ingest(youTubeURL: URL) async throws -> URL {
        try await ingestWithMetadata(youTubeURL: youTubeURL).audioURL
    }

    func ingestWithMetadata(youTubeURL: URL) async throws -> YouTubeIngestResult {
        try await ingestWithMetadata(youTubeURL: youTubeURL, onProgress: { _ in })
    }

    func ingestWithMetadata(youTubeURL: URL, onProgress: @Sendable (YouTubeIngestPhase) -> Void) async throws -> YouTubeIngestResult {
        ingestCallCount += 1
        ingestedURLs.append(youTubeURL)
        try Task.checkCancellation()
        return result
    }

    func cancel() async throws {}
}

private actor MockYouTubePreviewFlow: YouTubeIngesting {
    let preview: YouTubePreviewResult
    let ingestResult: YouTubeIngestResult?
    let downloadResult: YouTubeIngestResult?
    private(set) var fetchPreviewCallCount = 0
    private(set) var ingestCallCount = 0
    private(set) var downloadCallCount = 0
    private(set) var fetchPreviewURLs: [URL] = []
    private(set) var ingestURLs: [URL] = []
    private(set) var downloadURLs: [URL] = []

    init(preview: YouTubePreviewResult, ingestResult: YouTubeIngestResult? = nil, downloadResult: YouTubeIngestResult? = nil) {
        self.preview = preview
        self.ingestResult = ingestResult
        self.downloadResult = downloadResult
    }

    func ingest(youTubeURL: URL) async throws -> URL {
        try await ingestWithMetadata(youTubeURL: youTubeURL).audioURL
    }

    func ingestWithMetadata(youTubeURL: URL) async throws -> YouTubeIngestResult {
        try await ingestWithMetadata(youTubeURL: youTubeURL, onProgress: { _ in })
    }

    func ingestWithMetadata(youTubeURL: URL, onProgress: @Sendable (YouTubeIngestPhase) -> Void) async throws -> YouTubeIngestResult {
        ingestCallCount += 1
        ingestURLs.append(youTubeURL)
        try Task.checkCancellation()
        guard let r = ingestResult ?? downloadResult else {
            throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: 1, stderrTail: "no ingestResult configured")
        }
        return r
    }

    func fetchPreview(youTubeURL: URL) async throws -> YouTubePreviewResult {
        fetchPreviewCallCount += 1
        fetchPreviewURLs.append(youTubeURL)
        try Task.checkCancellation()
        return preview
    }

    func downloadAudioOnly(youTubeURL: URL) async throws -> YouTubeIngestResult {
        downloadCallCount += 1
        downloadURLs.append(youTubeURL)
        try Task.checkCancellation()
        guard let r = downloadResult ?? ingestResult else {
            throw YouTubeIngestError.toolFailure(tool: "yt-dlp", exitCode: 1, stderrTail: "no downloadResult configured")
        }
        return r
    }

    func cancel() async throws {}
}

private actor MockYouTubeFailure: YouTubeIngesting {
    let error: YouTubeIngestError
    private(set) var cancelCallCount = 0
    private(set) var ingestCallCount = 0
    init(error: YouTubeIngestError) { self.error = error }
    func ingest(youTubeURL: URL) async throws -> URL {
        ingestCallCount += 1
        throw error
    }
    func cancel() async throws { cancelCallCount += 1 }
}

private actor MockYouTubeHanging: YouTubeIngesting {
    var shouldThrowCleanupFailedOnCancel = false
    private var continuation: CheckedContinuation<URL, Error>?
    private(set) var ingestStarted = false
    private(set) var cancelCallCount = 0
    private(set) var ingestedURLs: [URL] = []
    let mixtureURL: URL

    init(mixtureURL: URL, shouldThrowCleanupFailedOnCancel: Bool = false) {
        self.mixtureURL = mixtureURL
        self.shouldThrowCleanupFailedOnCancel = shouldThrowCleanupFailedOnCancel
    }

    func ingest(youTubeURL: URL) async throws -> URL {
        ingestStarted = true
        ingestedURLs.append(youTubeURL)
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
        }
    }

    func cancel() async throws {
        cancelCallCount += 1
        if shouldThrowCleanupFailedOnCancel {
            if let c = continuation {
                c.resume(throwing: YouTubeIngestError.cleanupFailed("mock still running after SIGTERM/SIGKILL"))
                continuation = nil
            }
            throw YouTubeIngestError.cleanupFailed("mock still running after SIGTERM/SIGKILL")
        }
        if let c = continuation {
            c.resume(throwing: YouTubeIngestError.cancelled)
            continuation = nil
        }
    }

    func completeWithSuccess() {
        if let c = continuation {
            c.resume(returning: mixtureURL)
            continuation = nil
        }
    }

    func setShouldThrowCleanupFailedOnCancel(_ value: Bool) {
        shouldThrowCleanupFailedOnCancel = value
    }

    func failIngestWithCleanupFailed() {
        if let c = continuation {
            c.resume(throwing: YouTubeIngestError.cleanupFailed("mock still running after SIGTERM/SIGKILL"))
            continuation = nil
        }
    }
}

private actor MockYouTubeCleanupFailedDelayed: YouTubeIngesting {
    let delay: Duration
    init(delay: Duration = .milliseconds(250)) { self.delay = delay }
    func ingest(youTubeURL: URL) async throws -> URL {
        // Use non-cancellable sleep so cancellation of the task does not turn into CancellationError
        // before we can throw the stale cleanupFailed that must be preserved.
        try? await Task.sleep(for: delay)
        throw YouTubeIngestError.cleanupFailed("mock still running after SIGTERM/SIGKILL")
    }
    func cancel() async throws {}
}

private actor MockYouTubeDelayedSuccess: YouTubeIngesting {
    let mixtureURL: URL
    let delay: Duration
    private(set) var ingestCallCount = 0
    init(mixtureURL: URL, delay: Duration = .milliseconds(400)) {
        self.mixtureURL = mixtureURL
        self.delay = delay
    }
    func ingest(youTubeURL: URL) async throws -> URL {
        ingestCallCount += 1
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        return mixtureURL
    }
    func cancel() async throws {
        // no-op, let Task cancellation propagate via checkCancellation
    }
}

private actor MockYouTubeControllable: YouTubeIngesting {
    let mixtureURL: URL
    var shouldFailIngest = false
    var shouldThrowCleanupFailedOnCancel = false
    private(set) var ingestCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var ingestedURLs: [URL] = []
    init(mixtureURL: URL) { self.mixtureURL = mixtureURL }
    func setShouldFailIngest(_ v: Bool) { shouldFailIngest = v }
    func setShouldThrowCleanupFailedOnCancel(_ v: Bool) { shouldThrowCleanupFailedOnCancel = v }
    func ingest(youTubeURL: URL) async throws -> URL {
        ingestCallCount += 1
        ingestedURLs.append(youTubeURL)
        if shouldFailIngest {
            try? await Task.sleep(for: .milliseconds(50))
            throw YouTubeIngestError.cleanupFailed("mock still running after SIGTERM/SIGKILL")
        }
        return mixtureURL
    }
    func cancel() async throws {
        cancelCallCount += 1
        if shouldThrowCleanupFailedOnCancel {
            throw YouTubeIngestError.cleanupFailed("mock still running after SIGTERM/SIGKILL")
        }
    }
}

private actor MockYouTubePhased: YouTubeIngesting {
    let result: YouTubeIngestResult
    private(set) var ingestCallCount = 0
    init(result: YouTubeIngestResult) { self.result = result }
    func ingest(youTubeURL: URL) async throws -> URL {
        try await ingestWithMetadata(youTubeURL: youTubeURL, onProgress: { _ in }).audioURL
    }
    func ingestWithMetadata(youTubeURL: URL, onProgress: @Sendable (YouTubeIngestPhase) -> Void) async throws -> YouTubeIngestResult {
        ingestCallCount += 1
        onProgress(.downloading)
        try await Task.sleep(for: .milliseconds(30))
        onProgress(.preparing)
        try await Task.sleep(for: .milliseconds(30))
        try Task.checkCancellation()
        return result
    }
    func cancel() async throws {}
}

private actor MockYouTubePhasedFailure: YouTubeIngesting {
    let error: YouTubeIngestError
    init(error: YouTubeIngestError) { self.error = error }
    func ingest(youTubeURL: URL) async throws -> URL {
        throw error
    }
    func ingestWithMetadata(youTubeURL: URL, onProgress: @Sendable (YouTubeIngestPhase) -> Void) async throws -> YouTubeIngestResult {
        onProgress(.downloading)
        try await Task.sleep(for: .milliseconds(20))
        throw error
    }
    func cancel() async throws {}
}

private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func setTrue() { lock.lock(); _value = true; lock.unlock() }
}

// MARK: - Tests

@MainActor
final class InferenceControllerYouTubeTests: XCTestCase {

    private func makeFakeWorker(script: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let venvBin = tmp.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: venvBin, withIntermediateDirectories: true)
        let fakeScript = tmp.appendingPathComponent("fake_worker.py")
        try script.write(to: fakeScript, atomically: true, encoding: .utf8)
        let pythonWrapper = venvBin.appendingPathComponent("python3")
        let wrapper = "#!/bin/sh\nexec /usr/bin/python3 \"\(fakeScript.path)\" \"$@\"\n"
        try wrapper.write(to: pythonWrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pythonWrapper.path)
        return tmp
    }

    private func makeWAV(at url: URL, frames: UInt32 = 1024) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<2 {
            let ptr = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { ptr[i] = Float(i % 100) * 0.001 }
        }
        try file.write(from: buffer)
    }

    func testLoadYouTubeSourceIsIngestOnlyAndSavePreparationReusesCanonicalSource() async throws {
        // Metadata-only load: fetchPreview, no media, no FFmpeg, no separation
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artworkURL = directory.appendingPathComponent("thumb.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: artworkURL)
        let metadata = try XCTUnwrap(
            YouTubeTrackMetadata(artist: "Artist", title: "Song Title", channel: "Channel")
        )
        let preview = YouTubePreviewResult(metadata: metadata, artworkURL: artworkURL, duration: 123.4)
        let ingest = MockYouTubePreviewFlow(preview: preview)
        // Hook to ensure no worker launched
        let client = InferenceWorkerClient()
        let sawWorker = AtomicBool()
        await client.setTestHook { _ in sawWorker.setTrue() }
        let controller = InferenceController(
            client: client,
            outputBase: directory,
            youTubeIngest: ingest
        )
        let url = URL(string: "https://www.youtube.com/watch?v=source-first")!

        controller.loadYouTubeSource(youTubeURL: url)
        let loadTask = try XCTUnwrap(controller.debugCurrentTask())
        await loadTask.value

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.statusMessage, "Loaded — Ready to save or separate")
        XCTAssertNil(controller.result, "Loading a source must not start separation")
        XCTAssertNil(controller.loadedYouTubeSource, "Preview load must not create canonical source")
        XCTAssertEqual(controller.loadedYouTubePreview, preview)
        XCTAssertEqual(controller.loadedYouTubeURL, url)
        XCTAssertTrue(controller.isYouTubeSourceLoaded, "isYouTubeSourceLoaded should be true when preview exists")
        XCTAssertTrue(controller.isYouTubePreviewLoaded)
        XCTAssertEqual(controller.loadedYouTubeDuration ?? 0, 123.4, accuracy: 0.01)
        XCTAssertEqual(controller.exportBaseName, metadata.exportBaseName)
        XCTAssertEqual(controller.youTubeExportMetadata, metadata)
        XCTAssertEqual(controller.youTubeExportArtworkURL, artworkURL)
        XCTAssertEqual(controller.editableArtist, "Artist")
        XCTAssertEqual(controller.editableTitle, "Song Title")
        XCTAssertEqual(controller.editableArtwork, .keep)
        XCTAssertNil(controller.preparedYouTubeMP3Export)
        let fetchCount = await ingest.fetchPreviewCallCount
        XCTAssertEqual(fetchCount, 1, "Load must call fetchPreview once")
        let ingestCount = await ingest.ingestCallCount
        XCTAssertEqual(ingestCount, 0, "Load must NOT call ingestWithMetadata")
        let downloadCount = await ingest.downloadCallCount
        XCTAssertEqual(downloadCount, 0, "Load must NOT call downloadAudioOnly")
        XCTAssertFalse(sawWorker.value, "Preview load must not launch inference worker (no FFmpeg)")
        XCTAssertNil(controller.prepareYouTubeMP3ExportFromLoadedSource(), "No canonical source yet, prepare should return nil")
        XCTAssertEqual(controller.state, .idle, "Save preparation must not hide or reset the source state")
        XCTAssertNil(controller.result)
    }

    func testPrepareYouTubeMP3ExportFromLoadedPreviewAcquiresAudioOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previewArtwork = directory.appendingPathComponent("preview.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: previewArtwork)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(artist: "Preview Artist", title: "Preview Title", channel: "Channel"))
        let preview = YouTubePreviewResult(metadata: metadata, artworkURL: previewArtwork, duration: 99.9)

        let audioArtwork = directory.appendingPathComponent("audio.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: audioArtwork)
        let audioFile = directory.appendingPathComponent("source.m4a")
        try Data(repeating: 0, count: 2048).write(to: audioFile)
        let audioResult = YouTubeIngestResult(audioURL: audioFile, metadata: metadata, artworkURL: audioArtwork)

        let ingest = MockYouTubePreviewFlow(preview: preview, ingestResult: audioResult, downloadResult: audioResult)
        let workerDir = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: workerDir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(3), workerDirectory: workerDir)
        let sawWorker = AtomicBool()
        await client.setTestHook { _ in sawWorker.setTrue() }

        let controller = InferenceController(client: client, outputBase: directory, youTubeIngest: ingest)
        let url = URL(string: "https://www.youtube.com/watch?v=preview-save")!

        controller.loadYouTubeSource(youTubeURL: url)
        let loadTask = try XCTUnwrap(controller.debugCurrentTask())
        await loadTask.value
        XCTAssertTrue(controller.isYouTubePreviewLoaded)

        controller.prepareYouTubeMP3ExportFromLoadedPreview()
        let saveTask = try XCTUnwrap(controller.debugCurrentTask())
        await saveTask.value

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.statusMessage, "Ready to save MP3")
        XCTAssertEqual(controller.preparedYouTubeMP3Export, audioResult)
        XCTAssertNil(controller.loadedYouTubeSource, "Save MP3 must NOT set loadedYouTubeSource to raw download (WebM would trigger playback)")
        XCTAssertTrue(controller.isYouTubePreviewLoaded, "Preview must remain after Save MP3")
        XCTAssertTrue(controller.isYouTubeSourceLoaded, "isYouTubeSourceLoaded true via preview, not raw source")
        XCTAssertEqual(controller.youTubeExportMetadata, metadata)
        XCTAssertEqual(controller.editableArtist, "Preview Artist")
        XCTAssertEqual(controller.editableTitle, "Preview Title")
        let fetchCount = await ingest.fetchPreviewCallCount
        XCTAssertEqual(fetchCount, 1)
        let downloadCount = await ingest.downloadCallCount
        XCTAssertEqual(downloadCount, 1, "Save must trigger downloadAudioOnly once")
        let ingestCount = await ingest.ingestCallCount
        XCTAssertEqual(ingestCount, 0, "Save must NOT call ingestWithMetadata")
        XCTAssertFalse(sawWorker.value, "Save MP3 must not start inference")
        XCTAssertNil(controller.result)

        // Second Save should reuse preparedYouTubeMP3Export without re-download
        controller.prepareYouTubeMP3ExportFromLoadedPreview()
        // No new task should be created because preparedYouTubeMP3Export already exists; state remains idle
        // Allow a short hop
        try await Task.sleep(nanoseconds: 100_000_000)
        let downloadCountAfterSecond = await ingest.downloadCallCount
        XCTAssertEqual(downloadCountAfterSecond, 1, "Second Save should reuse prepared export without re-download")
        // Still no loadedYouTubeSource after reuse
        XCTAssertNil(controller.loadedYouTubeSource, "Reuse must still not set loadedYouTubeSource")
        XCTAssertEqual(controller.preparedYouTubeMP3Export, audioResult)
        await controller.shutdownWorker(policy: .testShort())
    }

    func testPrepareYouTubeMP3ExportFromLoadedPreviewWithWebMDoesNotTriggerPlayback() async throws {
        // Raw bestaudio may be .webm (Opus) — Save MP3 must keep it as intermediate only, not trigger PlaybackController.load
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previewArtwork = directory.appendingPathComponent("preview.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: previewArtwork)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(artist: "WebM Artist", title: "WebM Title", channel: "Channel"))
        let preview = YouTubePreviewResult(metadata: metadata, artworkURL: previewArtwork, duration: 42.0)

        let webmFile = directory.appendingPathComponent("source.webm")
        try Data(repeating: 0, count: 2048).write(to: webmFile)
        let webmResult = YouTubeIngestResult(audioURL: webmFile, metadata: metadata, artworkURL: previewArtwork)

        let ingest = MockYouTubePreviewFlow(preview: preview, downloadResult: webmResult)
        let workerDir = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: workerDir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(3), workerDirectory: workerDir)
        let sawWorker = AtomicBool()
        await client.setTestHook { _ in sawWorker.setTrue() }

        let controller = InferenceController(client: client, outputBase: directory, youTubeIngest: ingest)
        let url = URL(string: "https://www.youtube.com/watch?v=webm-save")!
        controller.loadYouTubeSource(youTubeURL: url)
        let loadTask = try XCTUnwrap(controller.debugCurrentTask())
        await loadTask.value

        controller.prepareYouTubeMP3ExportFromLoadedPreview()
        let saveTask = try XCTUnwrap(controller.debugCurrentTask())
        await saveTask.value

        XCTAssertEqual(controller.preparedYouTubeMP3Export?.audioURL.pathExtension, "webm", "Raw intermediate may be webm")
        XCTAssertEqual(controller.preparedYouTubeMP3Export, webmResult)
        XCTAssertNil(controller.loadedYouTubeSource, "WebM raw must NOT be assigned to loadedYouTubeSource (would trigger PlaybackController.load and fail)")
        XCTAssertTrue(controller.isYouTubePreviewLoaded, "Preview must remain; UI shows Preview only, not playing")
        XCTAssertEqual(controller.statusMessage, "Ready to save MP3")
        XCTAssertFalse(sawWorker.value, "WebM Save must not start inference; FFmpeg transcode happens at export time")
        // Simulate exportability: StemExporter can handle webm via FFmpeg, ensure file still exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: webmFile.path))
        let downloadCount = await ingest.downloadCallCount
        XCTAssertEqual(downloadCount, 1)
        await controller.shutdownWorker(policy: .testShort())
    }

    func testStartSeparationFromLoadedPreviewAcquiresAudioOnlyThenSeparates() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL, frames: 1024)
        let artworkURL = mixtureDir.appendingPathComponent("thumb.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: artworkURL)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(artist: "Artist", title: "Song Title", channel: "Channel"))
        let preview = YouTubePreviewResult(metadata: metadata, artworkURL: artworkURL, duration: 55.5)
        let ingestResult = YouTubeIngestResult(audioURL: mixtureURL, metadata: metadata, artworkURL: artworkURL)
        let ingest = MockYouTubePreviewFlow(preview: preview, ingestResult: ingestResult, downloadResult: ingestResult)

        let capturedInput = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: capturedInput) }
        let workerDir = try makeFakeWorker(script: floatSuccessScript(capturedInputPathFile: capturedInput))
        defer { try? FileManager.default.removeItem(at: workerDir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: workerDir)
        let outputBase = mixtureDir.appendingPathComponent("output", isDirectory: true)
        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: ingest)

        let url = URL(string: "https://www.youtube.com/watch?v=preview-separate")!
        controller.loadYouTubeSource(youTubeURL: url)
        let loadTask = try XCTUnwrap(controller.debugCurrentTask())
        await loadTask.value
        XCTAssertTrue(controller.isYouTubePreviewLoaded)

        controller.startSeparationFromLoadedPreview()
        let sepTask = try XCTUnwrap(controller.debugCurrentTask())
        await sepTask.value

        XCTAssertEqual(controller.state, .completed)
        XCTAssertNotNil(controller.result)
        XCTAssertEqual(controller.result?.stems.count, 6)
        let fetchCount = await ingest.fetchPreviewCallCount
        XCTAssertEqual(fetchCount, 1)
        let ingestCount = await ingest.ingestCallCount
        XCTAssertEqual(ingestCount, 1, "Separate must call ingestWithMetadata once (audio-only+canonical)")
        let downloadCount = await ingest.downloadCallCount
        XCTAssertEqual(downloadCount, 0, "Separate must NOT call downloadAudioOnly")
        let captured = try? String(contentsOf: capturedInput, encoding: .utf8)
        XCTAssertEqual(captured, mixtureURL.path, "Worker input_path should be canonical mixture.wav")

        // Generation guard: start a slow ingest then supersede with direct WAV, ensure stale not applied
        let slowPreview = YouTubePreviewResult(metadata: metadata, artworkURL: artworkURL, duration: 10)
        let slowIngest = MockYouTubePreviewFlow(preview: slowPreview, ingestResult: ingestResult)
        // Make ingest hang via delayed mock? Use separate controller for guard verification
        await controller.shutdownWorker(policy: .testShort())
    }

    func testSeparateFromLoadedYouTubeSourceDoesNotReingest() async throws {
        let mixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDirectory) }
        let mixtureURL = mixtureDirectory.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL)
        let metadata = try XCTUnwrap(
            YouTubeTrackMetadata(artist: "Artist", title: "Song Title", channel: "Channel")
        )
        let ingestResult = YouTubeIngestResult(audioURL: mixtureURL, metadata: metadata)
        // Preview load then deferred separate will download via ingestWithMetadata; second separate reuses.
        let preview = YouTubePreviewResult(metadata: metadata, artworkURL: nil, duration: 10)
        let ingest = MockYouTubePreviewFlow(preview: preview, ingestResult: ingestResult, downloadResult: ingestResult)
        let workerDirectory = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: workerDirectory) }
        let client = InferenceWorkerClient(
            readinessTimeout: .seconds(3),
            startedTimeout: .seconds(2),
            separationTimeout: .seconds(5),
            workerDirectory: workerDirectory
        )
        let outputBase = mixtureDirectory.appendingPathComponent("output", isDirectory: true)
        let controller = InferenceController(
            client: client,
            outputBase: outputBase,
            youTubeIngest: ingest
        )

        controller.loadYouTubeSource(youTubeURL: URL(string: "https://www.youtube.com/watch?v=source-first")!)
        let loadTask = try XCTUnwrap(controller.debugCurrentTask())
        await loadTask.value
        // Deferred separate triggers ingestWithMetadata once
        controller.startSeparationFromLoadedPreview()
        let separationTask = try XCTUnwrap(controller.debugCurrentTask())
        await separationTask.value

        XCTAssertEqual(controller.state, .completed)
        let ingestCountAfterFirstSeparate = await ingest.ingestCallCount
        XCTAssertEqual(ingestCountAfterFirstSeparate, 1, "First separate must ingest once")
        // Second separate reuses canonical source without re-ingest
        controller.startSeparationFromLoadedYouTubeSource()
        let secondTask = try XCTUnwrap(controller.debugCurrentTask())
        await secondTask.value
        XCTAssertEqual(controller.state, .completed)
        let ingestCountAfterSecond = await ingest.ingestCallCount
        XCTAssertEqual(ingestCountAfterSecond, 1, "Separate must reuse the loaded canonical source")
        await controller.shutdownWorker()
    }

    func testClearingSourceCancelsInFlightYouTubeLoad() async throws {
        let mixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let ingest = MockYouTubeHanging(mixtureURL: mixtureURL)
        let controller = InferenceController(client: InferenceWorkerClient(), youTubeIngest: ingest)

        controller.loadYouTubeSource(youTubeURL: URL(string: "https://www.youtube.com/watch?v=in-flight")!)
        for _ in 0..<50 {
            if await ingest.ingestStarted { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let ingestStarted = await ingest.ingestStarted
        XCTAssertTrue(ingestStarted)

        controller.clearLoadedYouTubeSource()
        if let tail = controller.debugCleanupChainTail() {
            await tail.value
        }

        XCTAssertNil(controller.loadedYouTubeSource)
        XCTAssertNil(controller.loadedYouTubeURL)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.result)
        let cancelCount = await ingest.cancelCallCount
        XCTAssertEqual(cancelCount, 1)
    }

    private func floatSuccessScript(capturedInputPathFile: URL? = nil) -> String {
        var captureLine = ""
        if let cap = capturedInputPathFile {
            captureLine = "open(\"\(cap.path)\", \"w\").write(obj.get(\"input_path\",\"\"))\n        "
        }
        return """
        import sys, json, os, struct, hashlib
        sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
        def make_wav(path, frames=1024, sr=44100, ch=2):
            data = b''.join(struct.pack('<f', 0.0) for _ in range(frames*ch))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as f:
                f.write(b'RIFF')
                f.write(struct.pack('<I', 36 + len(data)))
                f.write(b'WAVE')
                f.write(b'fmt ')
                f.write(struct.pack('<I', 16))
                f.write(struct.pack('<H', 3))
                f.write(struct.pack('<H', ch))
                f.write(struct.pack('<I', sr))
                f.write(struct.pack('<I', sr * ch * 4))
                f.write(struct.pack('<H', ch * 4))
                f.write(struct.pack('<H', 32))
                f.write(b'data')
                f.write(struct.pack('<I', len(data)))
                f.write(data)
        for line in sys.stdin:
            try:
                obj=json.loads(line)
            except:
                continue
            if obj.get("type")=="shutdown":
                sys.exit(0)
            if obj.get("type")=="separate":
                jid=obj["job_id"]
                outdir=obj["output_dir"]
                inp=obj["input_path"]
                \(captureLine)sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
                job_dir=os.path.join(outdir, jid)
                os.makedirs(job_dir, exist_ok=True)
                inp_sha=hashlib.sha256(open(inp,'rb').read()).hexdigest()
                stems=[]
                for name in ["bass","drums","other","vocals","guitar","piano"]:
                    p=os.path.join(job_dir, f"{name}.wav")
                    make_wav(p, frames=1024)
                    stems.append({"name":name,"path":p,"sha256":hashlib.sha256(open(p,'rb').read()).hexdigest(),"file_size":os.path.getsize(p),"frame_count":1024,"channels":2,"sample_rate":44100})
                    sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":p})+"\\n"); sys.stdout.flush()
                manifest={"job_id":jid,"model":"roformer-model-bs-roformer-sw-by-jarredou","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e","backend":"mlx","device":"mps","input_path":inp,"output_dir":outdir,"input_sha256":inp_sha,"input_metadata":{"sample_rate":44100,"channels":2,"frames":1024,"duration":0.02,"sha256":inp_sha},"stems":stems}
                man_path=os.path.join(job_dir,"manifest.json")
                open(man_path,'w').write(json.dumps(manifest))
                sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":man_path})+"\\n"); sys.stdout.flush()
        """
    }

    private func delayedSuccessScript(delaySeconds: Double = 0.8) -> String {
        """
        import sys, json, os, struct, hashlib, time
        sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
        def make_wav(path, frames=1024, sr=44100, ch=2):
            data = b''.join(struct.pack('<f', 0.0) for _ in range(frames*ch))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as f:
                f.write(b'RIFF')
                f.write(struct.pack('<I', 36 + len(data)))
                f.write(b'WAVE')
                f.write(b'fmt ')
                f.write(struct.pack('<I', 16))
                f.write(struct.pack('<H', 3))
                f.write(struct.pack('<H', ch))
                f.write(struct.pack('<I', sr))
                f.write(struct.pack('<I', sr * ch * 4))
                f.write(struct.pack('<H', ch * 4))
                f.write(struct.pack('<H', 32))
                f.write(b'data')
                f.write(struct.pack('<I', len(data)))
                f.write(data)
        for line in sys.stdin:
            try:
                obj=json.loads(line)
            except:
                continue
            if obj.get("type")=="shutdown":
                sys.exit(0)
            if obj.get("type")=="separate":
                jid=obj["job_id"]
                outdir=obj["output_dir"]
                inp=obj["input_path"]
                sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
                time.sleep(\(delaySeconds))
                job_dir=os.path.join(outdir, jid)
                os.makedirs(job_dir, exist_ok=True)
                inp_sha=hashlib.sha256(open(inp,'rb').read()).hexdigest()
                stems=[]
                for name in ["bass","drums","other","vocals","guitar","piano"]:
                    p=os.path.join(job_dir, f"{name}.wav")
                    make_wav(p, frames=1024)
                    stems.append({"name":name,"path":p,"sha256":hashlib.sha256(open(p,'rb').read()).hexdigest(),"file_size":os.path.getsize(p),"frame_count":1024,"channels":2,"sample_rate":44100})
                    sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":p})+"\\n"); sys.stdout.flush()
                manifest={"job_id":jid,"model":"roformer-model-bs-roformer-sw-by-jarredou","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e","backend":"mlx","device":"mps","input_path":inp,"output_dir":outdir,"input_sha256":inp_sha,"input_metadata":{"sample_rate":44100,"channels":2,"frames":1024,"duration":0.02,"sha256":inp_sha},"stems":stems}
                man_path=os.path.join(job_dir,"manifest.json")
                open(man_path,'w').write(json.dumps(manifest))
                sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":man_path})+"\\n"); sys.stdout.flush()
        """
    }

    private func hangingWorkerScript() -> String {
        """
        import sys, json, time
        sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
        for line in sys.stdin:
            obj=json.loads(line)
            if obj.get("type")=="separate":
                jid=obj["job_id"]
                sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
                time.sleep(10)
            elif obj.get("type")=="shutdown":
                sys.exit(0)
        """
    }

    private func slowTerminationWorkerScript() -> String {
        """
        import sys, json, os, struct, hashlib, signal, time
        def _h(sig, frame):
            time.sleep(1.0)
            sys.exit(0)
        signal.signal(signal.SIGTERM, _h)
        signal.signal(signal.SIGINT, _h)
        sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
        def make_wav(path, frames=1024, sr=44100, ch=2):
            data = b''.join(struct.pack('<f', 0.0) for _ in range(frames*ch))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as f:
                f.write(b'RIFF')
                f.write(struct.pack('<I', 36 + len(data)))
                f.write(b'WAVE')
                f.write(b'fmt ')
                f.write(struct.pack('<I', 16))
                f.write(struct.pack('<H', 3))
                f.write(struct.pack('<H', ch))
                f.write(struct.pack('<I', sr))
                f.write(struct.pack('<I', sr * ch * 4))
                f.write(struct.pack('<H', ch * 4))
                f.write(struct.pack('<H', 32))
                f.write(b'data')
                f.write(struct.pack('<I', len(data)))
                f.write(data)
        for line in sys.stdin:
            try:
                obj=json.loads(line)
            except:
                continue
            if obj.get("type")=="shutdown":
                sys.exit(0)
            if obj.get("type")=="separate":
                jid=obj["job_id"]
                outdir=obj["output_dir"]
                inp=obj["input_path"]
                sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
                job_dir=os.path.join(outdir, jid)
                os.makedirs(job_dir, exist_ok=True)
                inp_sha=hashlib.sha256(open(inp,'rb').read()).hexdigest()
                stems=[]
                for name in ["bass","drums","other","vocals","guitar","piano"]:
                    p=os.path.join(job_dir, f"{name}.wav")
                    make_wav(p, frames=1024)
                    stems.append({"name":name,"path":p,"sha256":hashlib.sha256(open(p,'rb').read()).hexdigest(),"file_size":os.path.getsize(p),"frame_count":1024,"channels":2,"sample_rate":44100})
                    sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":p})+"\\n"); sys.stdout.flush()
                manifest={"job_id":jid,"model":"roformer-model-bs-roformer-sw-by-jarredou","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e","backend":"mlx","device":"mps","input_path":inp,"output_dir":outdir,"input_sha256":inp_sha,"input_metadata":{"sample_rate":44100,"channels":2,"frames":1024,"duration":0.02,"sha256":inp_sha},"stems":stems}
                man_path=os.path.join(job_dir,"manifest.json")
                open(man_path,'w').write(json.dumps(manifest))
                sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":man_path})+"\\n"); sys.stdout.flush()
        """
    }

    // 1) YouTube success → mixture.wav passed to runSeparation → completed
    func testYouTubeSuccessPassesMixtureToInference() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL, frames: 1024)
        let artworkURL = mixtureDir.appendingPathComponent("thumbnail.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: artworkURL)
        let metadata = try XCTUnwrap(
            YouTubeTrackMetadata(artist: "Massive Attack", title: "Teardrop")
        )

        let captured = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: captured) }

        let dir = try makeFakeWorker(script: floatSuccessScript(capturedInputPathFile: captured))
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockIngest = MockYouTubeMetadataSuccess(
            result: YouTubeIngestResult(
                audioURL: mixtureURL,
                metadata: metadata,
                artworkURL: artworkURL
            )
        )
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: mockIngest)

        let youTubeURL = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        controller.startSeparation(youTubeURL: youTubeURL)

        // wait for completion
        let task = try XCTUnwrap(controller.debugCurrentTask())
        await task.value

        XCTAssertEqual(controller.state, .completed, "YouTube success should complete, got \(controller.state)")
        XCTAssertNotNil(controller.result)
        XCTAssertEqual(controller.result?.stems.count, 6)
        XCTAssertEqual(controller.youTubeExportMetadata, metadata)
        XCTAssertEqual(controller.youTubeExportArtworkURL, artworkURL)
        let ingestCount = await mockIngest.ingestCallCount
        XCTAssertEqual(ingestCount, 1)
        let ingested = await mockIngest.ingestedURLs
        XCTAssertEqual(ingested.first, youTubeURL)
        // Verify mixture path was passed to worker (captured file)
        let capturedPath = try? String(contentsOf: captured, encoding: .utf8)
        XCTAssertEqual(capturedPath, mixtureURL.path, "Worker input_path should be mixture.wav from ingest")

        await controller.shutdownWorker()
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "Lifecycle leak after YouTube success")
    }

    // 2) Ingest failure → .failed, no inference started
    func testDirectYouTubeMP3PreparationPreservesMetadataAndDoesNotStartInference() async throws {
        let mixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDirectory) }
        let mixtureURL = mixtureDirectory.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL)

        let workerDirectory = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: workerDirectory) }
        let client = InferenceWorkerClient(
            readinessTimeout: .seconds(3),
            startedTimeout: .seconds(2),
            separationTimeout: .seconds(3),
            workerDirectory: workerDirectory
        )
        let sawWorkerEvent = AtomicBool()
        await client.setTestHook { _ in sawWorkerEvent.setTrue() }

        let metadata = try XCTUnwrap(
            YouTubeTrackMetadata(
                artist: "Massive Attack",
                title: "Teardrop",
                album: "Mezzanine"
            )
        )
        let artworkURL = mixtureDirectory.appendingPathComponent("thumbnail.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: artworkURL)
        let ingest = MockYouTubeMetadataSuccess(
            result: YouTubeIngestResult(
                audioURL: mixtureURL,
                metadata: metadata,
                artworkURL: artworkURL
            )
        )
        let controller = InferenceController(
            client: client,
            outputBase: mixtureDirectory,
            youTubeIngest: ingest
        )

        controller.prepareYouTubeMP3Export(
            youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        )
        let task = try XCTUnwrap(controller.debugCurrentTask())
        await task.value

        XCTAssertEqual(
            controller.preparedYouTubeMP3Export,
            YouTubeIngestResult(
                audioURL: mixtureURL,
                metadata: metadata,
                artworkURL: artworkURL
            )
        )
        let ingestCallCount = await ingest.ingestCallCount
        XCTAssertEqual(ingestCallCount, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.result, "Direct MP3 export must not create stems")
        XCTAssertFalse(sawWorkerEvent.value, "Direct MP3 export must not launch the inference worker")
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork)
    }

    func testIngestFailureDoesNotStartInference() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let dir = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockFailure = MockYouTubeFailure(error: .invalidYouTubeURL("https://www.youtube.com/watch?v=bad"))
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(3), workerDirectory: dir)
        // Track if inference started via hook
        let didStart = AtomicBool()
        await client.setTestHook { event in
            if case .started = event { didStart.setTrue() }
        }
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: mockFailure)

        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=bad")!)
        let task = try XCTUnwrap(controller.debugCurrentTask())
        await task.value

        if case .failed(let msg) = controller.state {
            XCTAssertTrue(msg.contains("Invalid YouTube URL") || msg.contains("invalidYouTubeURL") || msg.lowercased().contains("invalid"), "Should surface invalidYouTubeURL, got \(msg)")
        } else {
            XCTFail("Expected failed, got \(controller.state)")
        }
        XCTAssertFalse(didStart.value, "Inference should not have started after ingest failure")
        XCTAssertNil(controller.result)
        XCTAssertFalse(controller.isSeparating)

        // Tool failure variant
        let mockToolFailure = MockYouTubeFailure(error: .toolFailure(tool: "yt-dlp", exitCode: 1, stderrTail: "yt-dlp failed mock"))
        let client2 = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(3), workerDirectory: dir)
        let didStart2 = AtomicBool()
        await client2.setTestHook { event in if case .started = event { didStart2.setTrue() } }
        let controller2 = InferenceController(client: client2, outputBase: outputBase, youTubeIngest: mockToolFailure)
        controller2.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        let task2 = try XCTUnwrap(controller2.debugCurrentTask())
        await task2.value
        if case .failed(let msg) = controller2.state {
            XCTAssertTrue(msg.contains("yt-dlp") || msg.contains("failed"), "Should surface toolFailure, got \(msg)")
        } else { XCTFail("Expected failed for toolFailure") }
        XCTAssertFalse(didStart2.value)
    }

    // 3) Cancellation during ingest stage
    func testCancellationDuringIngest() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL, frames: 1024)

        let dir = try makeFakeWorker(script: hangingWorkerScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let hanging = MockYouTubeHanging(mixtureURL: mixtureURL)
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let didStart = AtomicBool()
        await client.setTestHook { event in if case .started = event { didStart.setTrue() } }
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: hanging)

        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        // Wait until ingest started
        var started = false
        for _ in 0..<50 {
            let s = await hanging.ingestStarted
            if s { started = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(started, "Ingest should have started")
        XCTAssertTrue(controller.isSeparating)

        controller.cancel()
        // Wait for tail
        if let tail = controller.debugCleanupChainTail() {
            await tail.value
        }
        // Wait a bit for state to settle via MainActor tail update
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(didStart.value, "Inference should not start when cancelled during ingest")
        if case .failed(let msg) = controller.state {
            XCTAssertEqual(msg, "Cancelled", "Cancellation during ingest should be Cancelled, got \(msg)")
        } else {
            XCTFail("Expected failed Cancelled, got \(controller.state)")
        }
        XCTAssertNil(controller.result)
        let cancelCount = await hanging.cancelCallCount
        XCTAssertEqual(cancelCount, 1, "youTube cancel should be called")
        XCTAssertFalse(controller.debugHasPendingCancellationCleanup() && controller.debugYouTubeCleanupFailed(), "Should not have pending cleanup after cancel")
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork)
    }

    // 3b) Cancellation during ingest where cancel throws cleanupFailed -> must retain unsafe state
    func testCancellationDuringIngestWithCleanupFailedRetainsUnsafe() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL, frames: 1024)

        let dir = try makeFakeWorker(script: hangingWorkerScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let hanging = MockYouTubeHanging(mixtureURL: mixtureURL, shouldThrowCleanupFailedOnCancel: true)
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: hanging)

        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        // wait ingest started
        for _ in 0..<50 {
            if await hanging.ingestStarted { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        controller.cancel()
        if let tail = controller.debugCleanupChainTail() {
            await tail.value
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        // State should be cleanup failed, not idle/success
        if case .failed(let msg) = controller.state {
            XCTAssertTrue(msg.contains("Cleanup failed") || msg.contains("cleanupFailed"), "Should surface cleanupFailed, got \(msg)")
        } else {
            XCTFail("Expected failed cleanupFailed, got \(controller.state)")
        }
        XCTAssertTrue(controller.debugYouTubeCleanupFailed(), "Flag should be set after cleanupFailed")

        // terminateForApplicationExit should return unsafe due to prior cleanupFailed flag
        let result = await controller.terminateForApplicationExit(policy: .testShort())
        XCTAssertEqual(result, .unsafeToTerminate(reason: .cleanupIncomplete), "Should be unsafe after cleanupFailed")
    }

    // 4) Cancellation during inference stage after ingest succeeded
    func testCancellationDuringInferenceAfterIngest() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL, frames: 1024)

        let dir = try makeFakeWorker(script: hangingWorkerScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockSuccess = MockYouTubeSuccess(mixtureURL: mixtureURL)
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: mockSuccess)

        let started = expectation(description: "inference started")
        await client.setTestHook { event in if case .started = event { started.fulfill() } }

        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        await fulfillment(of: [started], timeout: 3)

        XCTAssertTrue(controller.isSeparating)
        controller.cancel()
        if let tail = controller.debugCleanupChainTail() {
            await tail.value
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        if case .failed(let msg) = controller.state {
            XCTAssertEqual(msg, "Cancelled")
        } else {
            XCTFail("Expected Cancelled after inference cancel, got \(controller.state)")
        }
        XCTAssertNil(controller.result)
        let ingestCount = await mockSuccess.ingestCallCount
        XCTAssertEqual(ingestCount, 1)
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork)
    }

    // 5) Generation/stale protection: YouTube op then direct WAV op
    func testGenerationStaleProtectionYouTubeThenDirectWAV() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL, frames: 1024)

        let dir = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let delayed = MockYouTubeDelayedSuccess(mixtureURL: mixtureURL, delay: .milliseconds(500))
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: delayed)

        // Direct WAV for second operation – create a separate valid input
        let directWavDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directWavDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directWavDir) }
        let directWAV = directWavDir.appendingPathComponent("direct.wav")
        try makeWAV(at: directWAV, frames: 1024)

        // Start YouTube path (will delay 500ms in ingest)
        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        // Quickly start direct WAV path before YouTube ingest completes
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.startSeparation(inputURL: directWAV)

        // Wait for second operation to complete
        let secondTask = try XCTUnwrap(controller.debugCurrentTask())
        await secondTask.value

        XCTAssertEqual(controller.state, .completed, "Second (direct WAV) should complete, got \(controller.state)")
        XCTAssertNotNil(controller.result)
        XCTAssertEqual(controller.result?.stems.count, 6)

        // Wait additional time to ensure first stale operation does not overwrite
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(controller.state, .completed, "Stale YouTube result must not overwrite newer direct WAV result")
        XCTAssertNotNil(controller.result)

        // Verify YouTube ingest was attempted but its result was discarded (generation guard)
        let ingestCount = await delayed.ingestCallCount
        XCTAssertEqual(ingestCount, 1)

        await controller.shutdownWorker()
    }

    // Default executable resolution must use Apple Silicon Homebrew paths (/opt/homebrew/bin)
    func testDefaultYouTubeIngestUsesHomebrewPaths() async throws {
        let ingest = InferenceController.makeDefaultYouTubeIngest()
        guard let client = ingest as? YouTubeIngestClient else {
            XCTFail("Default ingest should be YouTubeIngestClient, got \(type(of: ingest))")
            return
        }
        let ytDlpURL = await client.ytDlpURL
        let ffmpegURL = await client.ffmpegURL
        XCTAssertEqual(ytDlpURL.path, "/opt/homebrew/bin/yt-dlp", "yt-dlp must resolve to Apple Silicon Homebrew path")
        XCTAssertEqual(ffmpegURL.path, "/opt/homebrew/bin/ffmpeg", "ffmpeg must resolve to Apple Silicon Homebrew path")
        XCTAssertTrue(ytDlpURL.isFileURL, "yt-dlp URL must be absolute file URL")
        XCTAssertTrue(ffmpegURL.isFileURL, "ffmpeg URL must be absolute file URL")
        XCTAssertEqual(ytDlpURL.scheme, "file")
        XCTAssertEqual(ffmpegURL.scheme, "file")
        XCTAssertTrue(ytDlpURL.path.hasPrefix("/"), "must be absolute path")
        XCTAssertTrue(ffmpegURL.path.hasPrefix("/"), "must be absolute path")
    }

    func testSupersededYouTubeCleanupFailedNotDiscardedAndBlocksReplacement() async throws {
        // Direct WAV for replacement
        let directWavDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directWavDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directWavDir) }
        let directWAV = directWavDir.appendingPathComponent("direct.wav")
        try makeWAV(at: directWAV, frames: 1024)

        let dir = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let delayed = MockYouTubeCleanupFailedDelayed(delay: .milliseconds(250))
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let didStart = AtomicBool()
        await client.setTestHook { event in if case .started = event { didStart.setTrue() } }
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: delayed)

        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.startSeparation(inputURL: directWAV)

        let secondTask = try XCTUnwrap(controller.debugCurrentTask())
        await secondTask.value
        // allow stale handling MainActor hops
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(controller.debugYouTubeCleanupFailed(), "superseded cleanupFailed must set flag even when stale")
        if case .failed(let msg) = controller.state {
            XCTAssertTrue(msg.contains("Cleanup failed"), "replacement must not overwrite stale cleanupFailed, got \(msg)")
        } else {
            XCTFail("Expected failed Cleanup after stale, got \(controller.state)")
        }
        XCTAssertFalse(didStart.value, "replacement must not have proceeded to inference (no started) while flag true")
        // flag remains true blocking
        XCTAssertTrue(controller.debugYouTubeCleanupFailed(), "flag must remain true blocking replacement")
        await controller.shutdownWorker(policy: .testShort())
    }

    func testSuccessfulCancelClearsStaleFlagSoExitReturnsSafe() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL, frames: 1024)

        let dir = try makeFakeWorker(script: hangingWorkerScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let hanging = MockYouTubeHanging(mixtureURL: mixtureURL, shouldThrowCleanupFailedOnCancel: true)
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: hanging)

        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        for _ in 0..<50 {
            if await hanging.ingestStarted { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let ingestStarted = await hanging.ingestStarted
        XCTAssertTrue(ingestStarted)

        // Induce cleanupFailed via cancel that throws
        controller.cancel()
        if let tail = controller.debugCleanupChainTail() { await tail.value }
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(controller.debugYouTubeCleanupFailed(), "flag should be true after cleanupFailed via cancel")
        if case .failed(let msg) = controller.state {
            XCTAssertTrue(msg.contains("Cleanup failed"), "state should be cleanupFailed, got \(msg)")
        } else {
            XCTFail("Expected failed cleanupFailed, got \(controller.state)")
        }

        // First terminate returns unsafe (and preserves flag via early return path)
        let first = await controller.terminateForApplicationExit(policy: .testShort())
        XCTAssertEqual(first, .unsafeToTerminate(reason: .cleanupIncomplete), "first terminate should be unsafe due to cleanupFailed")
        // flag remains true after early-return unsafe (youTubeCancelThrew path does not clear)
        XCTAssertTrue(controller.debugYouTubeCleanupFailed(), "flag should remain true after first unsafe terminate")

        // Now successful cancel clears stale flag
        await hanging.setShouldThrowCleanupFailedOnCancel(false)
        controller.cancel()
        if let tail2 = controller.debugCleanupChainTail() { await tail2.value }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(controller.debugYouTubeCleanupFailed(), "flag must be cleared immediately after successful cancel")

        // Next terminate should be safe (no stale unsafe)
        let second = await controller.terminateForApplicationExit(policy: .testShort())
        XCTAssertEqual(second, .safeToTerminate, "second terminate after successful cancel should be safe, got \(second)")
        XCTAssertFalse(controller.debugYouTubeCleanupFailed())
    }

    // Additional: terminateForApplicationExit during YouTube ingest must return unsafe if cancel fails
    func testTerminateDuringIngestWithCleanupFailedReturnsUnsafe() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL, frames: 1024)

        let dir = try makeFakeWorker(script: hangingWorkerScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let hanging = MockYouTubeHanging(mixtureURL: mixtureURL, shouldThrowCleanupFailedOnCancel: true)
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: hanging)

        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        for _ in 0..<50 {
            if await hanging.ingestStarted { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let result = await controller.terminateForApplicationExit(policy: .testShort())
        XCTAssertEqual(result, .unsafeToTerminate(reason: .cleanupIncomplete), "terminate during hanging ingest with cleanupFailed should be unsafe")
    }

    // Requirement 1: cancel() must clear youTubeCleanupFailed immediately after youTubeIngest.cancel() succeeds, before worker/task cleanup
    func testCancelClearsFlagImmediatelyBeforeWorkerCleanup() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL, frames: 1024)

        let dir = try makeFakeWorker(script: slowTerminationWorkerScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let mock = MockYouTubeControllable(mixtureURL: mixtureURL)
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: mock)

        // Step 1: establish worker is alive via direct WAV success (uses slowTermination script)
        let directWAVDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directWAVDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directWAVDir) }
        let directWAV = directWAVDir.appendingPathComponent("direct.wav")
        try makeWAV(at: directWAV, frames: 1024)
        controller.startSeparation(inputURL: directWAV)
        let firstTask = try XCTUnwrap(controller.debugCurrentTask())
        await firstTask.value
        XCTAssertEqual(controller.state, .completed)

        // Step 2: induce cleanupFailed via YouTube ingest throwing cleanupFailed
        await mock.setShouldFailIngest(true)
        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        let failTask = try XCTUnwrap(controller.debugCurrentTask())
        await failTask.value
        // allow MainActor hop for flag/state
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(controller.debugYouTubeCleanupFailed(), "flag should be true after ingest cleanupFailed")
        if case .failed(let msg) = controller.state {
            XCTAssertTrue(msg.contains("Cleanup failed"))
        } else {
            XCTFail("Expected cleanupFailed state, got \(controller.state)")
        }

        // Worker should still be alive (idle ready) because ingest failed before worker use
        // Now invoke cancel() which should clear flag early before slow worker termination finishes
        await mock.setShouldFailIngest(false)
        await mock.setShouldThrowCleanupFailedOnCancel(false)
        controller.cancel()

        // Poll for early clearing: flag must become false while cleanup tail is still pending
        var sawFalseWhilePending = false
        var sawPending = false
        for _ in 0..<40 {
            if controller.debugCleanupChainTail() != nil { sawPending = true }
            if sawPending && !controller.debugYouTubeCleanupFailed() {
                sawFalseWhilePending = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(sawPending, "cleanup tail should be pending (slow termination) to observe ordering")
        XCTAssertTrue(sawFalseWhilePending, "youTubeCleanupFailed must be cleared immediately after youTube cancel succeeds, before worker cleanup finishes; old code would clear only at tail end")

        if let tail = controller.debugCleanupChainTail() { await tail.value }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(controller.debugYouTubeCleanupFailed(), "flag must remain false after cancel completes")
        // Verify subsequent terminate is safe (no stale flag)
        let result = await controller.terminateForApplicationExit(policy: .testShort())
        XCTAssertEqual(result, .safeToTerminate)
    }

    // Requirement 2: when youTubeCleanupFailed is true, both startSeparation entry points must reject synchronously before any UI mutation
    func testStartSeparationEarlyGuardPreservesStateWhenCleanupFailed() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL, frames: 1024)

        let dir = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let hanging = MockYouTubeHanging(mixtureURL: mixtureURL, shouldThrowCleanupFailedOnCancel: true)
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: hanging)

        // Induce cleanupFailed via cancel during ingest
        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        for _ in 0..<50 {
            if await hanging.ingestStarted { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let ingestStarted = await hanging.ingestStarted
        XCTAssertTrue(ingestStarted)
        controller.cancel()
        if let tail = controller.debugCleanupChainTail() { await tail.value }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(controller.debugYouTubeCleanupFailed())
        guard case .failed(let prevMsg) = controller.state else {
            XCTFail("Expected failed cleanup state, got \(controller.state)"); return
        }
        XCTAssertTrue(prevMsg.contains("Cleanup failed"))
        let prevStatus = controller.statusMessage
        let prevError = controller.errorMessage
        let prevTask = controller.debugCurrentTask()
        XCTAssertNil(prevTask, "currentTask should be nil after cancel")
        let ingested = await hanging.ingestedURLs
        let prevIngestedCount = ingested.count
        XCTAssertEqual(prevIngestedCount, 1)

        // Track if inference would start
        let didStart = AtomicBool()
        await client.setTestHook { event in if case .started = event { didStart.setTrue() } }

        // Attempt direct-WAV start — must be rejected synchronously
        let directWAVDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directWAVDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directWAVDir) }
        let directWAV = directWAVDir.appendingPathComponent("direct.wav")
        try makeWAV(at: directWAV, frames: 1024)

        controller.startSeparation(inputURL: directWAV)
        // Immediate synchronous check: no mutation
        XCTAssertEqual(controller.state, .failed(prevMsg), "direct-WAV start must not mutate state when cleanupFailed")
        XCTAssertEqual(controller.statusMessage, prevStatus)
        XCTAssertEqual(controller.errorMessage, prevError)
        XCTAssertTrue(controller.debugYouTubeCleanupFailed(), "flag must remain true")
        XCTAssertNil(controller.debugCurrentTask(), "must not create new currentTask when cleanupFailed")
        let cancelCount = await hanging.cancelCallCount
        XCTAssertEqual(cancelCount, 1, "youTube cancel must not be called again for rejected start")
        // Give Task a chance to run if it were incorrectly created
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(didStart.value, "inference must not start for rejected direct-WAV")
        XCTAssertEqual(controller.state, .failed(prevMsg))
        XCTAssertNil(controller.debugCurrentTask())

        // Attempt YouTube start — must also be rejected synchronously
        let ytURL2 = URL(string: "https://www.youtube.com/watch?v=aaaa")!
        controller.startSeparation(youTubeURL: ytURL2)
        XCTAssertEqual(controller.state, .failed(prevMsg), "YouTube start must not mutate state when cleanupFailed")
        XCTAssertEqual(controller.statusMessage, prevStatus)
        XCTAssertEqual(controller.errorMessage, prevError)
        XCTAssertTrue(controller.debugYouTubeCleanupFailed())
        XCTAssertNil(controller.debugCurrentTask(), "must not create new currentTask for rejected YouTube start")
        let ingestedAfterYT = await hanging.ingestedURLs
        XCTAssertEqual(ingestedAfterYT.count, prevIngestedCount, "ingest must not be called for rejected YouTube start")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(didStart.value, "inference must not start for rejected YouTube")
        let ingestedFinal = await hanging.ingestedURLs
        XCTAssertEqual(ingestedFinal.count, prevIngestedCount)

        await controller.shutdownWorker(policy: .testShort())
    }

    // MARK: - Truthful phase-based progress

    func testYouTubeSeparationTruthfulPhasesEndToEnd() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mixtureURL = directory.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL, frames: 1024)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(artist: "Artist", title: "Title"))
        let phasedResult = YouTubeIngestResult(audioURL: mixtureURL, metadata: metadata)
        let phasedMock = MockYouTubePhased(result: phasedResult)

        let workerDir = try makeFakeWorker(script: delayedSuccessScript())
        defer { try? FileManager.default.removeItem(at: workerDir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: workerDir)
        let outputBase = directory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: phasedMock)

        let url = URL(string: "https://www.youtube.com/watch?v=phase-test")!
        controller.startSeparation(youTubeURL: url)

        XCTAssertEqual(controller.creationPhase, .downloadingAudio)
        XCTAssertEqual(controller.statusMessage, "Downloading audio")
        XCTAssertTrue(controller.isYouTubeFlow)
        XCTAssertTrue(controller.showDownloadingPhase)
        XCTAssertTrue(controller.isSeparating)

        var observedPreparing = false
        for _ in 0..<50 {
            if controller.creationPhase == .preparingAudio && controller.statusMessage == "Preparing audio" {
                observedPreparing = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(observedPreparing, "Should transition to Preparing audio via FFmpeg phase")

        var observedLoading = false
        for _ in 0..<50 {
            if controller.creationPhase == .loadingModel && controller.statusMessage == "Loading separation model" {
                observedLoading = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(observedLoading, "Should transition to Loading separation model after ingest")

        var observedCreating = false
        for _ in 0..<100 {
            if controller.creationPhase == .creatingStrata && controller.statusMessage == "Creating strata" {
                observedCreating = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(observedCreating, "Worker .started should transition to Creating strata")

        let task = try XCTUnwrap(controller.debugCurrentTask())
        await task.value
        XCTAssertEqual(controller.creationPhase, .complete)
        XCTAssertEqual(controller.statusMessage, "Complete — 6 strata")
        XCTAssertEqual(controller.state, .completed)
        XCTAssertNotNil(controller.result)
        XCTAssertEqual(controller.result?.stems.count, 6)
        XCTAssertFalse(controller.isSeparating)

        await controller.shutdownWorker(policy: .testShort())
    }

    func testYouTubeSeparationFromLoadedSourceSkipsDownloadPrepare() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mixtureURL = directory.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(artist: "Artist", title: "Title"))
        let ingestResult = YouTubeIngestResult(audioURL: mixtureURL, metadata: metadata)
        let phasedMock = MockYouTubePhased(result: ingestResult)
        let workerDir = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: workerDir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: workerDir)
        let outputBase = directory.appendingPathComponent("output", isDirectory: true)
        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: phasedMock)

        let url = URL(string: "https://www.youtube.com/watch?v=reuse-test")!
        controller.startSeparation(youTubeURL: url)
        let firstTask = try XCTUnwrap(controller.debugCurrentTask())
        await firstTask.value
        XCTAssertEqual(controller.state, .completed)

        controller.startSeparationFromLoadedYouTubeSource()
        XCTAssertEqual(controller.creationPhase, .loadingModel)
        XCTAssertEqual(controller.statusMessage, "Loading separation model")
        XCTAssertTrue(controller.isYouTubeFlow)

        let secondTask = try XCTUnwrap(controller.debugCurrentTask())
        await secondTask.value
        XCTAssertEqual(controller.creationPhase, .complete)
        XCTAssertEqual(controller.statusMessage, "Complete — 6 strata")

        await controller.shutdownWorker(policy: .testShort())
    }

    func testYouTubeIngestFailurePreservesErrorWithoutFakeProgress() async throws {
        let failureMock = MockYouTubePhasedFailure(error: .invalidYouTubeURL("https://www.youtube.com/watch?v=bad"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workerDir = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: workerDir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(2), startedTimeout: .seconds(1), separationTimeout: .seconds(2), workerDirectory: workerDir)
        let controller = InferenceController(client: client, outputBase: directory, youTubeIngest: failureMock)

        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=bad")!)
        let task = try XCTUnwrap(controller.debugCurrentTask())
        await task.value
        if case .failed(let msg) = controller.state {
            XCTAssertTrue(msg.contains("Invalid YouTube URL"))
        } else {
            XCTFail("Expected failed, got \(controller.state)")
        }
        XCTAssertNil(controller.result)
        XCTAssertNotEqual(controller.statusMessage, "Complete — 6 strata")
        XCTAssertNotEqual(controller.creationPhase, .complete)

        await controller.shutdownWorker(policy: .testShort())
    }
}
