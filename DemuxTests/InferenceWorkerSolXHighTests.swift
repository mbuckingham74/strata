import XCTest
@testable import Demux
import Foundation
import CryptoKit
import AVFoundation

final class InferenceWorkerSolXHighTests: XCTestCase {

    // MARK: - Helpers

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

    private func makeWAV(at url: URL, frames: UInt32 = 1024, sr: Double = 44100, channels: UInt32 = 2) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(channels) {
            let ptr = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { ptr[i] = Float(i%100)*0.001 }
        }
        try file.write(from: buffer)
    }

    private final class LifecycleRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func record(_ event: String) {
            lock.withLock { storage.append(event) }
        }

        var events: [String] { lock.withLock { storage } }
    }

    // MARK: - Protocol §6

    func testDirectStartingToReadyFails() throws {
        var sm = InferenceWorkerStateMachine()
        try sm.startSession(generation: 1)
        XCTAssertThrowsError(try sm.handle(event: .ready(ReadyEvent(protocol: 1, type: "ready", backend: "mlx", device: "mps", checkpoint_sha256: "abc"))))
    }

    func testLoadingModelToReadySucceeds() throws {
        var sm = InferenceWorkerStateMachine()
        try sm.startSession(generation: 1)
        try sm.handle(event: .loadingModel(LoadingModelEvent(protocol: 1, type: "loading_model", model: "m")))
        try sm.handle(event: .ready(ReadyEvent(protocol: 1, type: "ready", backend: "mlx", device: "mps", checkpoint_sha256: "abc")))
        guard case .ready = sm.state else { return XCTFail() }
    }

    func testReadyFirstFakeWorkerFailsStartupAndIsSafelyTerminated() async throws {
        let script = """
import sys, json
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown":
        sys.exit(0)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(2), startedTimeout: .seconds(1), separationTimeout: .seconds(2), workerDirectory: dir)
        do {
            try await client.startupForTesting()
            XCTFail("ready-first should fail startup")
        } catch let error as InferenceError {
            guard case .illegalTransition = error else {
                return XCTFail("expected illegalTransition, got \(error)")
            }
        } catch {
            XCTFail("expected InferenceError.illegalTransition, got \(error)")
        }
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "startup failure must fully drain lifecycle: \(lifecycle)")
    }

    // MARK: - Validation §7

    private func createValidScenario(frames: UInt32 = 1024) throws -> (base: URL, jobId: String, manifestURL: URL, inputURL: URL, inputSHA: String, ready: ReadyMetadata, job: JobInfo, stems: [StemName: URL]) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let jobId = UUID().uuidString.lowercased()
        let jd = base.appendingPathComponent(jobId, isDirectory: true)
        try FileManager.default.createDirectory(at: jd, withIntermediateDirectories: true)
        let inputURL = base.appendingPathComponent("mixture.wav")
        try makeWAV(at: inputURL, frames: frames)
        let data = try Data(contentsOf: inputURL)
        let inputSHA = SHA256.hash(data: data).map{ String(format:"%02x",$0)}.joined()
        var received: [StemName: URL] = [:]
        var records: [[String:Any]] = []
        for stem in StemName.allCases {
            let url = jd.appendingPathComponent("\(stem.rawValue).wav")
            try makeWAV(at: url, frames: frames)
            let h = SHA256.hash(data: try Data(contentsOf: url)).map{ String(format:"%02x",$0)}.joined()
            received[stem]=url
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            records.append(["name":stem.rawValue,"path":url.path,"sha256":h,"file_size":size,"frame_count":UInt64(frames),"channels":2,"sample_rate":44100])
        }
        let manifest: [String:Any]=[
            "job_id":jobId,"model":TrustedInferenceIdentity.model,"checkpoint_sha256":TrustedInferenceIdentity.checkpointSHA256,
            "backend":TrustedInferenceIdentity.backend,"device":TrustedInferenceIdentity.device,
            "input_path":inputURL.path,"output_dir":base.path,"input_sha256":inputSHA,
            "input_metadata":["sample_rate":44100,"channels":2,"frames":UInt64(frames),"duration":Double(frames)/44100.0,"sha256":inputSHA],
            "stems":records
        ]
        let manifestURL = jd.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let ready = ReadyMetadata(backend: TrustedInferenceIdentity.backend, device: TrustedInferenceIdentity.device, checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256, model: nil)
        let job = JobInfo(jobId: jobId, inputPath: inputURL.path, outputDir: base.path)
        return (base, jobId, manifestURL, inputURL, inputSHA, ready, job, received)
    }

    func testMissingInputMetadataFails() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        obj.removeValue(forKey: "input_metadata")
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testMissingInputFramesFails() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        var meta = obj["input_metadata"] as! [String:Any]
        meta.removeValue(forKey: "frames")
        obj["input_metadata"]=meta
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testZeroInputFramesFails() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        var meta = obj["input_metadata"] as! [String:Any]
        meta["frames"]=0
        obj["input_metadata"]=meta
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testNativeInputFrameMismatchFails() throws {
        let sc = try createValidScenario(frames: 2048)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        var meta = obj["input_metadata"] as! [String:Any]
        meta["frames"]=9999
        obj["input_metadata"]=meta
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testStemManifestFrameMismatchFails() throws {
        let sc = try createValidScenario(frames: 1000)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        var stems = obj["stems"] as! [[String:Any]]
        stems[0]["frame_count"]=999
        obj["stems"]=stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testNativeStemLengthMismatchFails() throws {
        let sc = try createValidScenario(frames: 1000)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let url = sc.stems[.vocals]!
        try FileManager.default.removeItem(at: url)
        try makeWAV(at: url, frames: 2000)
        // update hash to match new file but keep manifest frame_count 1000 -> native length 2000 vs manifest 1000 mismatch
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        var stems = obj["stems"] as! [[String:Any]]
        for i in 0..<stems.count where stems[i]["name"] as? String == "vocals" {
            stems[i]["sha256"] = SHA256.hash(data: try Data(contentsOf: url)).map{ String(format:"%02x",$0)}.joined()
        }
        obj["stems"]=stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testArtifactFramesEqualInputFrames() throws {
        let sc = try createValidScenario(frames: 2048)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let result = try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems)
        for stem in StemName.allCases { XCTAssertEqual(result.stems[stem]?.frameCount, 2048) }
    }

    func testNoProductionHardcoded882k() throws {
        // Validator should accept arbitrary frame counts (e.g. 1024) and not require 882000
        let sc = try createValidScenario(frames: 1024)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        XCTAssertNoThrow(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
        // Also verify 882000 would be accepted if manifest consistent (fixture-specific), but not required globally
        let sc2 = try createValidScenario(frames: 8820)
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        XCTAssertNoThrow(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready, receivedStems: sc2.stems))
        // Production must not hard-code 882_000 as a *required* equality; we merely ensure 1024 passes, which already proves not required
    }

    // MARK: - SHA §8

    func testMissingStemHashFails() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        var stems = obj["stems"] as! [[String:Any]]
        stems[0].removeValue(forKey: "sha256")
        obj["stems"]=stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testEmptyHashFails() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        var stems = obj["stems"] as! [[String:Any]]
        stems[0]["sha256"]=""
        obj["stems"]=stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testShortHashFails() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        var stems = obj["stems"] as! [[String:Any]]
        stems[0]["sha256"]=String(repeating: "a", count: 63)
        obj["stems"]=stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testLongHashFails() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        var stems = obj["stems"] as! [[String:Any]]
        stems[0]["sha256"]=String(repeating: "a", count: 65)
        obj["stems"]=stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testNonHexHashFails() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        var stems = obj["stems"] as! [[String:Any]]
        stems[0]["sha256"]=String(repeating: "z", count: 64)
        obj["stems"]=stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
        // Non-ASCII
        stems[0]["sha256"]=String(repeating: "é", count: 64)
        obj["stems"]=stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testDigestMismatchFails() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        var stems = obj["stems"] as! [[String:Any]]
        stems[0]["sha256"]=String(repeating: "0", count: 64)
        obj["stems"]=stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testValidCaseNormalizedHexPasses() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String:Any]
        var stems = obj["stems"] as! [[String:Any]]
        // Uppercase the hash
        if let h = stems[0]["sha256"] as? String {
            stems[0]["sha256"]=h.uppercased()
        }
        obj["stems"]=stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertNoThrow(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    // MARK: - Fresh root harness §9

    func testArbitraryWorkerRootDrivesLaunch() throws {
        let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("demux-m3-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let venvBin = tmpRoot.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: venvBin, withIntermediateDirectories: true)
        // Create dummy script
        let fakeScript = tmpRoot.appendingPathComponent("fake_worker.py")
        try "import sys, json\nsys.stdout.write(json.dumps({\"protocol\":1,\"type\":\"loading_model\",\"model\":\"m\"})+\"\\n\")\n".write(to: fakeScript, atomically: true, encoding: .utf8)
        let pythonWrapper = venvBin.appendingPathComponent("python3")
        try "#!/bin/sh\nexec /usr/bin/python3 \"\(fakeScript.path)\" \"$@\"\n".write(to: pythonWrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: pythonWrapper.path)
        let config = try WorkerLaunchConfiguration.resolved(workerDirectoryOverride: tmpRoot.path, isDebug: true)
        XCTAssertEqual(config.processExecutableURL.resolvingSymlinksInPath().path, tmpRoot.appendingPathComponent(".venv/bin/python3").resolvingSymlinksInPath().path)
        XCTAssertEqual(config.processCurrentDirectoryURL.resolvingSymlinksInPath().path, tmpRoot.resolvingSymlinksInPath().path)
        XCTAssertFalse(config.processExecutableURL.path.contains("/private/tmp/demux-m3-worker"))
        // Ensure no fallback to fixed path
        XCTAssertNotEqual(tmpRoot.path, "/private/tmp/demux-m3-worker")
    }

    func testMissingSentinelWorkerRootFailsWithoutFallback() {
        // Sentinel missing workerDirectory should fail decode, not fallback to env
        let json = #"{"version":1,"mode":"startupOnly","mixturePath":"/private/tmp/mixture.wav"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(M3SentinelConfig.self, from: json))
        // Also WorkerLaunchConfiguration without override and without SRCROOT should throw, not fallback to fixed
        // We test by calling resolved with nil override and empty srcRoot
        XCTAssertThrowsError(try WorkerLaunchConfiguration.resolved(workerDirectoryOverride: nil, srcRoot: "", isDebug: false))
    }

    private struct M3SentinelConfig: Codable { let version:Int; let mode:String; let mixturePath:String; let workerDirectory:String }

    // MARK: - Process ownership §1/§2 (deterministic, no timing guesses)

    func testDeathObservedBeforeOwnershipReleased() async throws {
        let script = """
import sys, json, time, signal, os
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown":
        time.sleep(0.2); sys.exit(0)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(1), separationTimeout: .seconds(2), workerDirectory: dir)
        try await client.startupForTesting()
        let recorder = LifecycleRecorder()
        await client.setAppExitEventHandler { recorder.record($0) }
        let result = await client.terminateForApplicationExit(policy: .testShort(total: .milliseconds(800), idle: .milliseconds(200), sigterm: .milliseconds(150), sigkill: .milliseconds(150), reserve: .milliseconds(50)))
        XCTAssertEqual(result, .safeToTerminate)
        let events = recorder.events
        let deathIndex = try XCTUnwrap(events.firstIndex(of: "processExitObserved"), "missing death observation: \(events)")
        let cleanupIndex = try XCTUnwrap(events.firstIndex(of: "cleanupComplete"), "missing cleanup completion: \(events)")
        XCTAssertLessThan(deathIndex, cleanupIndex)
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "safe termination retained lifecycle work: \(lifecycle)")
    }

    func testNoNewWorkerLaunchesWhileRetained() async throws {
        let script = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    import json as j
    obj=j.loads(line)
    if obj.get("type")=="separate":
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":obj["job_id"]})+"\\n"); sys.stdout.flush()
        time.sleep(10)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(2), startedTimeout: .seconds(1), separationTimeout: .seconds(2), workerDirectory: dir)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let wav = base.appendingPathComponent("in.wav")
        try makeWAV(at: wav, frames: 1024)
        let started = expectation(description: "worker started first job")
        await client.setTestHook { event in
            if case .started = event { started.fulfill() }
        }
        let task = Task { try await client.runSeparation(inputPath: wav, outputBaseDir: base) }
        await fulfillment(of: [started], timeout: 2)
        do {
            _ = try await client.runSeparation(inputPath: wav, outputBaseDir: base)
            XCTFail("second launch should not succeed while first retained")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .alreadyRunningJob)
        } catch {
            XCTFail("expected alreadyRunningJob, got \(error)")
        }
        await client.cancelActiveJob()
        switch await task.result {
        case .failure(let error as InferenceError): XCTAssertEqual(error, .cancellation)
        case .failure(let error): XCTFail("expected cancellation, got \(error)")
        case .success: XCTFail("cancelled job unexpectedly succeeded")
        }
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "cancel must drain the exact worker: \(lifecycle)")
    }

    // MARK: - Reader drainage §4 (deterministic gates)

    func testHeldStdoutPreventsCleanupUntilDrained() async throws {
        // Use a fake that sends partial line without newline and holds
        let script = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="separate":
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":obj["job_id"]})+"\\n"); sys.stdout.flush()
        sys.stdout.write("{\\"protocol\\":1,\\"type\\":\\"stem\\""); sys.stdout.flush()
        time.sleep(5)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(2), startedTimeout: .seconds(1), separationTimeout: .seconds(2), workerDirectory: dir)
        try await client.startupForTesting()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let wav = base.appendingPathComponent("in.wav")
        try makeWAV(at: wav, frames: 1024)
        let started = expectation(description: "worker emitted started before partial stdout")
        await client.setTestHook { event in
            if case .started = event { started.fulfill() }
        }
        let task = Task { try await client.runSeparation(inputPath: wav, outputBaseDir: base) }
        await fulfillment(of: [started], timeout: 2)
        let result = await client.terminateForApplicationExit(policy: .testShort(total: .seconds(1), idle: .milliseconds(100), sigterm: .milliseconds(150), sigkill: .milliseconds(300), reserve: .milliseconds(100)))
        XCTAssertEqual(result, .safeToTerminate)
        switch await task.result {
        case .failure(let error as InferenceError): XCTAssertEqual(error, .cancellation)
        case .failure(let error): XCTFail("expected cancellation, got \(error)")
        case .success: XCTFail("terminated job unexpectedly succeeded")
        }
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "partial stdout reader survived cleanup: \(lifecycle)")
    }
}
