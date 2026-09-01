import XCTest
@testable import Strata
import Foundation

final class LocalMP3ExportTests: XCTestCase {
    func testDefaultLocalMP3UsesEditableMetadataWhenAvailable() throws {
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(artist: "Artist", title: "Song Title"))
        XCTAssertEqual(
            StemExporter.defaultLocalMP3Filename(metadata: metadata, fallbackTitle: "fallback", fallbackURL: URL(fileURLWithPath: "/tmp/foo.wav")),
            "Artist - Song Title.mp3"
        )
    }

    func testDefaultLocalMP3FallbackToTitleWhenNoMetadata() {
        XCTAssertEqual(
            StemExporter.defaultLocalMP3Filename(metadata: nil, fallbackTitle: "My Song", fallbackURL: URL(fileURLWithPath: "/tmp/other.wav")),
            "My Song.mp3"
        )
    }

    func testDefaultLocalMP3FallbackToURLWhenNoTitle() {
        XCTAssertEqual(
            StemExporter.defaultLocalMP3Filename(metadata: nil, fallbackTitle: nil, fallbackURL: URL(fileURLWithPath: "/tmp/cool_track.aiff")),
            "cool_track.mp3"
        )
        XCTAssertEqual(
            StemExporter.defaultLocalMP3Filename(metadata: nil, fallbackTitle: "   ", fallbackURL: URL(fileURLWithPath: "/tmp/cool_track.aiff")),
            "cool_track.mp3"
        )
    }

    func testDefaultLocalMP3SanitizesFallback() {
        XCTAssertEqual(
            StemExporter.defaultLocalMP3Filename(metadata: nil, fallbackTitle: "a/b:c", fallbackURL: nil),
            "a-b-c.mp3"
        )
        XCTAssertEqual(
            StemExporter.defaultLocalMP3Filename(metadata: nil, fallbackTitle: nil, fallbackURL: URL(fileURLWithPath: "/tmp/a/b:c.wav")),
            "b-c.mp3"
        )
    }

    func testDefaultLocalMP3FallbackToAudioWhenNoInfo() {
        XCTAssertEqual(
            StemExporter.defaultLocalMP3Filename(metadata: nil, fallbackTitle: nil, fallbackURL: nil),
            "Audio.mp3"
        )
        XCTAssertEqual(
            StemExporter.defaultLocalMP3Filename(metadata: nil, fallbackTitle: "   ", fallbackURL: URL(fileURLWithPath: "/tmp/.wav")),
            "Audio.mp3"
        )
    }

    func testLocalMP3ExportEncodesWithEditedMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("source.wav")
        let destURL = dir.appendingPathComponent("out.mp3")
        let argsURL = dir.appendingPathComponent("args.txt")
        let ffmpegURL = dir.appendingPathComponent("ffmpeg")
        try Data("audio".utf8).write(to: sourceURL)
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argsURL.path)'\nfor a in \"$@\"; do output=\"$a\"; done\nprintf 'x' > \"$output\"\n".utf8).write(to: ffmpegURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpegURL.path)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(artist: "Edited", title: "Title"))
        try StemExporter.exportMP3(from: sourceURL, to: destURL, metadata: metadata, ffmpegURL: ffmpegURL)
        let args = try String(contentsOf: argsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(args.contains("artist=Edited"))
        XCTAssertTrue(args.contains("title=Title"))
    }
}
