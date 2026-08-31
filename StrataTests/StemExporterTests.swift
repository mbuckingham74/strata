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
