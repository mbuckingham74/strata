import XCTest
@testable import Strata
import Foundation
import AVFoundation

final class LocalAudioIngestClientTests: XCTestCase {

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

    private func makeInputFile(at dir: URL, name: String = "input.mp3", content: Data = Data("fake audio".utf8)) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try content.write(to: url)
        return url
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

    func testFFmpegLaunchArguments() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let inputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inputDir) }
        let inputURL = try makeInputFile(at: inputDir, name: "song.m4a")

        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer { try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent()) }

        let client = LocalAudioIngestClient(ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let result = try await client.ingest(localFileURL: inputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        let log = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("-nostdin"), "Should contain -nostdin")
        XCTAssertTrue(log.contains("-ar"), "Should contain -ar")
        XCTAssertTrue(log.contains("44100"))
        XCTAssertTrue(log.contains("-ac"))
        XCTAssertTrue(log.contains("pcm_f32le"))
        XCTAssertTrue(log.contains("mixture.wav"))
        XCTAssertTrue(log.contains(inputURL.path), "Should contain input path")
        // -nostdin must precede -y and input
        if let n = log.range(of: "-nostdin"), let y = log.range(of: " -y ") {
            XCTAssertTrue(n.lowerBound < y.lowerBound)
        }
    }

    func testSuccessfulCanonicalPublication() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let inputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inputDir) }
        let inputURL = try makeInputFile(at: inputDir, name: "track.mp3")

        let ffScript = writeValidWavPythonScript(logPath: logFile.path, frames: 2048, sr: 44100, ch: 2)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer { try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent()) }

        let client = LocalAudioIngestClient(ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let result = try await client.ingest(localFileURL: inputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        let file = try AVAudioFile(forReading: result)
        XCTAssertEqual(file.processingFormat.sampleRate, 44100, accuracy: 0.1)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(file.processingFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(file.length, 2048)
        XCTAssertEqual(result.lastPathComponent, "mixture.wav")
        let runDir = result.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents.first?.lastPathComponent, "mixture.wav")
    }

    func testNonZeroToolExit() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let inputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inputDir) }
        let inputURL = try makeInputFile(at: inputDir)

        let ffFail = """
        #!/usr/bin/python3
        import sys
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("ffmpeg " + " ".join(sys.argv[1:]) + "\\n")
        sys.stderr.write("ffmpeg failed mock\\n")
        sys.exit(2)
        """
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffFail)
        defer { try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent()) }
        let client = LocalAudioIngestClient(ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        do {
            _ = try await client.ingest(localFileURL: inputURL)
            XCTFail("Should have thrown")
        } catch let err as LocalAudioIngestError {
            guard case .toolFailure(let tool, let code, let tail) = err else { return XCTFail("Wrong \(err)") }
            XCTAssertEqual(tool, "ffmpeg")
            XCTAssertEqual(code, 2)
            XCTAssertTrue(tail?.contains("ffmpeg failed mock") ?? false)
        }
        let remaining = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testInvalidCanonicalOutput() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let inputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inputDir) }
        let inputURL = try makeInputFile(at: inputDir)

        let ffInvalid = writeValidWavPythonScript(logPath: logFile.path, frames: 1024, sr: 48000, ch: 2)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffInvalid)
        defer { try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent()) }
        let client = LocalAudioIngestClient(ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        do {
            _ = try await client.ingest(localFileURL: inputURL)
            XCTFail("Should have thrown invalidCanonical")
        } catch let err as LocalAudioIngestError {
            guard case .invalidCanonicalOutput = err else { return XCTFail("Wrong \(err)") }
        }
        // mono
        let ffMono = writeValidWavPythonScript(logPath: logFile.path, frames: 1024, sr: 44100, ch: 1)
        let ffURL2 = try makeFakeExecutable(name: "ffmpeg2", scriptContent: ffMono)
        defer { try? FileManager.default.removeItem(at: ffURL2.deletingLastPathComponent()) }
        let client2 = LocalAudioIngestClient(ffmpegURL: ffURL2, cacheBaseURL: cacheBase)
        do {
            _ = try await client2.ingest(localFileURL: inputURL)
            XCTFail("Should have thrown for mono")
        } catch let err as LocalAudioIngestError {
            guard case .invalidCanonicalOutput = err else { return XCTFail("Wrong \(err)") }
        }
    }

    func testCancellationDuringFFmpeg() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let inputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inputDir) }
        let inputURL = try makeInputFile(at: inputDir)

        let ffSleep = """
        #!/usr/bin/python3
        import sys, time
        log_path = "\(logFile.path)"
        with open(log_path, "a") as f:
            f.write("ffmpeg " + " ".join(sys.argv[1:]) + "\\n")
        time.sleep(5)
        sys.exit(0)
        """
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffSleep)
        defer { try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent()) }
        let client = LocalAudioIngestClient(ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let task = Task { try await client.ingest(localFileURL: inputURL) }
        try await Task.sleep(nanoseconds: 200_000_000)
        try? await client.cancel()
        do {
            _ = try await task.value
            XCTFail("Should be cancelled")
        } catch let err as LocalAudioIngestError {
            XCTAssertEqual(err, .cancelled)
        } catch is CancellationError {}
        let remaining = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAlreadyRunningGuard() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let inputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inputDir) }
        let inputURL = try makeInputFile(at: inputDir)

        let ffSleep = """
        #!/usr/bin/python3
        import time
        time.sleep(5)
        """
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffSleep)
        defer { try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent()) }
        let client = LocalAudioIngestClient(ffmpegURL: ffURL, cacheBaseURL: cacheBase, isRunningCheck: { _ in true })
        let first = Task { try await client.ingest(localFileURL: inputURL) }
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            _ = try await client.ingest(localFileURL: inputURL)
            XCTFail("Should be alreadyRunning")
        } catch let err as LocalAudioIngestError {
            XCTAssertEqual(err, .alreadyRunning)
        }
        try? await client.cancel()
        _ = try? await first.value
        // cleanup
        if let dirs = try? FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil) {
            for d in dirs { try? FileManager.default.removeItem(at: d) }
        }
    }

    func testInvalidInputNotFound() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let ffScript = writeValidWavPythonScript(logPath: logFile.path)
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffScript)
        defer { try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent()) }
        let client = LocalAudioIngestClient(ffmpegURL: ffURL, cacheBaseURL: cacheBase)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            _ = try await client.ingest(localFileURL: missing)
            XCTFail("Should have thrown invalidInput")
        } catch let err as LocalAudioIngestError {
            guard case .invalidInput = err else { return XCTFail("Wrong \(err)") }
        }
    }

    func testCleanupOfTemporaryPartialFiles() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let inputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inputDir) }
        let inputURL = try makeInputFile(at: inputDir)

        // success leaves mixture
        do {
            let ffScript = writeValidWavPythonScript(logPath: logFile.path, frames: 512, sr: 44100, ch: 2)
            let ffURL = try makeFakeExecutable(name: "ffmpeg-ok", scriptContent: ffScript)
            defer { try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent()) }
            let client = LocalAudioIngestClient(ffmpegURL: ffURL, cacheBaseURL: cacheBase)
            let result = try await client.ingest(localFileURL: inputURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
            let runDir = result.deletingLastPathComponent()
            let contents = try FileManager.default.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil)
            XCTAssertEqual(contents.count, 1)
            try? FileManager.default.removeItem(at: runDir)
        }
        // failure cleanup
        do {
            let ffFail = """
            #!/usr/bin/python3
            import sys
            sys.stderr.write("failure mock\\n")
            sys.exit(1)
            """
            let ffURL = try makeFakeExecutable(name: "ffmpeg-fail", scriptContent: ffFail)
            defer { try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent()) }
            let client = LocalAudioIngestClient(ffmpegURL: ffURL, cacheBaseURL: cacheBase)
            _ = try? await client.ingest(localFileURL: inputURL)
            let remaining = try FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil)
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testOwnershipRemainsIfTerminationCannotBeProven() async throws {
        let cacheBase = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let logFile = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: logFile) }
        let inputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inputDir) }
        let inputURL = try makeInputFile(at: inputDir)

        let ffSleep = """
        #!/usr/bin/python3
        import time
        time.sleep(10)
        """
        let ffURL = try makeFakeExecutable(name: "ffmpeg", scriptContent: ffSleep)
        defer { try? FileManager.default.removeItem(at: ffURL.deletingLastPathComponent()) }
        let client = LocalAudioIngestClient(ffmpegURL: ffURL, cacheBaseURL: cacheBase, isRunningCheck: { _ in true })
        let task = Task { try await client.ingest(localFileURL: inputURL) }
        try await Task.sleep(nanoseconds: 300_000_000)
        do {
            try await client.cancel()
            XCTFail("Should have thrown cleanupFailed")
        } catch let err as LocalAudioIngestError {
            guard case .cleanupFailed = err else { return XCTFail("Expected cleanupFailed, got \(err)") }
        }
        do {
            _ = try await client.ingest(localFileURL: inputURL)
            XCTFail("Should be alreadyRunning")
        } catch let err as LocalAudioIngestError {
            XCTAssertEqual(err, .alreadyRunning)
        }
        if let dirs = try? FileManager.default.contentsOfDirectory(at: cacheBase, includingPropertiesForKeys: nil) {
            for d in dirs { try? FileManager.default.removeItem(at: d) }
        }
        task.cancel()
        _ = try? await task.value
    }
}
