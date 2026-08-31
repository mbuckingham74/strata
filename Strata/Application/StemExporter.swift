import Foundation
import Synchronization

enum StemExportError: Error, LocalizedError, Equatable {
    case sourceAndDestinationMatch
    case ffmpegLaunchFailed(String)
    case ffmpegFailed(exitCode: Int32, message: String?)

    var errorDescription: String? {
        switch self {
        case .sourceAndDestinationMatch:
            return "Choose a location other than the original stem file."
        case .ffmpegLaunchFailed(let message):
            return "Could not start MP3 encoding: \(message)"
        case .ffmpegFailed(let exitCode, let message):
            if let message, !message.isEmpty {
                return "MP3 encoding failed with exit \(exitCode): \(message)"
            }
            return "MP3 encoding failed with exit \(exitCode)."
        }
    }
}

enum StemExportFormat: Sendable, Equatable {
    case wav
    case mp3

    var filenameExtension: String {
        switch self {
        case .wav: return "wav"
        case .mp3: return "mp3"
        }
    }
}

struct StemExporter {
    static func defaultFilename(for stem: StemName, format: StemExportFormat = .wav) -> String {
        "\(stem.rawValue).\(format.filenameExtension)"
    }

    static func export(
        _ artifact: StemArtifact,
        to destinationURL: URL,
        format: StemExportFormat = .wav,
        ffmpegURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
        fileManager: FileManager = .default
    ) throws {
        let sourceURL = artifact.url.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDestinationURL = destinationURL.standardizedFileURL.resolvingSymlinksInPath()

        guard sourceURL != resolvedDestinationURL else {
            throw StemExportError.sourceAndDestinationMatch
        }

        switch format {
        case .wav:
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: artifact.url, to: destinationURL)
        case .mp3:
            try encodeMP3(from: artifact.url, to: destinationURL, ffmpegURL: ffmpegURL)
        }
    }

    private static func encodeMP3(from sourceURL: URL, to destinationURL: URL, ffmpegURL: URL) throws {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-nostdin",
            "-y",
            "-i", sourceURL.path,
            "-codec:a", "libmp3lame",
            "-q:a", "2",
            destinationURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw StemExportError.ffmpegLaunchFailed(error.localizedDescription)
        }

        let stderrHandle = stderrPipe.fileHandleForReading
        let stderrData = Mutex(Data())
        let stderrReadCompleted = DispatchGroup()
        stderrReadCompleted.enter()
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                stderrReadCompleted.leave()
                return
            }
            stderrData.withLock { $0.append(chunk) }
        }

        process.waitUntilExit()
        stderrReadCompleted.wait()

        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData.withLock { $0 }, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw StemExportError.ffmpegFailed(
                exitCode: process.terminationStatus,
                message: message?.isEmpty == false ? message : nil
            )
        }
    }
}
