import Foundation

// MARK: - UvAvailabilityError

enum UvAvailabilityError: Error, Sendable, Equatable, LocalizedError {
    case missingApplicationSupport(String)
    case installFailed(exitCode: Int32, message: String?)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupport(let msg): return "Missing Application Support: \(msg)"
        case .installFailed(let code, let msg): return "uv install failed (exit \(code))\(msg.map { ": \($0)" } ?? "")"
        case .verificationFailed(let msg): return "uv verification failed: \(msg)"
        }
    }
}

// MARK: - UvAvailabilityResult

enum UvAvailabilityResult: Sendable, Equatable {
    case success(URL)
    case failure(UvAvailabilityError)
}

// MARK: - UvAvailability

struct UvAvailability: Sendable {
    let applicationSupportURL: URL?
    let isExecutable: @Sendable (String) -> Bool
    let fileExists: @Sendable (String) -> Bool
    let createDirectory: @Sendable (URL) throws -> Void
    let runProcess: @Sendable (URL, [String], [String: String]?) -> ProcessOutcome

    struct ProcessOutcome: Sendable, Equatable {
        let terminationStatus: Int32
        let stdout: String?
        let stderr: String?
    }

    // MARK: - Managed locations

    var managedDirectoryURL: URL? {
        applicationSupportURL?.appendingPathComponent("Strata/Tools/uv").standardizedFileURL
    }

    var managedExecutableURL: URL? {
        managedDirectoryURL?.appendingPathComponent("uv").standardizedFileURL
    }

    var candidatePaths: [String] {
        var paths: [String] = []
        if let managed = managedExecutableURL?.path {
            paths.append(managed)
        }
        paths.append("/opt/homebrew/bin/uv")
        paths.append("/usr/local/bin/uv")
        return paths
    }

    // MARK: - Live convenience

    init(
        applicationSupportURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        isExecutable: @Sendable @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        fileExists: @Sendable @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        createDirectory: @Sendable @escaping (URL) throws -> Void = { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        },
        runProcess: @Sendable @escaping (URL, [String], [String: String]?) -> ProcessOutcome = { executable, args, env in
            UvAvailability.liveRun(executable: executable, arguments: args, environment: env)
        }
    ) {
        self.applicationSupportURL = applicationSupportURL
        self.isExecutable = isExecutable
        self.fileExists = fileExists
        self.createDirectory = createDirectory
        self.runProcess = runProcess
    }

    // MARK: - Resolve

    /// Ensure a usable uv is available. Checks managed copy first, then system candidates.
    /// Usable means executable and reports a parseable version (any version — not required to match the pinned fallback-install version).
    /// Otherwise installs pinned Astral uv into `~/Library/Application Support/Strata/Tools/uv`
    /// via unmanaged mechanism: `curl -LsSf https://astral.sh/uv/<version>/install.sh | env UV_UNMANAGED_INSTALL="<dest>" sh`
    func ensureAvailable() -> UvAvailabilityResult {
        // 1. Check existing candidates in priority — reuse any parseable existing uv, skip managed install.
        for path in candidatePaths {
            if !isExecutable(path) { continue }
            let outcome = runProcess(URL(fileURLWithPath: path), ["--version"], nil)
            guard outcome.terminationStatus == 0 else { continue }
            let raw = outcome.stdout ?? outcome.stderr ?? ""
            guard ExternalToolCompatibility.parseUvVersion(from: raw) != nil else { continue }
            return .success(URL(fileURLWithPath: path))
        }
        // 2. Install managed copy
        return installManaged()
    }

    // Backward alias
    func resolve() -> UvAvailabilityResult { ensureAvailable() }

    // MARK: - Install

    private func installManaged() -> UvAvailabilityResult {
        guard let appSupport = applicationSupportURL else {
            return .failure(.missingApplicationSupport("Unable to resolve Application Support directory"))
        }
        let dest = appSupport.appendingPathComponent("Strata/Tools/uv").standardizedFileURL
        do {
            try createDirectory(dest)
        } catch {
            return .failure(.missingApplicationSupport("Failed to create \(dest.path): \(error.localizedDescription)"))
        }
        let version = ExternalToolCompatibility.uvSupportedVersion
        // Flat unmanaged layout: binary ends up at <dest>/uv, no shell profile/PATH modification.
        let shellCommand = "curl -LsSf https://astral.sh/uv/\(version)/install.sh | env UV_UNMANAGED_INSTALL=\"\(dest.path)\" sh"
        let installOutcome = runProcess(URL(fileURLWithPath: "/bin/sh"), ["-c", shellCommand], nil)
        if installOutcome.terminationStatus != 0 {
            let msg = installOutcome.stderr ?? installOutcome.stdout
            return .failure(.installFailed(exitCode: installOutcome.terminationStatus, message: msg))
        }
        guard let managedURL = managedExecutableURL else {
            return .failure(.missingApplicationSupport("Unable to resolve managed uv path"))
        }
        if !isExecutable(managedURL.path) {
            return .failure(.verificationFailed("uv not executable at \(managedURL.path) after install"))
        }
        // Verify version matches pinned after install
        let verOutcome = runProcess(managedURL, ["--version"], nil)
        if verOutcome.terminationStatus == 0 {
            let raw = verOutcome.stdout ?? verOutcome.stderr ?? ""
            if let ver = ExternalToolCompatibility.parseUvVersion(from: raw) {
                if ver != version {
                    return .failure(.verificationFailed("installed uv version mismatch: expected \(version), got \(ver)"))
                }
            } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(.verificationFailed("unable to parse uv version from \(raw)"))
            }
        } else {
            let msg = verOutcome.stderr ?? verOutcome.stdout
            return .failure(.verificationFailed("uv --version failed after install: \(msg ?? "unknown")"))
        }
        return .success(managedURL)
    }

    // MARK: - Live process runner (merges environment like WorkerProvisioner)

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
