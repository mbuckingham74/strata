import XCTest
@testable import Strata
import Foundation
import AVFoundation

// MARK: - Mocks

private actor MockLocalSuccess: LocalAudioIngesting {
    let mixtureURL: URL
    private(set) var ingestCallCount = 0
    private(set) var ingestedURLs: [URL] = []
    private(set) var cancelCallCount = 0
    init(mixtureURL: URL) { self.mixtureURL = mixtureURL }
    func ingest(localFileURL: URL) async throws -> URL {
        ingestCallCount += 1
        ingestedURLs.append(localFileURL)
        try Task.checkCancellation()
        return mixtureURL
    }
    func cancel() async throws { cancelCallCount += 1 }
}

private actor MockLocalFailure: LocalAudioIngesting {
    let error: LocalAudioIngestError
    private(set) var ingestCallCount = 0
    private(set) var cancelCallCount = 0
    init(error: LocalAudioIngestError) { self.error = error }
    func ingest(localFileURL: URL) async throws -> URL {
        ingestCallCount += 1
        throw error
    }
    func cancel() async throws { cancelCallCount += 1 }
}

private actor MockLocalHanging: LocalAudioIngesting {
    var shouldThrowCleanupFailedOnCancel = false
    private var continuation: CheckedContinuation<URL, Error>?
    private(set) var ingestStarted = false
    private(set) var cancelCallCount = 0
    let mixtureURL: URL
    init(mixtureURL: URL, shouldThrowCleanupFailedOnCancel: Bool = false) {
        self.mixtureURL = mixtureURL
        self.shouldThrowCleanupFailedOnCancel = shouldThrowCleanupFailedOnCancel
    }
    func ingest(localFileURL: URL) async throws -> URL {
        ingestStarted = true
        return try await withCheckedThrowingContinuation { c in self.continuation = c }
    }
    func cancel() async throws {
        cancelCallCount += 1
        if shouldThrowCleanupFailedOnCancel {
            if let c = continuation { c.resume(throwing: LocalAudioIngestError.cleanupFailed("mock")) ; continuation = nil }
            throw LocalAudioIngestError.cleanupFailed("mock still running")
        }
        if let c = continuation { c.resume(throwing: LocalAudioIngestError.cancelled); continuation = nil }
    }
    func setShouldThrow(_ v: Bool) { shouldThrowCleanupFailedOnCancel = v }
}

private actor MockLocalDelayed: LocalAudioIngesting {
    let mixtureURL: URL
    let delay: Duration
    private(set) var ingestCallCount = 0
    init(mixtureURL: URL, delay: Duration = .milliseconds(400)) { self.mixtureURL = mixtureURL; self.delay = delay }
    func ingest(localFileURL: URL) async throws -> URL {
        ingestCallCount += 1
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        return mixtureURL
    }
    func cancel() async throws {}
}

private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func setTrue() { lock.lock(); _value = true; lock.unlock() }
}

// MARK: - Tests

@MainActor
final class InferenceControllerLocalTests: XCTestCase {

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
        for ch in 0..<2 {
            let ptr = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { ptr[i] = Float(i % 100) * 0.001 }
        }
        try file.write(from: buffer)
    }

    private func floatSuccessScript(capturedInputPathFile: URL? = nil) -> String {
        var captureLine = ""
        if let cap = capturedInputPathFile {
            captureLine = "open(\"\(cap.path)\", \"w\").write(obj.get(\"input_path\",\"\"))\n        "
        }
        return """
        import sys, json, os, struct, hashlib
        sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
        def make_wav(path, frames=1024, sr=44100, ch=2):
            data = b''.join(struct.pack('<f', 0.0) for _ in range(frames*ch))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as f:
                f.write(b'RIFF')
                f.write(struct.pack('<I', 36 + len(data)))
                f.write(b"WAVE")
                f.write(b"fmt ")
                f.write(struct.pack('<I', 16))
                f.write(struct.pack('<H', 3))
                f.write(struct.pack('<H', ch))
                f.write(struct.pack('<I', sr))
                f.write(struct.pack('<I', sr * ch * 4))
                f.write(struct.pack('<H', ch * 4))
                f.write(struct.pack('<H', 32))
                f.write(b'data')
                f.write(struct.pack('<I', len(data)))
                f.write(data)
        for line in sys.stdin:
            try:
                obj=json.loads(line)
            except:
                continue
            if obj.get("type")=="shutdown":
                sys.exit(0)
            if obj.get("type")=="separate":
                jid=obj["job_id"]
                outdir=obj["output_dir"]
                inp=obj["input_path"]
                \(captureLine)sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
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

    private func hangingWorkerScript() -> String {
        """
        import sys, json, time
        sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
        for line in sys.stdin:
            obj=json.loads(line)
            if obj.get("type")=="separate":
                jid=obj["job_id"]
                sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
                time.sleep(10)
            elif obj.get("type")=="shutdown":
                sys.exit(0)
        """
    }

    func testLocalSuccessPassesMixtureToInference() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL, frames: 1024)

        let captured = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: captured) }

        let dir = try makeFakeWorker(script: floatSuccessScript(capturedInputPathFile: captured))
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockIngest = MockLocalSuccess(mixtureURL: mixtureURL)
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: nil, localIngest: mockIngest)

        let inputURL = URL(fileURLWithPath: "/tmp/My Cool Song - Demo.m4a")
        controller.startSeparation(localFileURL: inputURL)

        let task = try XCTUnwrap(controller.debugCurrentTask())
        await task.value

        XCTAssertEqual(controller.state, .completed)
        XCTAssertNotNil(controller.result)
        XCTAssertEqual(controller.exportBaseName, "My Cool Song - Demo")
        let count = await mockIngest.ingestCallCount
        XCTAssertEqual(count, 1)
        let ingested = await mockIngest.ingestedURLs
        XCTAssertEqual(ingested.first, inputURL)
        let capturedPath = try? String(contentsOf: captured, encoding: .utf8)
        XCTAssertEqual(capturedPath, mixtureURL.path)

        await controller.shutdownWorker()
    }

    func testLocalIngestFailureDoesNotStartInference() async throws {
        let dir = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: dir) }
        let mockFailure = MockLocalFailure(error: .invalidInput("missing"))
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(3), workerDirectory: dir)
        let didStart = AtomicBool()
        await client.setTestHook { event in if case .started = event { didStart.setTrue() } }
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }
        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: nil, localIngest: mockFailure)
        controller.startSeparation(localFileURL: URL(fileURLWithPath: "/tmp/missing.m4a"))
        let task = try XCTUnwrap(controller.debugCurrentTask())
        await task.value
        if case .failed(let msg) = controller.state {
            XCTAssertTrue(msg.lowercased().contains("invalid") || msg.contains("Invalid"))
        } else { XCTFail("Expected failed") }
        XCTAssertFalse(didStart.value)
        XCTAssertNil(controller.result)
    }

    func testCancellationDuringLocalIngest() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL)

        let dir = try makeFakeWorker(script: hangingWorkerScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let hanging = MockLocalHanging(mixtureURL: mixtureURL)
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let didStart = AtomicBool()
        await client.setTestHook { event in if case .started = event { didStart.setTrue() } }
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: nil, localIngest: hanging)
        controller.startSeparation(localFileURL: URL(fileURLWithPath: "/tmp/song.mp3"))
        var started = false
        for _ in 0..<50 {
            let s = await hanging.ingestStarted
            if s { started = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(started)
        XCTAssertTrue(controller.isSeparating)
        controller.cancel()
        if let tail = controller.debugCleanupChainTail() { await tail.value }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(didStart.value)
        if case .failed(let msg) = controller.state { XCTAssertEqual(msg, "Cancelled") } else { XCTFail("Expected cancelled") }
        XCTAssertNil(controller.result)
        let cancelCount = await hanging.cancelCallCount
        XCTAssertEqual(cancelCount, 1)
        await controller.shutdownWorker(policy: .testShort())
    }

    func testCancellationDuringLocalIngestWithCleanupFailedRetainsUnsafe() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL)

        let dir = try makeFakeWorker(script: hangingWorkerScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let hanging = MockLocalHanging(mixtureURL: mixtureURL, shouldThrowCleanupFailedOnCancel: true)
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: nil, localIngest: hanging)
        controller.startSeparation(localFileURL: URL(fileURLWithPath: "/tmp/song.mp3"))
        for _ in 0..<50 {
            if await hanging.ingestStarted { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        controller.cancel()
        if let tail = controller.debugCleanupChainTail() { await tail.value }
        try await Task.sleep(nanoseconds: 100_000_000)
        if case .failed(let msg) = controller.state {
            XCTAssertTrue(msg.contains("Cleanup failed"))
        } else { XCTFail("Expected cleanupFailed") }
        XCTAssertTrue(controller.debugLocalCleanupFailed())
        let result = await controller.terminateForApplicationExit(policy: .testShort())
        XCTAssertEqual(result, .unsafeToTerminate(reason: .cleanupIncomplete))
    }

    func testGenerationStaleProtectionLocalThenDirect() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL)

        let dir = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let delayed = MockLocalDelayed(mixtureURL: mixtureURL, delay: .milliseconds(500))
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: nil, localIngest: delayed)

        let directWavDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directWavDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directWavDir) }
        let directWAV = directWavDir.appendingPathComponent("direct.wav")
        try makeWAV(at: directWAV, frames: 1024)

        controller.startSeparation(localFileURL: URL(fileURLWithPath: "/tmp/first.mp3"))
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.startSeparation(inputURL: directWAV)

        let secondTask = try XCTUnwrap(controller.debugCurrentTask())
        await secondTask.value

        XCTAssertEqual(controller.state, .completed)
        XCTAssertNotNil(controller.result)
        // second operation was canonical inputURL, so exportBaseName should be nil (no local base)
        // but first stale local should not overwrite
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(controller.state, .completed)
        let count = await delayed.ingestCallCount
        XCTAssertEqual(count, 1)
        await controller.shutdownWorker()
    }

    func testDefaultLocalIngestUsesHomebrewPath() async throws {
        let ingest = InferenceController.makeDefaultLocalIngest()
        guard let client = ingest as? LocalAudioIngestClient else {
            XCTFail("Default should be LocalAudioIngestClient")
            return
        }
        let ffmpegURL = await client.ffmpegURL
        XCTAssertEqual(ffmpegURL.path, "/opt/homebrew/bin/ffmpeg")
        XCTAssertTrue(ffmpegURL.isFileURL)
    }

    func testLocalSeparationTransitionsToSeparatingDuringInference() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL)

        let dir = try makeFakeWorker(script: hangingWorkerScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockIngest = MockLocalSuccess(mixtureURL: mixtureURL)
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(10), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: nil, localIngest: mockIngest)
        controller.startSeparation(localFileURL: URL(fileURLWithPath: "/tmp/song.mp3"))

        // Before .started, state must be .loadingModel with "Loading separation model" and creationPhase .loadingModel (truthful: Preparing → Loading)
        var observedLoading = false
        for _ in 0..<50 {
            if case .loadingModel = controller.state, controller.statusMessage == "Loading separation model", controller.creationPhase == .loadingModel {
                observedLoading = true
                break
            }
            // Also accept preparing phase briefly before loading
            if controller.statusMessage == "Preparing audio", controller.creationPhase == .preparingAudio {
                observedLoading = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(observedLoading, "Expected .loadingModel with 'Loading separation model' before worker emits started")
        // After ingest finishes, should be loadingModel; Preparing is transient
        if controller.creationPhase == .preparingAudio {
            // Wait a bit more for transition to loading
            for _ in 0..<20 {
                if controller.creationPhase == .loadingModel { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        XCTAssertEqual(controller.creationPhase, .loadingModel)
        XCTAssertEqual(controller.statusMessage, "Loading separation model")
        XCTAssertFalse(controller.showDownloadingPhase, "Local flow must hide downloading phase")
        if case .loadingModel = controller.state {} else { XCTFail("Expected loadingModel before started") }

        // After worker emits .started (hanging worker sleeps 10s after started), state becomes .separating with "Creating strata"
        var observedSeparating = false
        for _ in 0..<100 {
            if case .separating = controller.state, controller.statusMessage == "Creating strata", controller.creationPhase == .creatingStrata {
                observedSeparating = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(observedSeparating, "Expected transition to .separating with 'Creating strata' after started")
        XCTAssertEqual(controller.statusMessage, "Creating strata")
        XCTAssertEqual(controller.creationPhase, .creatingStrata)

        controller.cancel()
        if let tail = controller.debugCleanupChainTail() { await tail.value }
        await controller.shutdownWorker(policy: .testShort())
    }

    func testFastStartedCompletionEndsInCompletedNotSeparating() async throws {
        let mixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mixtureDir) }
        let mixtureURL = mixtureDir.appendingPathComponent("mixture.wav")
        try makeWAV(at: mixtureURL)

        let dir = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockIngest = MockLocalSuccess(mixtureURL: mixtureURL)
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }

        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: nil, localIngest: mockIngest)
        controller.startSeparation(localFileURL: URL(fileURLWithPath: "/tmp/song.mp3"))

        let task = try XCTUnwrap(controller.debugCurrentTask())
        await task.value

        // Fast worker emits started then immediately done; awaiting onStarted before result ensures
        // the awaited MainActor transition cannot overwrite .completed with a delayed .separating.
        XCTAssertEqual(controller.state, .completed)
        XCTAssertEqual(controller.statusMessage, "Complete — 6 strata")
        XCTAssertEqual(controller.creationPhase, .complete)
        XCTAssertFalse(controller.isSeparating)
        XCTAssertNotEqual(controller.state, .separating)
        XCTAssertFalse(controller.statusMessage == "Creating strata")
        await controller.shutdownWorker()
    }

    // MARK: - Inference Error alert dismiss (bug fix)

    func testDismissErrorAlertClearsPresentationButPreservesFailedState() async throws {
        let dir = try makeFakeWorker(script: floatSuccessScript())
        defer { try? FileManager.default.removeItem(at: dir) }
        let mockFailure = MockLocalFailure(error: .invalidInput("missing file"))
        let client = InferenceWorkerClient(readinessTimeout: .seconds(2), startedTimeout: .seconds(1), separationTimeout: .seconds(1), workerDirectory: dir)
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputBase) }
        let controller = InferenceController(client: client, outputBase: outputBase, youTubeIngest: nil, localIngest: mockFailure)

        controller.startSeparation(localFileURL: URL(fileURLWithPath: "/tmp/missing.m4a"))
        let task = try XCTUnwrap(controller.debugCurrentTask())
        await task.value

        guard case .failed(let msg) = controller.state else { return XCTFail("Expected failed, got \(controller.state)") }
        XCTAssertFalse(msg.isEmpty)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.statusMessage, "Failed")

        controller.dismissErrorAlert()

        XCTAssertNil(controller.errorMessage, "dismiss must clear errorMessage so alert does not re-present")
        guard case .failed(let preservedMsg) = controller.state else { return XCTFail("state must remain failed after dismiss") }
        XCTAssertEqual(preservedMsg, msg)
        XCTAssertEqual(controller.statusMessage, "Failed")
        XCTAssertNil(controller.result)
        // Alert predicate must be false after dismiss
        let shouldPresent = controller.errorMessage != nil && controller.state != .failed("Cancelled")
        XCTAssertFalse(shouldPresent)
    }

    func testDismissErrorAlertDoesNotAffectCancelledState() async throws {
        let controller = InferenceController(client: InferenceWorkerClient(), outputBase: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        controller.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.state, .failed("Cancelled"))
        XCTAssertEqual(controller.errorMessage, "Cancelled")
        XCTAssertEqual(controller.statusMessage, "Cancelled")

        controller.dismissErrorAlert()

        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.state, .failed("Cancelled"))
        XCTAssertEqual(controller.statusMessage, "Cancelled")
    }

    func testDismissErrorAlertIsNoOpWhenIdle() async throws {
        let controller = InferenceController(client: InferenceWorkerClient(), outputBase: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.errorMessage)
        controller.dismissErrorAlert()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.statusMessage, "Ready to create strata")
    }
}
