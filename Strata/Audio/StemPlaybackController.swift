import Foundation

// MARK: - Stem Transport Protocol

@MainActor
protocol StemAudioTransport: AnyObject {
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var mutedStems: Set<StemName> { get }
    var soloedStems: Set<StemName> { get }
    var stemGains: [StemName: Float] { get }
    var onCompletion: (() -> Void)? { get set }
    func load(result: SeparationResult) throws
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func stop()
    func setMuted(_ muted: Bool, for stem: StemName)
    func setSoloed(_ soloed: Bool, for stem: StemName)
    func gain(for stem: StemName) -> Float
    func setGain(_ gain: Float, for stem: StemName)
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
    private(set) var mutedStems: Set<StemName>
    private(set) var soloedStems: Set<StemName>
    private(set) var stemGains: [StemName: Float] = [:]
    var errorMessage: String?

    var hasStems: Bool { result != nil }
    var selectedStems: [StemArtifact] {
        guard let result else { return [] }
        let selectedNames: Set<StemName>
        if soloedStems.isEmpty {
            selectedNames = Set(result.stems.keys).subtracting(mutedStems)
        } else {
            selectedNames = soloedStems
        }
        return StemName.allCases.compactMap { name in
            guard selectedNames.contains(name) else { return nil }
            return result.stem(name)
        }
    }

    // MARK: - Transport

    private var transport: StemAudioTransport
    private var timer: Timer?
    private var sessionGeneration: UInt64 = 0

    init(transport: StemAudioTransport) {
        self.transport = transport
        self.mutedStems = transport.mutedStems
        self.soloedStems = transport.soloedStems
        self.stemGains = transport.stemGains
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
        load(result: result, displayName: nil)
    }

    func load(result: SeparationResult, displayName: String?) {
        if hasStems || isPlaying {
            stopSession()
        }
        sessionGeneration &+= 1
        errorMessage = nil
        mutedStems.removeAll()
        soloedStems.removeAll()
        stemGains.removeAll()

        do {
            try transport.load(result: result)
            self.result = result
            if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
                title = displayName
            } else {
                let name = result.inputURL.deletingPathExtension().lastPathComponent
                if name.isEmpty || name == "/" {
                    title = result.jobId.isEmpty ? "Untitled" : result.jobId
                } else {
                    title = name
                }
            }
            duration = transport.duration
            currentTime = 0
            isPlaying = false
            mutedStems = transport.mutedStems
            soloedStems = transport.soloedStems
            stemGains = transport.stemGains
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

    // MARK: - Stem Audibility

    func setMuted(_ muted: Bool, for stem: StemName) {
        guard hasStems else { return }
        transport.setMuted(muted, for: stem)
        mutedStems = transport.mutedStems
    }

    func setSoloed(_ soloed: Bool, for stem: StemName) {
        guard hasStems else { return }
        transport.setSoloed(soloed, for: stem)
        soloedStems = transport.soloedStems
    }

    func toggleMute(for stem: StemName) {
        setMuted(!mutedStems.contains(stem), for: stem)
    }

    func toggleSolo(for stem: StemName) {
        setSoloed(!soloedStems.contains(stem), for: stem)
    }

    // MARK: - Gain

    func gain(for stem: StemName) -> Float {
        stemGains[stem] ?? 1.0
    }

    func gainPercent(for stem: StemName) -> Double {
        gainToPercent(gain(for: stem))
    }

    func setGain(_ gain: Float, for stem: StemName) {
        guard hasStems else { return }
        let clamped = min(max(gain, 0), 1)
        stemGains[stem] = clamped
        transport.setGain(clamped, for: stem)
    }

    func setGainPercent(_ percent: Double, for stem: StemName) {
        setGain(uiPercentToGain(percent), for: stem)
    }

    // UI 0...100% -> gain 0...1 linear (small localized conversion)
    private func uiPercentToGain(_ percent: Double) -> Float {
        Float(min(max(percent, 0), 100) / 100.0)
    }

    private func gainToPercent(_ gain: Float) -> Double {
        Double(min(max(gain, 0), 1) * 100)
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
