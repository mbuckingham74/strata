import Foundation

enum ExternalToolCompatibility {
    static let ffmpegSupportedVersion = "9.0.1"
    static let ytDlpSupportedVersion = "2026.08.19"
    static let nodeSupportedVersion = "26.8.1"
    static let uvSupportedVersion = "0.12.8"

    // MARK: - Parsing helpers (pure, testable)

    /// Parse FFmpeg version from `ffmpeg -version` output.
    /// Example first line: "ffmpeg version 9.0.1 Copyright ..."
    static func parseFFmpegVersion(from output: String) -> String? {
        // Use first line only
        let firstLine = output.components(separatedBy: .newlines).first ?? output
        // Regex: ffmpeg version ([0-9.]+)
        guard let regex = try? NSRegularExpression(pattern: #"ffmpeg version ([0-9.]+)"#) else { return nil }
        let range = NSRange(firstLine.startIndex..<firstLine.endIndex, in: firstLine)
        guard let match = regex.firstMatch(in: firstLine, range: range),
              match.numberOfRanges >= 2,
              let verRange = Range(match.range(at: 1), in: firstLine) else {
            return nil
        }
        let ver = String(firstLine[verRange])
        return ver.isEmpty ? nil : ver
    }

    /// Parse yt-dlp version from `yt-dlp --version` output (trimmed).
    static func parseYtDlpVersion(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parse Node version from `node --version` output. Strips leading 'v'.
    static func parseNodeVersion(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("v") {
            let stripped = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? nil : stripped
        }
        return trimmed
    }

    /// Parse uv version from `uv --version` output.
    /// Example: "uv 0.12.8 (abc...)" or "uv 0.12.8"
    static func parseUvVersion(from output: String) -> String? {
        let firstLine = output.components(separatedBy: .newlines).first ?? output
        guard let regex = try? NSRegularExpression(pattern: #"uv ([0-9.]+)"#) else { return nil }
        let range = NSRange(firstLine.startIndex..<firstLine.endIndex, in: firstLine)
        guard let match = regex.firstMatch(in: firstLine, range: range),
              match.numberOfRanges >= 2,
              let verRange = Range(match.range(at: 1), in: firstLine) else {
            return nil
        }
        let ver = String(firstLine[verRange])
        return ver.isEmpty ? nil : ver
    }
}
