import AVFoundation
import XCTest
@testable import Strata

final class StemExporterTests: XCTestCase {
    private func makeExecutable(at url: URL, contents: String) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeArtifact(name: StemName, url: URL, data: Data) throws -> StemArtifact {
        try data.write(to: url)
        return StemArtifact(
            name: name,
            url: url,
            sha256: sha256Hex(of: data),
            fileSize: UInt64(data.count),
            frameCount: 1,
            channels: 2,
            sampleRate: 44_100
        )
    }

    private func makeWAVArtifact(
        name: StemName,
        url: URL,
        leftSamples: [Float],
        rightSamples: [Float]
    ) throws -> StemArtifact {
        guard leftSamples.count == rightSamples.count, !leftSamples.isEmpty else {
            throw NSError(domain: "StemExporterTests", code: 1)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(canonicalSampleRate),
            AVNumberOfChannelsKey: canonicalChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frameCount = AVAudioFrameCount(leftSamples.count)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ), let channels = buffer.floatChannelData else {
            throw NSError(domain: "StemExporterTests", code: 2)
        }
        buffer.frameLength = frameCount
        for frame in 0..<leftSamples.count {
            channels[0][frame] = leftSamples[frame]
            channels[1][frame] = rightSamples[frame]
        }
        try file.write(from: buffer)

        let data = try Data(contentsOf: url)
        return StemArtifact(
            name: name,
            url: url,
            sha256: sha256Hex(of: data),
            fileSize: UInt64(data.count),
            frameCount: UInt64(frameCount),
            channels: canonicalChannels,
            sampleRate: canonicalSampleRate
        )
    }

    func testDefaultFilenameUsesEachStemNameAndWAVExtension() {
        for stem in StemName.allCases {
            XCTAssertEqual(StemExporter.defaultFilename(for: stem), "\(stem.rawValue).wav")
        }
    }

    func testDefaultFilenameUsesEachStemNameAndMP3Extension() {
        for stem in StemName.allCases {
            XCTAssertEqual(
                StemExporter.defaultFilename(for: stem, format: .mp3),
                "\(stem.rawValue).mp3"
            )
        }
    }

    func testDefaultYouTubeMP3FilenameUsesReliableMetadataOrFallback() throws {
        let metadata = try XCTUnwrap(
            YouTubeTrackMetadata(artist: "Massive Attack", title: "Teardrop")
        )
        XCTAssertEqual(
            StemExporter.defaultYouTubeMP3Filename(metadata: metadata),
            "Massive Attack - Teardrop.mp3"
        )
        XCTAssertEqual(
            StemExporter.defaultYouTubeMP3Filename(metadata: nil),
            "YouTube Audio.mp3"
        )
    }

    func testDefaultFilenameUsesYouTubeMetadataForEveryStemAndFormat() throws {
        let metadata = try XCTUnwrap(
            YouTubeTrackMetadata(artist: "Massive Attack", title: "Teardrop")
        )

        for stem in StemName.allCases {
            let stemName = stem.rawValue.capitalized
            XCTAssertEqual(
                StemExporter.defaultFilename(
                    for: stem,
                    format: .wav,
                    sourceBaseName: metadata.exportBaseName
                ),
                "Massive Attack - Teardrop - \(stemName).wav"
            )
            XCTAssertEqual(
                StemExporter.defaultFilename(
                    for: stem,
                    format: .mp3,
                    sourceBaseName: metadata.exportBaseName
                ),
                "Massive Attack - Teardrop - \(stemName).mp3"
            )
        }
    }

    func testUnreliableYouTubeMetadataFallsBackToStemOnlyFilename() {
        XCTAssertNil(YouTubeTrackMetadata(artist: nil, title: "Teardrop"))
        XCTAssertNil(YouTubeTrackMetadata(artist: "Massive Attack", title: nil))
        XCTAssertNil(YouTubeTrackMetadata(artist: "  ", title: "Teardrop"))
        let missingArtist = YouTubeTrackMetadata(artist: "N/A", title: "Song")
        XCTAssertNil(missingArtist)
        XCTAssertNil(YouTubeTrackMetadata(artist: "Artist", title: "n/a"))
        XCTAssertEqual(
            StemExporter.defaultFilename(for: .vocals, sourceBaseName: missingArtist?.exportBaseName),
            "vocals.wav"
        )

        for stem in StemName.allCases {
            XCTAssertEqual(
                StemExporter.defaultFilename(for: stem, sourceBaseName: nil),
                "\(stem.rawValue).wav"
            )
            XCTAssertEqual(
                StemExporter.defaultFilename(for: stem, format: .mp3, sourceBaseName: nil),
                "\(stem.rawValue).mp3"
            )
        }
    }

    func testDefaultMixFilenameUsesMP3CanonicalStemOrderAndYouTubeMetadata() {
        XCTAssertEqual(
            StemExporter.defaultMixFilename(
                for: [.bass, .drums],
                sourceBaseName: "Artist - Song Title"
            ),
            "Artist - Song Title - Drums + Bass.mp3"
        )
        XCTAssertEqual(
            StemExporter.defaultMixFilename(for: [.bass, .drums]),
            "Drums + Bass.mp3"
        )
        XCTAssertEqual(
            StemExporter.defaultMixFilename(
                for: [.bass, .drums],
                format: .wav,
                sourceBaseName: "Artist - Song Title"
            ),
            "Artist - Song Title - Drums + Bass.wav"
        )
        XCTAssertEqual(
            StemExporter.defaultMixFilename(for: [.bass, .drums], format: .wav),
            "Drums + Bass.wav"
        )
    }

    func testCombinedWAVExportIncludesSelectedStemsAndPreservesAlignment() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let drums = try makeWAVArtifact(
            name: .drums,
            url: directoryURL.appendingPathComponent("drums.wav"),
            leftSamples: [0, 0.25, 0.10, 0, 0, 0],
            rightSamples: [0, 0, 0.15, 0, 0, 0.20]
        )
        let bass = try makeWAVArtifact(
            name: .bass,
            url: directoryURL.appendingPathComponent("bass.wav"),
            leftSamples: [0, 0, 0.20, 0, 0.40, 0],
            rightSamples: [0.30, 0, 0.10, 0, 0, 0]
        )
        _ = try makeWAVArtifact(
            name: .vocals,
            url: directoryURL.appendingPathComponent("vocals.wav"),
            leftSamples: [0.75, 0.75, 0.75, 0.75, 0.75, 0.75],
            rightSamples: [0.75, 0.75, 0.75, 0.75, 0.75, 0.75]
        )
        let destinationURL = directoryURL.appendingPathComponent("selected-mix.wav")

        try StemExporter.exportMix([drums, bass], to: destinationURL, format: .wav)

        let metadata = try validateAudioFile(at: destinationURL, expectedFrames: 6)
        XCTAssertEqual(metadata.sampleRate, canonicalSampleRate)
        XCTAssertEqual(metadata.channels, canonicalChannels)
        XCTAssertEqual(metadata.frames, 6)

        let outputFile = try AVAudioFile(forReading: destinationURL)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFile.processingFormat,
            frameCapacity: AVAudioFrameCount(outputFile.length)
        ) else {
            return XCTFail("Could not allocate output verification buffer")
        }
        try outputFile.read(into: outputBuffer)
        let outputChannels = try XCTUnwrap(outputBuffer.floatChannelData)
        let expectedLeft: [Float] = [0, 0.25, 0.30, 0, 0.40, 0]
        let expectedRight: [Float] = [0.30, 0, 0.25, 0, 0, 0.20]
        for frame in 0..<expectedLeft.count {
            XCTAssertEqual(outputChannels[0][frame], expectedLeft[frame], accuracy: 0.000_01)
            XCTAssertEqual(outputChannels[1][frame], expectedRight[frame], accuracy: 0.000_01)
        }
    }

    func testCombinedMP3ExportDefaultsToAlignedSelectedStemMixBeforeEncoding() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let drums = try makeWAVArtifact(
            name: .drums,
            url: directoryURL.appendingPathComponent("drums.wav"),
            leftSamples: [0, 0.25, 0.10, 0, 0, 0],
            rightSamples: [0, 0, 0.15, 0, 0, 0.20]
        )
        let bass = try makeWAVArtifact(
            name: .bass,
            url: directoryURL.appendingPathComponent("bass.wav"),
            leftSamples: [0, 0, 0.20, 0, 0.40, 0],
            rightSamples: [0.30, 0, 0.10, 0, 0, 0]
        )
        _ = try makeWAVArtifact(
            name: .vocals,
            url: directoryURL.appendingPathComponent("vocals.wav"),
            leftSamples: [0.75, 0.75, 0.75, 0.75, 0.75, 0.75],
            rightSamples: [0.75, 0.75, 0.75, 0.75, 0.75, 0.75]
        )

        let destinationURL = directoryURL.appendingPathComponent("selected-mix.mp3")
        let capturedMixURL = directoryURL.appendingPathComponent("captured-mix.wav")
        let ffmpegURL = directoryURL.appendingPathComponent("ffmpeg")
        try makeExecutable(at: ffmpegURL, contents: """
        #!/bin/sh
        input=''
        output=''
        previous=''
        for argument in "$@"; do
            if [ "$previous" = '-i' ]; then input="$argument"; fi
            previous="$argument"
            output="$argument"
        done
        cp "$input" '\(capturedMixURL.path)'
        printf 'encoded-selected-mix' > "$output"
        """)

        try StemExporter.exportMix(
            [drums, bass],
            to: destinationURL,
            ffmpegURL: ffmpegURL
        )

        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("encoded-selected-mix".utf8))
        let metadata = try validateAudioFile(at: capturedMixURL, expectedFrames: 6)
        XCTAssertEqual(metadata.sampleRate, canonicalSampleRate)
        XCTAssertEqual(metadata.channels, canonicalChannels)
        XCTAssertEqual(metadata.frames, 6)

        let outputFile = try AVAudioFile(forReading: capturedMixURL)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFile.processingFormat,
            frameCapacity: AVAudioFrameCount(outputFile.length)
        ) else {
            return XCTFail("Could not allocate output verification buffer")
        }
        try outputFile.read(into: outputBuffer)
        let outputChannels = try XCTUnwrap(outputBuffer.floatChannelData)
        let expectedLeft: [Float] = [0, 0.25, 0.30, 0, 0.40, 0]
        let expectedRight: [Float] = [0.30, 0, 0.25, 0, 0, 0.20]
        for frame in 0..<expectedLeft.count {
            XCTAssertEqual(outputChannels[0][frame], expectedLeft[frame], accuracy: 0.000_01)
            XCTAssertEqual(outputChannels[1][frame], expectedRight[frame], accuracy: 0.000_01)
        }
    }

    func testExportCopiesArtifactBytesWithoutChangingSource() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("vocals.wav")
        let destinationURL = directoryURL.appendingPathComponent("exported-vocals.wav")
        let sourceData = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xFF, 0x10, 0x80])
        let artifact = try makeArtifact(name: .vocals, url: sourceURL, data: sourceData)

        try StemExporter.export(artifact, to: destinationURL)

        XCTAssertEqual(try Data(contentsOf: destinationURL), sourceData)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testExportReplacesApprovedDestinationWithArtifactBytes() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("drums.wav")
        let destinationURL = directoryURL.appendingPathComponent("chosen.wav")
        let sourceData = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02, 0x03, 0x04])
        let artifact = try makeArtifact(name: .drums, url: sourceURL, data: sourceData)
        try Data([0xAA, 0xBB]).write(to: destinationURL)

        try StemExporter.export(artifact, to: destinationURL)

        XCTAssertEqual(try Data(contentsOf: destinationURL), sourceData)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testExportRejectsOriginalArtifactAsDestination() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("bass.wav")
        let sourceData = Data([0x52, 0x49, 0x46, 0x46, 0x10, 0x20])
        let artifact = try makeArtifact(name: .bass, url: sourceURL, data: sourceData)

        XCTAssertThrowsError(try StemExporter.export(artifact, to: sourceURL)) { error in
            XCTAssertEqual(error as? StemExportError, .sourceAndDestinationMatch)
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testMP3ExportEncodesArtifactWAVWithFFmpeg() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("guitar.wav")
        let destinationURL = directoryURL.appendingPathComponent("chosen-guitar.mp3")
        let argumentsURL = directoryURL.appendingPathComponent("arguments.txt")
        let ffmpegURL = directoryURL.appendingPathComponent("ffmpeg")
        let sourceData = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02])
        let artifact = try makeArtifact(name: .guitar, url: sourceURL, data: sourceData)

        try makeExecutable(at: ffmpegURL, contents: """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argumentsURL.path)'
        for argument in "$@"; do output="$argument"; done
        printf 'encoded-mp3' > "$output"
        """)

        try StemExporter.export(
            artifact,
            to: destinationURL,
            format: .mp3,
            ffmpegURL: ffmpegURL
        )

        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("encoded-mp3".utf8))
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        XCTAssertEqual(
            try String(contentsOf: argumentsURL, encoding: .utf8).split(separator: "\n").map(String.init),
            [
                "-nostdin",
                "-y",
                "-i", sourceURL.path,
                "-codec:a", "libmp3lame",
                "-q:a", "2",
                destinationURL.path,
            ]
        )
    }

    func testDirectYouTubeMP3ExportEncodesPreparedAudioWithFFmpeg() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("mixture.wav")
        let destinationURL = directoryURL.appendingPathComponent("Massive Attack - Teardrop.mp3")
        let argumentsURL = directoryURL.appendingPathComponent("arguments.txt")
        let ffmpegURL = directoryURL.appendingPathComponent("ffmpeg")
        let sourceData = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02])
        try sourceData.write(to: sourceURL)

        try makeExecutable(at: ffmpegURL, contents: """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argumentsURL.path)'
        for argument in "$@"; do output="$argument"; done
        printf 'encoded-youtube-mp3' > "$output"
        """)

        try StemExporter.exportMP3(
            from: sourceURL,
            to: destinationURL,
            ffmpegURL: ffmpegURL
        )

        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("encoded-youtube-mp3".utf8))
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        XCTAssertEqual(
            try String(contentsOf: argumentsURL, encoding: .utf8).split(separator: "\n").map(String.init),
            [
                "-nostdin",
                "-y",
                "-i", sourceURL.path,
                "-codec:a", "libmp3lame",
                "-q:a", "2",
                destinationURL.path,
            ]
        )
    }

    func testMP3ExportReportsFFmpegFailure() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("piano.wav")
        let destinationURL = directoryURL.appendingPathComponent("piano.mp3")
        let ffmpegURL = directoryURL.appendingPathComponent("ffmpeg")
        let artifact = try makeArtifact(
            name: .piano,
            url: sourceURL,
            data: Data([0x52, 0x49, 0x46, 0x46])
        )
        try makeExecutable(at: ffmpegURL, contents: """
        #!/bin/sh
        index=0
        while [ "$index" -lt 4096 ]; do
            printf 'verbose encoding output 0123456789abcdef0123456789abcdef0123456789abcdef\n' >&2
            index=$((index + 1))
        done
        printf 'test encoding failure\n' >&2
        exit 7
        """)

        XCTAssertThrowsError(try StemExporter.export(
            artifact,
            to: destinationURL,
            format: .mp3,
            ffmpegURL: ffmpegURL
        )) { error in
            guard case .ffmpegFailed(let exitCode, let message) = error as? StemExportError else {
                return XCTFail("Expected ffmpeg failure, got \(error)")
            }
            XCTAssertEqual(exitCode, 7)
            XCTAssertTrue(message?.hasSuffix("test encoding failure") == true)
        }
    }
}
