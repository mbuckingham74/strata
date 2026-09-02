import XCTest
@testable import Strata
import AVFoundation
import SwiftUI

// MARK: - Fakes (lightweight, isolated from other test files)

@MainActor
private final class LibraryFakeTransport: AudioTransport {
    var duration: TimeInterval = 120
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var onCompletion: (() -> Void)?
    var lastLoadedURL: URL?
    var loadCount = 0
    func load(url: URL) throws {
        lastLoadedURL = url
        loadCount += 1
        duration = 120
        currentTime = 0
        isPlaying = false
    }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to time: TimeInterval) { currentTime = time }
    func stop() { isPlaying = false; currentTime = 0 }
}

@MainActor
private final class LibraryFakeStemTransport: StemAudioTransport {
    var duration: TimeInterval = 120
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var mutedStems: Set<StemName> = []
    var soloedStems: Set<StemName> = []
    var stemGains: [StemName: Float] = [:]
    var onCompletion: (() -> Void)?
    var lastLoadedResult: SeparationResult?
    func load(result: SeparationResult) throws {
        lastLoadedResult = result
        for s in StemName.allCases { stemGains[s] = 1.0 }
        mutedStems.removeAll()
        soloedStems.removeAll()
        duration = 120
        currentTime = 0
        isPlaying = false
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

private func makeLibraryGains() -> [StemName: Double] {
    var g: [StemName: Double] = [:]
    for s in StemName.allCases { g[s] = 1.0 }
    return g
}

private func makeLibraryWAV(at url: URL, frames: UInt32 = 1024) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for ch in 0..<2 {
        let ptr = buffer.floatChannelData![ch]
        for i in 0..<Int(frames) { ptr[i] = sin(Float(i) * 0.01) * 0.1 }
    }
    try file.write(from: buffer)
}

@MainActor
private func createLibraryProject(persistence: StrataProjectPersistence, frames: UInt32 = 1024, sourceKind: StrataProjectSourceKind = .localFile, locator: String? = nil, displayTitle: String = "Test Title") throws -> (project: StrataProject, result: SeparationResult, scratchBase: URL) {
    let scratchBase = FileManager.default.temporaryDirectory.appendingPathComponent("StrataLibraryScratch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratchBase, withIntermediateDirectories: true)
    let mixtureURL = scratchBase.appendingPathComponent("mixture.wav")
    try makeLibraryWAV(at: mixtureURL, frames: frames)
    let inputSHA = try sha256File(at: mixtureURL)
    let jobId = UUID().uuidString.lowercased()
    let jobDir = scratchBase.appendingPathComponent(jobId, isDirectory: true)
    try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
    var stemURLs: [StemName: URL] = [:]
    var records: [[String: Any]] = []
    for stem in StemName.allCases {
        let url = jobDir.appendingPathComponent("\(stem.rawValue).wav")
        try makeLibraryWAV(at: url, frames: frames)
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
        "input_path": mixtureURL.path,
        "output_dir": scratchBase.path,
        "input_sha256": inputSHA,
        "input_metadata": ["sample_rate": 44100, "channels": 2, "frames": UInt64(frames), "duration": Double(frames)/44100.0, "sha256": inputSHA],
        "stems": records
    ]
    let manifestURL = jobDir.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]).write(to: manifestURL)
    let jobInfo = JobInfo(jobId: jobId, inputPath: mixtureURL.path, outputDir: scratchBase.path)
    let ready = ReadyMetadata(backend: TrustedInferenceIdentity.backend, device: TrustedInferenceIdentity.device, checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256, model: nil)
    let result = try SeparationValidator.validatedResult(manifestURL: manifestURL, job: jobInfo, readyMetadata: ready, receivedStems: stemURLs)
    let pid = UUID().uuidString.lowercased()
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let metadata: YouTubeTrackMetadata? = sourceKind == .youTube ? YouTubeTrackMetadata(artist: "Artist", title: "Title", album: "Album", albumArtist: "AA", year: "2024", genre: "Pop", trackNumber: "1") : nil
    let finalLocator: String
    if let locator { finalLocator = locator }
    else { finalLocator = sourceKind == .youTube ? "https://www.youtube.com/watch?v=abc123" : "/tmp/input-\(pid).wav" }
    let source = StrataProjectSource(kind: sourceKind, locator: finalLocator, metadata: metadata)
    let project = try StrataProject(schemaVersion: 1, id: pid, createdAt: now, lastOpenedAt: now, displayTitle: displayTitle, source: source, gains: makeLibraryGains())
    try persistence.persistCompletedSeparation(project: project, result: result, artworkSourceURL: nil)
    return (project, result, scratchBase)
}

// MARK: - Tests

@MainActor
final class SessionLibraryNavigationTests: XCTestCase {

    func testLibraryEnumerationReflectsProjectsSorted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StrataLibraryEnum-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: root)
        let store = SessionStore(persistence: persistence)
        XCTAssertEqual(store.projects.count, 0)

        // Create two projects with distinct lastOpenedAt via direct save with delay
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 1.0 }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let later = now.addingTimeInterval(100)
        let early = try StrataProject(schemaVersion: 1, id: UUID().uuidString.lowercased(), createdAt: now, lastOpenedAt: now, displayTitle: "Early", source: StrataProjectSource(kind: .localFile, locator: "/tmp/a.wav", metadata: nil), gains: gains)
        let late = try StrataProject(schemaVersion: 1, id: UUID().uuidString.lowercased(), createdAt: now, lastOpenedAt: later, displayTitle: "Late", source: StrataProjectSource(kind: .localFile, locator: "/tmp/b.wav", metadata: nil), gains: gains)
        try persistence.createProjectDirectory(for: early)
        try persistence.save(early)
        try persistence.createProjectDirectory(for: late)
        try persistence.save(late)

        store.loadProjects()
        XCTAssertEqual(store.projects.count, 2)
        XCTAssertEqual(store.projects.first?.id, late.id, "Library must be sorted by lastOpenedAt descending")
        XCTAssertEqual(store.projects.last?.id, early.id)
    }

    func testSelectionHighlightReflectsSelectedProjectID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StrataLibrarySel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: root)
        let store = SessionStore(persistence: persistence)
        let (project, _, scratchBase) = try createLibraryProject(persistence: persistence, displayTitle: "Selectable")
        defer { try? FileManager.default.removeItem(at: scratchBase) }
        store.loadProjects()
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertNil(store.selectedProjectID) // persistence via persistence directly does not set selection
        let playback = PlaybackController(transport: LibraryFakeTransport())
        let stem = StemPlaybackController(transport: LibraryFakeStemTransport())
        let inference = InferenceController()
        try store.reopen(projectID: project.id, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)
        XCTAssertEqual(store.selectedProjectID, project.id)
        // Simulate second project selection
        let (project2, _, scratchBase2) = try createLibraryProject(persistence: persistence, displayTitle: "Second")
        defer { try? FileManager.default.removeItem(at: scratchBase2) }
        store.loadProjects()
        XCTAssertEqual(store.projects.count, 2)
        try store.reopen(projectID: project2.id, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)
        XCTAssertEqual(store.selectedProjectID, project2.id)
        XCTAssertNotEqual(store.selectedProjectID, project.id)
    }

    func testReopenRestoresWithoutIngestOrSeparation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StrataLibraryReopen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: root)
        let store = SessionStore(persistence: persistence)
        let (project, _, scratchBase) = try createLibraryProject(persistence: persistence, sourceKind: .localFile, displayTitle: "Local Song")
        defer { try? FileManager.default.removeItem(at: scratchBase) }
        // Remove scratch to prove reopen does not need original scratch
        try? FileManager.default.removeItem(at: scratchBase)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchBase.path))
        let playback = PlaybackController(transport: LibraryFakeTransport())
        let stemTransport = LibraryFakeStemTransport()
        let stem = StemPlaybackController(transport: stemTransport)
        let inference = InferenceController()
        // Capture mtime before reopen to ensure no rewrite
        let dir = persistence.projectDirectory(for: project.id)
        let mixturePath = dir.appendingPathComponent("source/mixture.wav").path
        let attrsBefore = try FileManager.default.attributesOfItem(atPath: mixturePath)
        let mtimeBefore = attrsBefore[.modificationDate] as? Date

        try store.reopen(projectID: project.id, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)

        // Verify restored without ingest: file not rewritten, controllers populated, no error
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: mixturePath)
        XCTAssertEqual(mtimeBefore, attrsAfter[.modificationDate] as? Date)
        XCTAssertEqual(playback.title, project.displayTitle)
        XCTAssertTrue(playback.hasFile)
        XCTAssertTrue(playback.sourceURL!.path.hasSuffix("source/mixture.wav"))
        XCTAssertEqual(inference.state, .completed)
        XCTAssertNotNil(inference.result)
        XCTAssertTrue(stem.hasStems)
        XCTAssertEqual(stem.title, project.displayTitle)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.selectedProjectID, project.id)
        // YouTube draft should be empty for local
        XCTAssertEqual(store.draftYouTubeURLString, "")
        // Verify YouTube source also restores without ingest
        let root2 = FileManager.default.temporaryDirectory.appendingPathComponent("StrataLibraryReopenYT-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root2) }
        let persistence2 = StrataProjectPersistence(fileManager: .default, projectsRootOverride: root2)
        let store2 = SessionStore(persistence: persistence2)
        let ytLocator = "https://www.youtube.com/watch?v=restore123"
        let (ytProject, _, scratchBaseYT) = try createLibraryProject(persistence: persistence2, sourceKind: .youTube, locator: ytLocator, displayTitle: "Artist - Title")
        defer { try? FileManager.default.removeItem(at: scratchBaseYT) }
        try? FileManager.default.removeItem(at: scratchBaseYT)
        let playback2 = PlaybackController(transport: LibraryFakeTransport())
        let stem2 = StemPlaybackController(transport: LibraryFakeStemTransport())
        let inference2 = InferenceController()
        try store2.reopen(projectID: ytProject.id, playbackController: playback2, inferenceController: inference2, stemPlaybackController: stem2)
        XCTAssertEqual(store2.draftYouTubeURLString, ytLocator)
        XCTAssertEqual(inference2.loadedYouTubeURL?.absoluteString, ytLocator)
        XCTAssertTrue(inference2.isYouTubeFlow)
    }

    func testNewSessionClearsDraftAndMakesReadyForYouTubeAndLocal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StrataLibraryNewSession-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: root)
        let store = SessionStore(persistence: persistence)
        let (project, _, scratchBase) = try createLibraryProject(persistence: persistence, displayTitle: "ToClear")
        defer { try? FileManager.default.removeItem(at: scratchBase) }
        let playback = PlaybackController(transport: LibraryFakeTransport())
        let stem = StemPlaybackController(transport: LibraryFakeStemTransport())
        let inference = InferenceController()
        try store.reopen(projectID: project.id, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)
        store.draftYouTubeURLString = "https://www.youtube.com/watch?v=abc"
        XCTAssertNotNil(store.selectedProjectID)
        XCTAssertTrue(playback.hasFile)
        XCTAssertTrue(stem.hasStems)
        XCTAssertEqual(inference.state, .completed)

        store.newSession(playbackController: playback, inferenceController: inference, stemPlaybackController: stem)

        // Store cleared
        XCTAssertEqual(store.draftYouTubeURLString, "", "New Session must clear draft YouTube URL so TextField empty")
        XCTAssertNil(store.selectedProjectID)
        XCTAssertNil(store.lastError)
        // Playback cleared -> main view shows EmptyStateView + Add Audio path
        XCTAssertNil(playback.title)
        XCTAssertFalse(playback.hasFile)
        XCTAssertNil(playback.sourceURL)
        XCTAssertEqual(playback.duration, 0, accuracy: 0.001)
        // Inference cleared -> ready for either YouTube URL or local source
        XCTAssertEqual(inference.state, .idle)
        XCTAssertNil(inference.result)
        XCTAssertNil(inference.loadedYouTubeURL)
        XCTAssertNil(inference.loadedYouTubeSource)
        XCTAssertNil(inference.youTubeExportMetadata)
        XCTAssertEqual(inference.statusMessage, "Ready to create strata")
        // Stems cleared
        XCTAssertFalse(stem.hasStems)
        XCTAssertNil(stem.result)
        XCTAssertTrue(stem.stemGains.isEmpty)
        // Library still enumerated, selection cleared (projects remain, but none selected)
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertNil(store.selectedProjectID)
        // After newSession, inferenceController still accepts YouTube URL via draft and local via playback.load
        store.draftYouTubeURLString = "https://www.youtube.com/watch?v=newOne"
        XCTAssertEqual(store.draftYouTubeURLString, "https://www.youtube.com/watch?v=newOne")
        // Simulate user choosing local file
        let localURL = URL(fileURLWithPath: "/tmp/newLocal.wav")
        // Normally FileImporter would call playback.load; we verify that after newSession, load works
        // Create dummy wav for load to succeed? Fake transport accepts any URL, so just check state transition
        playback.load(url: localURL, displayTitle: "New Local")
        XCTAssertTrue(playback.hasFile)
        XCTAssertEqual(playback.title, "New Local")
    }

    func testSidebarEffectivePropertiesPreserved() throws {
        // Keep existing effectiveHasFile/effectiveTitle backward compat
        let pc = PlaybackController(transport: LibraryFakeTransport())
        let spc = StemPlaybackController(transport: LibraryFakeStemTransport())
        let ic = InferenceController()
        var showing = false
        let binding = Binding(get: { showing }, set: { showing = $0 })
        let sidebar = SidebarView(controller: pc, stemPlaybackController: spc, inferenceController: ic, showingImporter: binding)
        XCTAssertFalse(sidebar.effectiveHasFile)
        XCTAssertNil(sidebar.effectiveTitle)
        pc.load(url: URL(fileURLWithPath: "/tmp/song.wav"), displayTitle: "Song")
        let sidebar2 = SidebarView(controller: pc, stemPlaybackController: spc, inferenceController: ic, showingImporter: binding)
        XCTAssertTrue(sidebar2.effectiveHasFile)
        XCTAssertEqual(sidebar2.effectiveTitle, "Song")
    }

    func testProjectsEnumerationSortedAfterReopenUpdatesOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StrataLibraryOrder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: root)
        let store = SessionStore(persistence: persistence)
        let (p1, _, sb1) = try createLibraryProject(persistence: persistence, displayTitle: "First")
        defer { try? FileManager.default.removeItem(at: sb1) }
        // Ensure time difference for ordering
        Thread.sleep(forTimeInterval: 1.1)
        let (p2, _, sb2) = try createLibraryProject(persistence: persistence, displayTitle: "Second")
        defer { try? FileManager.default.removeItem(at: sb2) }
        store.loadProjects()
        // p2 is newer, should be first before reopen
        XCTAssertEqual(store.projects.first?.id, p2.id)
        // Reopen p1 should bump it to front
        let playback = PlaybackController(transport: LibraryFakeTransport())
        let stem = StemPlaybackController(transport: LibraryFakeStemTransport())
        let inference = InferenceController()
        Thread.sleep(forTimeInterval: 1.1)
        try store.reopen(projectID: p1.id, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)
        XCTAssertEqual(store.projects.first?.id, p1.id, "Reopen should update lastOpenedAt and reorder Library")
    }

    func testReopenFailureIsVisiblyRepresentableViaBoundedLastError() throws {
        // Proves the silent try? fix: a failing reopen is not discarded — it becomes visibly
        // presentable via the store's existing bounded lastError (alert binding), not a second model.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StrataLibraryReopenFailNav-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: root)
        let store = SessionStore(persistence: persistence)
        let (project, _, scratchBase) = try createLibraryProject(persistence: persistence, displayTitle: "KeepSelected")
        defer { try? FileManager.default.removeItem(at: scratchBase) }
        store.loadProjects()
        let playback = PlaybackController(transport: LibraryFakeTransport())
        let stem = StemPlaybackController(transport: LibraryFakeStemTransport())
        let inference = InferenceController()
        // Successful reopen establishes selection and clears any prior error
        try store.reopen(projectID: project.id, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertNil(store.lastError)
        XCTAssertNil(store.reopenError)
        let isAlertPresentedWhenNoError = store.lastError != nil
        XCTAssertFalse(isAlertPresentedWhenNoError, "No error → no alert")

        // Explicit handling (mirrors fixed UI: do { try store.reopen } catch {}) must NOT discard the error;
        // the bounded lastError must become visibly presentable instead of silent try? discard.
        let missingID = UUID().uuidString.lowercased()
        do {
            try store.reopen(projectID: missingID, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)
            XCTFail("Expected reopen to throw for missing ID")
        } catch {
            // Store already set bounded lastError; no second error model needed
        }
        // Visibly representable via existing bounded state (alert isPresented = lastError != nil)
        XCTAssertNotNil(store.lastError, "Failure must populate bounded lastError for visible alert, not silent discard")
        XCTAssertNotNil(store.reopenError, "reopenError alias must reflect same bounded state — no second model")
        XCTAssertEqual(store.lastError, store.reopenError)
        XCTAssertLessThanOrEqual(store.lastError!.count, 500, "Bounded state must remain ≤500")
        let isAlertPresentedAfterFailure = store.lastError != nil
        XCTAssertTrue(isAlertPresentedAfterFailure, "Failure must be visibly representable via lastError alert binding")
        // Selection must not move on failure (successful reopen behavior unchanged, failure preserves prior selection)
        XCTAssertEqual(store.selectedProjectID, project.id)
        // Dismissing alert clears the same bounded state — reuse, no second model
        store.lastError = nil
        XCTAssertNil(store.lastError)
        XCTAssertNil(store.reopenError)
        XCTAssertFalse(store.lastError != nil)

        // Re-confirm successful reopen still clears error and updates selection
        let (project2, _, sb2) = try createLibraryProject(persistence: persistence, displayTitle: "SecondOK")
        defer { try? FileManager.default.removeItem(at: sb2) }
        store.loadProjects()
        try store.reopen(projectID: project2.id, playbackController: playback, inferenceController: inference, stemPlaybackController: stem)
        XCTAssertEqual(store.selectedProjectID, project2.id)
        XCTAssertNil(store.lastError, "Successful reopen must clear bounded error")
    }
}
