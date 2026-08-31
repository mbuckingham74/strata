import XCTest
@testable import Strata
import AVFoundation
import Foundation
import CryptoKit

// Uses FakeStemTransport defined in StemPlaybackControllerTests.swift

@MainActor
final class StemGainTests: XCTestCase {

    // MARK: - Helpers

    private func makeDummyResult(jobId: String = "gain-job", inputPath: String = "/tmp/gain.wav") -> SeparationResult {
        let inputURL = URL(fileURLWithPath: inputPath)
        let jobDir = URL(fileURLWithPath: "/tmp/jobs/\(jobId)")
        let manifestURL = jobDir.appendingPathComponent("manifest.json")
        var stems: [StemName: StemArtifact] = [:]
        for stem in StemName.allCases {
            let url = jobDir.appendingPathComponent("\(stem.rawValue).wav")
            stems[stem] = StemArtifact(name: stem, url: url, sha256: String(repeating: "b", count: 64), fileSize: 1234, frameCount: 120*44100, channels: 2, sampleRate: 44100)
        }
        return SeparationResult(jobId: jobId, inputURL: inputURL, jobDirectoryURL: jobDir, manifestURL: manifestURL, stems: stems, backend: TrustedInferenceIdentity.backend, device: TrustedInferenceIdentity.device, checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256, model: TrustedInferenceIdentity.model)
    }

    private func makeWAV(at url: URL, frames: UInt32) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(2) { let ptr = buffer.floatChannelData![ch]; for i in 0..<Int(frames) { ptr[i] = 0.1 } }
        try file.write(from: buffer)
    }

    private func buildValidResult(frames: UInt32 = 8192, base: URL? = nil) throws -> (result: SeparationResult, base: URL) {
        let baseURL = base ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let jobId = UUID().uuidString.lowercased()
        let jobDir = baseURL.appendingPathComponent(jobId, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let manifestURL = jobDir.appendingPathComponent("manifest.json")
        let inputURL = baseURL.appendingPathComponent("mixture.wav")
        try makeWAV(at: inputURL, frames: frames)
        var stems: [StemName: StemArtifact] = [:]
        for stem in StemName.allCases {
            let url = jobDir.appendingPathComponent("\(stem.rawValue).wav")
            try makeWAV(at: url, frames: frames)
            let data = try Data(contentsOf: url)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size: UInt64 = (attrs[.size] as? UInt64) ?? (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            stems[stem] = StemArtifact(name: stem, url: url, sha256: sha, fileSize: size, frameCount: UInt64(frames), channels: 2, sampleRate: 44100)
        }
        let result = SeparationResult(jobId: jobId, inputURL: inputURL, jobDirectoryURL: jobDir, manifestURL: manifestURL, stems: stems, backend: TrustedInferenceIdentity.backend, device: TrustedInferenceIdentity.device, checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256, model: TrustedInferenceIdentity.model)
        return (result, baseURL)
    }

    // MARK: - Controller: default 100% after load

    func testControllerDefaultGainIs100AfterLoad() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        for stem in StemName.allCases {
            XCTAssertEqual(sut.gain(for: stem), 1.0, accuracy: 0.001)
            XCTAssertEqual(sut.gainPercent(for: stem), 100, accuracy: 0.001)
            XCTAssertEqual(fake.gain(for: stem), 1.0, accuracy: 0.001)
            XCTAssertEqual(sut.stemGains[stem], 1.0, "stemGains dict should contain 1.0 after load")
        }
    }

    func testTransportDefaultGainIs100AfterLoad() throws {
        let sc = try buildValidResult()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        for stem in StemName.allCases {
            XCTAssertEqual(sut.gain(for: stem), 1.0, accuracy: 0.001)
            XCTAssertEqual(sut.gainPercent(for: stem), 100, accuracy: 0.001)
            XCTAssertEqual(sut.stemGains[stem], 1.0)
            XCTAssertEqual(sut.effectiveVolume(for: stem), 1.0, accuracy: 0.001)
        }
    }

    // MARK: - 0% silence

    func testZeroPercentIsSilentEvenWhenAudible() {
        let fake = FakeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.setGainPercent(0, for: .vocals)
        XCTAssertEqual(sut.gain(for: .vocals), 0, accuracy: 0.001)
        XCTAssertEqual(fake.gain(for: .vocals), 0, accuracy: 0.001)
        XCTAssertEqual(fake.effectiveVolume(for: .vocals), 0, accuracy: 0.001, "0% gain must be silent even when audible")
        XCTAssertTrue(fake.mutedStems.isEmpty)
    }

    func testTransportZeroGainEffectiveVolumeZero() throws {
        let sc = try buildValidResult()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        sut.setGainPercent(0, for: .drums)
        XCTAssertEqual(sut.gain(for: .drums), 0, accuracy: 0.001)
        XCTAssertEqual(sut.effectiveVolume(for: .drums), 0, accuracy: 0.001)
    }

    // MARK: - Intermediate gain 50%

    func testIntermediateGain50PercentMapsToHalf() {
        let fake = FakeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.setGainPercent(50, for: .bass)
        XCTAssertEqual(sut.gain(for: .bass), 0.5, accuracy: 0.001)
        XCTAssertEqual(sut.gainPercent(for: .bass), 50, accuracy: 0.001)
        XCTAssertEqual(fake.gain(for: .bass), 0.5, accuracy: 0.001)
        XCTAssertEqual(fake.effectiveVolume(for: .bass), 0.5, accuracy: 0.001)
    }

    func testTransportIntermediateGainClamping() throws {
        let sc = try buildValidResult()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        sut.setGain(0.33, for: .guitar)
        XCTAssertEqual(sut.gain(for: .guitar), 0.33, accuracy: 0.001)
        sut.setGainPercent(33, for: .guitar)
        XCTAssertEqual(sut.gain(for: .guitar), 0.33, accuracy: 0.001)
        sut.setGain(2.0, for: .other) // clamp to 1
        XCTAssertEqual(sut.gain(for: .other), 1.0, accuracy: 0.001)
        sut.setGain(-0.5, for: .vocals) // clamp to 0
        XCTAssertEqual(sut.gain(for: .vocals), 0, accuracy: 0.001)
        sut.setGainPercent(150, for: .piano)
        XCTAssertEqual(sut.gain(for: .piano), 1.0, accuracy: 0.001)
        sut.setGainPercent(-10, for: .piano)
        XCTAssertEqual(sut.gain(for: .piano), 0, accuracy: 0.001)
    }

    // MARK: - Live gain updates while playing

    func testLiveGainUpdatesWhilePlaying() throws {
        let sc = try buildValidResult(frames: 44100)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        sut.setGainPercent(40, for: .vocals)
        XCTAssertEqual(sut.effectiveVolume(for: .vocals), 0.4, accuracy: 0.001, "live gain must update volume immediately while playing")
        sut.setGainPercent(80, for: .vocals)
        XCTAssertEqual(sut.effectiveVolume(for: .vocals), 0.8, accuracy: 0.001)
    }

    func testControllerLiveGainDoesNotToggleMuteSolo() {
        let fake = FakeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.play()
        XCTAssertTrue(sut.isPlaying)
        sut.setGainPercent(40, for: .vocals)
        XCTAssertEqual(fake.effectiveVolume(for: .vocals), 0.4, accuracy: 0.001)
        XCTAssertTrue(fake.mutedStems.isEmpty)
        XCTAssertTrue(fake.soloedStems.isEmpty)
        XCTAssertTrue(sut.mutedStems.isEmpty)
        XCTAssertTrue(sut.soloedStems.isEmpty)
    }

    // MARK: - Gain survives play/pause/seek

    func testGainSurvivesPauseAndSeekController() {
        let fake = FakeStemTransport(duration: 100)
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.setGainPercent(30, for: .vocals)
        XCTAssertEqual(sut.gain(for: .vocals), 0.3, accuracy: 0.001)
        sut.play()
        sut.pause()
        XCTAssertEqual(sut.gain(for: .vocals), 0.3, accuracy: 0.001)
        XCTAssertEqual(fake.gain(for: .vocals), 0.3, accuracy: 0.001)
        XCTAssertEqual(fake.effectiveVolume(for: .vocals), 0.3, accuracy: 0.001)
        sut.play()
        XCTAssertEqual(sut.gain(for: .vocals), 0.3, accuracy: 0.001)
        sut.seek(to: 42)
        XCTAssertEqual(sut.gain(for: .vocals), 0.3, accuracy: 0.001)
        XCTAssertEqual(fake.effectiveVolume(for: .vocals), 0.3, accuracy: 0.001)
    }

    func testGainSurvivesPauseAndSeekTransport() throws {
        let sc = try buildValidResult(frames: 44100)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        sut.setGainPercent(30, for: .bass)
        sut.play()
        sut.pause()
        XCTAssertEqual(sut.gain(for: .bass), 0.3, accuracy: 0.001)
        XCTAssertEqual(sut.effectiveVolume(for: .bass), 0.3, accuracy: 0.001)
        sut.play()
        XCTAssertEqual(sut.gain(for: .bass), 0.3, accuracy: 0.001)
        sut.seek(to: 0.5)
        XCTAssertEqual(sut.gain(for: .bass), 0.3, accuracy: 0.001)
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(sut.effectiveVolume(for: .bass), 0.3, accuracy: 0.001)
    }

    // MARK: - Mute/solo preserve gain

    func testMutePreservesGainController() {
        let fake = FakeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.setGainPercent(40, for: .vocals)
        sut.setMuted(true, for: .vocals)
        XCTAssertEqual(sut.gain(for: .vocals), 0.4, accuracy: 0.001, "mute must not destroy gain")
        XCTAssertEqual(fake.gain(for: .vocals), 0.4, accuracy: 0.001)
        XCTAssertEqual(fake.effectiveVolume(for: .vocals), 0, accuracy: 0.001, "muted volume must be 0")
        sut.setMuted(false, for: .vocals)
        XCTAssertEqual(fake.effectiveVolume(for: .vocals), 0.4, accuracy: 0.001, "unmute must restore gain")
    }

    func testSoloPreservesGainAndOverridesMute() throws {
        let sc = try buildValidResult()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        sut.setGainPercent(40, for: .vocals)
        sut.setGainPercent(60, for: .drums)
        sut.setMuted(true, for: .vocals) // mute vocals
        XCTAssertEqual(sut.effectiveVolume(for: .vocals), 0, accuracy: 0.001)
        sut.setSoloed(true, for: .vocals) // solo overrides mute
        XCTAssertEqual(sut.effectiveVolume(for: .vocals), 0.4, accuracy: 0.001, "solo should override mute and restore gain")
        XCTAssertEqual(sut.effectiveVolume(for: .drums), 0, accuracy: 0.001, "non-soloed drums should be silent")
        XCTAssertEqual(sut.gain(for: .drums), 0.6, accuracy: 0.001, "gain preserved while soloed out")
        sut.setSoloed(false, for: .vocals)
        XCTAssertEqual(sut.effectiveVolume(for: .vocals), 0, accuracy: 0.001, "after solo cleared, preserved mute applies")
        XCTAssertEqual(sut.effectiveVolume(for: .drums), 0.6, accuracy: 0.001)
        sut.setMuted(false, for: .vocals)
        XCTAssertEqual(sut.effectiveVolume(for: .vocals), 0.4, accuracy: 0.001)
    }

    func testControllerSoloPreservesGain() {
        let fake = FakeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.setGainPercent(40, for: .vocals)
        sut.setGainPercent(60, for: .drums)
        sut.setSoloed(true, for: .vocals)
        XCTAssertEqual(sut.gain(for: .vocals), 0.4, accuracy: 0.001)
        XCTAssertEqual(fake.effectiveVolume(for: .vocals), 0.4, accuracy: 0.001)
        XCTAssertEqual(fake.effectiveVolume(for: .drums), 0, accuracy: 0.001)
        sut.setSoloed(false, for: .vocals)
        XCTAssertEqual(fake.effectiveVolume(for: .vocals), 0.4, accuracy: 0.001)
        XCTAssertEqual(fake.effectiveVolume(for: .drums), 0.6, accuracy: 0.001)
    }

    func testMuteDoesNotChangeGainTransport() throws {
        let sc = try buildValidResult()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc.result)
        sut.setGainPercent(40, for: .vocals)
        sut.setMuted(true, for: .vocals)
        XCTAssertEqual(sut.gain(for: .vocals), 0.4, accuracy: 0.001)
        sut.setMuted(false, for: .vocals)
        XCTAssertEqual(sut.gain(for: .vocals), 0.4, accuracy: 0.001)
        sut.setSoloed(true, for: .drums)
        XCTAssertEqual(sut.gain(for: .vocals), 0.4, accuracy: 0.001)
    }

    // MARK: - Loading new result resets gains to 100%

    func testLoadingNewResultResetsGainsController() {
        let fake = FakeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult(jobId: "first"))
        sut.setGainPercent(30, for: .vocals)
        sut.setGainPercent(0, for: .drums)
        sut.setGainPercent(55, for: .bass)
        XCTAssertEqual(sut.gain(for: .vocals), 0.3, accuracy: 0.001)
        sut.load(result: makeDummyResult(jobId: "second"))
        for stem in StemName.allCases {
            XCTAssertEqual(sut.gain(for: stem), 1.0, accuracy: 0.001, "new load must reset \(stem) to 100%")
            XCTAssertEqual(fake.gain(for: stem), 1.0, accuracy: 0.001)
            XCTAssertEqual(sut.gainPercent(for: stem), 100, accuracy: 0.001)
        }
    }

    func testLoadingNewResultResetsGainsTransport() throws {
        let sc1 = try buildValidResult()
        defer { try? FileManager.default.removeItem(at: sc1.base) }
        let sut = MultiStemAudioTransport()
        try sut.load(result: sc1.result)
        sut.setGainPercent(30, for: .vocals)
        sut.setGainPercent(0, for: .drums)
        let sc2 = try buildValidResult()
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        try sut.load(result: sc2.result)
        for stem in StemName.allCases {
            XCTAssertEqual(sut.gain(for: stem), 1.0, accuracy: 0.001)
            XCTAssertEqual(sut.effectiveVolume(for: stem), 1.0, accuracy: 0.001)
        }
    }

    // MARK: - Changing gain does not affect muted/solo sets

    func testSetGainDoesNotAffectMuteSolo() {
        let fake = FakeStemTransport()
        let sut = StemPlaybackController(transport: fake)
        sut.load(result: makeDummyResult())
        sut.setMuted(true, for: .vocals)
        sut.setSoloed(true, for: .drums)
        sut.setGainPercent(40, for: .vocals)
        XCTAssertEqual(sut.mutedStems, [.vocals])
        XCTAssertEqual(sut.soloedStems, [.drums])
        XCTAssertEqual(fake.mutedStems, [.vocals])
        XCTAssertEqual(fake.soloedStems, [.drums])
    }
}
