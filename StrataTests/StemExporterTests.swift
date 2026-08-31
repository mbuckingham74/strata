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
        let missingArtist = YouTubeTrackMetadata(artist: "N/A", title: "Song")
        XCTAssertEqual(missingArtist?.title, "Song")
        XCTAssertNil(missingArtist?.artist)
        XCTAssertNil(missingArtist?.exportBaseName)
        XCTAssertNil(YouTubeTrackMetadata(artist: "  ", title: "n/a"))
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
        let argumentsURL = directoryURL.appendingPathComponent("arguments.txt")
        let artworkURL = directoryURL.appendingPathComponent("thumbnail.jpg")
        let ffmpegURL = directoryURL.appendingPathComponent("ffmpeg")
        try Data("artwork".utf8).write(to: artworkURL)
        let sourceMetadata = try XCTUnwrap(
            YouTubeTrackMetadata(artist: "Massive Attack", title: "Teardrop")
        )
        try makeExecutable(at: ffmpegURL, contents: """
        #!/bin/sh
        input=''
        output=''
        previous=''
        printf '%s\\n' "$@" > '\(argumentsURL.path)'
        for argument in "$@"; do
            if [ "$previous" = '-i' ] && [ -z "$input" ]; then input="$argument"; fi
            previous="$argument"
            output="$argument"
        done
        cp "$input" '\(capturedMixURL.path)'
        printf 'encoded-selected-mix' > "$output"
        """)

        try StemExporter.exportMix(
            [drums, bass],
            to: destinationURL,
            metadata: sourceMetadata,
            artworkURL: artworkURL,
            ffmpegURL: ffmpegURL
        )

        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("encoded-selected-mix".utf8))
        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertTrue(arguments.contains(artworkURL.path))
        XCTAssertTrue(arguments.contains("artist=Massive Attack"))
        XCTAssertTrue(arguments.contains("title=Teardrop"))
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
        let artworkURL = directoryURL.appendingPathComponent("thumbnail.jpg")
        let ffmpegURL = directoryURL.appendingPathComponent("ffmpeg")
        let sourceData = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02])
        let artifact = try makeArtifact(name: .guitar, url: sourceURL, data: sourceData)
        try Data("artwork".utf8).write(to: artworkURL)
        let metadata = try XCTUnwrap(
            YouTubeTrackMetadata(artist: "Massive Attack", title: "Teardrop")
        )

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
            metadata: metadata,
            artworkURL: artworkURL,
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
                "-i", artworkURL.path,
                "-map", "0:a:0",
                "-map", "1:v:0",
                "-codec:a", "libmp3lame",
                "-q:a", "2",
                "-codec:v", "mjpeg",
                "-disposition:v:0", "attached_pic",
                "-metadata:s:v:0", "title=Album cover",
                "-metadata:s:v:0", "comment=Cover (front)",
                "-id3v2_version", "3",
                "-metadata", "artist=Massive Attack",
                "-metadata", "title=Teardrop",
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
        let artworkURL = directoryURL.appendingPathComponent("thumbnail.webp")
        let ffmpegURL = directoryURL.appendingPathComponent("ffmpeg")
        let sourceData = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02])
        try sourceData.write(to: sourceURL)
        try Data("artwork".utf8).write(to: artworkURL)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(
            artist: "Massive Attack",
            title: "Teardrop",
            album: "Mezzanine",
            albumArtist: "Massive Attack",
            year: "1998",
            genre: "Trip Hop",
            trackNumber: "3"
        ))

        try makeExecutable(at: ffmpegURL, contents: """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argumentsURL.path)'
        for argument in "$@"; do output="$argument"; done
        printf 'encoded-youtube-mp3' > "$output"
        """)

        try StemExporter.exportMP3(
            from: sourceURL,
            to: destinationURL,
            metadata: metadata,
            artworkURL: artworkURL,
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
                "-i", artworkURL.path,
                "-map", "0:a:0",
                "-map", "1:v:0",
                "-codec:a", "libmp3lame",
                "-q:a", "2",
                "-codec:v", "mjpeg",
                "-disposition:v:0", "attached_pic",
                "-metadata:s:v:0", "title=Album cover",
                "-metadata:s:v:0", "comment=Cover (front)",
                "-id3v2_version", "3",
                "-metadata", "artist=Massive Attack",
                "-metadata", "title=Teardrop",
                "-metadata", "album=Mezzanine",
                "-metadata", "album_artist=Massive Attack",
                "-metadata", "date=1998",
                "-metadata", "genre=Trip Hop",
                "-metadata", "track=3",
                destinationURL.path,
            ]
        )
    }

    func testMP3MetadataOmitsMissingAndUnusableFields() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("mixture.wav")
        let destinationURL = directoryURL.appendingPathComponent("audio.mp3")
        let argumentsURL = directoryURL.appendingPathComponent("arguments.txt")
        let ffmpegURL = directoryURL.appendingPathComponent("ffmpeg")
        try Data("audio".utf8).write(to: sourceURL)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(
            artist: "N/A",
            title: "Teardrop",
            album: "  ",
            year: "unknown",
            trackNumber: "0"
        ))

        try makeExecutable(at: ffmpegURL, contents: """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argumentsURL.path)'
        for argument in "$@"; do output="$argument"; done
        printf 'encoded-mp3' > "$output"
        """)

        try StemExporter.exportMP3(
            from: sourceURL,
            to: destinationURL,
            metadata: metadata,
            ffmpegURL: ffmpegURL
        )

        XCTAssertEqual(
            try String(contentsOf: argumentsURL, encoding: .utf8).split(separator: "\n").map(String.init),
            [
                "-nostdin",
                "-y",
                "-i", sourceURL.path,
                "-codec:a", "libmp3lame",
                "-q:a", "2",
                "-id3v2_version", "3",
                "-metadata", "title=Teardrop",
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

    // MARK: - Gain-aware selected-mix export (matches audible stem mix)

    func testCombinedWAVExportWithZeroGainContributesSilence() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let drums = try makeWAVArtifact(
            name: .drums,
            url: directoryURL.appendingPathComponent("drums.wav"),
            leftSamples: [0.5, 0.0, 0.25],
            rightSamples: [0.0, 0.5, 0.25]
        )
        let bass = try makeWAVArtifact(
            name: .bass,
            url: directoryURL.appendingPathComponent("bass.wav"),
            leftSamples: [0.4, 0.2, 0.0],
            rightSamples: [0.0, 0.4, 0.0]
        )
        let destinationURL = directoryURL.appendingPathComponent("selected-mix.wav")

        try StemExporter.exportMix([drums, bass], to: destinationURL, gains: [.drums: 0, .bass: 1.0], format: .wav)

        let outputFile = try AVAudioFile(forReading: destinationURL)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFile.processingFormat, frameCapacity: AVAudioFrameCount(outputFile.length)) else {
            return XCTFail("Could not allocate output verification buffer")
        }
        try outputFile.read(into: outputBuffer)
        let outputChannels = try XCTUnwrap(outputBuffer.floatChannelData)
        // 0% gain must be silent: drums contributes nothing, mix equals bass alone
        let expectedLeft: [Float] = [0.4, 0.2, 0.0]
        let expectedRight: [Float] = [0.0, 0.4, 0.0]
        for frame in 0..<expectedLeft.count {
            XCTAssertEqual(outputChannels[0][frame], expectedLeft[frame], accuracy: 0.000_01)
            XCTAssertEqual(outputChannels[1][frame], expectedRight[frame], accuracy: 0.000_01)
        }
    }

    func testCombinedWAVExportAppliesNonUnityGainScaling() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let drums = try makeWAVArtifact(
            name: .drums,
            url: directoryURL.appendingPathComponent("drums.wav"),
            leftSamples: [0.6, 0.0, 0.4],
            rightSamples: [0.0, 0.6, 0.4]
        )
        let bass = try makeWAVArtifact(
            name: .bass,
            url: directoryURL.appendingPathComponent("bass.wav"),
            leftSamples: [0.4, 0.2, 0.0],
            rightSamples: [0.0, 0.4, 0.2]
        )
        let destinationURL = directoryURL.appendingPathComponent("selected-mix.wav")

        // drums at 50%, bass at 100% -> drums contribution halved
        try StemExporter.exportMix([drums, bass], to: destinationURL, gains: [.drums: 0.5, .bass: 1.0], format: .wav)

        let outputFile = try AVAudioFile(forReading: destinationURL)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFile.processingFormat, frameCapacity: AVAudioFrameCount(outputFile.length)) else {
            return XCTFail("Could not allocate output verification buffer")
        }
        try outputFile.read(into: outputBuffer)
        let outputChannels = try XCTUnwrap(outputBuffer.floatChannelData)
        // 0.6*0.5+0.4=0.7, 0+0.2=0.2, 0.4*0.5+0=0.2
        let expectedLeft: [Float] = [0.7, 0.2, 0.2]
        // 0*0.5+0=0, 0.6*0.5+0.4=0.7, 0.4*0.5+0.2=0.4
        let expectedRight: [Float] = [0.0, 0.7, 0.4]
        for frame in 0..<expectedLeft.count {
            XCTAssertEqual(outputChannels[0][frame], expectedLeft[frame], accuracy: 0.000_01)
            XCTAssertEqual(outputChannels[1][frame], expectedRight[frame], accuracy: 0.000_01)
        }
    }

    func testCombinedWAVExportAppliesIndependentGainsToEachStem() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let vocals = try makeWAVArtifact(
            name: .vocals,
            url: directoryURL.appendingPathComponent("vocals.wav"),
            leftSamples: [0.8, 0.0],
            rightSamples: [0.0, 0.8]
        )
        let guitar = try makeWAVArtifact(
            name: .guitar,
            url: directoryURL.appendingPathComponent("guitar.wav"),
            leftSamples: [0.2, 0.4],
            rightSamples: [0.2, 0.4]
        )
        let destinationURL = directoryURL.appendingPathComponent("selected-mix.wav")

        try StemExporter.exportMix([vocals, guitar], to: destinationURL, gains: [.vocals: 0.25, .guitar: 0.5], format: .wav)

        let outputFile = try AVAudioFile(forReading: destinationURL)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFile.processingFormat, frameCapacity: AVAudioFrameCount(outputFile.length)) else {
            return XCTFail("Could not allocate output verification buffer")
        }
        try outputFile.read(into: outputBuffer)
        let outputChannels = try XCTUnwrap(outputBuffer.floatChannelData)
        // frame0 left: 0.8*0.25 + 0.2*0.5 = 0.2+0.1=0.3 ; right: 0*0.25+0.2*0.5=0.1
        // frame1 left: 0*0.25+0.4*0.5=0.2 ; right: 0.8*0.25+0.4*0.5=0.2+0.2=0.4
        XCTAssertEqual(outputChannels[0][0], 0.3, accuracy: 0.000_01)
        XCTAssertEqual(outputChannels[1][0], 0.1, accuracy: 0.000_01)
        XCTAssertEqual(outputChannels[0][1], 0.2, accuracy: 0.000_01)
        XCTAssertEqual(outputChannels[1][1], 0.4, accuracy: 0.000_01)
    }

    func testCombinedWAVExportMissingGainDefaultsToUnity() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let drums = try makeWAVArtifact(
            name: .drums,
            url: directoryURL.appendingPathComponent("drums.wav"),
            leftSamples: [0.1, 0.2],
            rightSamples: [0.3, 0.4]
        )
        let bass = try makeWAVArtifact(
            name: .bass,
            url: directoryURL.appendingPathComponent("bass.wav"),
            leftSamples: [0.5, 0.1],
            rightSamples: [0.1, 0.5]
        )
        let destinationURL = directoryURL.appendingPathComponent("selected-mix.wav")

        // Only drums has explicit gain, bass missing must default to 1.0
        try StemExporter.exportMix([drums, bass], to: destinationURL, gains: [.drums: 0.5], format: .wav)

        let outputFile = try AVAudioFile(forReading: destinationURL)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFile.processingFormat, frameCapacity: AVAudioFrameCount(outputFile.length)) else {
            return XCTFail("Could not allocate output verification buffer")
        }
        try outputFile.read(into: outputBuffer)
        let outputChannels = try XCTUnwrap(outputBuffer.floatChannelData)
        // left: 0.1*0.5+0.5=0.55, 0.2*0.5+0.1=0.2
        XCTAssertEqual(outputChannels[0][0], 0.55, accuracy: 0.000_01)
        XCTAssertEqual(outputChannels[0][1], 0.2, accuracy: 0.000_01)
        // right: 0.3*0.5+0.1=0.25, 0.4*0.5+0.5=0.7
        XCTAssertEqual(outputChannels[1][0], 0.25, accuracy: 0.000_01)
        XCTAssertEqual(outputChannels[1][1], 0.7, accuracy: 0.000_01)
    }

    func testCombinedMP3ExportAppliesGainBeforeEncoding() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let drums = try makeWAVArtifact(
            name: .drums,
            url: directoryURL.appendingPathComponent("drums.wav"),
            leftSamples: [0.6, 0.0, 0.4],
            rightSamples: [0.0, 0.6, 0.4]
        )
        let bass = try makeWAVArtifact(
            name: .bass,
            url: directoryURL.appendingPathComponent("bass.wav"),
            leftSamples: [0.4, 0.2, 0.0],
            rightSamples: [0.0, 0.4, 0.2]
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
            if [ "$previous" = '-i' ] && [ -z "$input" ]; then input="$argument"; fi
            previous="$argument"
            output="$argument"
        done
        cp "$input" '\(capturedMixURL.path)'
        printf 'encoded-selected-mix' > "$output"
        """)

        try StemExporter.exportMix(
            [drums, bass],
            to: destinationURL,
            gains: [.drums: 0.5, .bass: 1.0],
            format: .mp3,
            ffmpegURL: ffmpegURL
        )

        let outputFile = try AVAudioFile(forReading: capturedMixURL)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFile.processingFormat, frameCapacity: AVAudioFrameCount(outputFile.length)) else {
            return XCTFail("Could not allocate output verification buffer")
        }
        try outputFile.read(into: outputBuffer)
        let outputChannels = try XCTUnwrap(outputBuffer.floatChannelData)
        let expectedLeft: [Float] = [0.7, 0.2, 0.2]
        let expectedRight: [Float] = [0.0, 0.7, 0.4]
        for frame in 0..<expectedLeft.count {
            XCTAssertEqual(outputChannels[0][frame], expectedLeft[frame], accuracy: 0.000_01)
            XCTAssertEqual(outputChannels[1][frame], expectedRight[frame], accuracy: 0.000_01)
        }
    }

    func testExportMixClampsGainToZeroAndOne() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let drums = try makeWAVArtifact(
            name: .drums,
            url: directoryURL.appendingPathComponent("drums.wav"),
            leftSamples: [0.5],
            rightSamples: [0.5]
        )
        let bass = try makeWAVArtifact(
            name: .bass,
            url: directoryURL.appendingPathComponent("bass.wav"),
            leftSamples: [0.5],
            rightSamples: [0.5]
        )
        let destinationURL = directoryURL.appendingPathComponent("selected-mix.wav")

        // Negative must clamp to 0 (silence), >1 must clamp to 1 (unity)
        try StemExporter.exportMix([drums, bass], to: destinationURL, gains: [.drums: -0.5, .bass: 2.0], format: .wav)

        let outputFile = try AVAudioFile(forReading: destinationURL)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFile.processingFormat, frameCapacity: AVAudioFrameCount(outputFile.length)) else {
            return XCTFail("Could not allocate output verification buffer")
        }
        try outputFile.read(into: outputBuffer)
        let outputChannels = try XCTUnwrap(outputBuffer.floatChannelData)
        // drums 0 + bass 1.0 => 0.5
        XCTAssertEqual(outputChannels[0][0], 0.5, accuracy: 0.000_01)
        XCTAssertEqual(outputChannels[1][0], 0.5, accuracy: 0.000_01)
    }
}
