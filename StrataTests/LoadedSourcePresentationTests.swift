import XCTest
@testable import Strata
import SwiftUI
import AVFoundation

// Focused tests for loaded-source presentation defect:
// - YouTube ingest metadata (exportBaseName / editableTitle) must surface as human title
// - Sidebar must show hasFile when YouTube stems are loaded, not "No audio loaded"
// - Local sources must keep filename title, no regression
// - StrataStack display title must prefer human title over raw path

@MainActor
final class LoadedSourcePresentationTests: XCTestCase {

    // MARK: - Helpers

    private func makeDummyResult(
        jobId: String = "test-job",
        inputPath: String = "/tmp/mixture.wav",
        jobDir: String = "/tmp/jobs/test-job"
    ) -> SeparationResult {
        let inputURL = URL(fileURLWithPath: inputPath)
        let jobDirURL = URL(fileURLWithPath: jobDir)
        let manifestURL = jobDirURL.appendingPathComponent("manifest.json")
        var stems: [StemName: StemArtifact] = [:]
        for stem in StemName.allCases {
            let url = jobDirURL.appendingPathComponent("\(stem.rawValue).wav")
            stems[stem] = StemArtifact(
                name: stem,
                url: url,
                sha256: String(repeating: "a", count: 64),
                fileSize: 1234,
                frameCount: 44100,
                channels: 2,
                sampleRate: 44100
            )
        }
        return SeparationResult(
            jobId: jobId,
            inputURL: inputURL,
            jobDirectoryURL: jobDirURL,
            manifestURL: manifestURL,
            stems: stems,
            backend: TrustedInferenceIdentity.backend,
            device: TrustedInferenceIdentity.device,
            checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256,
            model: TrustedInferenceIdentity.model
        )
    }

    private func makeStemTransport(duration: TimeInterval = 120) -> FakeStemTransport {
        FakeStemTransport(duration: duration)
    }

    // MARK: - StemPlaybackController displayName override

    func testStemLoadUsesDisplayNameForYouTubeMixtureInsteadOfRawPath() {
        let fake = makeStemTransport(duration: 60)
        let sut = StemPlaybackController(transport: fake)
        let result = makeDummyResult(inputPath: "/tmp/M4Ingest/abc/mixture.wav")

        sut.load(result: result, displayName: "Snow Patrol - Run")

        XCTAssertEqual(sut.title, "Snow Patrol - Run", "YouTube source should show human title, not 'mixture'")
        XCTAssertTrue(sut.hasStems)
    }

    func testStemLoadFallsBackToFilenameForLocalSourceWhenNoDisplayName() {
        let fake = makeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        let result = makeDummyResult(inputPath: "/tmp/My Song - Demo.m4a")

        sut.load(result: result)

        XCTAssertEqual(sut.title, "My Song - Demo")
    }

    func testStemLoadWithNilOrEmptyDisplayNameFallsBackToInputName() {
        let fake = makeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        let result = makeDummyResult(inputPath: "/tmp/LocalTrack.wav")

        sut.load(result: result, displayName: nil)
        XCTAssertEqual(sut.title, "LocalTrack")

        sut.load(result: result, displayName: "")
        XCTAssertEqual(sut.title, "LocalTrack")

        sut.load(result: result, displayName: "   ")
        XCTAssertEqual(sut.title, "LocalTrack")
    }

    func testStemLoadTrimsDisplayNameWhitespace() {
        let fake = makeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        let result = makeDummyResult(inputPath: "/tmp/mixture.wav")
        sut.load(result: result, displayName: "  Snow Patrol - Run  ")
        XCTAssertEqual(sut.title, "Snow Patrol - Run")
    }

    // MARK: - InferenceCard.loadCompletedResult propagation

    func testInferenceCardLoadCompletedResultPropagatesExportBaseName() {
        let fake = makeStemTransport(duration: 60)
        let sut = StemPlaybackController(transport: fake)
        let ic = InferenceController()
        ic.debugSetExportBaseName("Snow Patrol - Run")
        let card = InferenceCard(
            inferenceController: ic,
            stemPlaybackController: sut,
            inferenceInputURL: .constant(nil),
            showingInferenceImporter: .constant(false)
        )
        let result = makeDummyResult(inputPath: "/tmp/mixture.wav")

        card.loadCompletedResult(result)

        XCTAssertEqual(sut.title, "Snow Patrol - Run")
        XCTAssertTrue(sut.hasStems)
    }

    func testInferenceCardLoadCompletedResultUsesEditableTitleWhenExportBaseNameNil() {
        let fake = makeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        let ic = InferenceController()
        ic.debugSetExportBaseName(nil)
        ic.editableTitle = "Run"
        let card = InferenceCard(
            inferenceController: ic,
            stemPlaybackController: sut,
            inferenceInputURL: .constant(nil),
            showingInferenceImporter: .constant(false)
        )
        let result = makeDummyResult(inputPath: "/tmp/mixture.wav")

        card.loadCompletedResult(result)

        XCTAssertEqual(sut.title, "Run")
    }

    func testInferenceCardLoadCompletedResultFallsBackToFilenameForLocal() {
        let fake = makeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        let ic = InferenceController()
        ic.debugSetExportBaseName(nil)
        ic.editableTitle = ""
        let card = InferenceCard(
            inferenceController: ic,
            stemPlaybackController: sut,
            inferenceInputURL: .constant(nil),
            showingInferenceImporter: .constant(false)
        )
        let result = makeDummyResult(inputPath: "/tmp/LocalFile.wav")

        card.loadCompletedResult(result)

        XCTAssertEqual(sut.title, "LocalFile")
    }

    // MARK: - Sidebar effectiveHasFile / effectiveTitle

    func testSidebarShowsNoAudioWhenNeitherLocalNorStems() {
        let pc = PlaybackController(transport: MockAudioTransport())
        let spc = StemPlaybackController(transport: makeStemTransport())
        let ic = InferenceController()
        var showing = false
        let binding = Binding(get: { showing }, set: { showing = $0 })
        let sidebar = SidebarView(controller: pc, stemPlaybackController: spc, inferenceController: ic, showingImporter: binding)

        XCTAssertFalse(sidebar.effectiveHasFile)
        XCTAssertNil(sidebar.effectiveTitle)
    }

    func testSidebarShowsHumanTitleWhenYouTubeStemsLoaded() {
        let pc = PlaybackController(transport: MockAudioTransport())
        let fake = makeStemTransport()
        let spc = StemPlaybackController(transport: fake)
        let ic = InferenceController()
        ic.debugSetExportBaseName("Snow Patrol - Run")

        // Load YouTube result via InferenceCard propagation
        let card = InferenceCard(
            inferenceController: ic,
            stemPlaybackController: spc,
            inferenceInputURL: .constant(nil),
            showingInferenceImporter: .constant(false)
        )
        let result = makeDummyResult(inputPath: "/tmp/mixture.wav")
        card.loadCompletedResult(result)

        var showing = false
        let binding = Binding(get: { showing }, set: { showing = $0 })
        let sidebar = SidebarView(controller: pc, stemPlaybackController: spc, inferenceController: ic, showingImporter: binding)

        XCTAssertTrue(sidebar.effectiveHasFile, "Sidebar must not claim 'No audio loaded' once YouTube source is loaded")
        XCTAssertEqual(sidebar.effectiveTitle, "Snow Patrol - Run")
    }

    func testSidebarPrefersLocalTitleOverStems() throws {
        let pc = PlaybackController(transport: MockAudioTransport())
        // Need a real file for PlaybackController.load to succeed – create temp WAV
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: tmp, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        try file.write(from: buffer)
        pc.load(url: tmp)
        // Now load stems as well
        let fake = makeStemTransport()
        let spc = StemPlaybackController(transport: fake)
        spc.load(result: makeDummyResult(inputPath: "/tmp/mixture.wav"), displayName: "Snow Patrol - Run")
        let ic = InferenceController()
        ic.debugSetExportBaseName("Snow Patrol - Run")
        var showing = false
        let binding = Binding(get: { showing }, set: { showing = $0 })
        let sidebar = SidebarView(controller: pc, stemPlaybackController: spc, inferenceController: ic, showingImporter: binding)

        XCTAssertTrue(sidebar.effectiveHasFile)
        XCTAssertEqual(sidebar.effectiveTitle, pc.title, "Local title should take precedence when local file loaded")
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - StrataStack effectiveDisplayTitle (via InferenceCard + StemPlaybackController wiring)

    func testStrataEffectiveTitlePrefersExportBaseName() {
        // StrataStackView effectiveDisplayTitle logic mirrors inferenceController.exportBaseName > editableTitle > stem title > inputURL
        // We verify the underlying controllers carry the correct titles so StrataStack will display human title.
        let fake = makeStemTransport()
        let spc = StemPlaybackController(transport: fake)
        let ic = InferenceController()
        ic.debugSetExportBaseName("Snow Patrol - Run")
        let result = makeDummyResult(inputPath: "/tmp/mixture.wav", jobDir: "/tmp/jobs/job-123")
        let card = InferenceCard(
            inferenceController: ic,
            stemPlaybackController: spc,
            inferenceInputURL: .constant(nil),
            showingInferenceImporter: .constant(false)
        )
        card.loadCompletedResult(result)
        // StrataStack would be initialized with result, spc, ic – effectiveDisplayTitle would be exportBaseName
        XCTAssertEqual(ic.exportBaseName, "Snow Patrol - Run")
        XCTAssertEqual(spc.title, "Snow Patrol - Run")
    }

    // MARK: - StrataStackView footer: YouTube vs local

    func testStrataStackShowsHumanTitleForYouTubeSource() {
        let fake = makeStemTransport()
        let spc = StemPlaybackController(transport: fake)
        let ic = InferenceController()
        ic.debugSetExportBaseName("Snow Patrol - Run")
        let result = makeDummyResult(inputPath: "/tmp/M4Ingest/abc/mixture.wav", jobDir: "/tmp/jobs/yt-job-123")
        let card = InferenceCard(
            inferenceController: ic,
            stemPlaybackController: spc,
            inferenceInputURL: .constant(nil),
            showingInferenceImporter: .constant(false)
        )
        card.loadCompletedResult(result)
        let view = StrataStackView(result: result, stemPlaybackController: spc, inferenceController: ic)
        XCTAssertEqual(view.effectiveDisplayTitle, "Snow Patrol - Run", "YouTube ingest must show human-readable metadata/title, not jobDirectory path or mixture")
    }

    func testStrataStackPreservesJobDirectoryPathForLocalSource() {
        let fake = makeStemTransport()
        let spc = StemPlaybackController(transport: fake)
        let ic = InferenceController() // local: no YouTube metadata, exportBaseName nil
        let jobDir = "/tmp/jobs/local-job-456"
        let result = makeDummyResult(inputPath: "/Users/me/Music/My Song - Demo.wav", jobDir: jobDir)
        // Simulate local completed load (no displayName)
        spc.load(result: result)
        let view = StrataStackView(result: result, stemPlaybackController: spc, inferenceController: ic)
        XCTAssertEqual(view.effectiveDisplayTitle, result.jobDirectoryURL.path, "Local sources must preserve existing jobDirectoryURL.path")
        XCTAssertEqual(view.effectiveDisplayTitle, "/tmp/jobs/local-job-456")
        XCTAssertNotEqual(view.effectiveDisplayTitle, "My Song - Demo", "Must not show filename for local")
    }

    func testStrataStackLocalMixtureFilenameStillShowsJobDirectoryPath() {
        // Guards against inferring YouTube merely from filename "mixture.wav"
        let fake = makeStemTransport()
        let spc = StemPlaybackController(transport: fake)
        let ic = InferenceController()
        let jobDir = "/tmp/jobs/local-mixture-job"
        let result = makeDummyResult(inputPath: "/tmp/mixture.wav", jobDir: jobDir)
        spc.load(result: result) // local mixture file -> title "mixture"
        XCTAssertEqual(spc.title, "mixture")
        let view = StrataStackView(result: result, stemPlaybackController: spc, inferenceController: ic)
        XCTAssertEqual(view.effectiveDisplayTitle, result.jobDirectoryURL.path, "Local file named mixture.wav must still show jobDirectory path, not human-title fallback")
        XCTAssertEqual(view.effectiveDisplayTitle, "/tmp/jobs/local-mixture-job")
        XCTAssertNotEqual(view.effectiveDisplayTitle, "mixture")
    }

    func testStrataStackYouTubeShowsHumanTitleEvenWhenInputIsMixture() {
        // YouTube ingest also has inputURL mixture.wav but must show human title via inference state
        let fake = makeStemTransport()
        let spc = StemPlaybackController(transport: fake)
        let ic = InferenceController()
        ic.debugSetExportBaseName("Queen - Bohemian Rhapsody")
        let result = makeDummyResult(inputPath: "/tmp/mixture.wav", jobDir: "/tmp/jobs/yt-mixture-job")
        let card = InferenceCard(
            inferenceController: ic,
            stemPlaybackController: spc,
            inferenceInputURL: .constant(nil),
            showingInferenceImporter: .constant(false)
        )
        card.loadCompletedResult(result)
        let view = StrataStackView(result: result, stemPlaybackController: spc, inferenceController: ic)
        XCTAssertEqual(view.effectiveDisplayTitle, "Queen - Bohemian Rhapsody")
        XCTAssertNotEqual(view.effectiveDisplayTitle, result.jobDirectoryURL.path)
        XCTAssertNotEqual(view.effectiveDisplayTitle, "mixture")
    }

    // MARK: - Local regression guard

    func testLocalLoadRetainsFilenameTitleAfterYouTubeThenLocal() {
        let fake = makeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        // YouTube
        sut.load(result: makeDummyResult(inputPath: "/tmp/mixture.wav"), displayName: "Snow Patrol - Run")
        XCTAssertEqual(sut.title, "Snow Patrol - Run")
        // Local
        sut.load(result: makeDummyResult(inputPath: "/tmp/Another Song.wav"))
        XCTAssertEqual(sut.title, "Another Song")
    }
}

// Minimal mock for PlaybackController transport (needed for local title test)
private final class MockAudioTransport: AudioTransport {
    var duration: TimeInterval = 10
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var onCompletion: (() -> Void)?
    func load(url: URL) throws {
        // Derive duration from file length if possible, else 10
        duration = 10
        currentTime = 0
        isPlaying = false
    }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to time: TimeInterval) { currentTime = time }
    func stop() { isPlaying = false; currentTime = 0 }
}
