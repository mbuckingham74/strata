import Foundation

enum ToolOrigin: Sendable, Equatable {
    case managed
    case system
}

struct ResolvedExternalTool: Sendable, Equatable {
    let executableURL: URL?
    let version: String?
    let origin: ToolOrigin?
    var isAvailable: Bool { executableURL != nil }
    let managedURL: URL
    let installedVersion: String?
    let attemptedPath: String?
}

struct ExternalToolResolver: Sendable {
    let applicationSupportURL: URL?
    let isExecutable: @Sendable (String) -> Bool
    let runVersion: @Sendable (String) -> String?

    var managedFFmpegURL: URL? {
        applicationSupportURL?.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").standardizedFileURL
    }
    var managedYtDlpURL: URL? {
        applicationSupportURL?.appendingPathComponent("Strata/Tools/yt-dlp/yt-dlp").standardizedFileURL
    }
    var managedNodeURL: URL? {
        applicationSupportURL?.appendingPathComponent("Strata/Tools/node/bin/node").standardizedFileURL
    }

    var ffmpegCandidatePaths: [String] {
        var paths: [String] = []
        if let m = managedFFmpegURL?.path { paths.append(m) }
        paths.append("/opt/homebrew/bin/ffmpeg")
        paths.append("/usr/local/bin/ffmpeg")
        return paths
    }
    var ytDlpCandidatePaths: [String] {
        var paths: [String] = []
        if let m = managedYtDlpURL?.path { paths.append(m) }
        paths.append("/opt/homebrew/bin/yt-dlp")
        paths.append("/usr/local/bin/yt-dlp")
        return paths
    }
    var nodeCandidatePaths: [String] {
        var paths: [String] = []
        if let m = managedNodeURL?.path { paths.append(m) }
        paths.append("/opt/homebrew/bin/node")
        paths.append("/usr/local/bin/node")
        return paths
    }

    private func fallbackManagedURL(for tool: String) -> URL {
        switch tool {
        case "ffmpeg": return managedFFmpegURL ?? URL(fileURLWithPath: "/tmp/Strata/Tools/ffmpeg/ffmpeg")
        case "yt-dlp": return managedYtDlpURL ?? URL(fileURLWithPath: "/tmp/Strata/Tools/yt-dlp/yt-dlp")
        case "node": return managedNodeURL ?? URL(fileURLWithPath: "/tmp/Strata/Tools/node/bin/node")
        default: return URL(fileURLWithPath: "/tmp/Strata/Tools/\(tool)/\(tool)")
        }
    }

    private func resolve(candidates: [String], managedURL: URL, isCompatible: (String) -> Bool) -> ResolvedExternalTool {
        var lastInstalled: String?
        var lastPath: String?
        for path in candidates {
            if !isExecutable(path) { continue }
            guard let v = runVersion(path) else {
                lastInstalled = "unknown"
                lastPath = path
                continue
            }
            if !isCompatible(v) {
                lastInstalled = v
                lastPath = path
                continue
            }
            let origin: ToolOrigin = (path == managedURL.path) ? .managed : .system
            return ResolvedExternalTool(
                executableURL: URL(fileURLWithPath: path),
                version: v,
                origin: origin,
                managedURL: managedURL,
                installedVersion: nil,
                attemptedPath: nil
            )
        }
        return ResolvedExternalTool(
            executableURL: nil,
            version: nil,
            origin: nil,
            managedURL: managedURL,
            installedVersion: lastInstalled,
            attemptedPath: lastPath
        )
    }

    func resolveFFmpeg() -> ResolvedExternalTool {
        let managed = fallbackManagedURL(for: "ffmpeg")
        return resolve(candidates: ffmpegCandidatePaths, managedURL: managed) { v in
            v == ExternalToolCompatibility.ffmpegSupportedVersion
        }
    }

    func resolveYtDlp() -> ResolvedExternalTool {
        let managed = fallbackManagedURL(for: "yt-dlp")
        return resolve(candidates: ytDlpCandidatePaths, managedURL: managed) { v in
            v == ExternalToolCompatibility.ytDlpSupportedVersion
        }
    }

    func resolveNode() -> ResolvedExternalTool {
        let managed = fallbackManagedURL(for: "node")
        return resolve(candidates: nodeCandidatePaths, managedURL: managed) { v in
            isNodeCompatible(version: v)
        }
    }

    func resolveAll() -> (ffmpeg: ResolvedExternalTool, ytDlp: ResolvedExternalTool, node: ResolvedExternalTool) {
        (resolveFFmpeg(), resolveYtDlp(), resolveNode())
    }

    private func isNodeCompatible(version: String) -> Bool {
        // version already parsed via parseNodeVersion, e.g., "26.8.1"
        let majorStr = version.split(separator: ".").first.map(String.init) ?? version
        guard let major = Int(majorStr.trimmingCharacters(in: .whitespaces)) else { return false }
        return major >= 22
    }

    static var live: ExternalToolResolver {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return ExternalToolResolver(
            applicationSupportURL: appSupport,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            runVersion: { path in
                let lower = path.lowercased()
                if lower.contains("ffmpeg") {
                    guard let raw = RuntimeReadinessChecker.captureVersionOutput(executablePath: path, arguments: ["-version"], timeout: RuntimeReadinessChecker.versionTimeout) else { return nil }
                    return ExternalToolCompatibility.parseFFmpegVersion(from: raw)
                } else if lower.contains("yt-dlp") {
                    guard let raw = RuntimeReadinessChecker.captureVersionOutput(executablePath: path, arguments: ["--version"], timeout: RuntimeReadinessChecker.versionTimeout) else { return nil }
                    return ExternalToolCompatibility.parseYtDlpVersion(from: raw)
                } else if lower.hasSuffix("/node") || lower.contains("/node/") || lower == "node" {
                    guard let raw = RuntimeReadinessChecker.captureVersionOutput(executablePath: path, arguments: ["--version"], timeout: RuntimeReadinessChecker.versionTimeout) else { return nil }
                    return ExternalToolCompatibility.parseNodeVersion(from: raw)
                } else if lower.contains("node") {
                    guard let raw = RuntimeReadinessChecker.captureVersionOutput(executablePath: path, arguments: ["--version"], timeout: RuntimeReadinessChecker.versionTimeout) else { return nil }
                    return ExternalToolCompatibility.parseNodeVersion(from: raw)
                }
                return nil
            }
        )
    }
}
