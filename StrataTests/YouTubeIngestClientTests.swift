import XCTest
@testable import Strata
import Foundation
import AVFoundation

final class YouTubeIngestClientTests: XCTestCase {

    // MARK: - Helpers

    private func makeFakeExecutable(name: String, scriptContent: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try scriptContent.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    private func makeCacheBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeLogFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private func validYouTubeURL() -> URL {
        URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
    }

    private func shortYouTubeURL() -> URL {
        URL(string: "https://youtu.be/dQw4w9WgXcQ")!
    }

    private func writeValidWavPythonScript(logPath: String, frames: Int = 1024, sr: Int = 44100, ch: Int = 2) -> String {
        """
        #!/usr/bin/python3
        import sys, os, struct
        log_path = "\(logPath)"
        with open(log_path, "a") as f:
            f.write("ffmpeg " + " ".join(sys.argv[1:]) + "\\n")
        out = sys.argv[-1]
        os.makedirs(os.path.dirname(out), exist_ok=True)
        frames = \(frames)
        sr = \(sr)
        ch = \(ch)
        bits = 32
        byte_rate = sr * ch * bits // 8
        block_align = ch * bits // 8
        data_size = frames * ch * 4
        with open(out, "wb") as f:
            f.write(b"RIFF")
            f.write(struct.pack("<I", 36 + data_size))
            f.write(b"WAVE")
            f.write(b"fmt ")
            f.write(struct.pack("<IHHIIHH", 16, 3, ch, sr, byte_rate, block_align, bits))
            f.write(b"data")
            f.write(struct.pack("<I", data_size))
            f.write(b"\\x00" * data_size)
        sys.exit(0)
        """
    }

    // MARK: - 1. yt-dlp → FFmpeg launch order and arguments

    func testYtDlpToFFmpegLaunchOrderAndArguments() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("yt-dlp " + " ".join(sys.argv[1:]) + "\\n")
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "mp4")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as outf:
                outf.write(b"\\x00" * 1024)
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path, frames: 1024, sr: 44100, ch: 2)

        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let youTubeURL = validYouTubeURL()
        let result = try await client.ingest(youTubeURL: youTubeURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))

        let log = try String(contentsOf: logFile, encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "Expected two invocations, got log: \(log)")
        guard lines.count == 2 else { return }
        XCTAssertTrue(lines[0].hasPrefix("yt-dlp "), "First line should be yt-dlp: \(lines[0])")
        XCTAssertTrue(lines[1].hasPrefix("ffmpeg "), "Second line should be ffmpeg: \(lines[1])")
        // yt-dlp args contain https URL and --no-playlist and output template with source.%(ext)s
        XCTAssertTrue(lines[0].contains(youTubeURL.absoluteString), "yt-dlp should contain URL")
        XCTAssertTrue(lines[0].contains("--no-playlist"), "yt-dlp should contain --no-playlist")
        XCTAssertTrue(lines[0].contains("--write-info-json"), "yt-dlp should request metadata")
        XCTAssertTrue(lines[0].contains("--write-thumbnail"), "yt-dlp should request artwork")
        XCTAssertTrue(lines[0].contains("source.%(ext)s"), "yt-dlp should contain source template")
        XCTAssertTrue(lines[0].contains("--ffmpeg-location"), "yt-dlp should contain --ffmpeg-location for GUI PATH")
        XCTAssertTrue(lines[0].contains(ffURL.path), "yt-dlp --ffmpeg-location value must equal injected ffmpegURL.path \(ffURL.path): \(lines[0])")
        // Verify --ffmpeg-location value exactly matches injected path
        if let idx = lines[0].range(of: "--ffmpeg-location") {
            let after = lines[0][idx.upperBound...].trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(after.hasPrefix(ffURL.path) || after.contains(ffURL.path), "--ffmpeg-location should be followed by \(ffURL.path), got: \(after)")
        }
        XCTAssertTrue(lines[0].contains("--js-runtimes"), "yt-dlp should contain --js-runtimes for Node")
        // Default nodeURL is /opt/homebrew/bin/node when not injected
        XCTAssertTrue(lines[0].contains("node:/opt/homebrew/bin/node"), "yt-dlp --js-runtimes value must be node:/opt/homebrew/bin/node for default: \(lines[0])")
        // Also verify injected path pattern when default used
        XCTAssertTrue(lines[0].contains("node:\(URL(fileURLWithPath: "/opt/homebrew/bin/node").path)"), "yt-dlp --js-runtimes should contain injected node path")
        // Check absolute path in yt-dlp -o arg
        XCTAssertTrue(lines[0].contains(cacheBase.path) || lines[0].contains("/tmp") || lines[0].contains("/private"), "yt-dlp template should be absolute")
        // ffmpeg args contain -ar 44100, -ac 2, pcm_f32le, and mixture.wav
        XCTAssertTrue(lines[1].contains("-ar"), "ffmpeg should contain -ar")
        XCTAssertTrue(lines[1].contains("44100"), "ffmpeg should contain 44100")
        XCTAssertTrue(lines[1].contains("-ac"), "ffmpeg should contain -ac")
        // Ensure -ac 2 appears (allow spaced)
        XCTAssertTrue(lines[1].contains(" 2 ") || lines[1].hasSuffix(" 2") || lines[1].contains(" -ac 2"), "ffmpeg should contain 2 channels")
        XCTAssertTrue(lines[1].contains("pcm_f32le"), "ffmpeg should contain pcm_f32le")
        XCTAssertTrue(lines[1].contains("mixture.wav"), "ffmpeg should contain mixture.wav")
        // Check absolute paths for ffmpeg input/output
        XCTAssertTrue(lines[1].contains("/"), "ffmpeg args should contain absolute paths")
        // FFmpeg must disable stdin to avoid job-control stop (STAT=T) when launched from GUI app
        XCTAssertTrue(lines[1].contains("-nostdin"), "ffmpeg should contain -nostdin to avoid inherited stdin job-control stop: \(lines[1])")
        // -nostdin must precede input/output args for ffmpeg global option correctness
        if let nostdinRange = lines[1].range(of: "-nostdin"), let yRange = lines[1].range(of: " -y ") {
            XCTAssertTrue(nostdinRange.lowerBound < yRange.lowerBound, "-nostdin should appear before -y: \(lines[1])")
        }
    }

    func testInjectedNodeURLPassedToYtDlp() async throws {
        // Proves custom nodeURL reaches yt-dlp for entry points not already covered
        // by default-node ingest check in testYtDlpToFFmpegLaunchOrderAndArguments.
        // Covers fetchPreview and downloadAudioOnly (ingest default already proves ingest path).
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let customNode = URL(fileURLWithPath: "/tmp/custom/node")

        func ytDlpLine(ytScript: String, operation: (YouTubeIngestClient) async throws -> Void) async throws -> String {
            let ffScript = writeValidWavPythonScript(logPath: logFile.path)
            let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
            let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
            defer {
                try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
            }
            try "".write(to: logFile, atomically: true, encoding: .utf8)
            let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, nodeURL: customNode, cacheBaseURL: cacheBase)
            try await operation(client)
            let log = try String(contentsOf: logFile, encoding: .utf8)
            if let dirs = try? FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil) {
                for d in dirs { try? FileManager.default.removeItem(at: d) }
            }
            try "".write(to: logFile, atomically: true, encoding: .utf8)
            return log.split(separator: "\n").first(where: { $0.hasPrefix("yt-dlp ") }).map(String.init) ?? ""
        }

        let previewScript = """
        #!/usr/bin/python3
        import sys, os
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("yt-dlp " + " ".join(sys.argv[1:]) + "\\n")
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            os.makedirs(os.path.dirname(tmpl), exist_ok=True)
            info = tmpl.replace("%(ext)s", "info.json")
            with open(info, "w") as jf:
                jf.write('{"artist":"Preview Artist","track":"Preview Title","duration":10}')
            thumb = tmpl.replace("%(ext)s", "jpg")
            with open(thumb, "wb") as tf:
                tf.write(b"\\xff\\xd8\\xff\\xe0thumb")
        sys.exit(0)
        """
        let previewLine = try await ytDlpLine(ytScript: previewScript) { client in
            _ = try await client.fetchPreview(youTubeURL: validYouTubeURL())
        }
        XCTAssertTrue(previewLine.contains("node:/tmp/custom/node"), "fetchPreview should pass injected node: \(previewLine)")
        XCTAssertFalse(previewLine.contains("node:/opt/homebrew/bin/node"), "Should not contain default when custom injected")

        let audioScript = """
        #!/usr/bin/python3
        import sys, os
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("yt-dlp " + " ".join(sys.argv[1:]) + "\\n")
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "m4a")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as outf:
                outf.write(b"\\x00" * 512)
            info = tmpl.replace("%(ext)s", "info.json")
            with open(info, "w") as jf:
                jf.write('{"artist":"A","track":"T"}')
            thumb = tmpl.replace("%(ext)s", "jpg")
            with open(thumb, "wb") as tf:
                tf.write(b"\\xff\\xd8\\xff\\xe0thumb")
        sys.exit(0)
        """
        let audioLine = try await ytDlpLine(ytScript: audioScript) { client in
            _ = try await client.downloadAudioOnly(youTubeURL: validYouTubeURL())
        }
        XCTAssertTrue(audioLine.contains("node:/tmp/custom/node"), "downloadAudioOnly should pass injected node: \(audioLine)")
    }

    func testFFmpegInvokedWithNostdinAndDetachedStdin() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "webm")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as outf:
                outf.write(b"\\x00" * 256)
        sys.exit(0)
        """
        // Fake ffmpeg that asserts stdin is not a tty and reads EOF without blocking, and logs args
        let ffStdinScript = """
        #!/usr/bin/python3
        import sys, os, struct
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("ffmpeg " + " ".join(sys.argv[1:]) + "\\n")
            # Verify stdin is detached: reading should return immediate EOF (empty) not block
            try:
                data = sys.stdin.buffer.read(1)
                if data is None:
                    data = b""
                f.write("stdin_bytes: " + str(len(data)) + "\\n")
                f.write("stdin_is_tty: " + str(sys.stdin.isatty()) + "\\n")
            except Exception as e:
                f.write("stdin_error: " + str(e) + "\\n")
        # Still produce valid wav to allow ingest to succeed
        out = sys.argv[-1]
        os.makedirs(os.path.dirname(out), exist_ok=True)
        frames = 256
        sr = 44100
        ch = 2
        bits = 32
        byte_rate = sr * ch * bits // 8
        block_align = ch * bits // 8
        data_size = frames * ch * 4
        with open(out, "wb") as f:
            f.write(b"RIFF")
            f.write(struct.pack("<I", 36 + data_size))
            f.write(b"WAVE")
            f.write(b"fmt ")
            f.write(struct.pack("<IHHIIHH", 16, 3, ch, sr, byte_rate, block_align, bits))
            f.write(b"data")
            f.write(struct.pack("<I", data_size))
            f.write(b"\\x00" * data_size)
        sys.exit(0)
        """
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffStdinScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }
        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let result = try await client.ingest(youTubeURL: validYouTubeURL())
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path), "mixture.wav should exist when stdin is detached")

        let log = try String(contentsOf: logFile, encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init)
        let ffLine = lines.first(where: { $0.hasPrefix("ffmpeg ") })
        XCTAssertNotNil(ffLine, "ffmpeg invocation should be logged")
        XCTAssertTrue(ffLine!.contains("-nostdin"), "ffmpeg must be launched with -nostdin")
        XCTAssertTrue(ffLine!.hasPrefix("ffmpeg -nostdin"), "ffmpeg -nostdin should be first argument, got: \(ffLine!)")

        // Verify stdin was detached (EOF, not tty, not blocking)
        let stdinBytesLine = lines.first(where: { $0.hasPrefix("stdin_bytes:") })
        XCTAssertNotNil(stdinBytesLine, "fake ffmpeg should log stdin_bytes")
        XCTAssertEqual(stdinBytesLine, "stdin_bytes: 0", "stdin should be detached to EOF (0 bytes), got: \(stdinBytesLine ?? "nil")")
        let isTtyLine = lines.first(where: { $0.hasPrefix("stdin_is_tty:") })
        XCTAssertEqual(isTtyLine, "stdin_is_tty: False", "stdin should not be a tty when launched from GUI: \(isTtyLine ?? "nil")")
    }

    // MARK: - 2. successful canonical publication

    func testSuccessfulCanonicalPublication() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("yt-dlp " + " ".join(sys.argv[1:]) + "\\n")
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "mp4")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as outf:
                outf.write(b"\\x00" * 512)
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path, frames: 1024, sr: 44100, ch: 2)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let ingestResult = try await client.ingestWithMetadata(youTubeURL: shortYouTubeURL())
        let result = ingestResult.audioURL

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path), "mixture.wav should exist")
        XCTAssertNil(ingestResult.metadata, "Missing reliable metadata should remain a filename fallback")
        // Validate via AVAudioFile
        let file = try AVAudioFile(forReading: result)
        XCTAssertEqual(file.processingFormat.sampleRate, 44100, accuracy: 0.1)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(file.processingFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertEqual(file.length, 1024)

        // File is inside cacheBase under UUID subdir
        let standardizedBase = cacheBase.standardizedFileURL.resolvingSymlinksInPath().path
        let standardizedResult = result.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(standardizedResult.hasPrefix(standardizedBase), "Result should be inside cacheBase")
        XCTAssertTrue(result.lastPathComponent == "mixture.wav")

        // After success, intermediate source file removed but mixture remains
        let runDir = result.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(contents.count, 1, "Only mixture.wav should remain, got \(contents)")
        XCTAssertEqual(contents.first?.lastPathComponent, "mixture.wav")
    }

    func testPublishesReliableArtistAndTrackMetadata() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        args = sys.argv[1:]
        idx = args.index("-o")
        tmpl = args[idx+1]
        out = tmpl.replace("%(ext)s", "webm")
        info = out.rsplit(".", 1)[0] + ".info.json"
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "wb") as outf:
            outf.write(b"\\x00" * 512)
        with open(info, "w") as infof:
            infof.write('{"artist":"Massive Attack","track":"Teardrop","title":"Ignored video title","channel":"Massive Attack Official","album":"Mezzanine","album_artist":"Massive Attack","release_year":1998,"genre":"Trip Hop","track_number":3}')
        with open(out.rsplit(".", 1)[0] + ".jpg", "wb") as artwork:
            artwork.write(b"\\xff\\xd8\\xff\\xe0thumbnail")
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(
            logPath: logFile.path,
            frames: 1024,
            sr: 44100,
            ch: 2
        )
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(
            ytDlpURL: ytURL,
            ffmpegURL: ffURL,
            cacheBaseURL: cacheBase
        )
        let result = try await client.ingestWithMetadata(youTubeURL: validYouTubeURL())

        XCTAssertEqual(
            result.metadata,
            YouTubeTrackMetadata(
                artist: "Massive Attack",
                title: "Teardrop",
                album: "Mezzanine",
                albumArtist: "Massive Attack",
                year: "1998",
                genre: "Trip Hop",
                trackNumber: "3",
                channel: "Massive Attack Official"
            )
        )
        XCTAssertEqual(result.metadata?.exportBaseName, "Massive Attack - Teardrop")
        let artworkURL = try XCTUnwrap(result.artworkURL)
        XCTAssertEqual(artworkURL.lastPathComponent, "source.jpg")
        XCTAssertEqual(
            try Data(contentsOf: artworkURL),
            Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("thumbnail".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioURL.path))
        let contents = try FileManager.default.contentsOfDirectory(
            at: result.audioURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(Set(contents.map(\.lastPathComponent)), ["mixture.wav", "source.jpg"])
    }

    // MARK: - 3. nonzero tool exit

    func testNonZeroToolExit() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytScript = """
        #!/usr/bin/python3
        import sys
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("yt-dlp " + " ".join(sys.argv[1:]) + "\\n")
        sys.stderr.write("yt-dlp failed mock\\n")
        sys.stderr.flush()
        sys.exit(1)
        """
        // ffmpeg should not be called, but provide dummy
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)

        do {
            _ = try await client.ingest(youTubeURL: validYouTubeURL())
            XCTFail("Should have thrown toolFailure")
        } catch let err as YouTubeIngestError {
            switch err {
            case .toolFailure(let tool, let code, let tail):
                XCTAssertEqual(tool, "yt-dlp")
                XCTAssertEqual(code, 1)
                XCTAssertNotNil(tail)
                XCTAssertTrue(tail!.contains("yt-dlp failed mock"), "stderrTail should contain mock: \(tail ?? "")")
                // Bounded 32 KiB
                XCTAssertLessThanOrEqual((tail ?? "").utf8.count, 32 * 1024)
            default:
                XCTFail("Wrong error case \(err)")
            }
        }

        // ffmpeg nonzero test as well (yt success, ffmpeg fails)
        let ytScript2 = """
        #!/usr/bin/python3
        import sys, os
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("yt-dlp2 " + " ".join(sys.argv[1:]) + "\\n")
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "mp4")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as outf:
                outf.write(b"\\x00" * 100)
        sys.exit(0)
        """
        let ffFailScript = """
        #!/usr/bin/python3
        import sys
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("ffmpeg " + " ".join(sys.argv[1:]) + "\\n")
        sys.stderr.write("ffmpeg failed mock\\n")
        sys.stderr.flush()
        sys.exit(2)
        """
        let ytURL2 = try makeFakeExecutable(name: "yt-dlp2", scriptContent: ytScript2)
        let ffURL2 = try makeFakeExecutable(name: "ffmpeg2", scriptContent: ffFailScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL2.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL2.deletingLastPathComponent())
        }
        let client2 = YouTubeIngestClient(ytDlpURL: ytURL2, ffmpegURL: ffURL2, cacheBaseURL: cacheBase)
        do {
            _ = try await client2.ingest(youTubeURL: validYouTubeURL())
            XCTFail("Should have thrown ffmpeg toolFailure")
        } catch let err as YouTubeIngestError {
            guard case .toolFailure(let tool, let code, let tail) = err else { return XCTFail("Wrong \(err)") }
            XCTAssertEqual(tool, "ffmpeg")
            XCTAssertEqual(code, 2)
            XCTAssertTrue(tail?.contains("ffmpeg failed mock") ?? false)
        }

        // Ensure cleanup after failure: run dirs removed
        let remaining = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.isEmpty, "Cache base should be empty after failure, got \(remaining)")
    }

    // MARK: - 4. invalid canonical output

    func testInvalidCanonicalOutput() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("yt-dlp " + " ".join(sys.argv[1:]) + "\\n")
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "mp4")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as outf:
                outf.write(b"\\x00" * 100)
        sys.exit(0)
        """
        // Invalid: 48000 Hz instead of 44100
        let ffInvalidScript = writeValidWavPythonScript(logPath: logFile.path, frames: 1024, sr: 48000, ch: 2)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffInvalidScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        do {
            _ = try await client.ingest(youTubeURL: validYouTubeURL())
            XCTFail("Should have thrown invalidCanonicalOutput for 48k")
        } catch let err as YouTubeIngestError {
            guard case .invalidCanonicalOutput(let msg) = err else { return XCTFail("Wrong error \(err)") }
            XCTAssertTrue(msg.contains("44100") || msg.contains("sampleRate") || msg.contains("48000"), "Message should mention sample rate: \(msg)")
        }

        // Also test mono invalid
        let ffMonoScript = writeValidWavPythonScript(logPath: logFile.path, frames: 1024, sr: 44100, ch: 1)
        let ffURL2 = try makeFakeExecutable(name: "ffmpeg-mono", scriptContent: ffMonoScript)
        defer { try? FileManager.default.removeItem(at: ffURL2.deletingLastPathComponent()) }
        let client2 = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL2, cacheBaseURL: cacheBase)
        do {
            _ = try await client2.ingest(youTubeURL: validYouTubeURL())
            XCTFail("Should have thrown for mono")
        } catch let err as YouTubeIngestError {
            guard case .invalidCanonicalOutput = err else { return XCTFail("Wrong \(err)") }
        }

        // Cleanup happened: no mixture.wav published, run dir removed
        let remaining = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.isEmpty, "Should be cleaned after invalid output, got \(remaining)")
    }

    // MARK: - 5. cancellation during yt-dlp

    func testCancellationDuringYtDlp() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytSleepScript = """
        #!/usr/bin/python3
        import sys, os, time
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("yt-dlp " + " ".join(sys.argv[1:]) + "\\n")
        time.sleep(5)
        # If not cancelled, create file (should not happen)
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "mp4")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as outf:
                outf.write(b"\\x00" * 100)
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytSleepScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let ytTarget = validYouTubeURL()
        let task = Task { [client, ytTarget] in
            try await client.ingest(youTubeURL: ytTarget)
        }
        // Wait then cancel
        try await Task.sleep(nanoseconds: 200_000_000)
        try? await client.cancel()
        do {
            _ = try await task.value
            XCTFail("Should have been cancelled")
        } catch let err as YouTubeIngestError {
            XCTAssertEqual(err, .cancelled, "Should throw cancelled, got \(err)")
        } catch is CancellationError {
            // Also acceptable
        } catch {
            XCTFail("Wrong error \(error)")
        }

        // Run dir removed, no mixture.wav
        let remaining = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.isEmpty, "Should be cleaned after cancellation, got \(remaining)")
    }

    // MARK: - 6. cancellation during FFmpeg

    func testCancellationDuringFFmpeg() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytQuickScript = """
        #!/usr/bin/python3
        import sys, os
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("yt-dlp " + " ".join(sys.argv[1:]) + "\\n")
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "mp4")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as outf:
                outf.write(b"\\x00" * 100)
        sys.exit(0)
        """
        let ffSleepScript = """
        #!/usr/bin/python3
        import sys, os, time
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("ffmpeg " + " ".join(sys.argv[1:]) + "\\n")
        time.sleep(5)
        sys.exit(0)
        """
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytQuickScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffSleepScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let ytTarget2 = validYouTubeURL()
        let task = Task { [client, ytTarget2] in
            try await client.ingest(youTubeURL: ytTarget2)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        try? await client.cancel()
        do {
            _ = try await task.value
            XCTFail("Should have been cancelled")
        } catch let err as YouTubeIngestError {
            XCTAssertEqual(err, .cancelled)
        } catch is CancellationError {
        } catch {
            XCTFail("Wrong \(error)")
        }

        let remaining = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.isEmpty, "Cleaned after ffmpeg cancellation")
    }

    // MARK: - 7. cleanup of temporary/partial files

    func testCleanupOfTemporaryPartialFiles() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        // Success cleanup: source removed, mixture remains
        do {
            let ytScript = """
            #!/usr/bin/python3
            import sys, os
            log_path = "\(logFile.path)"
            with open(log_path, "a") as f:
                f.write("yt-dlp " + " ".join(sys.argv[1:]) + "\\n")
            args = sys.argv[1:]
            if "-o" in args:
                idx = args.index("-o")
                tmpl = args[idx+1]
                out = tmpl.replace("%(ext)s", "mp4")
                os.makedirs(os.path.dirname(out), exist_ok=True)
                with open(out, "wb") as outf:
                    outf.write(b"\\x00" * 200)
            sys.exit(0)
            """
            let ffScript = writeValidWavPythonScript(logPath: logFile.path, frames: 512, sr: 44100, ch: 2)
            let ytURL = try makeFakeExecutable(name: "yt-dlp-ok", scriptContent: ytScript)
            let ffURL = try makeFakeExecutable(name: "ffmpeg-ok", scriptContent: ffScript)
            defer {
                try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
            }
            let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
            let result = try await client.ingest(youTubeURL: validYouTubeURL())
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
            let runDir = result.deletingLastPathComponent()
            let contents = try FileManager.default.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil)
            XCTAssertEqual(contents.count, 1)
            XCTAssertEqual(contents.first?.lastPathComponent, "mixture.wav")
            // Clean up this run dir for next subtest
            try? FileManager.default.removeItem(at: runDir)
        }

        // Failure cleanup: after nonzero exit, no partial files
        do {
            let ytScript = """
            #!/usr/bin/python3
            import sys
            sys.stderr.write("failure mock long " + "x"*1000 + "\\n")
            sys.exit(1)
            """
            let ffScript = writeValidWavPythonScript(logPath: logFile.path)
            let ytURL = try makeFakeExecutable(name: "yt-dlp-fail", scriptContent: ytScript)
            let ffURL = try makeFakeExecutable(name: "ffmpeg-fail", scriptContent: ffScript)
            defer {
                try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
            }
            let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
            _ = try? await client.ingest(youTubeURL: validYouTubeURL())
            // After failure, cacheBase should have no leftover run dirs
            let remaining = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
            XCTAssertTrue(remaining.isEmpty, "After failure should be empty, got \(remaining)")
        }

        // Invalid output cleanup
        do {
            let ytScript = """
            #!/usr/bin/python3
            import sys, os
            args = sys.argv[1:]
            if "-o" in args:
                idx = args.index("-o")
                tmpl = args[idx+1]
                out = tmpl.replace("%(ext)s", "mp4")
                os.makedirs(os.path.dirname(out), exist_ok=True)
                open(out, "wb").write(b"data")
            sys.exit(0)
            """
            _ = writeValidWavPythonScript(logPath: logFile.path, frames: 0, sr: 44100, ch: 2)
            // Need to make a script that creates empty/invalid file manually
            let ffEmptyScript = """
            #!/usr/bin/python3
            import sys, os
            log_path = "\(logFile.path)"
            with open(log_path, "a") as f:
                f.write("ffmpeg " + " ".join(sys.argv[1:]) + "\\n")
            out = sys.argv[-1]
            os.makedirs(os.path.dirname(out), exist_ok=True)
            open(out, "wb").write(b"not a wav")
            sys.exit(0)
            """
            let ytURL = try makeFakeExecutable(name: "yt-dlp-inv", scriptContent: ytScript)
            let ffURL = try makeFakeExecutable(name: "ffmpeg-inv", scriptContent: ffEmptyScript)
            defer {
                try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
            }
            let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
            _ = try? await client.ingest(youTubeURL: validYouTubeURL())
            let remaining = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
            XCTAssertTrue(remaining.isEmpty, "After invalid output should be empty")
        }

        // Cancellation cleanup already tested, but verify no leaks
        let finalRemaining = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
        XCTAssertTrue(finalRemaining.isEmpty, "Final cleanup should leave empty cacheBase")
    }

    // MARK: - Additional validation: URL scheme

    func testInvalidYouTubeURLRejected() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let ytScript = """
        #!/usr/bin/python3
        import sys
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }
        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        do {
            _ = try await client.ingest(youTubeURL: URL(string: "http://www.youtube.com/watch?v=abc")!)
            XCTFail("http should be rejected")
        } catch let err as YouTubeIngestError {
            guard case .invalidYouTubeURL = err else { return XCTFail("Wrong \(err)") }
        }
        do {
            _ = try await client.ingest(youTubeURL: URL(string: "https://example.com/video")!)
            XCTFail("non-youtube should be rejected")
        } catch let err as YouTubeIngestError {
            guard case .invalidYouTubeURL = err else { return XCTFail("Wrong \(err)") }
        }
    }

    // MARK: - 9. ownership: cleanup does not occur before child exit is proven

    func testCleanupDoesNotOccurBeforeExitIsProven() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytSleepScript = """
        #!/usr/bin/python3
        import time, sys, os
        time.sleep(10)
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "mp4")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            open(out, "wb").write(b"\\x00"*100)
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytSleepScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        // Inject isRunningCheck that always returns true to simulate termination cannot be proven
        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase, isRunningCheck: { _ in true })

        let target = validYouTubeURL()
        let task = Task { [client, target] in
            try await client.ingest(youTubeURL: target)
        }
        // Allow runTool to start and create run directory
        try await Task.sleep(nanoseconds: 300_000_000)
        // Capture run directory before cancel
        let dirsBefore = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
        XCTAssertEqual(dirsBefore.count, 1, "Run directory should exist before cancel")
        let runDir = dirsBefore.first!

        // Cancel should surface cleanupFailed and NOT remove directory because exit not proven
        do {
            try await client.cancel()
            XCTFail("cancel should throw cleanupFailed when termination not proven")
        } catch let err as YouTubeIngestError {
            guard case .cleanupFailed = err else { return XCTFail("Expected cleanupFailed, got \(err)") }
        }

        // Directory must still exist after failed termination
        XCTAssertTrue(FileManager.default.fileExists(atPath: runDir.path), "Run directory must not be removed before exit is proven")
        let dirsAfter = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
        XCTAssertEqual(dirsAfter.count, 1, "Directory should be retained after failed cancel")

        // Ingest task should also surface cleanup failure, not pretend cancelled and cleaned
        do {
            _ = try await task.value
            XCTFail("Ingest should throw cleanupFailed")
        } catch let err as YouTubeIngestError {
            // runTool throws cleanupFailed which propagates through ingest
            if case .cleanupFailed = err { /* expected */ } else {
                XCTFail("Expected cleanupFailed from ingest, got \(err)")
            }
        } catch {
            XCTFail("Wrong error \(error)")
        }

        // Cleanup real process: it was sent SIGKILL and should be dead despite isRunningCheck override
        // Remove retained directory for test hygiene via fileManager directly
        // Next test will use fresh cacheBase, so just ensure we don't leak
        try? FileManager.default.removeItem(at: runDir)
        // Cancel the task to avoid warnings
        task.cancel()
        _ = try? await task.value
    }

    func testOwnershipRemainsIfTerminationCannotBeProven() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytSleepScript = """
        #!/usr/bin/python3
        import time, sys, os
        time.sleep(10)
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "mp4")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            open(out, "wb").write(b"\\x00"*100)
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytSleepScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase, isRunningCheck: { _ in true })

        let target2 = validYouTubeURL()
        let task = Task { [client, target2] in
            try await client.ingest(youTubeURL: target2)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        // Attempt cancel — should fail to prove termination and retain ownership
        do {
            try await client.cancel()
            XCTFail("Should have thrown cleanupFailed")
        } catch let err as YouTubeIngestError {
            guard case .cleanupFailed(let msg) = err else { return XCTFail("Expected cleanupFailed, got \(err)") }
            XCTAssertFalse(msg.isEmpty, "cleanupFailed should carry message")
        }

        // Ownership remains in the shared process runner and activeRunDirectory still set
        // Verify via attempting to start new ingest on same client — should be alreadyRunning
        do {
            _ = try await client.ingest(youTubeURL: validYouTubeURL())
            XCTFail("Second ingest should be blocked while prior process still owned")
        } catch let err as YouTubeIngestError {
            XCTAssertEqual(err, .alreadyRunning, "Ownership should remain, got \(err)")
        }

        // Original task should have surfaced cleanupFailed, not success
        do {
            _ = try await task.value
            XCTFail("Original ingest should throw cleanupFailed")
        } catch let err as YouTubeIngestError {
            XCTAssertTrue(err == .cancelled || { if case .cleanupFailed = err { return true }; return false }(), "Should be cancelled or cleanupFailed, got \(err)")
        } catch {
            // Also acceptable if task was cancelled
        }

        // Cleanup
        if let dirs = try? FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil) {
            for d in dirs { try? FileManager.default.removeItem(at: d) }
        }
        task.cancel()
        _ = try? await task.value
    }

    func testNewIngestCannotStartWhilePriorOwnedProcessRemainsAlive() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytSleepScript = """
        #!/usr/bin/python3
        import time, sys, os
        time.sleep(10)
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "mp4")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            open(out, "wb").write(b"\\x00"*100)
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytSleepScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase, isRunningCheck: { _ in true })

        let target3 = validYouTubeURL()
        let firstTask = Task { [client, target3] in
            try await client.ingest(youTubeURL: target3)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        // Fail termination
        do {
            try await client.cancel()
            XCTFail("Should throw cleanupFailed")
        } catch let err as YouTubeIngestError {
            guard case .cleanupFailed = err else { return XCTFail("Expected cleanupFailed, got \(err)") }
        }

        // Directly attempt second ingest while prior still owned — must be alreadyRunning
        do {
            _ = try await client.ingest(youTubeURL: shortYouTubeURL())
            XCTFail("Second ingest must be rejected with alreadyRunning")
        } catch let err as YouTubeIngestError {
            XCTAssertEqual(err, .alreadyRunning)
        }

        // Also attempt via separate Task to ensure actor guard holds under concurrency
        let shortTarget = shortYouTubeURL()
        let secondTask = Task { [client, shortTarget] in
            try await client.ingest(youTubeURL: shortTarget)
        }
        do {
            _ = try await secondTask.value
            XCTFail("Concurrent second ingest should be alreadyRunning")
        } catch let err as YouTubeIngestError {
            XCTAssertEqual(err, .alreadyRunning)
        } catch {
            XCTFail("Wrong \(error)")
        }

        // Verify run directory still present (not prematurely removed)
        let remaining = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
        XCTAssertEqual(remaining.count, 1, "Run directory must be retained while process still owned")

        // Cleanup
        for d in remaining { try? FileManager.default.removeItem(at: d) }
        firstTask.cancel()
        _ = try? await firstTask.value
    }

    // MARK: - Metadata-first preview: fetchPreview is metadata-only

    func testFetchPreviewIsMetadataOnlyNoMediaOrFFmpeg() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("yt-dlp " + " ".join(sys.argv[1:]) + "\\n")
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            os.makedirs(os.path.dirname(tmpl), exist_ok=True)
            if "--skip-download" in args:
                info = tmpl.replace("%(ext)s", "info.json")
                with open(info, "w") as jf:
                    jf.write('{"artist":"Preview Artist","track":"Preview Title","title":"Ignored","channel":"Preview Channel","album":"Preview Album","album_artist":"Preview AlbumArtist","release_year":2020,"genre":"Pop","track_number":2,"duration":123.4}')
                thumb = tmpl.replace("%(ext)s", "jpg")
                with open(thumb, "wb") as tf:
                    tf.write(b"\\xff\\xd8\\xff\\xe0thumb")
            else:
                out = tmpl.replace("%(ext)s", "mp4")
                os.makedirs(os.path.dirname(out), exist_ok=True)
                open(out, "wb").write(b"\\x00"*100)
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let preview = try await client.fetchPreview(youTubeURL: validYouTubeURL())

        // Metadata / artwork / duration
        XCTAssertEqual(preview.metadata, YouTubeTrackMetadata(artist: "Preview Artist", title: "Preview Title", album: "Preview Album", albumArtist: "Preview AlbumArtist", year: "2020", genre: "Pop", trackNumber: "2", channel: "Preview Channel"))
        XCTAssertEqual(preview.metadata?.exportBaseName, "Preview Artist - Preview Title")
        let artworkURL = try XCTUnwrap(preview.artworkURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkURL.path), "Artwork should be kept")
        XCTAssertEqual(artworkURL.lastPathComponent, "source.jpg")
        XCTAssertEqual(try Data(contentsOf: artworkURL), Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("thumb".utf8))
        XCTAssertEqual(preview.duration ?? 0, 123.4, accuracy: 0.01)

        let log = try String(contentsOf: logFile, encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1, "fetchPreview must invoke only yt-dlp, no FFmpeg, got log: \(log)")
        let ytLine = lines[0]
        XCTAssertTrue(ytLine.hasPrefix("yt-dlp "), "First line should be yt-dlp")
        XCTAssertTrue(ytLine.contains("--skip-download"), "fetchPreview must contain --skip-download: \(ytLine)")
        XCTAssertTrue(ytLine.contains("--no-playlist"), "fetchPreview must contain --no-playlist")
        XCTAssertTrue(ytLine.contains("--write-info-json"), "fetchPreview must contain --write-info-json")
        XCTAssertTrue(ytLine.contains("--write-thumbnail"), "fetchPreview must contain --write-thumbnail")
        XCTAssertFalse(ytLine.contains("bestaudio"), "fetchPreview must NOT contain bestaudio: \(ytLine)")
        XCTAssertFalse(ytLine.contains("bestvideo"), "fetchPreview must NOT request video: \(ytLine)")
        // Ensure no FFmpeg location formatting issues but no ffmpeg invocation
        XCTAssertFalse(ytLine.contains("ffmpeg -nostdin"), "Should not contain ffmpeg args")
        // Verify candidates.count == 0 success path: leaves no mixture.wav, no source media
        let runDirs = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
        XCTAssertEqual(runDirs.count, 1, "Run dir should remain with artwork only")
        let runDir = runDirs.first!
        let contents = try FileManager.default.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil)
        let names = Set(contents.map(\.lastPathComponent))
        XCTAssertFalse(names.contains("mixture.wav"), "fetchPreview must leave no mixture.wav")
        XCTAssertFalse(names.contains("source.mp4"), "fetchPreview must leave no media file candidate")
        XCTAssertTrue(names.contains("source.jpg"), "Artwork should be kept")
        XCTAssertFalse(names.contains("source.info.json"), "info.json should be cleaned")
        XCTAssertEqual(contents.count, 1, "Only artwork should remain, got \(contents)")

        // URL validation still works
        do {
            _ = try await client.fetchPreview(youTubeURL: URL(string: "http://www.youtube.com/watch?v=abc")!)
            XCTFail("http should be rejected")
        } catch let err as YouTubeIngestError {
            guard case .invalidYouTubeURL = err else { return XCTFail("Wrong \(err)") }
        }
        do {
            _ = try await client.fetchPreview(youTubeURL: URL(string: "https://example.com/video")!)
            XCTFail("non-youtube should be rejected")
        } catch let err as YouTubeIngestError {
            guard case .invalidYouTubeURL = err else { return XCTFail("Wrong \(err)") }
        }

        // Cleanup preview run dir
        try? FileManager.default.removeItem(at: runDir)
    }

    func testDownloadAudioOnlyUsesAudioOnlyNoFFmpeg() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("yt-dlp " + " ".join(sys.argv[1:]) + "\\n")
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "m4a")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as outf:
                outf.write(b"\\x00" * 2048)
            info = tmpl.replace("%(ext)s", "info.json")
            with open(info, "w") as jf:
                jf.write('{"artist":"Audio Artist","track":"Audio Title","channel":"Audio Channel","duration":99.9}')
            thumb = tmpl.replace("%(ext)s", "jpg")
            with open(thumb, "wb") as tf:
                tf.write(b"\\xff\\xd8\\xff\\xe0audiothumb")
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let result = try await client.downloadAudioOnly(youTubeURL: shortYouTubeURL())

        // audioURL is source file, not WAV, and exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioURL.path), "downloadAudioOnly should return existing audio file")
        XCTAssertFalse(result.audioURL.lastPathComponent == "mixture.wav", "downloadAudioOnly must NOT produce mixture.wav")
        XCTAssertTrue(result.audioURL.pathExtension.lowercased() == "m4a" || result.audioURL.pathExtension.lowercased() == "opus" || result.audioURL.pathExtension.lowercased() != "wav", "Should be audio file not WAV: \(result.audioURL)")
        // metadata/artwork
        XCTAssertEqual(result.metadata, YouTubeTrackMetadata(artist: "Audio Artist", title: "Audio Title", channel: "Audio Channel"))
        let artwork = try XCTUnwrap(result.artworkURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artwork.path))
        XCTAssertEqual(artwork.lastPathComponent, "source.jpg")

        let log = try String(contentsOf: logFile, encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1, "downloadAudioOnly must invoke only yt-dlp, no FFmpeg, got \(log)")
        let ytLine = lines[0]
        XCTAssertTrue(ytLine.hasPrefix("yt-dlp "))
        XCTAssertTrue(ytLine.contains("-f bestaudio"), "Should contain strict -f bestaudio: \(ytLine)")
        XCTAssertFalse(ytLine.contains("bestaudio*"), "Must NOT contain bestaudio* fallback: \(ytLine)")
        XCTAssertFalse(ytLine.contains("bestaudio/"), "Must be strict bestaudio, no slash fallback: \(ytLine)")
        XCTAssertTrue(ytLine.contains("--no-playlist"))
        XCTAssertTrue(ytLine.contains("--write-info-json"))
        XCTAssertTrue(ytLine.contains("--write-thumbnail"))
        XCTAssertFalse(ytLine.contains("--skip-download"), "downloadAudioOnly must NOT contain --skip-download: \(ytLine)")
        XCTAssertFalse(ytLine.contains("bestvideo"), "Must never request video: \(ytLine)")
        // Ensure no bare "best" without audio qualifier triggers false positive; check best without audio is not present except bestaudio
        if ytLine.contains("best") {
            XCTAssertTrue(ytLine.contains("bestaudio"), "Any best must be audio-qualified: \(ytLine)")
        }
        // No mixture.wav in run dir
        let runDir = result.audioURL.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil)
        let names = Set(contents.map(\.lastPathComponent))
        XCTAssertFalse(names.contains("mixture.wav"), "downloadAudioOnly must NOT produce mixture.wav")
        XCTAssertTrue(names.contains("source.m4a"), "Audio source should remain")
        XCTAssertTrue(names.contains("source.jpg"), "Artwork should remain")
        XCTAssertFalse(names.contains("source.info.json"), "info.json cleaned")
        // Output file exists and is audio file, not WAV validation
        let attrs = try FileManager.default.attributesOfItem(atPath: result.audioURL.path)
        XCTAssertGreaterThan(attrs[.size] as? UInt64 ?? 0, 0)

        // URL validation
        do {
            _ = try await client.downloadAudioOnly(youTubeURL: URL(string: "https://example.com/video")!)
            XCTFail("Should reject non-youtube")
        } catch let err as YouTubeIngestError {
            guard case .invalidYouTubeURL = err else { return XCTFail("Wrong \(err)") }
        }
    }

    func testIngestWithMetadataUsesAudioOnlyAndCanonicalFFmpeg() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("yt-dlp " + " ".join(sys.argv[1:]) + "\\n")
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "webm")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as outf:
                outf.write(b"\\x00" * 512)
            info = tmpl.replace("%(ext)s", "info.json")
            with open(info, "w") as jf:
                jf.write('{"artist":"Ingest Artist","track":"Ingest Title"}')
            thumb = tmpl.replace("%(ext)s", "jpg")
            with open(thumb, "wb") as tf:
                tf.write(b"\\xff\\xd8\\xff\\xe0thumb")
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path, frames: 2048, sr: 44100, ch: 2)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let result = try await client.ingestWithMetadata(youTubeURL: validYouTubeURL())

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioURL.path))
        XCTAssertEqual(result.audioURL.lastPathComponent, "mixture.wav")
        // Validate canonical via AVAudioFile
        let file = try AVAudioFile(forReading: result.audioURL)
        XCTAssertEqual(file.processingFormat.sampleRate, 44100, accuracy: 0.1)
        XCTAssertEqual(file.processingFormat.channelCount, 2)

        let log = try String(contentsOf: logFile, encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2, "ingestWithMetadata should invoke yt-dlp + ffmpeg, got \(log)")
        let ytLine = lines[0]
        XCTAssertTrue(ytLine.hasPrefix("yt-dlp "))
        XCTAssertTrue(ytLine.contains("-f bestaudio"), "ingestWithMetadata must contain strict -f bestaudio: \(ytLine)")
        XCTAssertFalse(ytLine.contains("bestaudio*"), "Must NOT contain bestaudio* fallback: \(ytLine)")
        XCTAssertFalse(ytLine.contains("bestaudio/"), "Must be strict bestaudio, no slash fallback: \(ytLine)")
        XCTAssertTrue(ytLine.contains("--no-playlist"))
        XCTAssertTrue(ytLine.contains("--write-info-json"))
        XCTAssertTrue(ytLine.contains("--write-thumbnail"))
        XCTAssertFalse(ytLine.contains("bestvideo"), "Must never request video: \(ytLine)")
        XCTAssertFalse(ytLine.contains("--skip-download"), "ingestWithMetadata must download media, not skip: \(ytLine)")

        let ffLine = lines[1]
        XCTAssertTrue(ffLine.hasPrefix("ffmpeg "))
        XCTAssertTrue(ffLine.contains("-nostdin"), "ffmpeg must contain -nostdin")
        XCTAssertTrue(ffLine.contains("-ar"), "ffmpeg must contain -ar")
        XCTAssertTrue(ffLine.contains("44100"))
        XCTAssertTrue(ffLine.contains("-ac"), "ffmpeg must contain -ac")
        XCTAssertTrue(ffLine.contains("pcm_f32le"))
        XCTAssertTrue(ffLine.contains("mixture.wav"))
        // Ensure canonical args exactly
        XCTAssertTrue(ffLine.contains("-ar 44100"), "ffmpeg should contain -ar 44100: \(ffLine)")
        XCTAssertTrue(ffLine.contains("-ac 2"), "ffmpeg should contain -ac 2: \(ffLine)")
        XCTAssertTrue(ffLine.contains("-c:a pcm_f32le"), "ffmpeg should contain -c:a pcm_f32le: \(ffLine)")
    }

    // MARK: - Conservative YouTube music metadata extraction

    func testStructuredArtistAndTrackWinsOverChannelSplit() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            os.makedirs(os.path.dirname(tmpl), exist_ok=True)
            info = tmpl.replace("%(ext)s", "info.json")
            with open(info, "w") as jf:
                jf.write('{"artist":"Real Artist","track":"Real Track","title":"Wrong Artist - Wrong Title","channel":"Wrong Artist"}')
            thumb = tmpl.replace("%(ext)s", "jpg")
            with open(thumb, "wb") as tf:
                tf.write(b"\\xff\\xd8\\xff\\xe0thumb")
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }
        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let preview = try await client.fetchPreview(youTubeURL: validYouTubeURL())
        XCTAssertEqual(preview.metadata?.artist, "Real Artist")
        XCTAssertEqual(preview.metadata?.title, "Real Track")
        XCTAssertEqual(preview.metadata?.channel, "Wrong Artist")
    }

    func testCreatorFallbackProvidesArtist() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            os.makedirs(os.path.dirname(tmpl), exist_ok=True)
            info = tmpl.replace("%(ext)s", "info.json")
            with open(info, "w") as jf:
                jf.write('{"creator":"Creator Artist","track":"Creator Track","title":"Some Video Title","channel":"Some Channel"}')
            thumb = tmpl.replace("%(ext)s", "jpg")
            with open(thumb, "wb") as tf:
                tf.write(b"\\xff\\xd8\\xff\\xe0thumb")
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }
        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let preview = try await client.fetchPreview(youTubeURL: validYouTubeURL())
        XCTAssertEqual(preview.metadata?.artist, "Creator Artist")
        XCTAssertEqual(preview.metadata?.title, "Creator Track")
        XCTAssertEqual(preview.metadata?.channel, "Some Channel")
    }

    func testChannelCorroboratedSplitInfersArtistAndTitle() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            os.makedirs(os.path.dirname(tmpl), exist_ok=True)
            info = tmpl.replace("%(ext)s", "info.json")
            with open(info, "w") as jf:
                jf.write('{"title":"Patrick Watson - Je Te Laisserai Des Mots","channel":"Patrick Watson"}')
            thumb = tmpl.replace("%(ext)s", "jpg")
            with open(thumb, "wb") as tf:
                tf.write(b"\\xff\\xd8\\xff\\xe0thumb")
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }
        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let preview = try await client.fetchPreview(youTubeURL: validYouTubeURL())
        XCTAssertEqual(preview.metadata?.artist, "Patrick Watson")
        XCTAssertEqual(preview.metadata?.title, "Je Te Laisserai Des Mots")
        XCTAssertEqual(preview.metadata?.channel, "Patrick Watson")
    }

    func testTopicChannelNormalizationInfersArtistAndTitle() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            os.makedirs(os.path.dirname(tmpl), exist_ok=True)
            info = tmpl.replace("%(ext)s", "info.json")
            with open(info, "w") as jf:
                jf.write('{"title":"Patrick Watson - Je Te Laisserai Des Mots","channel":"Patrick Watson - Topic"}')
            thumb = tmpl.replace("%(ext)s", "jpg")
            with open(thumb, "wb") as tf:
                tf.write(b"\\xff\\xd8\\xff\\xe0thumb")
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }
        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let preview = try await client.fetchPreview(youTubeURL: validYouTubeURL())
        XCTAssertEqual(preview.metadata?.artist, "Patrick Watson")
        XCTAssertEqual(preview.metadata?.title, "Je Te Laisserai Des Mots")
        XCTAssertEqual(preview.metadata?.channel, "Patrick Watson - Topic")
    }

    func testNonMatchingChannelDoesNotInfer() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            os.makedirs(os.path.dirname(tmpl), exist_ok=True)
            info = tmpl.replace("%(ext)s", "info.json")
            with open(info, "w") as jf:
                jf.write('{"title":"Patrick Watson - Je Te Laisserai Des Mots","channel":"Some Other Channel"}')
            thumb = tmpl.replace("%(ext)s", "jpg")
            with open(thumb, "wb") as tf:
                tf.write(b"\\xff\\xd8\\xff\\xe0thumb")
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }
        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let preview = try await client.fetchPreview(youTubeURL: validYouTubeURL())
        XCTAssertNil(preview.metadata?.artist)
        XCTAssertEqual(preview.metadata?.title, "Patrick Watson - Je Te Laisserai Des Mots")
        XCTAssertEqual(preview.metadata?.channel, "Some Other Channel")
    }

    func testRawTitleFallbackWithoutDash() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            os.makedirs(os.path.dirname(tmpl), exist_ok=True)
            info = tmpl.replace("%(ext)s", "info.json")
            with open(info, "w") as jf:
                jf.write('{"title":"Just A Video Title Without Dash Corroboration","channel":"Random Channel"}')
            thumb = tmpl.replace("%(ext)s", "jpg")
            with open(thumb, "wb") as tf:
                tf.write(b"\\xff\\xd8\\xff\\xe0thumb")
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }
        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let preview = try await client.fetchPreview(youTubeURL: validYouTubeURL())
        XCTAssertNil(preview.metadata?.artist)
        XCTAssertEqual(preview.metadata?.title, "Just A Video Title Without Dash Corroboration")
        XCTAssertEqual(preview.metadata?.channel, "Random Channel")
    }

    func testStructuredArtistWithMissingTrackUsesCorroboratedSplitTitle() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            os.makedirs(os.path.dirname(tmpl), exist_ok=True)
            info = tmpl.replace("%(ext)s", "info.json")
            with open(info, "w") as jf:
                jf.write('{"artist":"Patrick Watson","title":"Patrick Watson - Je te laisserai des mots","channel":"Some Other Channel"}')
            thumb = tmpl.replace("%(ext)s", "jpg")
            with open(thumb, "wb") as tf:
                tf.write(b"\\xff\\xd8\\xff\\xe0thumb")
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }
        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let preview = try await client.fetchPreview(youTubeURL: validYouTubeURL())
        XCTAssertEqual(preview.metadata?.artist, "Patrick Watson")
        XCTAssertEqual(preview.metadata?.title, "Je te laisserai des mots")
        XCTAssertEqual(preview.metadata?.channel, "Some Other Channel")
    }

    // MARK: - Progress phases (truthful)

    func testIngestWithMetadataReportsDownloadingThenPreparing() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }

        let ytScript = """
        #!/usr/bin/python3
        import sys, os
        args = sys.argv[1:]
        if "-o" in args:
            idx = args.index("-o")
            tmpl = args[idx+1]
            out = tmpl.replace("%(ext)s", "mp4")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            open(out, "wb").write(b"\\x00"*1024)
        sys.exit(0)
        """
        let ffScript = writeValidWavPythonScript(logPath: logFile.path, frames: 1024, sr: 44100, ch: 2)
        let ytURL = try makeFakeExecutable(name: "yt-dlp", scriptContent: ytScript)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer {
            try? FileManager.default.removeItem(at: ytURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent())
        }

        let client = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase)

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private var _phases: [YouTubeIngestPhase] = []
            var phases: [YouTubeIngestPhase] { lock.withLock { _phases } }
            func append(_ p: YouTubeIngestPhase) { lock.withLock { _phases.append(p) } }
        }
        let collector = Collector()

        let result = try await client.ingestWithMetadata(youTubeURL: validYouTubeURL(), onProgress: { phase in
            collector.append(phase)
        })

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioURL.path))
        XCTAssertEqual(collector.phases, [.downloading, .preparing], "Progress must be downloading then preparing in order")
        // Backward-compatible no-arg call must still work
        let cacheBase2 = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase2) }
        let client2 = YouTubeIngestClient(ytDlpURL: ytURL, ffmpegURL: ffURL, cacheBaseURL: cacheBase2)
        let result2 = try await client2.ingestWithMetadata(youTubeURL: shortYouTubeURL())
        XCTAssertTrue(FileManager.default.fileExists(atPath: result2.audioURL.path))
    }
}
