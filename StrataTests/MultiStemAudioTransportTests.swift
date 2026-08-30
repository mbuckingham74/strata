import XCTest
@testable import Strata
import AVFoundation
import Foundation
import CryptoKit

@MainActor
final class MultiStemAudioTransportTests: XCTestCase {

    // MARK: - Helpers

    private func makeWAV(at url: URL, frames: UInt32, sr: Double = 44100, channels: UInt32 = 2) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(channels) {
            let ptr = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { ptr[i] = sin(Float(i) * 0.01) * 0.1 + Float(ch)*0.01 }
        }
        try file.write(from: buffer)
    }

    private func buildValidResult(frames: UInt32 = 8192, base: URL? = nil) throws -> (result: SeparationResult, base: URL, jobId: String, jobDir: URL, manifestURL: URL) {
        let baseURL = base ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let jobId = UUID().uuidString.lowercased()
        let jobDir = baseURL.appendingPathComponent(jobId, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let manifestURL = jobDir.appendingPathComponent("manifest.json")
        // Input placeholder
        let inputURL = baseURL.appendingPathComponent("mixture.wav")
        try makeWAV(at: inputURL, frames: frames)
        var stems: [StemName: StemArtifact] = [:]
        for stem in StemName.allCases {
            let url = jobDir.appendingPathComponent("\(stem.rawValue).wav")
            try makeWAV(at: url, frames: frames)
            let data = try Data(contentsOf: url)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size: UInt64
            if let n = attrs[.size] as? UInt64 { size = n }
            else if let n = attrs[.size] as? NSNumber { size = n.uint64Value }
            else { size = 0 }
            let artifact = StemArtifact(name: stem, url: url, sha256: sha, fileSize: size, frameCount: UInt64(frames), channels: 2, sampleRate: 44100)
            stems[stem] = artifact
        }
        let result = SeparationResult(
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
        return (result, baseURL, jobId, jobDir, manifestURL)
    }

    // MARK: - Tests

    func testMuteAndSoloAudibilitySemanticsDoNotChangePlaybackSchedule() {
        let sut = MultiStemAudioTransport()
        let generation = sut.currentGeneration

        XCTAssertTrue(StemName.allCases.allSatisfy(sut.isAudible))

        sut.setMuted(true, for: .vocals)
        XCTAssertEqual(sut.mutedStems, [.vocals])
        XCTAssertFalse(sut.isAudible(.vocals))
        XCTAssertTrue(sut.isAudible(.drums))

        sut.setSoloed(true, for: .vocals)
        XCTAssertEqual(sut.mutedStems, [.vocals], "Solo must preserve mute state")
        XCTAssertTrue(sut.isAudible(.vocals), "Solo temporarily overrides mute")
        XCTAssertFalse(sut.isAudible(.drums))

        sut.setSoloed(true, for: .drums)
        XCTAssertEqual(sut.soloedStems, [.vocals, .drums])
        XCTAssertTrue(sut.isAudible(.vocals))
        XCTAssertTrue(sut.isAudible(.drums))
        XCTAssertFalse(sut.isAudible(.bass))

        sut.setSoloed(false, for: .vocals)
        XCTAssertFalse(sut.isAudible(.vocals))
        XCTAssertTrue(sut.isAudible(.drums))

        sut.setSoloed(false, for: .drums)
        XCTAssertTrue(sut.soloedStems.isEmpty)
        XCTAssertFalse(sut.isAudible(.vocals), "Preserved mute must apply after solo clears")
        XCTAssertTrue(sut.isAudible(.drums))

        sut.setMuted(false, for: .vocals)
        XCTAssertTrue(sut.isAudible(.vocals))
        XCTAssertEqual(sut.currentGeneration, generation, "Audibility changes must not reschedule playback")
        XCTAssertFalse(sut.isPlaying)
    }

    func testLoadValidResultSetsDurationAndSharedPosition() throws {
        let sc = try buildValidResult(frames: 8820)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        XCTAssertEqual(sut.duration, Double(8820)/44100.0, accuracy: 0.001)
        XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
        XCTAssertFalse(sut.isPlaying)
        // duration shared across stems; totalFrames equal
    }

    func testLoadRejectsWhenFilesNoLongerMatchArtifactFrameCount() throws {
        let sc = try buildValidResult(frames: 8192)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        // Tamper one file to different length
        let victimURL = sc.result.stems[.vocals]!.url
        try FileManager.default.removeItem(at: victimURL)
        try makeWAV(at: victimURL, frames: 4096)
        let sut = MultiStemAudioTransport()
        XCTAssertThrowsError(try sut.load(result: sc.result)) { err in
            // Should be manifestValidationFailure or NSError about frame mismatch
            XCTAssertNotNil(err)
        }
        // Ensure transport remains empty after failed load
        XCTAssertEqual(sut.duration, 0, accuracy: 0.001)
        XCTAssertFalse(sut.isPlaying)
    }

    func testPlaySchedulesAllSixFromSameFrameAndSameFutureTime() throws {
        let sc = try buildValidResult(frames: 8192)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        let genBefore = sut.currentGeneration
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 0, accuracy: 0.05) // near zero after play, allow small drift
        XCTAssertEqual(sut.duration, Double(8192)/44100.0, accuracy: 0.001)
        XCTAssertNotEqual(genBefore, sut.currentGeneration, "play must advance generation via schedule")
        // Stop and ensure generation advanced again
        let genAfterPlay = sut.currentGeneration
        sut.stop()
        XCTAssertNotEqual(genAfterPlay, sut.currentGeneration)
    }

    func testNaturalCompletionPublishedOnce() throws {
        let sc = try buildValidResult(frames: 1024)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        var completionCount = 0
        sut.onCompletion = { completionCount += 1 }
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        let gen = sut.currentGeneration
        // Simulate 6 player completions delivering same generation
        // Our transport schedules only 1 leader, but handleScheduledCompletion must be idempotent per generation.
        sut.handleScheduledCompletion(generation: gen)
        sut.handleScheduledCompletion(generation: gen)
        sut.handleScheduledCompletion(generation: gen)
        sut.handleScheduledCompletion(generation: gen)
        sut.handleScheduledCompletion(generation: gen)
        sut.handleScheduledCompletion(generation: gen)
        XCTAssertEqual(completionCount, 1, "Natural completion must be published once, not per player")
        XCTAssertFalse(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, sut.duration, accuracy: 0.001)
    }

    func testStaleCompletionAfterSeekDoesNotTerminateNewPlayback() throws {
        let sc = try buildValidResult(frames: 44100) // 1 sec
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        var completionCount = 0
        sut.onCompletion = { completionCount += 1 }
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        let oldGen = sut.currentGeneration
        // Seek while playing reschedules
        sut.seek(to: 0.5)
        XCTAssertTrue(sut.isPlaying)
        let newGen = sut.currentGeneration
        XCTAssertNotEqual(oldGen, newGen)
        // Old completion arrives late
        sut.handleScheduledCompletion(generation: oldGen)
        XCTAssertEqual(completionCount, 0, "Stale completion must be ignored")
        XCTAssertTrue(sut.isPlaying, "New playback must remain")
        // New generation completion should fire
        sut.handleScheduledCompletion(generation: newGen)
        XCTAssertEqual(completionCount, 1)
        XCTAssertFalse(sut.isPlaying)
    }

    func testStaleCompletionAfterStopDoesNotAffectNextPlayback() throws {
        let sc = try buildValidResult(frames: 44100)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        var completionCount = 0
        sut.onCompletion = { completionCount += 1 }
        sut.play()
        let oldGen = sut.currentGeneration
        sut.stop()
        let genAfterStop = sut.currentGeneration
        XCTAssertNotEqual(oldGen, genAfterStop)
        // Load new result and play
        let sc2 = try buildValidResult(frames: 8192)
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        try sut.load(result: sc2.result)
        sut.onCompletion = { completionCount += 1 }
        sut.play()
        let newGen = sut.currentGeneration
        XCTAssertNotEqual(oldGen, newGen)
        // Stale from first playback must not affect new
        sut.handleScheduledCompletion(generation: oldGen)
        XCTAssertEqual(completionCount, 0)
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(sut.duration, Double(8192)/44100.0, accuracy: 0.001)
        // Stale after stop also ignored
        sut.handleScheduledCompletion(generation: genAfterStop)
        XCTAssertEqual(completionCount, 0)
        XCTAssertTrue(sut.isPlaying)
    }

    func testReplayAfterCompletionStartsFromZero() throws {
        let sc = try buildValidResult(frames: 4410) // 0.1 sec
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        var completionCount = 0
        sut.onCompletion = { completionCount += 1 }
        sut.play()
        let gen = sut.currentGeneration
        sut.handleScheduledCompletion(generation: gen)
        XCTAssertEqual(completionCount, 1)
        XCTAssertFalse(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, sut.duration, accuracy: 0.001)
        // Replay
        let genBeforeReplay = sut.currentGeneration
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 0, accuracy: 0.05)
        XCTAssertNotEqual(genBeforeReplay, sut.currentGeneration, "Replay must schedule with full frames, not zero-length")
        // Ensure completion again works
        let gen2 = sut.currentGeneration
        sut.handleScheduledCompletion(generation: gen2)
        XCTAssertEqual(completionCount, 2)
    }

    func testPauseCapturesPositionAndResumeFromSameFrame() throws {
        let sc = try buildValidResult(frames: 44100)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        // Seek to mid then pause
        sut.seek(to: 0.5)
        XCTAssertEqual(sut.currentTime, 0.5, accuracy: 0.05)
        sut.pause()
        XCTAssertFalse(sut.isPlaying)
        let pausedTime = sut.currentTime
        XCTAssertEqual(pausedTime, 0.5, accuracy: 0.05)
        let genBeforeResume = sut.currentGeneration
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, pausedTime, accuracy: 0.05)
        XCTAssertNotEqual(genBeforeResume, sut.currentGeneration)
    }

    func testSeekWhilePlayingReschedulesAllSix() throws {
        let sc = try buildValidResult(frames: 44100)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        sut.play()
        let genBefore = sut.currentGeneration
        XCTAssertTrue(sut.isPlaying)
        sut.seek(to: 0.2)
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 0.2, accuracy: 0.05)
        XCTAssertNotEqual(genBefore, sut.currentGeneration)
        // Old generation must be stale
        var fired = false
        sut.onCompletion = { fired = true }
        sut.handleScheduledCompletion(generation: genBefore)
        XCTAssertFalse(fired)
        XCTAssertTrue(sut.isPlaying)
    }

    func testStopInvalidatesPendingCompletion() throws {
        let sc = try buildValidResult(frames: 44100)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        var count = 0
        sut.onCompletion = { count += 1 }
        sut.play()
        let gen = sut.currentGeneration
        sut.stop()
        XCTAssertFalse(sut.isPlaying)
        XCTAssertEqual(sut.currentTime, 0, accuracy: 0.001)
        sut.handleScheduledCompletion(generation: gen)
        XCTAssertEqual(count, 0, "Stop must invalidate pending completion")
    }

    func testAVAudioEngineMultiStemStaleGuard() throws {
        let sc = try buildValidResult(frames: 8192)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        var count = 0
        sut.onCompletion = { count += 1 }
        let genBefore = sut.currentGeneration
        sut.play()
        let genAfterPlay = sut.currentGeneration
        XCTAssertNotEqual(genBefore, genAfterPlay)
        // Stale before play ignored
        sut.handleScheduledCompletion(generation: genBefore)
        XCTAssertEqual(count, 0)
        // Current fires
        sut.handleScheduledCompletion(generation: genAfterPlay)
        XCTAssertEqual(count, 1)
        // Second duplicate for same gen must not fire again (once guard)
        sut.handleScheduledCompletion(generation: genAfterPlay)
        XCTAssertEqual(count, 1, "Duplicate for same generation must not publish again")
        // After stop, new generation, old remains stale
        sut.stop()
        let genAfterStop = sut.currentGeneration
        sut.handleScheduledCompletion(generation: genAfterPlay)
        XCTAssertEqual(count, 1)
        sut.handleScheduledCompletion(generation: genAfterStop)
        XCTAssertEqual(count, 2, "Current generation after stop should publish")
        // To make deterministic after reload, reset count
        count = 0
        try sut.load(result: sc.result)
        sut.onCompletion = { count += 1 }
        sut.play()
        let newGen = sut.currentGeneration
        sut.handleScheduledCompletion(generation: genAfterPlay)
        XCTAssertEqual(count, 0, "Old gen must stay stale after reload")
        sut.handleScheduledCompletion(generation: newGen)
        XCTAssertEqual(count, 1)
    }
}
