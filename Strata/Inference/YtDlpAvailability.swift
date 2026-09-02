import Foundation

// MARK: - YtDlpAvailabilityError

enum YtDlpAvailabilityError: Error, Sendable, Equatable, LocalizedError {
    case missingApplicationSupport(String)
    case installFailed(exitCode: Int32, message: String?)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupport(let msg): return "Missing Application Support: \(msg)"
        case .installFailed(let code, let msg): return "yt-dlp install failed (exit \(code))\(msg.map { ": \($0)" } ?? "")"
        case .verificationFailed(let msg): return "yt-dlp verification failed: \(msg)"
        }
    }
}

// MARK: - YtDlpAvailabilityResult

enum YtDlpAvailabilityResult: Sendable, Equatable {
    case success(URL)
    case failure(YtDlpAvailabilityError)
}

// MARK: - YtDlpAvailability

/// Managed yt-dlp provisioning. Reuses a compatible resolved copy first
/// (managed or system, exactly `ytDlpSupportedVersion`); otherwise installs a
/// pinned release binary into `~/Library/Application Support/Strata/Tools/yt-dlp`.
struct YtDlpAvailability: Sendable {
    let applicationSupportURL: URL?
    let isExecutable: @Sendable (String) -> Bool
    let fileExists: @Sendable (String) -> Bool
    let createDirectory: @Sendable (URL) throws -> Void
    let runProcess: @Sendable (URL, [String], [String: String]?) -> ProcessOutcome
    let downloadFile: @Sendable (URL, URL) throws -> Void
    let makeExecutable: @Sendable (URL) throws -> Void
    let moveFile: @Sendable (URL, URL) throws -> Void
    let removeFile: @Sendable (URL) -> Void

    struct ProcessOutcome: Sendable, Equatable {
        let terminationStatus: Int32
        let stdout: String?
        let stderr: String?
    }

    // MARK: - Managed locations

    var managedDirectoryURL: URL? {
        applicationSupportURL?.appendingPathComponent("Strata/Tools/yt-dlp").standardizedFileURL
    }

    var managedExecutableURL: URL? {
        managedDirectoryURL?.appendingPathComponent("yt-dlp").standardizedFileURL
    }

    /// Pinned official release binary for a given yt-dlp version (macOS).
    static func downloadURL(forVersion version: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/\(version)/yt-dlp_macos")!
    }

    var downloadURL: URL {
        Self.downloadURL(forVersion: ExternalToolCompatibility.ytDlpSupportedVersion)
    }

    /// Same candidate order as ExternalToolResolver: managed first, then system.
    var candidatePaths: [String] {
        var paths: [String] = []
        if let managed = managedExecutableURL?.path {
            paths.append(managed)
        }
        paths.append("/opt/homebrew/bin/yt-dlp")
        paths.append("/usr/local/bin/yt-dlp")
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
            YtDlpAvailability.liveRun(executable: executable, arguments: args, environment: env)
        },
        downloadFile: @Sendable @escaping (URL, URL) throws -> Void = { remote, local in
            try YtDlpAvailability.liveDownload(from: remote, to: local)
        },
        makeExecutable: @Sendable @escaping (URL) throws -> Void = { url in
            try YtDlpAvailability.liveMakeExecutable(url: url)
        },
        moveFile: @Sendable @escaping (URL, URL) throws -> Void = { from, to in
            try YtDlpAvailability.liveMove(from: from, to: to)
        },
        removeFile: @Sendable @escaping (URL) -> Void = { url in
            try? FileManager.default.removeItem(at: url)
        }
    ) {
        self.applicationSupportURL = applicationSupportURL
        self.isExecutable = isExecutable
        self.fileExists = fileExists
        self.createDirectory = createDirectory
        self.runProcess = runProcess
        self.downloadFile = downloadFile
        self.makeExecutable = makeExecutable
        self.moveFile = moveFile
        self.removeFile = removeFile
    }

    // MARK: - Resolve

    /// Ensure a compatible yt-dlp is available. Reuses the first candidate that is
    /// executable and reports exactly `ytDlpSupportedVersion`. Otherwise installs
    /// the pinned managed build. Never downloads when a compatible copy resolves.
    func ensureAvailable() -> YtDlpAvailabilityResult {
        let expected = ExternalToolCompatibility.ytDlpSupportedVersion
        for path in candidatePaths {
            if !isExecutable(path) { continue }
            let outcome = runProcess(URL(fileURLWithPath: path), ["--version"], nil)
            guard outcome.terminationStatus == 0 else { continue }
            let raw = outcome.stdout ?? outcome.stderr ?? ""
            guard let version = ExternalToolCompatibility.parseYtDlpVersion(from: raw),
                  version == expected else { continue }
            return .success(URL(fileURLWithPath: path))
        }
        return installManaged()
    }

    // Backward alias
    func resolve() -> YtDlpAvailabilityResult { ensureAvailable() }

    // MARK: - Install

    private func installManaged() -> YtDlpAvailabilityResult {
        guard let appSupport = applicationSupportURL else {
            return .failure(.missingApplicationSupport("Unable to resolve Application Support directory"))
        }
        let dir = appSupport.appendingPathComponent("Strata/Tools/yt-dlp").standardizedFileURL
        do {
            try createDirectory(dir)
        } catch {
            return .failure(.missingApplicationSupport("Failed to create \(dir.path): \(error.localizedDescription)"))
        }
        let version = ExternalToolCompatibility.ytDlpSupportedVersion
        // Same-dir temp file: a partial download never sits at the managed path,
        // so ExternalToolResolver/RuntimeReadiness can never validate it as ready.
        let tmpBinary = dir.appendingPathComponent(".tmp-yt-dlp.\(UUID().uuidString)")
        do {
            try downloadFile(downloadURL, tmpBinary)
        } catch let err as YtDlpAvailabilityError {
            removeFile(tmpBinary)
            return .failure(err)
        } catch {
            removeFile(tmpBinary)
            return .failure(.installFailed(exitCode: 1, message: error.localizedDescription))
        }
        guard fileExists(tmpBinary.path) else {
            removeFile(tmpBinary)
            return .failure(.verificationFailed("downloaded yt-dlp not found at \(tmpBinary.path)"))
        }
        do {
            try makeExecutable(tmpBinary)
        } catch let err as YtDlpAvailabilityError {
            removeFile(tmpBinary)
            return .failure(err)
        } catch {
            removeFile(tmpBinary)
            return .failure(.verificationFailed("failed to make yt-dlp executable: \(error.localizedDescription)"))
        }
        if !isExecutable(tmpBinary.path) {
            removeFile(tmpBinary)
            return .failure(.verificationFailed("yt-dlp not executable at \(tmpBinary.path) after install"))
        }
        // Verify the exact supported version before exposing the managed path.
        // Only output that parses AND equals the supported version succeeds;
        // empty or unparseable output fails so a bad staged binary never moves into place.
        let verOutcome = runProcess(tmpBinary, ["--version"], nil)
        guard verOutcome.terminationStatus == 0 else {
            removeFile(tmpBinary)
            let msg = verOutcome.stderr ?? verOutcome.stdout
            return .failure(.verificationFailed("yt-dlp --version failed after install: \(msg ?? "unknown")"))
        }
        let raw = verOutcome.stdout ?? verOutcome.stderr ?? ""
        guard let found = ExternalToolCompatibility.parseYtDlpVersion(from: raw) else {
            removeFile(tmpBinary)
            return .failure(.verificationFailed("unable to parse installed yt-dlp version (expected \(version))"))
        }
        guard found == version else {
            removeFile(tmpBinary)
            return .failure(.verificationFailed("installed yt-dlp version mismatch: expected \(version), got \(found)"))
        }
        // Atomic rename into place (same directory).
        guard let dest = managedExecutableURL else {
            removeFile(tmpBinary)
            return .failure(.missingApplicationSupport("Unable to resolve managed yt-dlp path"))
        }
        do {
            try moveFile(tmpBinary, dest)
        } catch {
            removeFile(tmpBinary)
            return .failure(.installFailed(exitCode: 1, message: "failed to install yt-dlp to \(dest.path): \(error.localizedDescription)"))
        }
        // Post-move verify: only now may the managed path validate as ready.
        // Same strict rule as pre-move; a bad managed install is removed so it
        // can never validate as ready on a later resolve()/check().
        if !isExecutable(dest.path) {
            removeFile(dest)
            return .failure(.verificationFailed("yt-dlp not executable at \(dest.path) after install"))
        }
        let finalOutcome = runProcess(dest, ["--version"], nil)
        guard finalOutcome.terminationStatus == 0 else {
            removeFile(dest)
            let msg = finalOutcome.stderr ?? finalOutcome.stdout
            return .failure(.verificationFailed("yt-dlp --version failed after install: \(msg ?? "unknown")"))
        }
        let finalRaw = finalOutcome.stdout ?? finalOutcome.stderr ?? ""
        guard let finalFound = ExternalToolCompatibility.parseYtDlpVersion(from: finalRaw) else {
            removeFile(dest)
            return .failure(.verificationFailed("unable to parse installed yt-dlp version (expected \(version))"))
        }
        guard finalFound == version else {
            removeFile(dest)
            return .failure(.verificationFailed("installed yt-dlp version mismatch: expected \(version), got \(finalFound)"))
        }
        return .success(dest)
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

    // MARK: - Live download / chmod / move

    /// Live download via curl. Throws `installFailed` with the curl exit code.
    static func liveDownload(from remote: URL, to local: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-LsSf", remote.absoluteString, "-o", local.path]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw YtDlpAvailabilityError.installFailed(exitCode: 1, message: error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw YtDlpAvailabilityError.installFailed(
                exitCode: process.terminationStatus,
                message: (detail?.isEmpty == false) ? detail : "curl failed for \(remote.absoluteString)"
            )
        }
    }

    /// Mark the downloaded binary executable.
    static func liveMakeExecutable(url: URL) throws {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            throw YtDlpAvailabilityError.verificationFailed("failed to make yt-dlp executable: \(error.localizedDescription)")
        }
    }

    /// Same-directory rename (atomic on the same volume).
    static func liveMove(from: URL, to: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: to.path) {
            try fileManager.removeItem(at: to)
        }
        try fileManager.moveItem(at: from, to: to)
    }
}
