import AVFoundation

// MARK: - Transport Protocol

/// Narrow protocol sufficient to unit-test the controller with a fake.
@MainActor
protocol AudioTransport: AnyObject {
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var onCompletion: (() -> Void)? { get set }
    func load(url: URL) throws
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func stop()
}

// MARK: - Real Engine Transport

@MainActor
final class AVAudioEngineTransport: AudioTransport {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var sampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0
    private var seekFrame: AVAudioFramePosition = 0
    private var needsSchedule = true
    private var _isPlaying = false
    private var scheduleGeneration: UInt64 = 0
    /// Exposed for testing: current schedule generation.
    var currentGeneration: UInt64 { scheduleGeneration }

    var duration: TimeInterval {
        guard totalFrames > 0 else { return 0 }
        return Double(totalFrames) / sampleRate
    }

    var isPlaying: Bool { _isPlaying }

    var currentTime: TimeInterval {
        guard file != nil else { return 0 }
        if !_isPlaying {
            return TimeInterval(seekFrame) / sampleRate
        }
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return TimeInterval(seekFrame) / sampleRate
        }
        let elapsed = AVAudioFramePosition(playerTime.sampleTime)
        let current = seekFrame + elapsed
        let clamped = min(max(current, 0), totalFrames)
        return TimeInterval(clamped) / sampleRate
    }

    var onCompletion: (() -> Void)?

    init() {
        engine.attach(player)
    }

    deinit {
        // AVAudioEngineTransport is MainActor-isolated; all engine/player mutation
        // happens on the MainActor. Normal lifecycle calls stop() on MainActor
        // before deallocation. We avoid touching MainActor-isolated state here
        // because deinit is nonisolated; ARC tears down the graph.
    }

    func load(url: URL) throws {
        // Stop and reset prior session cleanly. stop() invalidates pending completions.
        stop()

        let loadedFile = try AVAudioFile(forReading: url)
        let format = loadedFile.processingFormat
        guard format.sampleRate > 0, loadedFile.length > 0 else {
            throw NSError(
                domain: "Demux.AudioTransport",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported or empty audio file."]
            )
        }

        file = loadedFile
        sampleRate = format.sampleRate
        totalFrames = loadedFile.length
        seekFrame = 0
        needsSchedule = true

        // Ensure graph is connected with file's format.
        // Reconnect if needed to match new format.
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func play() {
        guard file != nil else { return }
        if _isPlaying { return }

        // Replay after natural completion: seekFrame == totalFrames means we
        // completed and remain at end until user explicitly replays.
        // Reset to zero without zero-frame schedule.
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
        player.play()
        _isPlaying = true
    }

    func pause() {
        guard _isPlaying else { return }
        // Capture accurate position before pausing; lastRenderTime becomes unreliable after pause.
        let current = currentTime
        seekFrame = AVAudioFramePosition((current * sampleRate).rounded())
        seekFrame = min(max(seekFrame, 0), totalFrames)
        player.pause()
        // Keep engine running for quick resume, but pause state is tracked.
        _isPlaying = false
        needsSchedule = true
    }

    func seek(to time: TimeInterval) {
        guard file != nil else { return }
        let clamped = min(max(time, 0), duration)
        let targetFrame = AVAudioFramePosition((clamped * sampleRate).rounded())
        let wasPlaying = _isPlaying

        seekFrame = min(max(targetFrame, 0), totalFrames)

        // Invalidate any pending completion before stopping the player.
        // AVAudioPlayerNode.stop() can synchronously invoke the previous
        // schedule's completion handler on an arbitrary thread; we guard
        // against stale callbacks via scheduleGeneration.
        scheduleGeneration &+= 1
        player.stop()
        needsSchedule = true
        _isPlaying = false

        if wasPlaying {
            if seekFrame >= totalFrames {
                // Seeking to the very end while playing: do not create a
                // zero-frame schedule. Treat as natural completion.
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
            player.play()
            _isPlaying = true
        } else {
            // Not playing: remain stopped at new position; next play will schedule from seekFrame.
            if seekFrame >= totalFrames {
                // Clamped to end while paused — stay at end, no schedule needed until user seeks back or replays.
                return
            }
        }
    }

    func stop() {
        // Invalidate pending completions so a completion that fires after
        // stop() cannot terminate a future schedule.
        scheduleGeneration &+= 1
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        _isPlaying = false
        // Reset seek so a subsequent load starts clean; caller will set correct seekFrame.
        // For stop-not-reload, leave at current but mark needsSchedule.
        // Distinguish: if we have a file, keep seekFrame at current time clamp for stop semantics.
        // However spec says replacing file must stop/release prior session cleanly — we reset to 0.
        seekFrame = 0
        needsSchedule = true
    }

    // MARK: - Private

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file else { return }
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        let framesToPlay = AVAudioFrameCount(totalFrames - frame)
        guard framesToPlay > 0 else {
            // At or beyond end: do not create zero-frame schedule; dispatch
            // completion with generation guard so stale zero-frame completions are ignored.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleScheduledCompletion(generation: generation)
            }
            return
        }

        player.stop()

        if frame == 0 && framesToPlay == file.length {
            player.scheduleFile(file, at: nil) { [weak self] in
                // AVFoundation may invoke this on a non-MainActor thread.
                // Hop back to MainActor and check generation before mutating state.
                // `generation` is Sendable (UInt64) so capture is safe; `self` is
                // MainActor-isolated and accessed only after hopping.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleScheduledCompletion(generation: generation)
                }
            }
        } else {
            player.scheduleSegment(file, startingFrame: frame, frameCount: framesToPlay, at: nil) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleScheduledCompletion(generation: generation)
                }
            }
        }
        needsSchedule = false
    }

    /// Testability seam: production-side generation guard.
    /// Called on MainActor from AVFoundation completion handlers (via Task hop).
    /// Tests can exercise this directly to prove stale generations are rejected.
    func handleScheduledCompletion(generation: UInt64) {
        guard scheduleGeneration == generation else { return }
        handleEngineCompletion()
    }

    private func handleEngineCompletion() {
        // Called on MainActor via Task hop from audio callback.
        seekFrame = totalFrames
        _isPlaying = false
        needsSchedule = true
        onCompletion?()
    }
}
