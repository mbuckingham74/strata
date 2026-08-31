import AVFoundation
import Foundation

// MARK: - WaveformProvider
//
// Small native waveform extraction for M7 strata.
// Reads real WAV (44.1 kHz stereo) via AVAudioFile, downsamples to a fixed
// number of peak amplitudes. No fake/decorative data.
//
// - Uses AVAudioFile + PCM Float32 reading in 8k chunks
// - Per-bin peak (max absolute amplitude across channels) -> 0...1
// - Cached in-memory by URL so six stems don't re-decode on every redraw
// - Runs off MainActor in a detached Task; UI consumes via MainActor cache
//
// If decoding fails, returns empty — caller shows subtle placeholder, never fake waveform.

actor WaveformProvider {
    static let shared = WaveformProvider()
    private var cache: [URL: [Float]] = [:]

    func cachedSamples(for url: URL) -> [Float]? {
        cache[url]
    }

    func store(_ samples: [Float], for url: URL) {
        cache[url] = samples
    }

    /// Load peak waveform for `url`. Returns `targetCount` floats in 0...1.
    /// Checks cache first; otherwise decodes on a detached background task.
    func load(url: URL, targetCount: Int = 220) async -> [Float] {
        if let hit = cachedSamples(for: url), !hit.isEmpty { return hit }
        let samples: [Float] = await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                Self.decodePeaks(url: url, targetCount: targetCount)
            }
        }.value
        if !samples.isEmpty {
            store(samples, for: url)
        }
        return samples
    }

    // MARK: - Decoding (background)

    nonisolated private static func decodePeaks(url: URL, targetCount: Int) -> [Float] {
        do {
            let file = try AVAudioFile(forReading: url)
            let totalFrames = Int(file.length)
            guard totalFrames > 0 else { return [] }
            let binCount = min(max(targetCount, 32), totalFrames)

            var peaks = [Float](repeating: 0, count: binCount)

            // Out format: Float32, non-interleaved, same sampleRate/channels as file
            // Using file.processingFormat ensures we handle the file's actual layout.
            let format = file.processingFormat
            guard let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: format.channelCount,
                interleaved: false
            ) else { return [] }

            file.framePosition = 0
            let bufferSize: AVAudioFrameCount = 8192
            var globalFrame = 0

            while file.framePosition < file.length {
                let remaining = AVAudioFrameCount(file.length - file.framePosition)
                let toRead = min(bufferSize, remaining)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: toRead) else { break }
                do {
                    try file.read(into: buffer)
                } catch { break }
                guard let channelData = buffer.floatChannelData else { continue }
                let frames = Int(buffer.frameLength)
                let chCount = Int(buffer.format.channelCount)
                for i in 0..<frames {
                    var maxAmp: Float = 0
                    for ch in 0..<chCount {
                        let v = abs(channelData[ch][i])
                        if v > maxAmp { maxAmp = v }
                    }
                    let bin = Int(Double(globalFrame + i) / Double(totalFrames) * Double(binCount))
                    let clamped = min(max(bin, 0), binCount - 1)
                    if maxAmp > peaks[clamped] { peaks[clamped] = maxAmp }
                }
                globalFrame += frames
                if globalFrame >= totalFrames { break }
            }
            // Clamp to 0...1 and lightly lift near-silent bins for visibility
            for i in 0..<peaks.count {
                var v = min(max(peaks[i], 0), 1)
                // Preserve silence as 0, but make audible low-level bins a touch taller
                if v > 0 && v < 0.06 { v = 0.06 + v * 0.5 }
                peaks[i] = v
            }
            return peaks
        } catch {
            return []
        }
    }
}
