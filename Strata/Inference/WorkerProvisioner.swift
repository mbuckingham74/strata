import Foundation

// MARK: - WorkerProvisioningError

enum WorkerProvisioningError: Error, Sendable, Equatable, LocalizedError {
    case missingBundledProject(String)
    case missingUV(String)
    case directoryCreationFailed(String)
    case syncFailed(exitCode: Int32, message: String?)
    case missingPython(String)
    case prepareModelFailed(exitCode: Int32, message: String?)

    var errorDescription: String? {
        switch self {
        case .missingBundledProject(let msg): return "Missing bundled project: \(msg)"
        case .missingUV(let msg): return "Missing uv: \(msg)"
        case .directoryCreationFailed(let msg): return "Directory creation failed: \(msg)"
        case .syncFailed(let code, let msg): return "uv sync failed (exit \(code))\(msg.map { ": \($0)" } ?? "")"
        case .missingPython(let msg): return "Missing provisioned Python: \(msg)"
        case .prepareModelFailed(let code, let msg): return "prepare-model failed (exit \(code))\(msg.map { ": \($0)" } ?? "")"
        }
    }
}

// MARK: - WorkerProvisioningResult

enum WorkerProvisioningResult: Sendable, Equatable {
    case success
    case failure(WorkerProvisioningError)
}

// MARK: - WorkerProvisioner

struct WorkerProvisioner: Sendable {
    static let uvExecutablePath = "/opt/homebrew/bin/uv"

    let resourceURL: URL?
    let applicationSupportURL: URL?
    let fileExists: @Sendable (String) -> Bool
    let isExecutable: @Sendable (String) -> Bool
    let createDirectory: @Sendable (URL) throws -> Void
    let runProcess: @Sendable (URL, [String], [String: String]?) -> ProcessOutcome

    struct ProcessOutcome: Sendable, Equatable {
        let terminationStatus: Int32
        let stdout: String?
        let stderr: String?
    }

    // MARK: - Computed URLs

    var bundledProjectURL: URL? {
        resourceURL?.appendingPathComponent("InferenceWorker").standardizedFileURL
    }

    var workerRootURL: URL? {
        applicationSupportURL?.appendingPathComponent("Strata/InferenceWorker").standardizedFileURL
    }

    var venvURL: URL? {
        workerRootURL?.appendingPathComponent(".venv").standardizedFileURL
    }

    var workerPythonURL: URL? {
        venvURL?.appendingPathComponent("bin/python3").standardizedFileURL
    }

    // MARK: - Bundle fallback helper (matches AboutView pattern)

    static func resolveResourceURL() -> URL? {
        if let url = Bundle.main.resourceURL {
            return url
        }
        let bundle = Bundle(for: BundleToken.self)
        return bundle.resourceURL
    }

    private final class BundleToken {}

    // MARK: - Live convenience

    init(
        resourceURL: URL? = WorkerProvisioner.resolveResourceURL(),
        applicationSupportURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        fileExists: @Sendable @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isExecutable: @Sendable @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        createDirectory: @Sendable @escaping (URL) throws -> Void = { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        },
        runProcess: @Sendable @escaping (URL, [String], [String: String]?) -> ProcessOutcome = { executable, args, env in
            WorkerProvisioner.liveRun(executable: executable, arguments: args, environment: env)
        }
    ) {
        self.resourceURL = resourceURL
        self.applicationSupportURL = applicationSupportURL
        self.fileExists = fileExists
        self.isExecutable = isExecutable
        self.createDirectory = createDirectory
        self.runProcess = runProcess
    }

    // MARK: - Provision

    func provision() -> WorkerProvisioningResult {
        // 1. Validate bundled project (never access Documents / repo checkout)
        guard let projectURL = bundledProjectURL else {
            return .failure(.missingBundledProject("Bundled InferenceWorker not found: resourceURL is nil"))
        }
        let pyproject = projectURL.appendingPathComponent("pyproject.toml").path
        if !fileExists(pyproject) {
            return .failure(.missingBundledProject("missing \(pyproject)"))
        }
        let lock = projectURL.appendingPathComponent("uv.lock").path
        if !fileExists(lock) {
            return .failure(.missingBundledProject("missing \(lock)"))
        }
        let pyVersion = projectURL.appendingPathComponent(".python-version").path
        if !fileExists(pyVersion) {
            return .failure(.missingBundledProject("missing \(pyVersion)"))
        }
        let readme = projectURL.appendingPathComponent("README.md").path
        if !fileExists(readme) {
            return .failure(.missingBundledProject("missing \(readme)"))
        }
        let src = projectURL.appendingPathComponent("src").path
        if !fileExists(src) {
            return .failure(.missingBundledProject("missing \(src)"))
        }

        // 2. Validate uv
        if !isExecutable(Self.uvExecutablePath) {
            return .failure(.missingUV("uv not found or not executable at \(Self.uvExecutablePath)"))
        }

        // 3. Resolve destination (only manage .venv, never delete parent Strata or Projects)
        guard let workerRoot = workerRootURL, let venv = venvURL else {
            return .failure(.directoryCreationFailed("Unable to resolve Application Support destination"))
        }

        do {
            try createDirectory(workerRoot)
        } catch {
            return .failure(.directoryCreationFailed("Failed to create \(workerRoot.path): \(error.localizedDescription)"))
        }

        // 4. Run uv sync
        let uvURL = URL(fileURLWithPath: Self.uvExecutablePath)
        let syncArgs = [
            "sync",
            "--project", projectURL.path,
            "--locked",
            "--no-dev",
            "--no-editable",
            "--managed-python",
            "--reinstall-package", "demux-worker"
        ]
        let env = ["UV_PROJECT_ENVIRONMENT": venv.path]
        let syncOutcome = runProcess(uvURL, syncArgs, env)
        if syncOutcome.terminationStatus != 0 {
            let msg = syncOutcome.stderr ?? syncOutcome.stdout
            return .failure(.syncFailed(exitCode: syncOutcome.terminationStatus, message: msg))
        }

        // 5. Verify python exists after sync
        guard let pythonURL = workerPythonURL else {
            return .failure(.missingPython("Unable to resolve worker Python path"))
        }
        if !fileExists(pythonURL.path) {
            return .failure(.missingPython("expected python not found at \(pythonURL.path) after uv sync"))
        }
        if !isExecutable(pythonURL.path) {
            return .failure(.missingPython("python not executable at \(pythonURL.path)"))
        }

        // 6. Run prepare-model
        let prepareArgs = ["-m", "demux_worker", "prepare-model"]
        let prepareOutcome = runProcess(pythonURL, prepareArgs, nil)
        if prepareOutcome.terminationStatus != 0 {
            let msg = prepareOutcome.stderr ?? prepareOutcome.stdout
            return .failure(.prepareModelFailed(exitCode: prepareOutcome.terminationStatus, message: msg))
        }

        return .success
    }

    // MARK: - Live process runner (only used when not injected)

    static func liveRun(executable: URL, arguments: [String], environment: [String: String]?) -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let env = environment {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            process.environment = merged
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: error.localizedDescription)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8)
        let stderr = String(data: errData, encoding: .utf8)
        return ProcessOutcome(terminationStatus: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
