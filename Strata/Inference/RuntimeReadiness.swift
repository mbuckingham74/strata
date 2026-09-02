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
    let ffmpegExecutableURL: URL?
    let ytDlpExecutableURL: URL?
    let nodeExecutableURL: URL?
    let ffmpegOrigin: ToolOrigin?
    let ytDlpOrigin: ToolOrigin?
    let nodeOrigin: ToolOrigin?
    let ffmpegManagedURL: URL?
    let ytDlpManagedURL: URL?
    let nodeManagedURL: URL?
    let ffmpegAttemptedPath: String?
    let ytDlpAttemptedPath: String?
    let nodeAttemptedPath: String?

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
        nodeInstalledVersion: String? = nil,
        ffmpegExecutableURL: URL? = nil,
        ytDlpExecutableURL: URL? = nil,
        nodeExecutableURL: URL? = nil,
        ffmpegOrigin: ToolOrigin? = nil,
        ytDlpOrigin: ToolOrigin? = nil,
        nodeOrigin: ToolOrigin? = nil,
        ffmpegManagedURL: URL? = nil,
        ytDlpManagedURL: URL? = nil,
        nodeManagedURL: URL? = nil,
        ffmpegAttemptedPath: String? = nil,
        ytDlpAttemptedPath: String? = nil,
        nodeAttemptedPath: String? = nil
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
        self.ffmpegExecutableURL = ffmpegExecutableURL
        self.ytDlpExecutableURL = ytDlpExecutableURL
        self.nodeExecutableURL = nodeExecutableURL
        self.ffmpegOrigin = ffmpegOrigin
        self.ytDlpOrigin = ytDlpOrigin
        self.nodeOrigin = nodeOrigin
        self.ffmpegManagedURL = ffmpegManagedURL
        self.ytDlpManagedURL = ytDlpManagedURL
        self.nodeManagedURL = nodeManagedURL
        self.ffmpegAttemptedPath = ffmpegAttemptedPath
        self.ytDlpAttemptedPath = ytDlpAttemptedPath
        self.nodeAttemptedPath = nodeAttemptedPath
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
                let path = ffmpegAttemptedPath ?? ffmpegExecutableURL?.path ?? ffmpegManagedURL?.path ?? Self.ffmpegPath
                return "Setup needed · FFmpeg version mismatch at \(path) (installed \(installed), supported \(ExternalToolCompatibility.ffmpegSupportedVersion))"
            }
            let path = ffmpegAttemptedPath ?? ffmpegManagedURL?.path ?? Self.ffmpegPath
            return "Setup needed · missing FFmpeg at \(path)"
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
                let path = ytDlpAttemptedPath ?? ytDlpExecutableURL?.path ?? ytDlpManagedURL?.path ?? Self.ytDlpPath
                return "YouTube disabled · yt-dlp version mismatch at \(path) (installed \(installed), supported \(ExternalToolCompatibility.ytDlpSupportedVersion))"
            }
            let path = ytDlpAttemptedPath ?? ytDlpManagedURL?.path ?? Self.ytDlpPath
            return "YouTube disabled · missing yt-dlp at \(path)"
        }
        if !nodeAvailable {
            if let installed = nodeInstalledVersion {
                let path = nodeAttemptedPath ?? nodeExecutableURL?.path ?? nodeManagedURL?.path ?? Self.nodePath
                return "YouTube disabled · Node version mismatch at \(path) (installed \(installed), supported \(ExternalToolCompatibility.nodeSupportedVersion))"
            }
            let path = nodeAttemptedPath ?? nodeManagedURL?.path ?? Self.nodePath
            return "YouTube disabled · missing Node at \(path)"
        }
        return "Separation ready · runs on this Mac"
    }
}

struct RuntimeReadinessChecker: Sendable {
    var isExecutable: @Sendable (String) -> Bool
    var resolveWorker: @Sendable () throws -> WorkerLaunchConfiguration
    var runVersion: @Sendable (String) -> String?
    var resolver: ExternalToolResolver

    init(
        isExecutable: @Sendable @escaping (String) -> Bool,
        resolveWorker: @Sendable @escaping () throws -> WorkerLaunchConfiguration,
        runVersion: (@Sendable (String) -> String?)? = nil
    ) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let rv: @Sendable (String) -> String?
        if let runVersion {
            rv = runVersion
        } else {
            rv = { path in
                if path == RuntimeReadiness.ffmpegPath { return ExternalToolCompatibility.ffmpegSupportedVersion }
                if path == RuntimeReadiness.ytDlpPath { return ExternalToolCompatibility.ytDlpSupportedVersion }
                if path == RuntimeReadiness.nodePath { return ExternalToolCompatibility.nodeSupportedVersion }
                return nil
            }
        }
        self.isExecutable = isExecutable
        self.resolveWorker = resolveWorker
        self.runVersion = rv
        self.resolver = ExternalToolResolver(
            applicationSupportURL: appSupport,
            isExecutable: isExecutable,
            runVersion: rv
        )
    }

    init(
        resolver: ExternalToolResolver,
        resolveWorker: @Sendable @escaping () throws -> WorkerLaunchConfiguration
    ) {
        self.resolver = resolver
        self.isExecutable = resolver.isExecutable
        self.runVersion = resolver.runVersion
        self.resolveWorker = resolveWorker
    }

    static var live: RuntimeReadinessChecker {
        RuntimeReadinessChecker(
            resolver: .live,
            resolveWorker: { try WorkerLaunchConfiguration.resolved() }
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
            // Support managed paths via resolver logic: infer tool from suffix
            let lower = path.lowercased()
            if lower.contains("ffmpeg") {
                args = ["-version"]
            } else if lower.contains("yt-dlp") {
                args = ["--version"]
            } else if lower.contains("node") {
                args = ["--version"]
            } else {
                return nil
            }
        }
        guard let raw = captureVersionOutput(executablePath: path, arguments: args, timeout: versionTimeout) else {
            return nil
        }
        if path == RuntimeReadiness.ffmpegPath || path.lowercased().contains("ffmpeg") {
            // Try ffmpeg parse first, fallback to generic
            if let v = ExternalToolCompatibility.parseFFmpegVersion(from: raw) { return v }
            // If not ffmpeg path but contains ffmpeg, still try that
            if path.lowercased().contains("ffmpeg") { return ExternalToolCompatibility.parseFFmpegVersion(from: raw) }
        }
        if path == RuntimeReadiness.ytDlpPath || path.lowercased().contains("yt-dlp") {
            return ExternalToolCompatibility.parseYtDlpVersion(from: raw)
        }
        if path == RuntimeReadiness.nodePath || path.lowercased().contains("node") {
            return ExternalToolCompatibility.parseNodeVersion(from: raw)
        }
        // Fallback exact match handling
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
            lock.lock()
            let d = handle.availableData
            if !d.isEmpty {
                outBox.data.append(d)
            }
            lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            lock.lock()
            let d = handle.availableData
            if !d.isEmpty {
                errBox.data.append(d)
            }
            lock.unlock()
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
        let ff = resolver.resolveFFmpeg()
        let yt = resolver.resolveYtDlp()
        let node = resolver.resolveNode()

        let ffmpegAvailable = ff.isAvailable
        let ytDlpAvailable = yt.isAvailable
        let nodeAvailable = node.isAvailable

        let ffmpegInstalled: String? = ff.isAvailable ? ff.version : ff.installedVersion
        let ytDlpInstalled: String? = yt.isAvailable ? yt.version : yt.installedVersion
        let nodeInstalled: String? = node.isAvailable ? node.version : node.installedVersion

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
                    nodeInstalledVersion: nodeInstalled,
                    ffmpegExecutableURL: ff.executableURL,
                    ytDlpExecutableURL: yt.executableURL,
                    nodeExecutableURL: node.executableURL,
                    ffmpegOrigin: ff.origin,
                    ytDlpOrigin: yt.origin,
                    nodeOrigin: node.origin,
                    ffmpegManagedURL: ff.managedURL,
                    ytDlpManagedURL: yt.managedURL,
                    nodeManagedURL: node.managedURL,
                    ffmpegAttemptedPath: ff.attemptedPath,
                    ytDlpAttemptedPath: yt.attemptedPath,
                    nodeAttemptedPath: node.attemptedPath
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
                    nodeInstalledVersion: nodeInstalled,
                    ffmpegExecutableURL: ff.executableURL,
                    ytDlpExecutableURL: yt.executableURL,
                    nodeExecutableURL: node.executableURL,
                    ffmpegOrigin: ff.origin,
                    ytDlpOrigin: yt.origin,
                    nodeOrigin: node.origin,
                    ffmpegManagedURL: ff.managedURL,
                    ytDlpManagedURL: yt.managedURL,
                    nodeManagedURL: node.managedURL,
                    ffmpegAttemptedPath: ff.attemptedPath,
                    ytDlpAttemptedPath: yt.attemptedPath,
                    nodeAttemptedPath: node.attemptedPath
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
                nodeInstalledVersion: nodeInstalled,
                ffmpegExecutableURL: ff.executableURL,
                ytDlpExecutableURL: yt.executableURL,
                nodeExecutableURL: node.executableURL,
                ffmpegOrigin: ff.origin,
                ytDlpOrigin: yt.origin,
                nodeOrigin: node.origin,
                ffmpegManagedURL: ff.managedURL,
                ytDlpManagedURL: yt.managedURL,
                nodeManagedURL: node.managedURL,
                ffmpegAttemptedPath: ff.attemptedPath,
                ytDlpAttemptedPath: yt.attemptedPath,
                nodeAttemptedPath: node.attemptedPath
            )
        }
    }
}

protocol RuntimeReadinessChecking: Sendable {
    func check() -> RuntimeReadiness
}

extension RuntimeReadinessChecker: RuntimeReadinessChecking {}
