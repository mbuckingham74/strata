import Foundation

// MARK: - NodeAvailabilityError

enum NodeAvailabilityError: Error, Sendable, Equatable, LocalizedError {
    case missingApplicationSupport(String)
    case installFailed(exitCode: Int32, message: String?)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupport(let msg): return "Missing Application Support: \(msg)"
        case .installFailed(let code, let msg): return "node install failed (exit \(code))\(msg.map { ": \($0)" } ?? "")"
        case .verificationFailed(let msg): return "node verification failed: \(msg)"
        }
    }
}

// MARK: - NodeAvailabilityResult

enum NodeAvailabilityResult: Sendable, Equatable {
    case success(URL)
    case failure(NodeAvailabilityError)
}

// MARK: - NodeAvailability

/// Managed Node provisioning. Reuses a compatible resolved copy first
/// (managed or system, major >= 22 per ExternalToolResolver); otherwise installs
/// pinned Node 26.8.1 into `~/Library/Application Support/Strata/Tools/node`.
struct NodeAvailability: Sendable {
    let applicationSupportURL: URL?
    let isExecutable: @Sendable (String) -> Bool
    let fileExists: @Sendable (String) -> Bool
    let createDirectory: @Sendable (URL) throws -> Void
    let runProcess: @Sendable (URL, [String], [String: String]?) -> ProcessOutcome
    let downloadFile: @Sendable (URL, URL) throws -> Void
    let verifyChecksum: @Sendable (URL) throws -> Void
    let extractBinary: @Sendable (URL, URL) throws -> Void
    let moveFile: @Sendable (URL, URL) throws -> Void
    let removeFile: @Sendable (URL) -> Void

    struct ProcessOutcome: Sendable, Equatable {
        let terminationStatus: Int32
        let stdout: String?
        let stderr: String?
    }

    // MARK: - Managed locations

    var managedDirectoryURL: URL? {
        applicationSupportURL?.appendingPathComponent("Strata/Tools/node").standardizedFileURL
    }

    var managedBinDirectoryURL: URL? {
        managedDirectoryURL?.appendingPathComponent("bin").standardizedFileURL
    }

    var managedExecutableURL: URL? {
        managedBinDirectoryURL?.appendingPathComponent("node").standardizedFileURL
    }

    /// Pinned Node distribution (macOS arm64) for a given version.
    static func downloadURL(forVersion version: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://nodejs.org/dist/v\(version)/node-v\(version)-darwin-arm64.tar.gz")!
    }

    var downloadURL: URL {
        Self.downloadURL(forVersion: ExternalToolCompatibility.nodeSupportedVersion)
    }

    /// Expected SHA-256 of the pinned distribution archive.
    static let expectedSHA256 = "6e577fd0d9db776db82306629e441a9dace416702622aebdd171c9dfaa41f4d2"

    /// Same candidate order as ExternalToolResolver: managed first, then system.
    var candidatePaths: [String] {
        var paths: [String] = []
        if let managed = managedExecutableURL?.path {
            paths.append(managed)
        }
        paths.append("/opt/homebrew/bin/node")
        paths.append("/usr/local/bin/node")
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
            NodeAvailability.liveRun(executable: executable, arguments: args, environment: env)
        },
        downloadFile: @Sendable @escaping (URL, URL) throws -> Void = { remote, local in
            try NodeAvailability.liveDownload(from: remote, to: local)
        },
        verifyChecksum: @Sendable @escaping (URL) throws -> Void = { local in
            try NodeAvailability.liveVerifyChecksum(file: local)
        },
        extractBinary: @Sendable @escaping (URL, URL) throws -> Void = { archive, dest in
            try NodeAvailability.liveExtract(archive: archive, destBinary: dest)
        },
        moveFile: @Sendable @escaping (URL, URL) throws -> Void = { from, to in
            try NodeAvailability.liveMove(from: from, to: to)
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
        self.verifyChecksum = verifyChecksum
        self.extractBinary = extractBinary
        self.moveFile = moveFile
        self.removeFile = removeFile
    }

    // MARK: - Resolve

    /// Ensure a compatible node is available. Reuses the first candidate that is
    /// executable and reports a version with major >= 22 (same rule as
    /// ExternalToolResolver). Otherwise installs the pinned managed build.
    /// Never downloads when a compatible copy resolves.
    func ensureAvailable() -> NodeAvailabilityResult {
        for path in candidatePaths {
            if !isExecutable(path) { continue }
            let outcome = runProcess(URL(fileURLWithPath: path), ["--version"], nil)
            guard outcome.terminationStatus == 0 else { continue }
            let raw = outcome.stdout ?? outcome.stderr ?? ""
            guard let version = ExternalToolCompatibility.parseNodeVersion(from: raw),
                  Self.isCompatible(version: version) else { continue }
            return .success(URL(fileURLWithPath: path))
        }
        return installManaged()
    }

    // Backward alias
    func resolve() -> NodeAvailabilityResult { ensureAvailable() }

    /// Same compatibility rule as ExternalToolResolver: major >= 22.
    static func isCompatible(version: String) -> Bool {
        let majorStr = version.split(separator: ".").first.map(String.init) ?? version
        guard let major = Int(majorStr.trimmingCharacters(in: .whitespaces)) else { return false }
        return major >= 22
    }

    // MARK: - Install

    private func installManaged() -> NodeAvailabilityResult {
        guard let appSupport = applicationSupportURL else {
            return .failure(.missingApplicationSupport("Unable to resolve Application Support directory"))
        }
        let binDir = appSupport.appendingPathComponent("Strata/Tools/node/bin").standardizedFileURL
        do {
            try createDirectory(binDir)
        } catch {
            return .failure(.missingApplicationSupport("Failed to create \(binDir.path): \(error.localizedDescription)"))
        }
        let version = ExternalToolCompatibility.nodeSupportedVersion
        // Same-dir temp files: a partial download never sits at the managed path,
        // so ExternalToolResolver/RuntimeReadiness can never validate it as ready.
        let tmpArchive = binDir.appendingPathComponent(".tmp-node-archive.\(UUID().uuidString)")
        let tmpBinary = binDir.appendingPathComponent(".tmp-node.\(UUID().uuidString)")
        do {
            try downloadFile(downloadURL, tmpArchive)
        } catch let err as NodeAvailabilityError {
            removeFile(tmpArchive)
            removeFile(tmpBinary)
            return .failure(err)
        } catch {
            removeFile(tmpArchive)
            removeFile(tmpBinary)
            return .failure(.installFailed(exitCode: 1, message: error.localizedDescription))
        }
        do {
            try verifyChecksum(tmpArchive)
        } catch let err as NodeAvailabilityError {
            removeFile(tmpArchive)
            removeFile(tmpBinary)
            return .failure(err)
        } catch {
            removeFile(tmpArchive)
            removeFile(tmpBinary)
            return .failure(.verificationFailed("node archive checksum failed: \(error.localizedDescription)"))
        }
        do {
            try extractBinary(tmpArchive, tmpBinary)
        } catch let err as NodeAvailabilityError {
            removeFile(tmpArchive)
            removeFile(tmpBinary)
            return .failure(err)
        } catch {
            removeFile(tmpArchive)
            removeFile(tmpBinary)
            return .failure(.installFailed(exitCode: 1, message: error.localizedDescription))
        }
        removeFile(tmpArchive)
        guard fileExists(tmpBinary.path) else {
            removeFile(tmpBinary)
            return .failure(.verificationFailed("extracted node not found at \(tmpBinary.path)"))
        }
        if !isExecutable(tmpBinary.path) {
            removeFile(tmpBinary)
            return .failure(.verificationFailed("node not executable at \(tmpBinary.path) after install"))
        }
        // Verify the exact supported version before exposing the managed path.
        // Only output that parses AND equals the supported version succeeds;
        // empty or unparseable output fails so a bad staged binary never moves into place.
        let verOutcome = runProcess(tmpBinary, ["--version"], nil)
        guard verOutcome.terminationStatus == 0 else {
            removeFile(tmpBinary)
            let msg = verOutcome.stderr ?? verOutcome.stdout
            return .failure(.verificationFailed("node --version failed after install: \(msg ?? "unknown")"))
        }
        let raw = verOutcome.stdout ?? verOutcome.stderr ?? ""
        guard let found = ExternalToolCompatibility.parseNodeVersion(from: raw) else {
            removeFile(tmpBinary)
            return .failure(.verificationFailed("unable to parse installed node version (expected \(version))"))
        }
        guard found == version else {
            removeFile(tmpBinary)
            return .failure(.verificationFailed("installed node version mismatch: expected \(version), got \(found)"))
        }
        // Atomic rename into place (same directory).
        guard let dest = managedExecutableURL else {
            removeFile(tmpBinary)
            return .failure(.missingApplicationSupport("Unable to resolve managed node path"))
        }
        do {
            try moveFile(tmpBinary, dest)
        } catch {
            removeFile(tmpBinary)
            return .failure(.installFailed(exitCode: 1, message: "failed to install node to \(dest.path): \(error.localizedDescription)"))
        }
        // Post-move verify: only now may the managed path validate as ready.
        // Same strict rule as pre-move; a bad managed install is removed so it
        // can never validate as ready on a later resolve()/check().
        if !isExecutable(dest.path) {
            removeFile(dest)
            return .failure(.verificationFailed("node not executable at \(dest.path) after install"))
        }
        let finalOutcome = runProcess(dest, ["--version"], nil)
        guard finalOutcome.terminationStatus == 0 else {
            removeFile(dest)
            let msg = finalOutcome.stderr ?? finalOutcome.stdout
            return .failure(.verificationFailed("node --version failed after install: \(msg ?? "unknown")"))
        }
        let finalRaw = finalOutcome.stdout ?? finalOutcome.stderr ?? ""
        guard let finalFound = ExternalToolCompatibility.parseNodeVersion(from: finalRaw) else {
            removeFile(dest)
            return .failure(.verificationFailed("unable to parse installed node version (expected \(version))"))
        }
        guard finalFound == version else {
            removeFile(dest)
            return .failure(.verificationFailed("installed node version mismatch: expected \(version), got \(finalFound)"))
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

    // MARK: - Live download / verify / extract / move

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
            throw NodeAvailabilityError.installFailed(exitCode: 1, message: error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NodeAvailabilityError.installFailed(
                exitCode: process.terminationStatus,
                message: (detail?.isEmpty == false) ? detail : "curl failed for \(remote.absoluteString)"
            )
        }
    }

    /// Live SHA-256 verification via shasum against the pinned checksum.
    static func liveVerifyChecksum(file: URL, expected: String = expectedSHA256) throws {
        let outcome = liveRun(
            executable: URL(fileURLWithPath: "/usr/bin/shasum"),
            arguments: ["-a", "256", file.path],
            environment: nil
        )
        guard outcome.terminationStatus == 0 else {
            let msg = outcome.stderr ?? outcome.stdout
            throw NodeAvailabilityError.installFailed(
                exitCode: outcome.terminationStatus,
                message: "failed to checksum \(file.lastPathComponent)\(msg.map { ": \($0)" } ?? "")"
            )
        }
        let raw = outcome.stdout ?? ""
        let actual = raw.split(separator: " ").first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard let actual, !actual.isEmpty else {
            throw NodeAvailabilityError.verificationFailed("unable to parse checksum for \(file.lastPathComponent)")
        }
        guard actual == expected.lowercased() else {
            throw NodeAvailabilityError.verificationFailed(
                "checksum mismatch for \(file.lastPathComponent): expected \(expected), got \(actual)"
            )
        }
    }

    /// Live extraction of the pinned Node tarball into a staged binary.
    /// Extracts to an isolated temp dir, locates `bin/node` inside the
    /// top-level `node-v*/` directory, and stages it at `destBinary`.
    static func liveExtract(archive: URL, destBinary: URL) throws {
        let fileManager = FileManager.default
        let extractDir = fileManager.temporaryDirectory
            .appendingPathComponent(".tmp-node-extract.\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
        } catch {
            throw NodeAvailabilityError.installFailed(exitCode: 1, message: "failed to create extract dir: \(error.localizedDescription)")
        }
        defer { try? fileManager.removeItem(at: extractDir) }
        let outcome = liveRun(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", extractDir.path],
            environment: nil
        )
        guard outcome.terminationStatus == 0 else {
            let msg = outcome.stderr ?? outcome.stdout
            throw NodeAvailabilityError.installFailed(
                exitCode: outcome.terminationStatus,
                message: "failed to extract \(archive.lastPathComponent)\(msg.map { ": \($0)" } ?? "")"
            )
        }
        var located: URL?
        if let entries = try? fileManager.contentsOfDirectory(
            at: extractDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let nested = entry.appendingPathComponent("bin/node")
                if fileManager.fileExists(atPath: nested.path) {
                    located = nested
                    break
                }
            }
        }
        guard let found = located else {
            throw NodeAvailabilityError.verificationFailed("extracted node binary not found in \(archive.lastPathComponent)")
        }
        if fileManager.fileExists(atPath: destBinary.path) {
            try? fileManager.removeItem(at: destBinary)
        }
        do {
            try fileManager.moveItem(at: found, to: destBinary)
        } catch {
            throw NodeAvailabilityError.installFailed(exitCode: 1, message: "failed to stage node binary: \(error.localizedDescription)")
        }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destBinary.path)
        } catch {
            throw NodeAvailabilityError.verificationFailed("failed to make node executable: \(error.localizedDescription)")
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
