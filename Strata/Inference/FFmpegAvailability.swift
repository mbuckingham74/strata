import Foundation

// MARK: - FFmpegAvailabilityError

enum FFmpegAvailabilityError: Error, Sendable, Equatable, LocalizedError {
    case missingApplicationSupport(String)
    case installFailed(exitCode: Int32, message: String?)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupport(let msg): return "Missing Application Support: \(msg)"
        case .installFailed(let code, let msg): return "ffmpeg install failed (exit \(code))\(msg.map { ": \($0)" } ?? "")"
        case .verificationFailed(let msg): return "ffmpeg verification failed: \(msg)"
        }
    }
}

// MARK: - FFmpegAvailabilityResult

enum FFmpegAvailabilityResult: Sendable, Equatable {
    case success(URL)
    case failure(FFmpegAvailabilityError)
}

// MARK: - FFmpegAvailability

/// Managed FFmpeg provisioning. Reuses a compatible resolved copy first
/// (managed or system, exactly `ffmpegSupportedVersion`); otherwise installs a
/// pinned static build into `~/Library/Application Support/Strata/Tools/ffmpeg`.
struct FFmpegAvailability: Sendable {
    let applicationSupportURL: URL?
    let isExecutable: @Sendable (String) -> Bool
    let fileExists: @Sendable (String) -> Bool
    let createDirectory: @Sendable (URL) throws -> Void
    let runProcess: @Sendable (URL, [String], [String: String]?) -> ProcessOutcome
    let downloadFile: @Sendable (URL, URL) throws -> Void
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
        applicationSupportURL?.appendingPathComponent("Strata/Tools/ffmpeg").standardizedFileURL
    }

    var managedExecutableURL: URL? {
        managedDirectoryURL?.appendingPathComponent("ffmpeg").standardizedFileURL
    }

    /// Pinned static build for a given FFmpeg version (macOS arm64).
    static func downloadURL(forVersion version: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://evermeet.cx/ffmpeg/ffmpeg-\(version).7z")!
    }

    var downloadURL: URL {
        Self.downloadURL(forVersion: ExternalToolCompatibility.ffmpegSupportedVersion)
    }

    /// Same candidate order as ExternalToolResolver: managed first, then system.
    var candidatePaths: [String] {
        var paths: [String] = []
        if let managed = managedExecutableURL?.path {
            paths.append(managed)
        }
        paths.append("/opt/homebrew/bin/ffmpeg")
        paths.append("/usr/local/bin/ffmpeg")
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
            FFmpegAvailability.liveRun(executable: executable, arguments: args, environment: env)
        },
        downloadFile: @Sendable @escaping (URL, URL) throws -> Void = { remote, local in
            try FFmpegAvailability.liveDownload(from: remote, to: local)
        },
        extractBinary: @Sendable @escaping (URL, URL) throws -> Void = { archive, dest in
            try FFmpegAvailability.liveExtract(archive: archive, destBinary: dest)
        },
        moveFile: @Sendable @escaping (URL, URL) throws -> Void = { from, to in
            try FFmpegAvailability.liveMove(from: from, to: to)
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
        self.extractBinary = extractBinary
        self.moveFile = moveFile
        self.removeFile = removeFile
    }

    // MARK: - Resolve

    /// Ensure a compatible ffmpeg is available. Reuses the first candidate that is
    /// executable and reports exactly `ffmpegSupportedVersion`. Otherwise installs
    /// the pinned managed build. Never downloads when a compatible copy resolves.
    func ensureAvailable() -> FFmpegAvailabilityResult {
        let expected = ExternalToolCompatibility.ffmpegSupportedVersion
        for path in candidatePaths {
            if !isExecutable(path) { continue }
            let outcome = runProcess(URL(fileURLWithPath: path), ["-version"], nil)
            guard outcome.terminationStatus == 0 else { continue }
            let raw = outcome.stdout ?? outcome.stderr ?? ""
            guard let version = ExternalToolCompatibility.parseFFmpegVersion(from: raw),
                  version == expected else { continue }
            return .success(URL(fileURLWithPath: path))
        }
        return installManaged()
    }

    // Backward alias
    func resolve() -> FFmpegAvailabilityResult { ensureAvailable() }

    // MARK: - Install

    private func installManaged() -> FFmpegAvailabilityResult {
        guard let appSupport = applicationSupportURL else {
            return .failure(.missingApplicationSupport("Unable to resolve Application Support directory"))
        }
        let dir = appSupport.appendingPathComponent("Strata/Tools/ffmpeg").standardizedFileURL
        do {
            try createDirectory(dir)
        } catch {
            return .failure(.missingApplicationSupport("Failed to create \(dir.path): \(error.localizedDescription)"))
        }
        let version = ExternalToolCompatibility.ffmpegSupportedVersion
        // Same-dir temp files: a partial download never sits at the managed path,
        // so ExternalToolResolver/RuntimeReadiness can never validate it as ready.
        let tmpArchive = dir.appendingPathComponent(".tmp-ffmpeg-archive.\(UUID().uuidString)")
        let tmpBinary = dir.appendingPathComponent(".tmp-ffmpeg.\(UUID().uuidString)")
        do {
            try downloadFile(downloadURL, tmpArchive)
        } catch let err as FFmpegAvailabilityError {
            removeFile(tmpArchive)
            removeFile(tmpBinary)
            return .failure(err)
        } catch {
            removeFile(tmpArchive)
            removeFile(tmpBinary)
            return .failure(.installFailed(exitCode: 1, message: error.localizedDescription))
        }
        do {
            try extractBinary(tmpArchive, tmpBinary)
        } catch let err as FFmpegAvailabilityError {
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
            return .failure(.verificationFailed("extracted ffmpeg not found at \(tmpBinary.path)"))
        }
        if !isExecutable(tmpBinary.path) {
            removeFile(tmpBinary)
            return .failure(.verificationFailed("ffmpeg not executable at \(tmpBinary.path) after install"))
        }
        // Verify the exact supported version before exposing the managed path.
        // Only output that parses AND equals the supported version succeeds;
        // empty or unparseable output fails so a bad staged binary never moves into place.
        let verOutcome = runProcess(tmpBinary, ["-version"], nil)
        guard verOutcome.terminationStatus == 0 else {
            removeFile(tmpBinary)
            let msg = verOutcome.stderr ?? verOutcome.stdout
            return .failure(.verificationFailed("ffmpeg -version failed after install: \(msg ?? "unknown")"))
        }
        let raw = verOutcome.stdout ?? verOutcome.stderr ?? ""
        guard let found = ExternalToolCompatibility.parseFFmpegVersion(from: raw) else {
            removeFile(tmpBinary)
            return .failure(.verificationFailed("unable to parse installed ffmpeg version (expected \(version))"))
        }
        guard found == version else {
            removeFile(tmpBinary)
            return .failure(.verificationFailed("installed ffmpeg version mismatch: expected \(version), got \(found)"))
        }
        // Atomic rename into place (same directory).
        guard let dest = managedExecutableURL else {
            removeFile(tmpBinary)
            return .failure(.missingApplicationSupport("Unable to resolve managed ffmpeg path"))
        }
        do {
            try moveFile(tmpBinary, dest)
        } catch {
            removeFile(tmpBinary)
            return .failure(.installFailed(exitCode: 1, message: "failed to install ffmpeg to \(dest.path): \(error.localizedDescription)"))
        }
        // Post-move verify: only now may the managed path validate as ready.
        // Same strict rule as pre-move; a bad managed install is removed so it
        // can never validate as ready on a later resolve()/check().
        if !isExecutable(dest.path) {
            removeFile(dest)
            return .failure(.verificationFailed("ffmpeg not executable at \(dest.path) after install"))
        }
        let finalOutcome = runProcess(dest, ["-version"], nil)
        guard finalOutcome.terminationStatus == 0 else {
            removeFile(dest)
            let msg = finalOutcome.stderr ?? finalOutcome.stdout
            return .failure(.verificationFailed("ffmpeg -version failed after install: \(msg ?? "unknown")"))
        }
        let finalRaw = finalOutcome.stdout ?? finalOutcome.stderr ?? ""
        guard let finalFound = ExternalToolCompatibility.parseFFmpegVersion(from: finalRaw) else {
            removeFile(dest)
            return .failure(.verificationFailed("unable to parse installed ffmpeg version (expected \(version))"))
        }
        guard finalFound == version else {
            removeFile(dest)
            return .failure(.verificationFailed("installed ffmpeg version mismatch: expected \(version), got \(finalFound)"))
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

    // MARK: - Live download / extract / move

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
            throw FFmpegAvailabilityError.installFailed(exitCode: 1, message: error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw FFmpegAvailabilityError.installFailed(
                exitCode: process.terminationStatus,
                message: (detail?.isEmpty == false) ? detail : "curl failed for \(remote.absoluteString)"
            )
        }
    }

    /// Live extraction of the pinned archive into a staged binary. Supports .zip
    /// via unzip and anything tar/libarchive reads (including .7z) via tar, then
    /// locates the top-level `ffmpeg` binary and stages it at `destBinary`.
    static func liveExtract(archive: URL, destBinary: URL) throws {
        let dir = destBinary.deletingLastPathComponent()
        let outcome: ProcessOutcome
        if archive.pathExtension.lowercased() == "zip" {
            outcome = liveRun(
                executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-j", "-o", archive.path, "ffmpeg", "-d", dir.path],
                environment: nil
            )
        } else {
            outcome = liveRun(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xf", archive.path, "-C", dir.path],
                environment: nil
            )
        }
        guard outcome.terminationStatus == 0 else {
            let msg = outcome.stderr ?? outcome.stdout
            throw FFmpegAvailabilityError.installFailed(
                exitCode: outcome.terminationStatus,
                message: "failed to extract \(archive.lastPathComponent)\(msg.map { ": \($0)" } ?? "")"
            )
        }
        let fileManager = FileManager.default
        var located: URL?
        let topLevel = dir.appendingPathComponent("ffmpeg")
        if fileManager.fileExists(atPath: topLevel.path) {
            located = topLevel
        } else if let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let nested = entry.appendingPathComponent("ffmpeg")
                if fileManager.fileExists(atPath: nested.path) {
                    located = nested
                    break
                }
            }
        }
        guard let found = located else {
            throw FFmpegAvailabilityError.verificationFailed("extracted ffmpeg binary not found in \(archive.lastPathComponent)")
        }
        if found.path != destBinary.path {
            if fileManager.fileExists(atPath: destBinary.path) {
                try? fileManager.removeItem(at: destBinary)
            }
            do {
                try fileManager.moveItem(at: found, to: destBinary)
            } catch {
                throw FFmpegAvailabilityError.installFailed(exitCode: 1, message: "failed to stage ffmpeg binary: \(error.localizedDescription)")
            }
        }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destBinary.path)
        } catch {
            throw FFmpegAvailabilityError.verificationFailed("failed to make ffmpeg executable: \(error.localizedDescription)")
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
