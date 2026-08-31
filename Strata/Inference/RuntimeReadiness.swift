import Foundation

struct RuntimeReadiness: Sendable, Equatable {
    let workerAvailable: Bool
    let workerError: String?
    let workerPythonPath: String?
    let ffmpegAvailable: Bool
    let ytDlpAvailable: Bool

    static let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    static let ytDlpPath = "/opt/homebrew/bin/yt-dlp"

    // Local file separation requires worker + FFmpeg (canonicalization)
    var isSeparationReady: Bool { isLocalSeparationReady }
    var isLocalSeparationReady: Bool { workerAvailable && ffmpegAvailable }
    // Separating an already-canonical loaded YouTube source requires only worker
    var isLoadedSeparationReady: Bool { workerAvailable }
    var isWorkerReady: Bool { workerAvailable }

    var isYouTubeAcquisitionReady: Bool { ffmpegAvailable && ytDlpAvailable }

    // MP3 exports require FFmpeg; WAV exports are pure file copy / AVFoundation mix and do not
    var isExportReady: Bool { isMp3ExportReady }
    var isMp3ExportReady: Bool { ffmpegAvailable }
    var isWavExportReady: Bool { true }

    var sidebarStatus: String {
        if !ffmpegAvailable {
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
            return "YouTube disabled · missing yt-dlp at \(Self.ytDlpPath)"
        }
        return "Separation ready · runs on this Mac"
    }
}

struct RuntimeReadinessChecker: Sendable {
    var isExecutable: @Sendable (String) -> Bool
    var resolveWorker: @Sendable () throws -> WorkerLaunchConfiguration

    static var live: RuntimeReadinessChecker {
        RuntimeReadinessChecker(
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            resolveWorker: { try WorkerLaunchConfiguration.resolved() }
        )
    }

    func check() -> RuntimeReadiness {
        let ffmpegAvailable = isExecutable(RuntimeReadiness.ffmpegPath)
        let ytDlpAvailable = isExecutable(RuntimeReadiness.ytDlpPath)
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
                    ytDlpAvailable: ytDlpAvailable
                )
            } else {
                return RuntimeReadiness(
                    workerAvailable: false,
                    workerError: "python not executable at \(pythonPath)",
                    workerPythonPath: pythonPath,
                    ffmpegAvailable: ffmpegAvailable,
                    ytDlpAvailable: ytDlpAvailable
                )
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Try to extract attempted python path from error message if it contains a path
            // Leave workerPythonPath nil when resolution failed before path known
            return RuntimeReadiness(
                workerAvailable: false,
                workerError: msg,
                workerPythonPath: nil,
                ffmpegAvailable: ffmpegAvailable,
                ytDlpAvailable: ytDlpAvailable
            )
        }
    }
}

protocol RuntimeReadinessChecking: Sendable {
    func check() -> RuntimeReadiness
}

extension RuntimeReadinessChecker: RuntimeReadinessChecking {}
