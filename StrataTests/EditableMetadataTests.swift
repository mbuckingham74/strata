import XCTest
import AVFoundation
@testable import Strata
import Foundation

@MainActor
final class EditableMetadataTests: XCTestCase {

    // MARK: - Helpers

    private func makeExecutable(at url: URL, contents: String) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeWAVArtifact(name: StemName, url: URL, left: [Float], right: [Float]) throws -> StemArtifact {
        guard left.count == right.count, !left.isEmpty else { throw NSError(domain: "EditableMetadataTests", code: 1) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(canonicalSampleRate),
            AVNumberOfChannelsKey: canonicalChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = AVAudioFrameCount(left.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount), let channels = buffer.floatChannelData else {
            throw NSError(domain: "EditableMetadataTests", code: 2)
        }
        buffer.frameLength = frameCount
        for frame in 0..<left.count { channels[0][frame] = left[frame]; channels[1][frame] = right[frame] }
        try file.write(from: buffer)
        let data = try Data(contentsOf: url)
        return StemArtifact(name: name, url: url, sha256: sha256Hex(of: data), fileSize: UInt64(data.count), frameCount: UInt64(frameCount), channels: canonicalChannels, sampleRate: canonicalSampleRate)
    }

    private func makeFakeWorker(script: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let venvBin = tmp.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: venvBin, withIntermediateDirectories: true)
        let fakeScript = tmp.appendingPathComponent("fake_worker.py")
        try script.write(to: fakeScript, atomically: true, encoding: .utf8)
        let pythonWrapper = venvBin.appendingPathComponent("python3")
        let wrapper = "#!/bin/sh\nexec /usr/bin/python3 \"\(fakeScript.path)\" \"$@\"\n"
        try wrapper.write(to: pythonWrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pythonWrapper.path)
        return tmp
    }

    private func makeWAV(at url: URL, frames: UInt32 = 1024) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<2 { let ptr = buffer.floatChannelData![ch]; for i in 0..<Int(frames) { ptr[i] = Float(i % 100)*0.001 } }
        try file.write(from: buffer)
    }

    private func successWorkerScript() -> String {
        """
        import sys, json, os, struct, hashlib
        sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
        def make_wav(path, frames=1024, sr=44100, ch=2):
            data = b''.join(struct.pack('<f', 0.0) for _ in range(frames*ch))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            import struct as st
            with open(path, 'wb') as f:
                f.write(b'RIFF')
                f.write(st.pack('<I', 36 + len(data)))
                f.write(b'WAVE')
                f.write(b'fmt ')
                f.write(st.pack('<I', 16))
                f.write(st.pack('<H', 3))
                f.write(st.pack('<H', ch))
                f.write(st.pack('<I', sr))
                f.write(st.pack('<I', sr * ch * 4))
                f.write(st.pack('<H', ch * 4))
                f.write(st.pack('<H', 32))
                f.write(b'data')
                f.write(st.pack('<I', len(data)))
                f.write(data)
        for line in sys.stdin:
            try: obj=json.loads(line)
            except: continue
            if obj.get("type")=="shutdown": sys.exit(0)
            if obj.get("type")=="separate":
                jid=obj["job_id"]; outdir=obj["output_dir"]; inp=obj["input_path"]
                sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
                job_dir=os.path.join(outdir, jid)
                os.makedirs(job_dir, exist_ok=True)
                inp_sha=hashlib.sha256(open(inp,'rb').read()).hexdigest()
                stems=[]
                for name in ["bass","drums","other","vocals","guitar","piano"]:
                    p=os.path.join(job_dir, f"{name}.wav")
                    make_wav(p, frames=1024)
                    stems.append({"name":name,"path":p,"sha256":hashlib.sha256(open(p,'rb').read()).hexdigest(),"file_size":os.path.getsize(p),"frame_count":1024,"channels":2,"sample_rate":44100})
                    sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":p})+"\\n"); sys.stdout.flush()
                manifest={"job_id":jid,"model":"roformer-model-bs-roformer-sw-by-jarredou","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e","backend":"mlx","device":"mps","input_path":inp,"output_dir":outdir,"input_sha256":inp_sha,"input_metadata":{"sample_rate":44100,"channels":2,"frames":1024,"duration":0.02,"sha256":inp_sha},"stems":stems}
                man_path=os.path.join(job_dir,"manifest.json")
                open(man_path,'w').write(json.dumps(manifest))
                sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":man_path})+"\\n"); sys.stdout.flush()
        """
    }

    private func makeArtifact(name: StemName, url: URL, data: Data) throws -> StemArtifact {
        try data.write(to: url)
        return StemArtifact(name: name, url: url, sha256: sha256Hex(of: data), fileSize: UInt64(data.count), frameCount: 1, channels: 2, sampleRate: 44_100)
    }

    private actor MockYouTubeMeta: YouTubeIngesting {
        let result: YouTubeIngestResult
        init(result: YouTubeIngestResult) { self.result = result }
        func ingest(youTubeURL: URL) async throws -> URL { try await ingestWithMetadata(youTubeURL: youTubeURL).audioURL }
        func ingestWithMetadata(youTubeURL: URL) async throws -> YouTubeIngestResult { result }
        func cancel() async throws {}
    }

    // MARK: - Prepopulation and edit override

    func testPrepopulationFromYouTubeIngest() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL)
        let artworkURL = mixtureDir.appendingPathComponent("thumb.jpg")
        try Data([0xFF,0xD8,0xFF,0xE0]).write(to: artworkURL)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(artist: "Massive Attack", title: "Teardrop", album: "Mezzanine", albumArtist: "Massive Attack", year: "1998", genre: "Trip Hop", trackNumber: "3"))
        let dir = try makeFakeWorker(script: successWorkerScript())
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockYouTubeMeta(result: YouTubeIngestResult(audioURL: mixtureURL, metadata: metadata, artworkURL: artworkURL))
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }
        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: mock)
        controller.editableTitle = "stale"
        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        let task = try XCTUnwrap(controller.debugCurrentTask())
        await task.value
        XCTAssertEqual(controller.state, .completed)
        XCTAssertEqual(controller.editableArtist, "Massive Attack")
        XCTAssertEqual(controller.editableTitle, "Teardrop")
        XCTAssertEqual(controller.editableAlbum, "Mezzanine")
        XCTAssertEqual(controller.editableAlbumArtist, "Massive Attack")
        XCTAssertEqual(controller.editableYear, "1998")
        XCTAssertEqual(controller.editableGenre, "Trip Hop")
        XCTAssertEqual(controller.editableTrackNumber, "3")
        XCTAssertEqual(controller.editableArtwork, .keep)
        XCTAssertEqual(controller.effectiveArtworkURL, artworkURL)
        XCTAssertEqual(controller.isEditableMetadataAvailable, true)
        await controller.shutdownWorker(policy: .testShort())
    }

    func testEditOverridesPropagation() async throws {
        let controller = InferenceController()
        controller.editableArtist = "Massive Attack"
        controller.editableTitle = "Teardrop"
        controller.editableAlbum = "Mezzanine"
        controller.editableYear = "1998"
        let effective = controller.effectiveYouTubeMetadata
        XCTAssertEqual(effective?.artist, "Massive Attack")
        XCTAssertEqual(effective?.title, "Teardrop")
        controller.editableArtist = "Edited Artist"
        controller.editableTitle = "Edited Title"
        let edited = controller.effectiveYouTubeMetadata
        XCTAssertEqual(edited?.artist, "Edited Artist")
        XCTAssertEqual(edited?.title, "Edited Title")
        XCTAssertEqual(edited?.album, "Mezzanine")
    }

    func testClearingFieldOmitsMetadataArg() async throws {
        let controller = InferenceController()
        controller.editableArtist = "Massive Attack"
        controller.editableTitle = "Teardrop"
        var meta = controller.effectiveYouTubeMetadata
        XCTAssertNotNil(meta)
        controller.editableArtist = ""
        meta = controller.effectiveYouTubeMetadata
        XCTAssertNil(meta?.artist)
        XCTAssertEqual(meta?.title, "Teardrop")
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sourceURL = directoryURL.appendingPathComponent("vocals.wav")
        let destURL = directoryURL.appendingPathComponent("out.mp3")
        let argsURL = directoryURL.appendingPathComponent("args.txt")
        let ffmpegURL = directoryURL.appendingPathComponent("ffmpeg")
        let artifact = try makeArtifact(name: .vocals, url: sourceURL, data: Data([0x52,0x49,0x46,0x46]))
        try makeExecutable(at: ffmpegURL, contents: "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argsURL.path)'\nfor a in \"$@\"; do output=\"$a\"; done\nprintf 'x' > \"$output\"\n")
        let currentMeta = controller.effectiveYouTubeMetadata
        try StemExporter.export(artifact, to: destURL, format: .mp3, metadata: currentMeta, ffmpegURL: ffmpegURL)
        let args = try String(contentsOf: argsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertFalse(args.contains("artist=Massive Attack"))
        XCTAssertTrue(args.contains("title=Teardrop"))
    }

    func testClearingAllFieldsYieldsNilMetadataNoId3WithoutArtwork() async throws {
        let controller = InferenceController()
        controller.editableArtist = ""
        controller.editableTitle = ""
        controller.editableAlbum = ""
        controller.editableAlbumArtist = ""
        controller.editableYear = ""
        controller.editableGenre = ""
        controller.editableTrackNumber = ""
        controller.editableArtwork = .keep
        let meta = controller.effectiveYouTubeMetadata
        XCTAssertNil(meta)
        let art = controller.effectiveArtworkURL
        XCTAssertNil(art)
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sourceURL = directoryURL.appendingPathComponent("a.wav")
        let destURL = directoryURL.appendingPathComponent("b.mp3")
        let argsURL = directoryURL.appendingPathComponent("args.txt")
        let ffmpegURL = directoryURL.appendingPathComponent("ffmpeg")
        try Data("x".utf8).write(to: sourceURL)
        try makeExecutable(at: ffmpegURL, contents: "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argsURL.path)'\nfor a in \"$@\"; do output=\"$a\"; done\nprintf 'x' > \"$output\"\n")
        try StemExporter.exportMP3(from: sourceURL, to: destURL, metadata: meta, artworkURL: art, ffmpegURL: ffmpegURL)
        let args = try String(contentsOf: argsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertFalse(args.contains("-id3v2_version"))
        XCTAssertFalse(args.contains("-metadata"))
    }

    func testArtworkKeepUsesOriginal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("s.wav")
        let destURL = dir.appendingPathComponent("d.mp3")
        let argsURL = dir.appendingPathComponent("args.txt")
        let ffmpegURL = dir.appendingPathComponent("ffmpeg")
        let artworkURL = dir.appendingPathComponent("art.jpg")
        try Data("art".utf8).write(to: artworkURL)
        try Data("wav".utf8).write(to: sourceURL)
        try makeExecutable(at: ffmpegURL, contents: "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argsURL.path)'\nfor a in \"$@\"; do output=\"$a\"; done\nprintf 'x' > \"$output\"\n")
        let controller = InferenceController()
        controller.editableArtwork = .keep
        try StemExporter.exportMP3(from: sourceURL, to: destURL, metadata: nil, artworkURL: artworkURL, ffmpegURL: ffmpegURL)
        let args = try String(contentsOf: argsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(args.contains(artworkURL.path))
        XCTAssertTrue(args.contains("-map"))
        XCTAssertTrue(args.contains("-id3v2_version"))
    }

    func testArtworkRemoveOmitsArtworkArgs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("s.wav")
        let destURL = dir.appendingPathComponent("d.mp3")
        let argsURL = dir.appendingPathComponent("args.txt")
        let ffmpegURL = dir.appendingPathComponent("ffmpeg")
        try Data("wav".utf8).write(to: sourceURL)
        try makeExecutable(at: ffmpegURL, contents: "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argsURL.path)'\nfor a in \"$@\"; do output=\"$a\"; done\nprintf 'x' > \"$output\"\n")
        let meta = try XCTUnwrap(YouTubeTrackMetadata(artist: "A", title: "T"))
        try StemExporter.exportMP3(from: sourceURL, to: destURL, metadata: meta, artworkURL: nil, ffmpegURL: ffmpegURL)
        let args = try String(contentsOf: argsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertFalse(args.contains("-map"))
        XCTAssertFalse(args.contains("mjpeg"))
        XCTAssertTrue(args.contains("-id3v2_version"))
        XCTAssertTrue(args.contains("artist=A"))
    }

    func testArtworkReplaceUsesReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("s.wav")
        let destURL = dir.appendingPathComponent("d.mp3")
        let argsURL = dir.appendingPathComponent("args.txt")
        let ffmpegURL = dir.appendingPathComponent("ffmpeg")
        let originalArt = dir.appendingPathComponent("orig.jpg")
        let replacementArt = dir.appendingPathComponent("repl.png")
        try Data("orig".utf8).write(to: originalArt)
        try Data("repl".utf8).write(to: replacementArt)
        try Data("wav".utf8).write(to: sourceURL)
        try makeExecutable(at: ffmpegURL, contents: "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argsURL.path)'\nfor a in \"$@\"; do output=\"$a\"; done\nprintf 'x' > \"$output\"\n")
        try StemExporter.exportMP3(from: sourceURL, to: destURL, metadata: nil, artworkURL: replacementArt, ffmpegURL: ffmpegURL)
        let args = try String(contentsOf: argsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(args.contains(replacementArt.path))
        XCTAssertFalse(args.contains(originalArt.path))
    }

    func testEffectiveArtworkSwitch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let originalURL = dir.appendingPathComponent("thumb.jpg")
        let replacementURL = dir.appendingPathComponent("new.jpg")
        try Data([0xFF,0xD8,0xFF]).write(to: originalURL)
        try Data([0x89,0x50,0x4E,0x47]).write(to: replacementURL)
        let mixtureURL = dir.appendingPathComponent("mix.wav")
        try makeWAV(at: mixtureURL)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(artist: "A", title: "T"))
        let dir2 = try makeFakeWorker(script: successWorkerScript())
        defer { try? FileManager.default.removeItem(at: dir2) }
        let mock = MockYouTubeMeta(result: YouTubeIngestResult(audioURL: mixtureURL, metadata: metadata, artworkURL: originalURL))
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir2)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }
        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: mock)
        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        let task = try XCTUnwrap(controller.debugCurrentTask())
        await task.value
        XCTAssertEqual(controller.effectiveArtworkURL, originalURL)
        controller.editableArtwork = .removed
        XCTAssertNil(controller.effectiveArtworkURL)
        controller.editableArtwork = .replaced(replacementURL)
        XCTAssertEqual(controller.effectiveArtworkURL, replacementURL)
        controller.editableArtwork = .keep
        XCTAssertEqual(controller.effectiveArtworkURL, originalURL)
        await controller.shutdownWorker(policy: .testShort())
    }

    func testSingleStemMP3UsesEditedMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("vocals.wav")
        let destURL = dir.appendingPathComponent("out.mp3")
        let argsURL = dir.appendingPathComponent("args.txt")
        let ffmpegURL = dir.appendingPathComponent("ffmpeg")
        let artworkURL = dir.appendingPathComponent("art.jpg")
        try Data("art".utf8).write(to: artworkURL)
        let artifact = try makeArtifact(name: .vocals, url: sourceURL, data: Data([0x52,0x49,0x46,0x46]))
        try makeExecutable(at: ffmpegURL, contents: "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argsURL.path)'\nfor a in \"$@\"; do output=\"$a\"; done\nprintf 'x' > \"$output\"\n")
        let editedMeta = try XCTUnwrap(YouTubeTrackMetadata(artist: "Edited", title: "Edited Title", album: "Edited Album"))
        try StemExporter.export(artifact, to: destURL, format: .mp3, metadata: editedMeta, artworkURL: artworkURL, ffmpegURL: ffmpegURL)
        let args = try String(contentsOf: argsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(args.contains("artist=Edited"))
        XCTAssertTrue(args.contains("title=Edited Title"))
        XCTAssertTrue(args.contains("album=Edited Album"))
        XCTAssertTrue(args.contains(artworkURL.path))
    }

    func testCombinedMixUsesEditedMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let drums = try makeWAVArtifact(name: .drums, url: dir.appendingPathComponent("drums.wav"), left: [0,0.1], right: [0,0.1])
        let bass = try makeWAVArtifact(name: .bass, url: dir.appendingPathComponent("bass.wav"), left: [0,0.2], right: [0,0.2])
        let destURL = dir.appendingPathComponent("mix.mp3")
        let argsURL = dir.appendingPathComponent("args.txt")
        let ffmpegURL = dir.appendingPathComponent("ffmpeg")
        let artworkURL = dir.appendingPathComponent("art.jpg")
        try Data("art".utf8).write(to: artworkURL)
        try makeExecutable(at: ffmpegURL, contents: "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argsURL.path)'\nfor a in \"$@\"; do output=\"$a\"; done\nprintf 'x' > \"$output\"\n")
        let editedMeta = try XCTUnwrap(YouTubeTrackMetadata(artist: "Edited", title: "T"))
        try StemExporter.exportMix([drums, bass], to: destURL, format: .mp3, metadata: editedMeta, artworkURL: artworkURL, ffmpegURL: ffmpegURL)
        let args = try String(contentsOf: argsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(args.contains("artist=Edited"))
        XCTAssertTrue(args.contains(artworkURL.path))
    }

    func testDirectYouTubeMP3UsesEditedMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("mix.wav")
        let destURL = dir.appendingPathComponent("out.mp3")
        let argsURL = dir.appendingPathComponent("args.txt")
        let ffmpegURL = dir.appendingPathComponent("ffmpeg")
        let replacementArt = dir.appendingPathComponent("repl.jpg")
        try Data("wav".utf8).write(to: sourceURL)
        try Data("repl".utf8).write(to: replacementArt)
        try makeExecutable(at: ffmpegURL, contents: "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argsURL.path)'\nfor a in \"$@\"; do output=\"$a\"; done\nprintf 'x' > \"$output\"\n")
        let editedMeta = try XCTUnwrap(YouTubeTrackMetadata(artist: "Edited", title: "Edited Title", year: "2020"))
        try StemExporter.exportMP3(from: sourceURL, to: destURL, metadata: editedMeta, artworkURL: replacementArt, ffmpegURL: ffmpegURL)
        let args = try String(contentsOf: argsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(args.contains("artist=Edited"))
        XCTAssertTrue(args.contains("date=2020"))
        XCTAssertTrue(args.contains(replacementArt.path))
    }

    func testWAVExportIgnoresMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("vocals.wav")
        let destURL = dir.appendingPathComponent("out.wav")
        let data = Data([0x52,0x49,0x46,0x46,0x01])
        let artifact = try makeArtifact(name: .vocals, url: sourceURL, data: data)
        let meta = try XCTUnwrap(YouTubeTrackMetadata(artist: "A", title: "T"))
        let artURL = dir.appendingPathComponent("art.jpg")
        try Data("a".utf8).write(to: artURL)
        try StemExporter.export(artifact, to: destURL, format: .wav, metadata: meta, artworkURL: artURL)
        XCTAssertEqual(try Data(contentsOf: destURL), data)
    }

    func testLocalFileIngestClearsEditableMetadata() async throws {
        let dir = try makeFakeWorker(script: successWorkerScript())
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mix.wav")
        try makeWAV(at: mixtureURL)
        let metadata = try XCTUnwrap(YouTubeTrackMetadata(artist: "A", title: "T"))
        let artURL = mixtureDir.appendingPathComponent("thumb.jpg")
        try Data([0xFF,0xD8,0xFF]).write(to: artURL)
        let mock = MockYouTubeMeta(result: YouTubeIngestResult(audioURL: mixtureURL, metadata: metadata, artworkURL: artURL))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let controller = InferenceController(client: client, outputBase: base, youTubeIngest: mock)
        controller.startSeparation(youTubeURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        let t1 = try XCTUnwrap(controller.debugCurrentTask())
        await t1.value
        XCTAssertEqual(controller.editableArtist, "A")
        let localURL = mixtureDir.appendingPathComponent("local.wav")
        try makeWAV(at: localURL)
        controller.startSeparation(inputURL: localURL)
        let t2 = try XCTUnwrap(controller.debugCurrentTask())
        await t2.value
        XCTAssertEqual(controller.editableArtist, "")
        XCTAssertEqual(controller.editableTitle, "")
        XCTAssertEqual(controller.editableArtwork, .keep)
        XCTAssertNil(controller.effectiveYouTubeMetadata)
        XCTAssertNil(controller.effectiveArtworkURL)
        XCTAssertFalse(controller.isEditableMetadataAvailable)
        await controller.shutdownWorker(policy: .testShort())
    }

    func testPrepareYouTubeMP3PopulatesEditable() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mix.wav")
        try makeWAV(at: mixtureURL)
        let artURL = mixtureDir.appendingPathComponent("thumb.jpg")
        try Data([0xFF,0xD8,0xFF]).write(to: artURL)
        let meta = try XCTUnwrap(YouTubeTrackMetadata(artist: "PrepArtist", title: "PrepTitle"))
        let mock = MockYouTubeMeta(result: YouTubeIngestResult(audioURL: mixtureURL, metadata: meta, artworkURL: artURL))
        let controller = InferenceController(client: InferenceWorkerClient(), outputBase: mixtureDir, youTubeIngest: mock)
        controller.prepareYouTubeMP3Export(youTubeURL: URL(string: "https://www.youtube.com/watch?v=abc")!)
        let task = try XCTUnwrap(controller.debugCurrentTask())
        await task.value
        XCTAssertEqual(controller.editableArtist, "PrepArtist")
        XCTAssertEqual(controller.editableTitle, "PrepTitle")
        XCTAssertEqual(controller.effectiveArtworkURL, artURL)
        XCTAssertTrue(controller.isEditableMetadataAvailable)
    }
}
