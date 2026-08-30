import Foundation

// MARK: - WorkerLaunchConfiguration

/// Resolved launch configuration for the long-lived Python NDJSON worker.
/// Executable is the uv-created venv Python directly, never via /bin/sh, uv run, or homebrew shell.
struct WorkerLaunchConfiguration: Sendable, Equatable {
    let workerDirectory: URL
    let pythonExecutable: URL
    let arguments: [String]
    let currentDirectory: URL
    let environmentAdditions: [String: String]

    /// Expected shape:
    /// executable: InferenceWorker/.venv/bin/python3
    /// arguments: -m demux_worker
    /// cwd: InferenceWorker/
    /// env additions: PYTHONUNBUFFERED=1 added to inherited environment

    // MARK: - Resolved

    /// Resolve per spec priority:
    /// 1. DEMUX_WORKER_DIRECTORY env override if present
    /// 2. Debug build pointing to $(SRCROOT)/InferenceWorker
    /// 3. Otherwise fail with typed clear error
    static func resolved() throws -> WorkerLaunchConfiguration {
        let override = ProcessInfo.processInfo.environment["DEMUX_WORKER_DIRECTORY"]
        return try resolved(workerDirectoryOverride: override, srcRoot: ProcessInfo.processInfo.environment["SRCROOT"], isDebug: isDebugBuild)
    }

    /// Testable variant.
    static func resolved(
        workerDirectoryOverride: String?,
        srcRoot: String? = nil,
        isDebug: Bool = isDebugBuild
    ) throws -> WorkerLaunchConfiguration {
        let directoryString: String

        if let ov = workerDirectoryOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !ov.isEmpty {
            directoryString = ov
        } else if isDebug, let src = srcRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !src.isEmpty {
            directoryString = (src as NSString).appendingPathComponent("InferenceWorker")
        } else if isDebug {
            // Attempt to locate via #filePath search upwards for InferenceWorker
            if let found = findWorkerViaFilePath() {
                directoryString = found.path
            } else {
                throw InferenceError.launchConfiguration(
                    "No DEMUX_WORKER_DIRECTORY and DEBUG SRCROOT not set. Set DEMUX_WORKER_DIRECTORY to absolute InferenceWorker path or ensure SRCROOT is provided in Debug."
                )
            }
        } else {
            throw InferenceError.launchConfiguration(
                "Worker location not configured. Set DEMUX_WORKER_DIRECTORY environment variable to absolute InferenceWorker directory."
            )
        }

        let workerURL = URL(fileURLWithPath: directoryString).standardizedFileURL

        // Require absolute
        guard workerURL.path.hasPrefix("/") else {
            throw InferenceError.launchConfiguration("worker directory must be absolute: \(directoryString)")
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: workerURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw InferenceError.launchConfiguration("worker directory does not exist or not a directory: \(workerURL.path)")
        }

        let pythonURL = workerURL.appendingPathComponent(".venv/bin/python3").standardizedFileURL

        guard fm.fileExists(atPath: pythonURL.path) else {
            throw InferenceError.missingWorkerExecutable("missing .venv/bin/python3 at \(pythonURL.path)")
        }
        guard fm.isExecutableFile(atPath: pythonURL.path) else {
            throw InferenceError.missingWorkerExecutable("python not executable at \(pythonURL.path)")
        }

        return WorkerLaunchConfiguration(
            workerDirectory: workerURL,
            pythonExecutable: pythonURL,
            arguments: ["-m", "demux_worker"],
            currentDirectory: workerURL,
            environmentAdditions: ["PYTHONUNBUFFERED": "1"]
        )
    }

    // MARK: - Helpers

    private static var isDebugBuild: Bool {
#if DEBUG
        return true
#else
        return false
#endif
    }

    /// Search upwards from #file for InferenceWorker directory.
    private static func findWorkerViaFilePath(file: String = #filePath) -> URL? {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        // Go up at most 6 levels
        for _ in 0..<6 {
            let candidate = url.appendingPathComponent("InferenceWorker")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                let python = candidate.appendingPathComponent(".venv/bin/python3")
                if FileManager.default.fileExists(atPath: python.path) {
                    return candidate
                }
            }
            let parent = url.deletingLastPathComponent()
            if parent == url { break }
            url = parent
        }
        // Also try SRCROOT derived from project structure: locate Strata.xcodeproj parent
        // Fallback: use current working directory
        let cwd = FileManager.default.currentDirectoryPath
        let cwdCandidate = URL(fileURLWithPath: cwd).appendingPathComponent("InferenceWorker")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cwdCandidate.path, isDirectory: &isDir), isDir.boolValue {
            return cwdCandidate
        }
        return nil
    }

    /// Produce Process configuration values.
    var processExecutableURL: URL { pythonExecutable }
    var processArguments: [String] { arguments }
    var processCurrentDirectoryURL: URL { currentDirectory }
    var processEnvironment: [String: String]? {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environmentAdditions {
            env[k] = v
        }
        return env
    }
}
