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
        return try resolved(
            workerDirectoryOverride: override,
            srcRoot: ProcessInfo.processInfo.environment["SRCROOT"],
            isDebug: isDebugBuild,
            bundlePath: Bundle.main.bundlePath,
            resourceURL: Bundle.main.resourceURL,
            applicationSupportURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            sourceFilePath: #filePath,
            currentDirectoryPath: FileManager.default.currentDirectoryPath
        )
    }

    /// Testable variant (backward compat). Now injects bundle-relative checks and gates source-tree fallback behind isInstalledBundle.
    static func resolved(
        workerDirectoryOverride: String?,
        srcRoot: String? = nil,
        isDebug: Bool = isDebugBuild
    ) throws -> WorkerLaunchConfiguration {
        try resolved(
            workerDirectoryOverride: workerDirectoryOverride,
            srcRoot: srcRoot,
            isDebug: isDebug,
            bundlePath: Bundle.main.bundlePath,
            resourceURL: Bundle.main.resourceURL,
            applicationSupportURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            sourceFilePath: #filePath,
            currentDirectoryPath: FileManager.default.currentDirectoryPath
        )
    }

    /// Full testable variant with injection for installed-vs-dev gating and file probe tracking.
    static func resolved(
        workerDirectoryOverride: String?,
        srcRoot: String?,
        isDebug: Bool,
        bundlePath: String,
        resourceURL: URL?,
        applicationSupportURL: URL?,
        fileExists: @escaping (String) -> Bool,
        isExecutable: @escaping (String) -> Bool,
        sourceFilePath: String,
        currentDirectoryPath: String
    ) throws -> WorkerLaunchConfiguration {
        let directoryString: String

        if let ov = workerDirectoryOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !ov.isEmpty {
            directoryString = ov
        } else if isInstalledBundle(bundlePath: bundlePath) {
            // Installed app (e.g. /Applications/Strata.app): never probe source-tree / Documents. Only app-owned candidates.
            if let candidate = firstValidAppOwnedCandidate(
                resourceURL: resourceURL,
                applicationSupportURL: applicationSupportURL,
                fileExists: fileExists,
                isExecutable: isExecutable
            ) {
                directoryString = candidate.path
            } else {
                let resourceHint = resourceURL?.appendingPathComponent("InferenceWorker").path ?? "Bundle resource InferenceWorker"
                let supportHint = applicationSupportURL?.appendingPathComponent("Strata/InferenceWorker").path ?? "Application Support/Strata/InferenceWorker"
                throw InferenceError.launchConfiguration(
                    "Worker not found. Checked \(supportHint) and \(resourceHint). Run scripts/install-inference-worker.sh from the repository to create the worker at ~/Library/Application Support/Strata/InferenceWorker, or set DEMUX_WORKER_DIRECTORY to an absolute InferenceWorker directory."
                )
            }
        } else {
            // Development / non-installed: prefer app-owned candidate, then source-tree fallbacks.
            if let candidate = firstValidAppOwnedCandidate(
                resourceURL: resourceURL,
                applicationSupportURL: applicationSupportURL,
                fileExists: fileExists,
                isExecutable: isExecutable
            ) {
                directoryString = candidate.path
            } else if isDebug, let src = srcRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !src.isEmpty {
                directoryString = (src as NSString).appendingPathComponent("InferenceWorker")
            } else if isDebug {
                if let found = findWorkerViaFilePath(file: sourceFilePath, currentDirectoryPath: currentDirectoryPath, fileExists: fileExists) {
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
        }

        let workerURL = URL(fileURLWithPath: directoryString).standardizedFileURL

        // Require absolute
        guard workerURL.path.hasPrefix("/") else {
            throw InferenceError.launchConfiguration("worker directory must be absolute: \(directoryString)")
        }

        guard fileExists(workerURL.path) else {
            throw InferenceError.launchConfiguration("worker directory does not exist or not a directory: \(workerURL.path)")
        }

        let pythonURL = workerURL.appendingPathComponent(".venv/bin/python3").standardizedFileURL

        guard fileExists(pythonURL.path) else {
            throw InferenceError.missingWorkerExecutable("missing .venv/bin/python3 at \(pythonURL.path)")
        }
        guard isExecutable(pythonURL.path) else {
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

    static func isInstalledBundle(bundlePath: String) -> Bool {
        bundlePath.contains("/Applications/")
    }

    private static func firstValidAppOwnedCandidate(
        resourceURL: URL?,
        applicationSupportURL: URL?,
        fileExists: (String) -> Bool,
        isExecutable: (String) -> Bool
    ) -> URL? {
        if let sup = applicationSupportURL?.appendingPathComponent("Strata/InferenceWorker").standardizedFileURL {
            if fileExists(sup.path) {
                let python = sup.appendingPathComponent(".venv/bin/python3").standardizedFileURL
                if fileExists(python.path), isExecutable(python.path) {
                    return sup
                }
            }
        }
        if let res = resourceURL?.appendingPathComponent("InferenceWorker").standardizedFileURL {
            if fileExists(res.path) {
                let python = res.appendingPathComponent(".venv/bin/python3").standardizedFileURL
                if fileExists(python.path), isExecutable(python.path) {
                    return res
                }
            }
        }
        return nil
    }

    /// Search upwards from #file for InferenceWorker directory.
    private static func findWorkerViaFilePath(file: String = #filePath) -> URL? {
        findWorkerViaFilePath(file: file, currentDirectoryPath: FileManager.default.currentDirectoryPath, fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    static func findWorkerViaFilePath(file: String, currentDirectoryPath: String, fileExists: (String) -> Bool) -> URL? {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        // Go up at most 6 levels
        for _ in 0..<6 {
            let candidate = url.appendingPathComponent("InferenceWorker")
            if fileExists(candidate.path) {
                let python = candidate.appendingPathComponent(".venv/bin/python3")
                if fileExists(python.path) {
                    return candidate
                }
            }
            let parent = url.deletingLastPathComponent()
            if parent == url { break }
            url = parent
        }
        // Fallback: use current working directory
        let cwdCandidate = URL(fileURLWithPath: currentDirectoryPath).appendingPathComponent("InferenceWorker")
        if fileExists(cwdCandidate.path) {
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
