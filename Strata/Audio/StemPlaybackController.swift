import Foundation

// MARK: - Stem Transport Protocol

@MainActor
protocol StemAudioTransport: AnyObject {
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var onCompletion: (() -> Void)? { get set }
    func load(result: SeparationResult) throws
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func stop()
}

extension MultiStemAudioTransport: StemAudioTransport {}

// MARK: - Stem Playback Controller

@MainActor
@Observable
final class StemPlaybackController {

    // MARK: - Observable State

    var result: SeparationResult?
    var title: String?
    var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0
    var isPlaying: Bool = false
    var errorMessage: String?

    var hasStems: Bool { result != nil }

    // MARK: - Transport

    private var transport: StemAudioTransport
    private var timer: Timer?
    private var sessionGeneration: UInt64 = 0

    init(transport: StemAudioTransport) {
        self.transport = transport
        self.transport.onCompletion = { [weak self] in
            guard let self else { return }
            let captured = self.sessionGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.sessionGeneration == captured else { return }
                self.handleCompletion()
            }
        }
    }

    convenience init() {
        self.init(transport: MultiStemAudioTransport())
    }

    // MARK: - Loading

    func load(result: SeparationResult) {
        if hasStems || isPlaying {
            stopSession()
        }
        sessionGeneration &+= 1
        errorMessage = nil

        do {
            try transport.load(result: result)
            self.result = result
            let name = result.inputURL.deletingPathExtension().lastPathComponent
            if name.isEmpty || name == "/" {
                title = result.jobId.isEmpty ? "Untitled" : result.jobId
            } else {
                title = name
            }
            duration = transport.duration
            currentTime = 0
            isPlaying = false
            stopTimer()
        } catch {
            self.result = nil
            title = nil
            duration = 0
            currentTime = 0
            isPlaying = false
            errorMessage = "Couldn’t load stems for \"\(result.jobId)\". \(error.localizedDescription)"
        }
    }

    // MARK: - Playback Controls

    func play() {
        guard hasStems else { return }
        sessionGeneration &+= 1
        transport.play()
        isPlaying = true
        startTimer()
        currentTime = transport.currentTime
    }

    func pause() {
        guard hasStems else { return }
        transport.pause()
        isPlaying = false
        currentTime = transport.currentTime
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        guard hasStems else { return }
        sessionGeneration &+= 1
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        transport.seek(to: clamped)
        isPlaying = transport.isPlaying
        if !isPlaying {
            stopTimer()
        }
    }

    func stopSession() {
        sessionGeneration &+= 1
        transport.stop()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        stopSession()
    }

    // MARK: - Completion

    func handleCompletion() {
        isPlaying = false
        currentTime = duration
        stopTimer()
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying {
                    self.currentTime = self.transport.currentTime
                    if self.currentTime >= self.duration - 0.05 {
                        self.currentTime = min(self.currentTime, self.duration)
                    }
                }
            }
        }
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
