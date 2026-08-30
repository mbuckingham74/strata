import XCTest
@testable import Strata
import Foundation

// MARK: - Fake Stem Transport

@MainActor
final class FakeStemTransport: StemAudioTransport {
    var duration: TimeInterval
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var onCompletion: (() -> Void)?

    var loadCallCount = 0
    var lastLoadedResult: SeparationResult?
    var shouldThrowOnLoad = false
    var loadError: Error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake load failure"])

    var playCallCount = 0
    var pauseCallCount = 0
    var seekCallCount = 0
    var lastSeekTime: TimeInterval?
    var stopCallCount = 0

    private(set) var scheduleGeneration: UInt64 = 0
    private var activeGeneration: UInt64 = 0
    var lastScheduledFramesToPlay: TimeInterval?
    var didScheduleZeroLength: Bool = false

    private var scheduledCompletions: [UInt64: () -> Void] = [:]

    var currentGeneration: UInt64 { scheduleGeneration }
    var activeGen: UInt64 { activeGeneration }

    init(duration: TimeInterval = 120) {
        self.duration = duration
    }

    private func storeCompletion(for generation: UInt64) {
        scheduledCompletions[generation] = { [weak self] in
            guard let self else { return }
            guard self.scheduleGeneration == generation, self.activeGeneration == generation else { return }
            self.isPlaying = false
            self.currentTime = self.duration
            self.activeGeneration = 0
            self.onCompletion?()
        }
    }

    func load(result: SeparationResult) throws {
        loadCallCount += 1
        lastLoadedResult = result
        if shouldThrowOnLoad {
            throw loadError
        }
        scheduleGeneration &+= 1
        activeGeneration = 0
        currentTime = 0
        isPlaying = false
        lastScheduledFramesToPlay = nil
        didScheduleZeroLength = false
    }

    func play() {
        playCallCount += 1
        if currentTime >= duration {
            currentTime = 0
        }
        if !isPlaying {
            scheduleGeneration &+= 1
            activeGeneration = scheduleGeneration
            let framesToPlay = duration - currentTime
            lastScheduledFramesToPlay = framesToPlay
            didScheduleZeroLength = framesToPlay <= 0
            storeCompletion(for: activeGeneration)
        }
        isPlaying = true
    }

    func pause() {
        pauseCallCount += 1
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        seekCallCount += 1
        lastSeekTime = time
        let wasPlaying = isPlaying
        scheduleGeneration &+= 1
        currentTime = time
        isPlaying = false
        if wasPlaying {
            if currentTime >= duration {
                currentTime = duration
                activeGeneration = 0
                lastScheduledFramesToPlay = 0
                didScheduleZeroLength = false
                return
            }
            scheduleGeneration &+= 1
            activeGeneration = scheduleGeneration
            let framesToPlay = duration - currentTime
            lastScheduledFramesToPlay = framesToPlay
            didScheduleZeroLength = framesToPlay <= 0
            isPlaying = true
            storeCompletion(for: activeGeneration)
        } else {
            if currentTime >= duration {
                activeGeneration = 0
                lastScheduledFramesToPlay = nil
                return
            }
            activeGeneration = 0
            lastScheduledFramesToPlay = nil
            didScheduleZeroLength = false
        }
    }

    func stop() {
        stopCallCount += 1
        scheduleGeneration &+= 1
        isPlaying = false
        currentTime = 0
        activeGeneration = 0
        lastScheduledFramesToPlay = nil
        didScheduleZeroLength = false
    }

    func triggerCompletion() {
        guard activeGeneration != 0 else { return }
        guard let completion = scheduledCompletions[activeGeneration] else { return }
        completion()
    }

    func triggerStaleCompletion(generation: UInt64) {
        guard let completion = scheduledCompletions[generation] else {
            return
        }
        completion()
    }

    func completionHandler(for generation: UInt64) -> (() -> Void)? {
        scheduledCompletions[generation]
    }

    func fireCompletion(for generation: UInt64) {
        triggerStaleCompletion(generation: generation)
    }
}

// MARK: - Dummy Result Helpers

@MainActor
private func makeDummyResult(
    jobId: String = "test-job-1",
    inputPath: String = "/tmp/My Song - Demo.m4a"
) -> SeparationResult {
    let inputURL = URL(fileURLWithPath: inputPath)
    let jobDir = URL(fileURLWithPath: "/tmp/jobs/\(jobId)")
    let manifestURL = jobDir.appendingPathComponent("manifest.json")
    var stems: [StemName: StemArtifact] = [:]
    for stem in StemName.allCases {
        let url = jobDir.appendingPathComponent("\(stem.rawValue).wav")
        let artifact = StemArtifact(
            name: stem,
            url: url,
            sha256: String(repeating: "a", count: 64),
            fileSize: 1234,
            frameCount: 120 * 44100,
            channels: 2,
            sampleRate: 44100
        )
        stems[stem] = artifact
    }
    return SeparationResult(
        jobId: jobId,
        inputURL: inputURL,
        jobDirectoryURL: jobDir,
        manifestURL: manifestURL,
        stems: stems,
        backend: TrustedInferenceIdentity.backend,
        device: TrustedInferenceIdentity.device,
        checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256,
        model: TrustedInferenceIdentity.model
    )
}

// MARK: - Tests

@MainActor
final class StemPlaybackControllerTests: XCTestCase {

    // 1. Empty initial state
    func testEmptyInitialState() {
        let fake = FakeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        XCTAssertNil(sut.result)
        XCTAssertNil(sut.title)
        XCTAssertEqual(sut.duration, 0, accuracy: 0.001)
        XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
        XCTAssertFalse(sut.isPlaying)
        XCTAssertFalse(sut.hasStems)
        XCTAssertNil(sut.errorMessage)
    }

    // 2. Loading sets title and duration
    func testLoadingSetsTitleAndDuration() {
        let fake = FakeStemTransport(duration: 187)
        let sut = StemPlaybackController(transport: fake)
        let result = makeDummyResult(jobId: "job-42", inputPath: "/tmp/My Song - Demo.m4a")
        sut.load(result: result)
        XCTAssertEqual(sut.title, "My Song - Demo")
        XCTAssertEqual(sut.duration, 187, accuracy: 0.001)
        XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(fake.loadCallCount, 1)
        XCTAssertEqual(fake.lastLoadedResult?.jobId, "job-42")
        XCTAssertNil(sut.errorMessage)
        XCTAssertTrue(sut.hasStems)
        XCTAssertNotNil(sut.result)
    }

    func testLoadingClearsError() {
        let fake = FakeStemTransport(duration: 100)
        fake.shouldThrowOnLoad = true
        let sut = StemPlaybackController(transport: fake)
        let bad = makeDummyResult(jobId: "bad-job")
        sut.load(result: bad)
        XCTAssertNotNil(sut.errorMessage)
        fake.shouldThrowOnLoad = false
        let good = makeDummyResult(jobId: "good-job", inputPath: "/tmp/good.wav")
        sut.load(result: good)
        XCTAssertNil(sut.errorMessage)
        XCTAssertEqual(sut.title, "good")
    }

    // 3. Play updates state
    func testPlayUpdatesStateAndInvokesTransport() {
        let fake = FakeStemTransport(duration: 120)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        XCTAssertFalse(sut.isPlaying)
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(fake.playCallCount, 1)
        XCTAssertEqual(sut.currentTime, fake.currentTime, accuracy: 0.001)
    }

    func testPlayWithoutStemsDoesNothing() {
        let fake = FakeStemTransport(duration: 120)
        let sut = StemPlaybackController(transport: fake)
        sut.play()
        XCTAssertEqual(fake.playCallCount, 0)
        XCTAssertFalse(sut.isPlaying)
    }

    // 4. Pause updates state
    func testPauseUpdatesStateAndInvokesTransport() {
        let fake = FakeStemTransport(duration: 120)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        fake.currentTime = 42
        sut.pause()
        XCTAssertFalse(sut.isPlaying)
        XCTAssertEqual(fake.pauseCallCount, 1)
        XCTAssertEqual(sut.currentTime, 42, accuracy: 0.001)
    }

    // 5. Seeking clamps
    func testSeekingClampsAndInvokesTransport() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())

        sut.seek(to: -10)
        XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(fake.lastSeekTime, 0)
        XCTAssertEqual(fake.seekCallCount, 1)

        sut.seek(to: 999)
        XCTAssertEqual(sut.currentTime, 100, accuracy: 0.001)
        XCTAssertEqual(fake.lastSeekTime, 100)
        XCTAssertEqual(fake.seekCallCount, 2)

        sut.seek(to: 42.5)
        XCTAssertEqual(sut.currentTime, 42.5, accuracy: 0.001)
        XCTAssertEqual(fake.lastSeekTime, 42.5)
    }

    func testSeekWithoutStemsDoesNothing() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        sut.seek(to: 10)
        XCTAssertEqual(fake.seekCallCount, 0)
        XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
    }

    // 6. Completion resets playing state
    func testPlaybackCompletionResetsPlayingState() {
        let fake = FakeStemTransport(duration: 60)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        sut.handleCompletion()
        XCTAssertFalse(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 60, accuracy: 0.001)

        // via transport onCompletion Task hop
        let fake2 = FakeStemTransport(duration: 60)
        let sut2 = StemPlaybackController(transport: fake2)
        sut2.load(result: makeDummyResult(jobId: "job2"))
        sut2.play()
        XCTAssertTrue(sut2.isPlaying)
        fake2.triggerCompletion()
        let exp = expectation(description: "completion")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertFalse(sut2.isPlaying)
            XCTAssertEqual(sut2.currentTime, 60, accuracy: 0.001)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // 7. Replacing result stops prior session
    func testReplacingResultStopsPriorSession() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        let first = makeDummyResult(jobId: "first", inputPath: "/tmp/first.wav")
        let second = makeDummyResult(jobId: "second", inputPath: "/tmp/second.wav")

        sut.load(result: first)
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(fake.stopCallCount, 0, "First load has no prior session to stop")

        sut.load(result: second)
        XCTAssertEqual(fake.stopCallCount, 1, "Replacing result must stop prior session")
        XCTAssertEqual(sut.title, "second")
        XCTAssertFalse(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(fake.lastLoadedResult?.jobId, "second")
    }

    // 7b. Unreadable/invalid load produces recoverable error
    func testUnreadableLoadProducesRecoverableError() {
        let fake = FakeStemTransport(duration: 100)
        fake.shouldThrowOnLoad = true
        let sut = StemPlaybackController(transport: fake)
        let first = makeDummyResult(jobId: "first", inputPath: "/tmp/first.wav")
        sut.load(result: first)
        XCTAssertNotNil(sut.errorMessage)
        XCTAssertTrue(sut.errorMessage!.contains("first"))
        XCTAssertNil(sut.result)
        XCTAssertNil(sut.title)
        XCTAssertFalse(sut.isPlaying)
        XCTAssertFalse(sut.hasStems)
        XCTAssertEqual(sut.duration, 0, accuracy: 0.001)
        // Recovery
        fake.shouldThrowOnLoad = false
        let second = makeDummyResult(jobId: "second", inputPath: "/tmp/good.wav")
        sut.load(result: second)
        XCTAssertNil(sut.errorMessage)
        XCTAssertNotNil(sut.result)
        XCTAssertEqual(sut.title, "good")
        XCTAssertTrue(sut.hasStems)
    }

    func testLoadErrorMessageIsConcise() {
        let fake = FakeStemTransport(duration: 100)
        fake.shouldThrowOnLoad = true
        fake.loadError = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake load failure"])
        let sut = StemPlaybackController(transport: fake)
        let result = makeDummyResult(jobId: "my-job-id")
        sut.load(result: result)
        XCTAssertEqual(sut.errorMessage, "Couldn’t load stems for \"my-job-id\". fake load failure")
    }

    func testLoadWithEmptyInputURLUsesJobIdAsTitle() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        let result = makeDummyResult(jobId: "fallback-job", inputPath: "/")
        sut.load(result: result)
        XCTAssertEqual(sut.title, "fallback-job")
    }

    // 8. Time formatting
    func testTimeFormattingZero() {
        XCTAssertEqual(StemPlaybackController.formattedTime(0), "0:00")
        let sut = StemPlaybackController(transport: FakeStemTransport())
        XCTAssertEqual(sut.formattedTime(0), "0:00")
    }

    func testTimeFormattingOrdinaryDuration() {
        XCTAssertEqual(StemPlaybackController.formattedTime(65), "1:05")
        XCTAssertEqual(StemPlaybackController.formattedTime(125), "2:05")
        XCTAssertEqual(StemPlaybackController.formattedTime(3599), "59:59")
    }

    func testTimeFormattingAtLeastOneHour() {
        XCTAssertEqual(StemPlaybackController.formattedTime(3600), "1:00:00")
        XCTAssertEqual(StemPlaybackController.formattedTime(3661), "1:01:01")
        XCTAssertEqual(StemPlaybackController.formattedTime(7322), "2:02:02")
    }

    func testTimeFormattingRoundingAndClamping() {
        XCTAssertEqual(StemPlaybackController.formattedTime(0.4), "0:00")
        XCTAssertEqual(StemPlaybackController.formattedTime(0.6), "0:01")
    }

    // MARK: - Stale completion guards

    func testStaleCompletionAfterSeekDoesNotTerminateNewPlayback() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        let oldGeneration = fake.currentGeneration
        let oldCompletion = fake.completionHandler(for: oldGeneration)
        XCTAssertNotNil(oldCompletion)
        sut.seek(to: 30)
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 30, accuracy: 0.001)
        let newGeneration = fake.currentGeneration
        XCTAssertNotEqual(oldGeneration, newGeneration)
        XCTAssertNotNil(fake.completionHandler(for: newGeneration))
        if let old = oldCompletion {
            old()
        } else {
            fake.triggerStaleCompletion(generation: oldGeneration)
        }
        let exp = expectation(description: "stale completion ignored")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(sut.isPlaying)
            XCTAssertEqual(sut.currentTime, 30, accuracy: 0.001)
            XCTAssertEqual(fake.activeGen, newGeneration)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testStaleCompletionAfterReplacementDoesNotTerminateNewPlayback() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        let first = makeDummyResult(jobId: "first", inputPath: "/tmp/first.wav")
        let second = makeDummyResult(jobId: "second", inputPath: "/tmp/second.wav")

        sut.load(result: first)
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        let oldGeneration = fake.currentGeneration
        let oldCompletion = fake.completionHandler(for: oldGeneration)
        XCTAssertNotNil(oldCompletion)

        sut.load(result: second)
        XCTAssertFalse(sut.isPlaying)
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        let newGeneration = fake.currentGeneration
        XCTAssertNotEqual(oldGeneration, newGeneration)

        if let old = oldCompletion {
            old()
        } else {
            fake.triggerStaleCompletion(generation: oldGeneration)
        }
        let exp = expectation(description: "stale replacement")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(sut.isPlaying)
            XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
            XCTAssertEqual(sut.title, "second")
            XCTAssertEqual(fake.activeGen, newGeneration)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testStaleCompletionAfterStopDoesNotAffectNextPlayback() {
        let fake = FakeStemTransport(duration: 120)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        let oldGen = fake.currentGeneration
        let oldCompletion = fake.completionHandler(for: oldGen)
        XCTAssertNotNil(oldCompletion)
        sut.pause()
        sut.seek(to: 10)
        fake.stop()
        let invalidatedGen = fake.currentGeneration
        XCTAssertNotEqual(oldGen, invalidatedGen)
        sut.load(result: makeDummyResult(jobId: "second", inputPath: "/tmp/track2.wav"))
        sut.play()
        let newGen = fake.currentGeneration
        XCTAssertNotEqual(oldGen, newGen)
        if let old = oldCompletion {
            old()
        } else {
            fake.triggerStaleCompletion(generation: oldGen)
        }
        let exp = expectation(description: "stale after stop")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertTrue(sut.isPlaying)
            XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
            XCTAssertEqual(sut.title, "track2")
            XCTAssertEqual(fake.activeGen, newGen)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testStaleCompletionViaHelperDoesNotPreFilter() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.play()
        let oldGen = fake.currentGeneration
        sut.seek(to: 20)
        let newGen = fake.currentGeneration
        XCTAssertNotEqual(oldGen, newGen)
        fake.triggerStaleCompletion(generation: oldGen)
        let exp = expectation(description: "helper stale")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(sut.isPlaying)
            XCTAssertEqual(sut.currentTime, 20, accuracy: 0.001)
            XCTAssertEqual(fake.activeGen, newGen)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Replay after natural completion

    func testReplayAfterNaturalCompletionRestartsFromZero() {
        let fake = FakeStemTransport(duration: 60)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        fake.triggerCompletion()
        let exp1 = expectation(description: "natural completion")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertFalse(sut.isPlaying)
            XCTAssertEqual(sut.currentTime, 60, accuracy: 0.001)
            XCTAssertEqual(fake.currentTime, 60, accuracy: 0.001)
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)

        sut.play()
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(fake.currentTime, 0, accuracy: 0.001)
        XCTAssertFalse(fake.didScheduleZeroLength)
        XCTAssertNotNil(fake.lastScheduledFramesToPlay)
        XCTAssertEqual(fake.lastScheduledFramesToPlay!, 60, accuracy: 0.001)
        XCTAssertEqual(fake.playCallCount, 2)

        let exp2 = expectation(description: "replay stable")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(sut.isPlaying)
            XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)
    }

    func testPauseNearEndDoesNotResetToZeroOnResume() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.play()
        sut.seek(to: 95)
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 95, accuracy: 0.001)
        fake.currentTime = 95
        sut.pause()
        XCTAssertFalse(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 95, accuracy: 0.001)
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 95, accuracy: 0.001)
        XCTAssertFalse(fake.didScheduleZeroLength)
        XCTAssertEqual(fake.lastScheduledFramesToPlay ?? -1, 5, accuracy: 0.001)
    }

    // MARK: - Stop semantics

    func testStopDoesNotClearResult() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        let result = makeDummyResult()
        sut.load(result: result)
        sut.play()
        XCTAssertTrue(sut.hasStems)
        sut.stopSession()
        XCTAssertTrue(sut.hasStems)
        XCTAssertNotNil(sut.result)
        XCTAssertEqual(sut.title, "My Song - Demo")
        XCTAssertFalse(sut.isPlaying)
        XCTAssertEqual(fake.stopCallCount, 1)
    }

    // MARK: - Production seam: MultiStemAudioTransport generation guard

    func testMultiStemAudioTransportStaleGuard() {
        let transport = MultiStemAudioTransport()
        var completionCount = 0
        transport.onCompletion = { completionCount += 1 }
        let genBefore = transport.currentGeneration
        transport.stop()
        let genAfterStop = transport.currentGeneration
        XCTAssertNotEqual(genBefore, genAfterStop)
        transport.handleScheduledCompletion(generation: genBefore)
        XCTAssertEqual(completionCount, 0, "Stale generation must not trigger completion")
        transport.handleScheduledCompletion(generation: genAfterStop)
        XCTAssertEqual(completionCount, 1)
        transport.stop()
        let newGen = transport.currentGeneration
        transport.handleScheduledCompletion(generation: genAfterStop)
        XCTAssertEqual(completionCount, 1)
        transport.handleScheduledCompletion(generation: newGen)
        XCTAssertEqual(completionCount, 2)
    }

    func testQueuedCompletionFromOldSessionIsIgnoredAfterReplacement() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        let first = makeDummyResult(jobId: "first", inputPath: "/tmp/first.wav")
        let second = makeDummyResult(jobId: "second", inputPath: "/tmp/second.wav")
        sut.load(result: first)
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        // Trigger valid completion which queues controller Task
        fake.triggerCompletion()
        // Before queued Task executes, replace session
        sut.load(result: second)
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 0)
        let exp = expectation(description: "queued old completion ignored")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(sut.isPlaying, "Stale queued completion must not stop new session")
            XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
            XCTAssertEqual(sut.title, "second")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testQueuedCompletionIsIgnoredAfterSeekWithinSameSession() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        fake.triggerCompletion() // queues controller Task
        sut.seek(to: 30) // should invalidate queued completion
        XCTAssertEqual(sut.currentTime, 30, accuracy: 0.001)
        XCTAssertFalse(sut.isPlaying)
        XCTAssertEqual(sut.isPlaying, fake.isPlaying)
        let exp = expectation(description: "queued completion ignored after seek")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertFalse(sut.isPlaying)
            XCTAssertEqual(sut.isPlaying, fake.isPlaying)
            XCTAssertEqual(sut.currentTime, 30, accuracy: 0.001)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testQueuedCompletionIsIgnoredAfterImmediateReplay() {
        let fake = FakeStemTransport(duration: 60)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        fake.triggerCompletion() // queues controller Task
        sut.play() // immediate replay should invalidate queued completion
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
        let exp = expectation(description: "queued completion ignored after replay")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(sut.isPlaying, "Stale queued completion must not stop replayed session")
            XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
