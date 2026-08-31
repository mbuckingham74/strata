import AVFoundation
import Foundation
import Synchronization

enum StemExportError: Error, LocalizedError, Equatable {
    case sourceAndDestinationMatch
    case combinedExportRequiresMultipleStems
    case invalidMix(String)
    case ffmpegLaunchFailed(String)
    case ffmpegFailed(exitCode: Int32, message: String?)

    var errorDescription: String? {
        switch self {
        case .sourceAndDestinationMatch:
            return "Choose a location other than the original stem file."
        case .combinedExportRequiresMultipleStems:
            return "Select at least two stems to export a combined mix."
        case .invalidMix(let message):
            return "Could not export the stem mix: \(message)"
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
    private static let mixChunkFrameCount: AVAudioFrameCount = 16_384

    static func defaultYouTubeMP3Filename(metadata: YouTubeTrackMetadata?) -> String {
        if let exportBaseName = metadata?.exportBaseName {
            return "\(exportBaseName).mp3"
        }
        return "YouTube Audio.mp3"
    }

    static func defaultFilename(
        for stem: StemName,
        format: StemExportFormat = .wav,
        sourceBaseName: String? = nil
    ) -> String {
        if let sourceBaseName, !sourceBaseName.isEmpty {
            return "\(sourceBaseName) - \(stem.rawValue.capitalized).\(format.filenameExtension)"
        }
        return "\(stem.rawValue).\(format.filenameExtension)"
    }

    static func defaultMixFilename(
        for stems: [StemName],
        format: StemExportFormat = .mp3,
        sourceBaseName: String? = nil
    ) -> String {
        let selectedStems = Set(stems)
        let stemDescription = StemName.allCases
            .filter { selectedStems.contains($0) }
            .map { $0.rawValue.capitalized }
            .joined(separator: " + ")
        let mixDescription = stemDescription.isEmpty ? "Stems" : stemDescription

        if let sourceBaseName, !sourceBaseName.isEmpty {
            return "\(sourceBaseName) - \(mixDescription).\(format.filenameExtension)"
        }
        return "\(mixDescription).\(format.filenameExtension)"
    }

    static func export(
        _ artifact: StemArtifact,
        to destinationURL: URL,
        format: StemExportFormat = .wav,
        metadata: YouTubeTrackMetadata? = nil,
        artworkURL: URL? = nil,
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
            try encodeMP3(
                from: artifact.url,
                to: destinationURL,
                metadata: metadata,
                artworkURL: artworkURL,
                ffmpegURL: ffmpegURL
            )
        }
    }

    static func exportMP3(
        from sourceURL: URL,
        to destinationURL: URL,
        metadata: YouTubeTrackMetadata? = nil,
        artworkURL: URL? = nil,
        ffmpegURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    ) throws {
        let resolvedSourceURL = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDestinationURL = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedSourceURL != resolvedDestinationURL else {
            throw StemExportError.sourceAndDestinationMatch
        }
        try encodeMP3(
            from: sourceURL,
            to: destinationURL,
            metadata: metadata,
            artworkURL: artworkURL,
            ffmpegURL: ffmpegURL
        )
    }

    static func exportMix(
        _ artifacts: [StemArtifact],
        to destinationURL: URL,
        format: StemExportFormat = .mp3,
        metadata: YouTubeTrackMetadata? = nil,
        artworkURL: URL? = nil,
        ffmpegURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
        fileManager: FileManager = .default
    ) throws {
        guard artifacts.count >= 2 else {
            throw StemExportError.combinedExportRequiresMultipleStems
        }
        guard Set(artifacts.map(\.name)).count == artifacts.count else {
            throw StemExportError.invalidMix("Each selected stem must be unique.")
        }

        let resolvedDestinationURL = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        for artifact in artifacts {
            let sourceURL = artifact.url.standardizedFileURL.resolvingSymlinksInPath()
            guard sourceURL != resolvedDestinationURL else {
                throw StemExportError.sourceAndDestinationMatch
            }
        }

        switch format {
        case .wav:
            try writeAlignedMix(artifacts, to: destinationURL, fileManager: fileManager)
        case .mp3:
            let temporaryDirectoryURL = fileManager.temporaryDirectory
                .appendingPathComponent("Strata-Mix-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: temporaryDirectoryURL) }

            let temporaryWAVURL = temporaryDirectoryURL.appendingPathComponent("mix.wav")
            try writeAlignedMix(artifacts, to: temporaryWAVURL, fileManager: fileManager)
            try encodeMP3(
                from: temporaryWAVURL,
                to: destinationURL,
                metadata: metadata,
                artworkURL: artworkURL,
                ffmpegURL: ffmpegURL
            )
        }
    }

    private static func writeAlignedMix(
        _ artifacts: [StemArtifact],
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        var files: [AVAudioFile] = []
        var commonFrameCount: UInt64?
        for artifact in artifacts {
            guard artifact.sampleRate == canonicalSampleRate,
                  artifact.channels == canonicalChannels,
                  artifact.frameCount > 0 else {
                throw StemExportError.invalidMix("\(artifact.name.rawValue.capitalized) is not canonical 44.1 kHz stereo audio.")
            }

            let metadata: (sampleRate: UInt32, channels: UInt32, frames: UInt64)
            do {
                metadata = try validateAudioFile(at: artifact.url, expectedFrames: artifact.frameCount)
            } catch {
                throw StemExportError.invalidMix(error.localizedDescription)
            }
            guard metadata.sampleRate == canonicalSampleRate,
                  metadata.channels == canonicalChannels,
                  metadata.frames == artifact.frameCount else {
                throw StemExportError.invalidMix("\(artifact.name.rawValue.capitalized) does not match its validated audio metadata.")
            }
            if let commonFrameCount, commonFrameCount != artifact.frameCount {
                throw StemExportError.invalidMix("Selected stems must have equal frame counts.")
            }
            commonFrameCount = artifact.frameCount

            do {
                let file = try AVAudioFile(forReading: artifact.url)
                guard file.processingFormat.commonFormat == .pcmFormatFloat32,
                      file.processingFormat.sampleRate == Double(canonicalSampleRate),
                      file.processingFormat.channelCount == canonicalChannels,
                      UInt64(file.length) == artifact.frameCount else {
                    throw StemExportError.invalidMix("\(artifact.name.rawValue.capitalized) could not be read as canonical audio.")
                }
                files.append(file)
            } catch let error as StemExportError {
                throw error
            } catch {
                throw StemExportError.invalidMix(error.localizedDescription)
            }
        }

        guard let totalFrameCount = commonFrameCount else {
            throw StemExportError.combinedExportRequiresMultipleStems
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(canonicalSampleRate),
            AVNumberOfChannelsKey: canonicalChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw StemExportError.invalidMix(error.localizedDescription)
        }

        let outputFormat = outputFile.processingFormat
        var framesWritten: UInt64 = 0
        while framesWritten < totalFrameCount {
            let remainingFrames = totalFrameCount - framesWritten
            let frameCount = AVAudioFrameCount(min(UInt64(mixChunkFrameCount), remainingFrames))
            guard let mixBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: frameCount
            ), let mixChannels = mixBuffer.floatChannelData else {
                throw StemExportError.invalidMix("Could not allocate an output audio buffer.")
            }
            mixBuffer.frameLength = frameCount
            for channel in 0..<Int(canonicalChannels) {
                mixChannels[channel].update(repeating: 0, count: Int(frameCount))
            }

            for file in files {
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: frameCount
                ) else {
                    throw StemExportError.invalidMix("Could not allocate an input audio buffer.")
                }
                do {
                    try file.read(into: inputBuffer, frameCount: frameCount)
                } catch {
                    throw StemExportError.invalidMix(error.localizedDescription)
                }
                guard inputBuffer.frameLength == frameCount,
                      let inputChannels = inputBuffer.floatChannelData else {
                    throw StemExportError.invalidMix("A selected stem ended before the expected aligned frame count.")
                }

                for channel in 0..<Int(canonicalChannels) {
                    for frame in 0..<Int(frameCount) {
                        mixChannels[channel][frame] += inputChannels[channel][frame]
                    }
                }
            }

            for channel in 0..<Int(canonicalChannels) {
                for frame in 0..<Int(frameCount) {
                    mixChannels[channel][frame] = min(max(mixChannels[channel][frame], -1), 1)
                }
            }

            do {
                try outputFile.write(from: mixBuffer)
            } catch {
                throw StemExportError.invalidMix(error.localizedDescription)
            }
            framesWritten += UInt64(frameCount)
        }
    }

    private static func encodeMP3(
        from sourceURL: URL,
        to destinationURL: URL,
        metadata: YouTubeTrackMetadata?,
        artworkURL: URL?,
        ffmpegURL: URL
    ) throws {
        let process = Process()
        process.executableURL = ffmpegURL
        var arguments = [
            "-nostdin",
            "-y",
            "-i", sourceURL.path,
        ]
        if let artworkURL {
            arguments += [
                "-i", artworkURL.path,
                "-map", "0:a:0",
                "-map", "1:v:0",
            ]
        }
        arguments += [
            "-codec:a", "libmp3lame",
            "-q:a", "2",
        ]
        if artworkURL != nil {
            arguments += [
                "-codec:v", "mjpeg",
                "-disposition:v:0", "attached_pic",
                "-metadata:s:v:0", "title=Album cover",
                "-metadata:s:v:0", "comment=Cover (front)",
            ]
        }
        if metadata != nil || artworkURL != nil {
            arguments += ["-id3v2_version", "3"]
        }
        if let metadata {
            let fields: [(String, String?)] = [
                ("artist", metadata.artist),
                ("title", metadata.title),
                ("album", metadata.album),
                ("album_artist", metadata.albumArtist),
                ("date", metadata.year),
                ("genre", metadata.genre),
                ("track", metadata.trackNumber),
            ]
            for (key, value) in fields {
                if let value {
                    arguments += ["-metadata", "\(key)=\(value)"]
                }
            }
        }
        arguments.append(destinationURL.path)
        process.arguments = arguments
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
