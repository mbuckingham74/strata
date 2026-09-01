import Foundation
import Darwin

struct RuntimeReadiness: Sendable, Equatable {
    let workerAvailable: Bool
    let workerError: String?
    let workerPythonPath: String?
    let ffmpegAvailable: Bool
    let ytDlpAvailable: Bool
    let nodeAvailable: Bool
    let ffmpegInstalledVersion: String?
    let ytDlpInstalledVersion: String?
    let nodeInstalledVersion: String?

    static let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    static let ytDlpPath = "/opt/homebrew/bin/yt-dlp"
    static let nodePath = "/opt/homebrew/bin/node"

    init(
        workerAvailable: Bool,
        workerError: String?,
        workerPythonPath: String?,
        ffmpegAvailable: Bool,
        ytDlpAvailable: Bool,
        nodeAvailable: Bool,
        ffmpegInstalledVersion: String? = nil,
        ytDlpInstalledVersion: String? = nil,
        nodeInstalledVersion: String? = nil
    ) {
        self.workerAvailable = workerAvailable
        self.workerError = workerError
        self.workerPythonPath = workerPythonPath
        self.ffmpegAvailable = ffmpegAvailable
        self.ytDlpAvailable = ytDlpAvailable
        self.nodeAvailable = nodeAvailable
        self.ffmpegInstalledVersion = ffmpegInstalledVersion
        self.ytDlpInstalledVersion = ytDlpInstalledVersion
        self.nodeInstalledVersion = nodeInstalledVersion
    }

    // Local file separation requires worker + FFmpeg (canonicalization)
    var isSeparationReady: Bool { isLocalSeparationReady }
    var isLocalSeparationReady: Bool { workerAvailable && ffmpegAvailable }
    // Separating an already-canonical loaded YouTube source requires only worker
    var isLoadedSeparationReady: Bool { workerAvailable }
    var isWorkerReady: Bool { workerAvailable }

    var isYouTubeAcquisitionReady: Bool { ffmpegAvailable && ytDlpAvailable && nodeAvailable }

    // Granular YouTube readiness per metadata-first workflow (prefer combining existing readiness properties)
    var isYouTubePreviewReady: Bool { ytDlpAvailable && nodeAvailable }
    var isYouTubeMp3Ready: Bool { isYouTubePreviewReady && isMp3ExportReady }
    var isYouTubeSeparationReady: Bool { isYouTubeMp3Ready && isWorkerReady }

    // MP3 exports require FFmpeg; WAV exports are pure file copy / AVFoundation mix and do not
    var isExportReady: Bool { isMp3ExportReady }
    var isMp3ExportReady: Bool { ffmpegAvailable }
    var isWavExportReady: Bool { true }

    var sidebarStatus: String {
        if !ffmpegAvailable {
            if let installed = ffmpegInstalledVersion {
                return "Setup needed · FFmpeg version mismatch at \(Self.ffmpegPath) (installed \(installed), supported \(ExternalToolCompatibility.ffmpegSupportedVersion))"
            }
            return "Setup needed · missing FFmpeg at \(Self.ffmpegPath)"
        }
        if !workerAvailable {
            if let path = workerPythonPath, !path.isEmpty {
                return "Setup needed · missing worker Python at \(path)"
            }
            if let err = workerError, !err.isEmpty {
                if err.contains("/") {
                    return "Setup needed · \(err)"
                }
                return "Setup needed · missing worker Python — \(err)"
            }
            return "Setup needed · missing worker Python"
        }
        if !ytDlpAvailable {
            if let installed = ytDlpInstalledVersion {
                return "YouTube disabled · yt-dlp version mismatch at \(Self.ytDlpPath) (installed \(installed), supported \(ExternalToolCompatibility.ytDlpSupportedVersion))"
            }
            return "YouTube disabled · missing yt-dlp at \(Self.ytDlpPath)"
        }
        if !nodeAvailable {
            if let installed = nodeInstalledVersion {
                return "YouTube disabled · Node version mismatch at \(Self.nodePath) (installed \(installed), supported \(ExternalToolCompatibility.nodeSupportedVersion))"
            }
            return "YouTube disabled · missing Node at \(Self.nodePath)"
        }
        return "Separation ready · runs on this Mac"
    }
}

struct RuntimeReadinessChecker: Sendable {
    var isExecutable: @Sendable (String) -> Bool
    var resolveWorker: @Sendable () throws -> WorkerLaunchConfiguration
    var runVersion: @Sendable (String) -> String?

    init(
        isExecutable: @Sendable @escaping (String) -> Bool,
        resolveWorker: @Sendable @escaping () throws -> WorkerLaunchConfiguration,
        runVersion: (@Sendable (String) -> String?)? = nil
    ) {
        self.isExecutable = isExecutable
        self.resolveWorker = resolveWorker
        if let runVersion {
            self.runVersion = runVersion
        } else {
            // Default for backward compatibility (tests that only mock isExecutable): assume supported versions.
            self.runVersion = { path in
                if path == RuntimeReadiness.ffmpegPath { return ExternalToolCompatibility.ffmpegSupportedVersion }
                if path == RuntimeReadiness.ytDlpPath { return ExternalToolCompatibility.ytDlpSupportedVersion }
                if path == RuntimeReadiness.nodePath { return ExternalToolCompatibility.nodeSupportedVersion }
                return nil
            }
        }
    }

    static var live: RuntimeReadinessChecker {
        RuntimeReadinessChecker(
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            resolveWorker: { try WorkerLaunchConfiguration.resolved() },
            runVersion: { path in liveVersion(for: path) }
        )
    }

    // Bounded timeout for --version probes (kept under 5s so readiness cannot hang).
    static let versionTimeout: TimeInterval = 2.0
    private static let versionGrace: TimeInterval = 0.2

    static func liveVersion(for path: String) -> String? {
        let args: [String]
        if path == RuntimeReadiness.ffmpegPath {
            args = ["-version"]
        } else if path == RuntimeReadiness.ytDlpPath {
            args = ["--version"]
        } else if path == RuntimeReadiness.nodePath {
            args = ["--version"]
        } else {
            return nil
        }
        guard let raw = captureVersionOutput(executablePath: path, arguments: args, timeout: versionTimeout) else {
            return nil
        }
        if path == RuntimeReadiness.ffmpegPath {
            return ExternalToolCompatibility.parseFFmpegVersion(from: raw)
        } else if path == RuntimeReadiness.ytDlpPath {
            return ExternalToolCompatibility.parseYtDlpVersion(from: raw)
        } else if path == RuntimeReadiness.nodePath {
            return ExternalToolCompatibility.parseNodeVersion(from: raw)
        }
        return nil
    }

    /// Test-visible helper: runs an executable with concurrent stdout/stderr draining and a hard timeout.
    /// Returns stdout as UTF-8 string on success (exit 0), nil on timeout, launch failure, non-zero exit, or undecodable output.
    static func captureVersionOutput(executablePath: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        final class DataBox: @unchecked Sendable { var data = Data() }
        let outBox = DataBox()
        let errBox = DataBox()
        let lock = NSLock()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty {
                lock.lock()
                outBox.data.append(d)
                lock.unlock()
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty {
                lock.lock()
                errBox.data.append(d)
                lock.unlock()
            }
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            // Timeout: terminate cleanly, reap, return nil
            process.terminate()
            var grace = Date(timeIntervalSinceNow: versionGrace)
            while process.isRunning && Date() < grace {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.interrupt()
                grace = Date(timeIntervalSinceNow: versionGrace)
                while process.isRunning && Date() < grace {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                grace = Date(timeIntervalSinceNow: versionGrace)
                while process.isRunning && Date() < grace {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            // Never block on pipe EOF after timeout; descendant may hold write end open. Close without unbounded read.
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            return nil
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        var finalOut = outBox.data
        lock.unlock()

        // Only consume immediately available data without blocking; descendant may hold pipe open so EOF never arrives.
        // Use non-blocking read to avoid hang seen with availableData/readToEnd (availableData blocks when writer held open).
        func drainImmediate(_ handle: FileHandle) -> Data {
            let fd = handle.fileDescriptor
            let origFlags = fcntl(fd, F_GETFL)
            let didSet: Bool = {
                if origFlags != -1 && (origFlags & O_NONBLOCK) == 0 {
                    _ = fcntl(fd, F_SETFL, origFlags | O_NONBLOCK)
                    return true
                }
                return false
            }()
            defer {
                if didSet, origFlags != -1 {
                    _ = fcntl(fd, F_SETFL, origFlags)
                }
            }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return read(fd, base, ptr.count)
                }
                if n > 0 {
                    result.append(buffer, count: n)
                    if n < buffer.count { break }
                    continue
                } else if n == 0 {
                    break
                } else {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        break
                    } else if errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
            return result
        }

        let remainingOut = drainImmediate(outPipe.fileHandleForReading)
        if !remainingOut.isEmpty { finalOut.append(remainingOut) }
        // Drain stderr immediate data only without blocking (ignore)
        _ = drainImmediate(errPipe.fileHandleForReading)
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        guard process.terminationStatus == 0 else { return nil }
        guard let output = String(data: finalOut, encoding: .utf8) else { return nil }
        return output
    }

    func check() -> RuntimeReadiness {
        // Resolve versions only if executable
        let ffmpegExecutable = isExecutable(RuntimeReadiness.ffmpegPath)
        var ffmpegInstalled: String? = nil
        var ffmpegAvailable = false
        if ffmpegExecutable {
            if let v = runVersion(RuntimeReadiness.ffmpegPath) {
                ffmpegInstalled = v
                ffmpegAvailable = (v == ExternalToolCompatibility.ffmpegSupportedVersion)
                if !ffmpegAvailable {
                    // keep installed for mismatch status
                }
            } else {
                ffmpegInstalled = "unknown"
                ffmpegAvailable = false
            }
        }

        let ytDlpExecutable = isExecutable(RuntimeReadiness.ytDlpPath)
        var ytDlpInstalled: String? = nil
        var ytDlpAvailable = false
        if ytDlpExecutable {
            if let v = runVersion(RuntimeReadiness.ytDlpPath) {
                ytDlpInstalled = v
                ytDlpAvailable = (v == ExternalToolCompatibility.ytDlpSupportedVersion)
            } else {
                ytDlpInstalled = "unknown"
                ytDlpAvailable = false
            }
        }

        let nodeExecutable = isExecutable(RuntimeReadiness.nodePath)
        var nodeInstalled: String? = nil
        var nodeAvailable = false
        if nodeExecutable {
            if let v = runVersion(RuntimeReadiness.nodePath) {
                nodeInstalled = v
                nodeAvailable = (v == ExternalToolCompatibility.nodeSupportedVersion)
            } else {
                nodeInstalled = "unknown"
                nodeAvailable = false
            }
        }

        do {
            let config = try resolveWorker()
            let pythonPath = config.pythonExecutable.path
            let workerAvailable = isExecutable(pythonPath)
            if workerAvailable {
                return RuntimeReadiness(
                    workerAvailable: true,
                    workerError: nil,
                    workerPythonPath: pythonPath,
                    ffmpegAvailable: ffmpegAvailable,
                    ytDlpAvailable: ytDlpAvailable,
                    nodeAvailable: nodeAvailable,
                    ffmpegInstalledVersion: ffmpegInstalled,
                    ytDlpInstalledVersion: ytDlpInstalled,
                    nodeInstalledVersion: nodeInstalled
                )
            } else {
                return RuntimeReadiness(
                    workerAvailable: false,
                    workerError: "python not executable at \(pythonPath)",
                    workerPythonPath: pythonPath,
                    ffmpegAvailable: ffmpegAvailable,
                    ytDlpAvailable: ytDlpAvailable,
                    nodeAvailable: nodeAvailable,
                    ffmpegInstalledVersion: ffmpegInstalled,
                    ytDlpInstalledVersion: ytDlpInstalled,
                    nodeInstalledVersion: nodeInstalled
                )
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return RuntimeReadiness(
                workerAvailable: false,
                workerError: msg,
                workerPythonPath: nil,
                ffmpegAvailable: ffmpegAvailable,
                ytDlpAvailable: ytDlpAvailable,
                nodeAvailable: nodeAvailable,
                ffmpegInstalledVersion: ffmpegInstalled,
                ytDlpInstalledVersion: ytDlpInstalled,
                nodeInstalledVersion: nodeInstalled
            )
        }
    }
}

protocol RuntimeReadinessChecking: Sendable {
    func check() -> RuntimeReadiness
}

extension RuntimeReadinessChecker: RuntimeReadinessChecking {}
