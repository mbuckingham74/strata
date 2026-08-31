import AVFoundation
import Foundation
import Darwin

// MARK: - Multi-Stem Engine Transport

/// Narrow AVAudioEngine transport for 6 stems. Mirrors AVAudioEngineTransport semantics
/// with 6 sample-synchronous AVAudioPlayerNodes.
@MainActor
final class MultiStemAudioTransport {

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var files: [AVAudioFile] = [] // parallel to players, sorted by StemName rawValue
    private var stemNames: [StemName] = [] // parallel to players and files
    private var sampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0
    private var seekFrame: AVAudioFramePosition = 0
    private var needsSchedule = true
    private var _isPlaying = false
    private var scheduleGeneration: UInt64 = 0
    private var lastCompletedGeneration: UInt64?

    private(set) var mutedStems: Set<StemName> = []
    private(set) var soloedStems: Set<StemName> = []
    private(set) var stemGains: [StemName: Float] = [:]

    /// Exposed for testing: current schedule generation.
    var currentGeneration: UInt64 { scheduleGeneration }

    // MARK: - Gain (0...1, UI 0...100%)

    /// Returns per-stem gain in 0...1 (nil means 1.0 = 100%).
    func gain(for stem: StemName) -> Float {
        stemGains[stem] ?? 1.0
    }

    func gainPercent(for stem: StemName) -> Double {
        gainToPercent(gain(for: stem))
    }

    func setGain(_ gain: Float, for stem: StemName) {
        let clamped = min(max(gain, 0), 1)
        stemGains[stem] = clamped
        applyStemAudibility()
    }

    func setGainPercent(_ percent: Double, for stem: StemName) {
        setGain(uiPercentToGain(percent), for: stem)
    }

    // UI 0...100% maps to audio gain 0...1 via small localized linear conversion.
    private func uiPercentToGain(_ percent: Double) -> Float {
        Float(min(max(percent, 0), 100) / 100.0)
    }

    private func gainToPercent(_ gain: Float) -> Double {
        Double(min(max(gain, 0), 1) * 100)
    }

    var duration: TimeInterval {
        guard totalFrames > 0 else { return 0 }
        return Double(totalFrames) / sampleRate
    }

    var isPlaying: Bool { _isPlaying }

    var currentTime: TimeInterval {
        guard !files.isEmpty else { return 0 }
        if !_isPlaying {
            return TimeInterval(seekFrame) / sampleRate
        }
        // Use one representative player's timeline.
        guard let rep = players.first,
              let nodeTime = rep.lastRenderTime,
              let playerTime = rep.playerTime(forNodeTime: nodeTime) else {
            return TimeInterval(seekFrame) / sampleRate
        }
        let elapsed = AVAudioFramePosition(playerTime.sampleTime)
        let current = seekFrame + elapsed
        let clamped = min(max(current, 0), totalFrames)
        return TimeInterval(clamped) / sampleRate
    }

    var onCompletion: (() -> Void)?

    init() {}

    deinit {
        // MainActor-isolated; normal lifecycle calls stop() on MainActor.
    }

    // MARK: - Load

    func load(result: SeparationResult) throws {
        // Stop and clear prior session first. stop() invalidates pending completions.
        stop()

        // Detach any previous players (stop already stopped engine but nodes remain attached).
        for p in players {
            engine.detach(p)
        }
        players.removeAll()
        files.removeAll()
        stemNames.removeAll()
        mutedStems.removeAll()
        soloedStems.removeAll()
        stemGains.removeAll()
        sampleRate = 44_100
        totalFrames = 0
        seekFrame = 0
        needsSchedule = true

        // Re-validate files still match artifact metadata.
        guard result.stems.count == 6, Set(result.stems.keys) == StemName.requiredSet else {
            throw NSError(domain: "Strata.MultiStemAudioTransport", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected 6 stems with required set."])
        }

        var opened: [(StemName, AVAudioFile)] = []
        var commonFrames: UInt64?
        // Deterministic order for validation/open.
        let sortedNames = StemName.allCases.sorted { $0.rawValue < $1.rawValue }
        for name in sortedNames {
            guard let artifact = result.stems[name] else {
                throw NSError(domain: "Strata.MultiStemAudioTransport", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Missing stem \(name.rawValue)."])
            }
            // Throws if file missing, channel/sr mismatch, or frameCount mismatch.
            let meta = try validateAudioFile(at: artifact.url, expectedFrames: artifact.frameCount)
            guard meta.frames == artifact.frameCount, meta.frames > 0 else {
                throw NSError(domain: "Strata.MultiStemAudioTransport", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Frame mismatch for \(name.rawValue)."])
            }
            guard meta.sampleRate == canonicalSampleRate, meta.channels == canonicalChannels else {
                throw NSError(domain: "Strata.MultiStemAudioTransport", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Canonical format mismatch for \(name.rawValue)."])
            }
            if let cf = commonFrames {
                guard cf == artifact.frameCount else {
                    throw NSError(domain: "Strata.MultiStemAudioTransport", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "All stems must have equal frames."])
                }
            } else {
                commonFrames = artifact.frameCount
            }
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: artifact.url)
            } catch {
                throw NSError(domain: "Strata.MultiStemAudioTransport", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "AVAudioFile open failed for \(name.rawValue): \(error.localizedDescription)"])
            }
            guard UInt64(file.length) == artifact.frameCount else {
                throw NSError(domain: "Strata.MultiStemAudioTransport", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "File length mismatch for \(name.rawValue)."])
            }
            guard file.processingFormat.sampleRate == 44_100, file.processingFormat.channelCount == 2 else {
                throw NSError(domain: "Strata.MultiStemAudioTransport", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Processing format mismatch for \(name.rawValue)."])
            }
            opened.append((name, file))
        }

        guard let cf = commonFrames, cf > 0 else {
            throw NSError(domain: "Strata.MultiStemAudioTransport", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid frame count."])
        }
        guard opened.count == 6 else {
            throw NSError(domain: "Strata.MultiStemAudioTransport", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Incomplete stems after open."])
        }

        // All validated — attach 6 player nodes.
        totalFrames = AVAudioFramePosition(cf)
        sampleRate = 44_100
        seekFrame = 0
        needsSchedule = true

        for (name, file) in opened {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            players.append(player)
            files.append(file)
            stemNames.append(name)
        }
        // Reset gains to 100% (1.0) for all six stems.
        for name in StemName.allCases {
            stemGains[name] = 1.0
        }
        applyStemAudibility()
        engine.prepare()
    }

    // MARK: - Playback Controls

    func play() {
        guard !files.isEmpty else { return }
        if _isPlaying { return }

        // Replay after natural completion: seekFrame == totalFrames means at end.
        if seekFrame >= totalFrames {
            seekFrame = 0
        }

        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            return
        }

        if needsSchedule {
            schedule(from: seekFrame)
        }

        // Start all six against same future AVAudioTime for sample-synchronous start.
        // Compute one future hostTime (~50ms ahead) and call play(at:) on each node with same time.
        let when = futureHostTime(delaySeconds: 0.05)
        for player in players {
            player.play(at: when)
        }
        _isPlaying = true
    }

    func pause() {
        guard _isPlaying else { return }
        let current = currentTime
        seekFrame = AVAudioFramePosition((current * sampleRate).rounded())
        seekFrame = min(max(seekFrame, 0), totalFrames)
        for player in players {
            player.pause()
        }
        _isPlaying = false
        needsSchedule = true
    }

    func seek(to time: TimeInterval) {
        guard !files.isEmpty else { return }
        let clamped = min(max(time, 0), duration)
        let targetFrame = AVAudioFramePosition((clamped * sampleRate).rounded())
        let wasPlaying = _isPlaying

        seekFrame = min(max(targetFrame, 0), totalFrames)

        // Invalidate any pending completion before stopping the players.
        scheduleGeneration &+= 1
        for player in players {
            player.stop()
        }
        needsSchedule = true
        _isPlaying = false

        if wasPlaying {
            if seekFrame >= totalFrames {
                handleEngineCompletion()
                return
            }
            schedule(from: seekFrame)
            do {
                if !engine.isRunning {
                    try engine.start()
                }
            } catch {
                return
            }
            let when = futureHostTime(delaySeconds: 0.05)
            for player in players {
                player.play(at: when)
            }
            _isPlaying = true
        } else {
            if seekFrame >= totalFrames {
                return
            }
        }
    }

    func stop() {
        scheduleGeneration &+= 1
        for player in players {
            player.stop()
        }
        if engine.isRunning {
            engine.stop()
        }
        _isPlaying = false
        seekFrame = 0
        needsSchedule = true
    }

    // MARK: - Stem Audibility

    func setMuted(_ muted: Bool, for stem: StemName) {
        if muted {
            mutedStems.insert(stem)
        } else {
            mutedStems.remove(stem)
        }
        applyStemAudibility()
    }

    func setSoloed(_ soloed: Bool, for stem: StemName) {
        if soloed {
            soloedStems.insert(stem)
        } else {
            soloedStems.remove(stem)
        }
        applyStemAudibility()
    }

    func isAudible(_ stem: StemName) -> Bool {
        if !soloedStems.isEmpty {
            return soloedStems.contains(stem)
        }
        return !mutedStems.contains(stem)
    }

    // MARK: - Private

    private func applyStemAudibility() {
        for (stem, player) in zip(stemNames, players) {
            player.volume = isAudible(stem) ? gain(for: stem) : 0
        }
    }

    /// Test helper: effective volume accounting for mute/solo and gain.
    func effectiveVolume(for stem: StemName) -> Float {
        isAudible(stem) ? gain(for: stem) : 0
    }

    private func futureHostTime(delaySeconds: Double) -> AVAudioTime? {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.numer != 0 else {
            return nil
        }
        let nanos = UInt64(delaySeconds * 1_000_000_000)
        let ticks = nanos * UInt64(info.denom) / UInt64(info.numer)
        let hostTime = mach_absolute_time() + ticks
        return AVAudioTime(hostTime: hostTime)
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard !files.isEmpty, !players.isEmpty else { return }
        // Invalidate previous schedule and capture new generation.
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        let framesToPlay = AVAudioFrameCount(totalFrames - frame)
        guard framesToPlay > 0 else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleScheduledCompletion(generation: generation)
            }
            return
        }

        for player in players {
            player.stop()
        }

        // Schedule all six from same frame (startingFrame + frameCount).
        // Natural completion must be published once, not per player.
        // We schedule 5 followers without completion handler and 1 leader with
        // Task hop to handleScheduledCompletion. This ensures only one group
        // completion fires per schedule generation.
        for (index, player) in players.enumerated() {
            let file = files[index]
            let isLeader = (index == 0)
            if frame == 0 && framesToPlay == file.length {
                if isLeader {
                    player.scheduleFile(file, at: nil) { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.handleScheduledCompletion(generation: generation)
                        }
                    }
                } else {
                    // Schedule follower without completion handler so only leader fires.
                    player.scheduleFile(file, at: nil, completionHandler: nil)
                }
            } else {
                if isLeader {
                    player.scheduleSegment(file, startingFrame: frame, frameCount: framesToPlay, at: nil) { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.handleScheduledCompletion(generation: generation)
                        }
                    }
                } else {
                    player.scheduleSegment(file, startingFrame: frame, frameCount: framesToPlay, at: nil, completionHandler: nil)
                }
            }
        }
        needsSchedule = false
    }

    /// Testability seam: generation guard.
    func handleScheduledCompletion(generation: UInt64) {
        guard scheduleGeneration == generation else { return }
        // Natural completion must be published once per generation, not per player.
        // Guard against duplicate deliveries of the same generation (e.g. if 6
        // completion handlers were scheduled, only the first should fire).
        guard lastCompletedGeneration != generation else { return }
        lastCompletedGeneration = generation
        handleEngineCompletion()
    }

    private func handleEngineCompletion() {
        seekFrame = totalFrames
        _isPlaying = false
        needsSchedule = true
        onCompletion?()
    }
}
