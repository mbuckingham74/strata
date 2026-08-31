import Foundation
import AVFoundation
import Darwin

// MARK: - Shared process support

enum AudioProcessRunnerError: Error, Equatable, Sendable {
    case launchFailed(String)
    case cancelled
    case cleanupFailed(String)
}

final class AudioStderrTail: @unchecked Sendable {
    private var data = Data()
    private let maxBytes = 32 * 1024

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        self.data.append(data)
        if self.data.count > maxBytes {
            self.data = self.data.suffix(maxBytes)
        }
    }

    func string() -> String? {
        guard !data.isEmpty else { return nil }
        if let string = String(data: data, encoding: .utf8) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return "<non-utf8 \(data.count) bytes>"
    }
}

actor AudioProcessRunner {
    private var activeProcess: Process?
    private var cancellationRequested = false
    private let isRunningCheck: @Sendable (Process) -> Bool

    init(isRunningCheck: @escaping @Sendable (Process) -> Bool = { $0.isRunning }) {
        self.isRunningCheck = isRunningCheck
    }

    func hasActiveProcess() -> Bool {
        activeProcess != nil
    }

    func hasLiveProcess() -> Bool {
        guard let activeProcess else { return false }
        return isRunningCheck(activeProcess)
    }

    func run(executableURL: URL, arguments: [String], stderrTail: AudioStderrTail) async throws -> Int32 {
        if activeProcess != nil {
            throw AudioProcessRunnerError.cleanupFailed("another process is already running")
        }
        cancellationRequested = false
        if Task.isCancelled {
            throw AudioProcessRunnerError.cancelled
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        let handle = stderrPipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty {
                stderrTail.append(data)
            }
        }

        activeProcess = process
        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            activeProcess = nil
            throw AudioProcessRunnerError.launchFailed(error.localizedDescription)
        }

        while isRunningCheck(process) {
            if Task.isCancelled || cancellationRequested {
                await terminate(process)
                handle.readabilityHandler = nil
                let remaining = handle.availableData
                if !remaining.isEmpty { stderrTail.append(remaining) }
                if isRunningCheck(process) {
                    throw AudioProcessRunnerError.cleanupFailed(
                        "Process \(process.processIdentifier) still running after SIGTERM/SIGKILL"
                    )
                }
                activeProcess = nil
                throw AudioProcessRunnerError.cancelled
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        handle.readabilityHandler = nil
        let remaining = handle.availableData
        if !remaining.isEmpty { stderrTail.append(remaining) }
        if let data = try? handle.readToEnd(), !data.isEmpty {
            stderrTail.append(data)
        }
        let status = process.terminationStatus
        activeProcess = nil
        if cancellationRequested || Task.isCancelled {
            throw AudioProcessRunnerError.cancelled
        }
        return status
    }

    func cancel() async throws {
        cancellationRequested = true
        guard let process = activeProcess else { return }

        if isRunningCheck(process) {
            await terminate(process)
        }
        if isRunningCheck(process) {
            throw AudioProcessRunnerError.cleanupFailed(
                "Process \(process.processIdentifier) still running after SIGTERM/SIGKILL"
            )
        }
        activeProcess = nil
    }

    private func terminate(_ process: Process) async {
        if isRunningCheck(process) {
            process.terminate()
            let deadline = ContinuousClock.now + .milliseconds(500)
            while isRunningCheck(process) && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        if isRunningCheck(process) {
            kill(process.processIdentifier, SIGKILL)
            let deadline = ContinuousClock.now + .milliseconds(500)
            while isRunningCheck(process) && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

// MARK: - Shared canonical-output validation

enum CanonicalAudioFileError: Error, Equatable, Sendable {
    case invalid(String)

    var reason: String {
        switch self {
        case .invalid(let reason): return reason
        }
    }
}

func validateCanonicalAudioFile(at url: URL, fileManager: FileManager) throws {
    guard fileManager.fileExists(atPath: url.path) else {
        throw CanonicalAudioFileError.invalid("mixture.wav missing at \(url.path)")
    }

    var isDirectory: ObjCBool = false
    _ = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
    if isDirectory.boolValue {
        throw CanonicalAudioFileError.invalid("mixture.wav is directory")
    }

    let audioFile: AVAudioFile
    do {
        audioFile = try AVAudioFile(forReading: url)
    } catch {
        throw CanonicalAudioFileError.invalid("AVAudioFile open failed: \(error.localizedDescription)")
    }

    let format = audioFile.processingFormat
    guard format.sampleRate == 44100 else {
        throw CanonicalAudioFileError.invalid("sampleRate \(format.sampleRate) != 44100")
    }
    guard format.channelCount == 2 else {
        throw CanonicalAudioFileError.invalid("channelCount \(format.channelCount) != 2")
    }
    guard format.commonFormat == .pcmFormatFloat32 else {
        throw CanonicalAudioFileError.invalid("format not Float32: \(format.commonFormat)")
    }
    guard audioFile.length > 0 else {
        throw CanonicalAudioFileError.invalid("frame count 0")
    }
}
