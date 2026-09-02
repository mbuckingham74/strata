import Foundation

@MainActor
@Observable
final class PlaybackController {

    // MARK: - Observable State

    var title: String?
    var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0
    var isPlaying: Bool = false
    var errorMessage: String?

    var hasFile: Bool { title != nil }

    // Source identity for separation (exposed for unified local workflow)
    private(set) var sourceURL: URL?

    // MARK: - Transport

    private var transport: AudioTransport
    private var timer: Timer?

    init(transport: AudioTransport) {
        self.transport = transport
        self.transport.onCompletion = { [weak self] in
            Task { @MainActor in
                self?.handleCompletion()
            }
        }
    }

    // MARK: - Loading

    func load(url: URL) {
        load(url: url, displayTitle: nil)
    }

    func load(url: URL, displayTitle: String?) {
        // Stop prior session cleanly before loading new file.
        if hasFile || isPlaying {
            stopSession()
        }
        errorMessage = nil

        do {
            try transport.load(url: url)
            if let displayTitle = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !displayTitle.isEmpty {
                title = displayTitle
            } else {
                // Derive displayed title from filename without extension.
                let name = url.deletingPathExtension().lastPathComponent
                title = name.isEmpty ? "Untitled" : name
            }
            sourceURL = url
            duration = transport.duration
            currentTime = 0
            isPlaying = false
            stopTimer()
        } catch {
            // Concise, recoverable error; leave in clean empty-ish state.
            // Ensure prior title is cleared if load failed.
            title = nil
            sourceURL = nil
            duration = 0
            currentTime = 0
            isPlaying = false
            errorMessage = "Couldn’t open “\(url.lastPathComponent)”. \(error.localizedDescription)"
        }
    }

    /// Convenience for YouTube source display.
    func loadYouTubeSource(url: URL, displayTitle: String?) {
        load(url: url, displayTitle: displayTitle)
    }

    // MARK: - Playback Controls

    func play() {
        guard hasFile else { return }
        transport.play()
        isPlaying = true
        startTimer()
        // Sync immediately from transport timeline.
        currentTime = transport.currentTime
    }

    func pause() {
        guard hasFile else { return }
        transport.pause()
        isPlaying = false
        currentTime = transport.currentTime
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        guard hasFile else { return }
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        transport.seek(to: clamped)
        // If transport was playing, it will have resumed from new position; keep timer.
        // If we were at end and seeked back, stay paused unless user presses play.
    }

    func stopSession() {
        transport.stop()
        isPlaying = false
        stopTimer()
    }

    func resetForNewSession() {
        transport.stop()
        stopTimer()
        title = nil
        duration = 0
        currentTime = 0
        isPlaying = false
        sourceURL = nil
        errorMessage = nil
    }

    // MARK: - Completion

    func handleCompletion() {
        // Called when engine reaches end (already dispatched to main).
        isPlaying = false
        currentTime = duration
        stopTimer()
    }

    // MARK: - Timer (UI refresh only; transport timeline is authoritative)

    private func startTimer() {
        stopTimer()
        // 0.1s refresh is smooth without driving truth.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Only update while playing; paused time is manual.
                if self.isPlaying {
                    self.currentTime = self.transport.currentTime
                    // Clamp to duration; if we've reached the end, completion will also fire.
                    if self.currentTime >= self.duration - 0.05 {
                        // Let transport completion handle state; but ensure we don't overshoot.
                        self.currentTime = min(self.currentTime, self.duration)
                    }
                }
            }
        }
        // Ensure timer fires in common modes.
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Time Formatting

    func formattedTime(_ time: TimeInterval) -> String {
        Self.formattedTime(time)
    }

    static func formattedTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time.rounded(.toNearestOrAwayFromZero))
        let safe = max(totalSeconds, 0)
        let hours = safe / 3600
        let minutes = (safe % 3600) / 60
        let seconds = safe % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    var formattedCurrentTime: String { Self.formattedTime(currentTime) }
    var formattedDuration: String { Self.formattedTime(duration) }
}
