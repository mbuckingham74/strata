import XCTest
@testable import Strata
import AVFoundation

final class WaveformProviderTests: XCTestCase {

    // MARK: - Helpers

    private func makeWAV(at url: URL, frames: UInt32, amplitude: Float = 0.5) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<2 {
            let ptr = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                // Simple sine-like mix so peaks are non-zero
                ptr[i] = sin(Float(i) * 0.1) * amplitude
            }
        }
        try file.write(from: buffer)
    }

    private func makeSilentWAV(at url: URL, frames: UInt32 = 2048) throws {
        try makeWAV(at: url, frames: frames, amplitude: 0)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Decoding

    func testLoadReturnsCorrectBinCountAndRange() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try makeWAV(at: url, frames: 8192, amplitude: 0.8)

        let provider = WaveformProvider()
        let samples = await provider.load(url: url, targetCount: 220)
        XCTAssertEqual(samples.count, 220)
        for v in samples {
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
        }
        XCTAssertTrue(samples.contains { $0 > 0 }, "Expected non-silent peaks")
    }

    func testEmptyForMissingAndInvalidURL() async {
        let provider = WaveformProvider()
        let missing = URL(fileURLWithPath: "/tmp/strata-missing-\(UUID().uuidString).wav")
        let r1 = await provider.load(url: missing, targetCount: 220)
        XCTAssertEqual(r1.count, 0, "Missing file should return empty, not fake waveform")

        // Invalid content (not a WAV)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad.wav")
        try? Data("not a wav".utf8).write(to: bad)
        let r2 = await provider.load(url: bad, targetCount: 220)
        XCTAssertEqual(r2.count, 0)
    }

    func testCacheHitReturnsSameSamples() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cached.wav")
        try makeWAV(at: url, frames: 4096, amplitude: 0.6)

        let provider = WaveformProvider()
        let first = await provider.load(url: url, targetCount: 64)
        let second = await provider.load(url: url, targetCount: 64)
        XCTAssertEqual(first, second)
        // Also verify internal cache via exposed method
        let cached = await provider.cachedSamples(for: url)
        XCTAssertEqual(cached, first)
    }

    func testEmptyFailureDoesNotCache() async {
        let provider = WaveformProvider()
        let missing = URL(fileURLWithPath: "/tmp/strata-empty-cache-\(UUID().uuidString).wav")
        let r = await provider.load(url: missing, targetCount: 220)
        XCTAssertEqual(r.count, 0)
        let cached = await provider.cachedSamples(for: missing)
        XCTAssertNil(cached)
    }

    func testTargetCountClamping() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clamp.wav")
        try makeWAV(at: url, frames: 8192, amplitude: 0.4)

        let provider = WaveformProvider()
        // Below minimum 32 -> clamped to 32
        let smallURL = dir.appendingPathComponent("clamp-small.wav")
        try makeWAV(at: smallURL, frames: 8192, amplitude: 0.4)
        let small = await provider.load(url: smallURL, targetCount: 10)
        XCTAssertEqual(small.count, 32)

        // Above totalFrames -> clamped to totalFrames
        let tinyURL = dir.appendingPathComponent("tiny.wav")
        try makeWAV(at: tinyURL, frames: 100, amplitude: 0.4)
        let tiny = await provider.load(url: tinyURL, targetCount: 220)
        XCTAssertEqual(tiny.count, 100)

        let normal = await provider.load(url: url, targetCount: 220)
        XCTAssertEqual(normal.count, 220)
    }

    func testSilentFileProducesZeros() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("silent.wav")
        try makeSilentWAV(at: url, frames: 4096)
        let provider = WaveformProvider()
        let samples = await provider.load(url: url, targetCount: 64)
        XCTAssertEqual(samples.count, 64)
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
    }
}
