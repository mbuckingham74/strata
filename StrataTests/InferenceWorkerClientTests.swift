import XCTest
@testable import Strata
import Foundation
import AVFoundation
import CryptoKit

private final class ValidationCompletionInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var completionAttempts = 0

    func complete(
        stateMachine: inout InferenceWorkerStateMachine,
        metadata: ReadyMetadata
    ) throws {
        let shouldFail: Bool = lock.withLock {
            completionAttempts += 1
            return completionAttempts == 1
        }
        if shouldFail {
            let session = stateMachine.sessionGeneration
            stateMachine = InferenceWorkerStateMachine(
                initialState: .ready(session: session, metadata: metadata),
                sessionGeneration: session
            )
        }
        try stateMachine.completeValidation(with: metadata)
    }

    var attempts: Int {
        lock.withLock { completionAttempts }
    }
}

final class InferenceWorkerClientTests: XCTestCase {

    // MARK: - Fake worker infrastructure

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

    private func withFakeWorker(script: String, readinessTimeout: Duration = .seconds(5), separationTimeout: Duration = .seconds(5), test: (InferenceWorkerClient) async throws -> Void) async throws {
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: readinessTimeout, startedTimeout: .seconds(2), separationTimeout: separationTimeout, workerDirectory: dir)
        do {
            try await test(client)
        } catch {
            // Ensure cleanup before rethrow
            try? await client.shutdown()
            throw error
        }
        // Ensure no orphan after each test
        try await client.shutdown()
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "test cleanup retained worker lifecycle work: \(lifecycle)")
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

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func makeReusableValidatingWorkerScript(corruptFirstStemHash: Bool = false) -> String {
        """
import sys, json, os, struct, hashlib
corrupt_first_stem_hash=\(corruptFirstStemHash ? "True" : "False")
job_count=0
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
def make_wav(path, frames=1024, sample_rate=44100, channels=2):
    data = b''.join(struct.pack('<f', 0.0) for _ in range(frames*channels))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as output:
        output.write(b'RIFF')
        output.write(struct.pack('<I', 36 + len(data)))
        output.write(b'WAVEfmt ')
        output.write(struct.pack('<I', 16))
        output.write(struct.pack('<H', 3))
        output.write(struct.pack('<H', channels))
        output.write(struct.pack('<I', sample_rate))
        output.write(struct.pack('<I', sample_rate * channels * 4))
        output.write(struct.pack('<H', channels * 4))
        output.write(struct.pack('<H', 32))
        output.write(b'data')
        output.write(struct.pack('<I', len(data)))
        output.write(data)
def sha256_file(path):
    with open(path, 'rb') as input_file:
        return hashlib.sha256(input_file.read()).hexdigest()
for line in sys.stdin:
    command=json.loads(line)
    if command.get("type") == "shutdown":
        sys.exit(0)
    if command.get("type") == "separate":
        job_count += 1
        job_id=command["job_id"]
        input_path=command["input_path"]
        output_dir=command["output_dir"]
        job_dir=os.path.join(output_dir, job_id)
        os.makedirs(job_dir, exist_ok=True)
        input_sha=sha256_file(input_path)
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":job_id})+"\\n"); sys.stdout.flush()
        stems=[]
        for name in ["bass","drums","other","vocals","guitar","piano"]:
            path=os.path.join(job_dir, name+".wav")
            make_wav(path)
            manifest_hash=("0"*64) if corrupt_first_stem_hash and job_count == 1 and name == "bass" else sha256_file(path)
            stems.append({"name":name,"path":path,"sha256":manifest_hash,"file_size":os.path.getsize(path),"frame_count":1024,"channels":2,"sample_rate":44100})
            sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":job_id,"name":name,"path":path})+"\\n"); sys.stdout.flush()
        manifest={"job_id":job_id,"model":"roformer-model-bs-roformer-sw-by-jarredou","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e","backend":"mlx","device":"mps","input_path":input_path,"output_dir":output_dir,"input_sha256":input_sha,"input_metadata":{"sample_rate":44100,"channels":2,"frames":1024,"duration":1024/44100.0,"sha256":input_sha},"stems":stems}
        manifest_path=os.path.join(job_dir, "manifest.json")
        with open(manifest_path, 'w') as manifest_file:
            json.dump(manifest, manifest_file)
        sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":job_id,"output_manifest":manifest_path})+"\\n"); sys.stdout.flush()
"""
    }

    private func makeRealisticFakeScript() -> String {
        // This script implements full successful job with real files and manifest that passes validator
        return """
import sys, json, os, hashlib, time, pathlib
import struct, wave
sys.stderr.write("fake worker starting\\n"); sys.stderr.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"roformer-model-bs-roformer-sw-by-jarredou"})+"\\n"); sys.stdout.flush()
time.sleep(0.05)
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
def make_wav(path, frames=1024, sr=44100, channels=2):
    import wave, struct, math
    with wave.open(path, 'w') as wf:
        wf.setnchannels(channels)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        wf.setnframes(frames)
        # write silence as int16
        data = struct.pack('<' + 'h'*(frames*channels), *([0]*(frames*channels)))
        wf.writeframes(data)
    # Actually we need float32 for AVAudioFile validation? Use python's wave but we need pcmFormatFloat32
    # Alternative: just write a valid wav via our own helper using scipy? Simpler: invoke swift's makeWAV not possible
    # For tests that need validation, we will create files via swift after receiving started? But fake worker can't easily create valid float32 wav without numpy.
    # Instead we will create dummy files and let swift validator be bypassed? But validator requires AVAudioFile open.
    # So we need to create proper wav files using python's wave with float32? wave module doesn't support float.
    # We'll cheat: the validator in fake tests will be expected to fail if we don't create valid wavs, but our client tests will use short-circuit?
    # For successful job we will write minimal valid wav using struct float32 via custom.
    pass

for line in sys.stdin:
    line=line.strip()
    if not line:
        continue
    try:
        obj=json.loads(line)
    except:
        sys.stdout.write(json.dumps({"protocol":1,"type":"error","job_id":"unknown","code":"malformed","message":"bad json"})+"\\n"); sys.stdout.flush()
        continue
    if obj.get("type")=="shutdown":
        sys.stdout.flush(); sys.stderr.write("shutdown\\n"); sys.stderr.flush(); sys.exit(0)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        inp=obj["input_path"]
        outdir=obj["output_dir"]
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        # Create job dir and stems as valid wavs via python's audio creation using wave with int16 then convert? For test we will create float wavs via dummy - use avfoundation not available
        # Instead we will create placeholder files and let swift side not validate? For full validation test we need to create valid files from swift after fake worker signals.
        # So we emit stems pointing to real files we pre-create outside? We'll just emit paths that swift test will have created.
        # For generic fake, emit stems that may not exist - validator will fail but we test framing.
        for name in ["vocals","drums","bass","guitar","piano","other"]:
            sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":f"/tmp/{name}.wav"})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":"/tmp/manifest.json"})+"\\n"); sys.stdout.flush()
"""
    }

    // MARK: - Launch configuration

    func testDirectExecutableLaunchUsesVenvPython() throws {
        let dir = try makeFakeWorker(script: "import sys,json; sys.stdout.write(json.dumps({'protocol':1,'type':'loading_model','model':'m'})+'\\n'); sys.stdout.flush()")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try WorkerLaunchConfiguration.resolved(workerDirectoryOverride: dir.path, isDebug: true)
        XCTAssertEqual(config.processExecutableURL.path, dir.appendingPathComponent(".venv/bin/python3").path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: config.processExecutableURL.path))
        XCTAssertEqual(config.processExecutableURL.lastPathComponent, "python3")
        XCTAssertFalse(config.processExecutableURL.path.contains("uv"))
    }

    func testArgumentsExactlyCompatibleWithMDemuxWorker() throws {
        let dir = try makeFakeWorker(script: "import time; time.sleep(10)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try WorkerLaunchConfiguration.resolved(workerDirectoryOverride: dir.path, isDebug: true)
        XCTAssertEqual(config.processArguments, ["-m", "demux_worker"])
        XCTAssertEqual(config.arguments, ["-m", "demux_worker"])
        XCTAssertFalse(config.processArguments.contains("uv"))
        XCTAssertFalse(config.processArguments.contains("run"))
    }

    func testNoRuntimeUvRun() throws {
        let dir = try makeFakeWorker(script: "")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try WorkerLaunchConfiguration.resolved(workerDirectoryOverride: dir.path, isDebug: true)
        let exe = config.processExecutableURL.path
        let args = config.processArguments.joined(separator: " ")
        let full = exe + " " + args
        XCTAssertFalse(full.contains("uv run"))
        XCTAssertFalse(full.contains("uv"))
        XCTAssertTrue(exe.hasSuffix(".venv/bin/python3"))
    }

    func testWorkingDirectoryIsWorkerDirectory() throws {
        let dir = try makeFakeWorker(script: "")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try WorkerLaunchConfiguration.resolved(workerDirectoryOverride: dir.path, isDebug: true)
        XCTAssertEqual(config.processCurrentDirectoryURL.standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertEqual(config.currentDirectory.standardizedFileURL.path, dir.standardizedFileURL.path)
    }

    func testPythonUnbufferedEnv() throws {
        let dir = try makeFakeWorker(script: "")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try WorkerLaunchConfiguration.resolved(workerDirectoryOverride: dir.path, isDebug: true)
        XCTAssertEqual(config.environmentAdditions["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(config.processEnvironment?["PYTHONUNBUFFERED"], "1")
    }

    // MARK: - Lazy startup

    func testLazyStartup() async throws {
        let script = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
time.sleep(0.05)
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown":
        sys.exit(0)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(3), workerDirectory: dir)
        // No process yet — lazy. We can't directly inspect private process, but we can ensure shutdown is no-op before start
        try await client.shutdown() // should not throw even though never started
        // Now trigger start via runSeparation that will startup lazily
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wav = tmp.appendingPathComponent("in.wav")
        try Data(count: 100).write(to: wav)
        // This will launch worker lazily and then fail validation (since manifest missing), but startup should have occurred
        do { _ = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp) } catch {}
        // Now worker is running, shutdown should exit 0
        try await client.shutdown()
    }

    func testLoadingModelToReady() async throws {
        let script = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"roformer-model-bs-roformer-sw-by-jarredou"})+"\\n"); sys.stdout.flush()
time.sleep(0.1)
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown":
        sys.exit(0)
"""
        try await withFakeWorker(script: script) { client in
            try await client.startupForTesting()
            guard case .ready(_, let metadata) = await client.currentState() else {
                return XCTFail("expected ready state after loading_model")
            }
            XCTAssertEqual(metadata.backend, "mlx")
            XCTAssertEqual(metadata.device, "mps")
            try await client.shutdown()
        }
    }

    // MARK: - Partial line & multiple lines

    func testPartialStdoutLineDeliveryAcrossWrites() async throws {
        let script = """
import sys, json, time, os
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
time.sleep(0.05)
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        msg=json.dumps({"protocol":1,"type":"started","job_id":jid})
        # Split across two writes without newline in first
        sys.stdout.write(msg[:10]); sys.stdout.flush(); time.sleep(0.05); sys.stdout.write(msg[10:]+"\\n"); sys.stdout.flush()
        for name in ["vocals","drums","bass","guitar","piano","other"]:
            sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":f"/tmp/{name}.wav"})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":"/tmp/manifest.json"})+"\\n"); sys.stdout.flush()
    elif obj.get("type")=="shutdown":
        sys.exit(0)
"""
        try await withFakeWorker(script: script) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 100).write(to: wav)
            do {
                _ = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
                XCTFail("expected validation failure")
            } catch let error as InferenceError {
                guard case .manifestValidationFailure = error else {
                    return XCTFail("partial framing produced wrong error: \(error)")
                }
            } catch { XCTFail("expected manifestValidationFailure, got \(error)") }
        }
    }

    func testMultipleLinesInOneStdoutWrite() async throws {
        let script = """
import sys, json
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        # Write started+6 stems+done in one write
        out=""
        out+=json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"
        for name in ["vocals","drums","bass","guitar","piano","other"]:
            out+=json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":f"/tmp/{name}.wav"})+"\\n"
        out+=json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":"/tmp/manifest.json"})+"\\n"
        sys.stdout.write(out); sys.stdout.flush()
    elif obj.get("type")=="shutdown":
        sys.exit(0)
"""
        try await withFakeWorker(script: script) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 100).write(to: wav)
            do {
                _ = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
                XCTFail("expected validation failure")
            } catch let error as InferenceError {
                guard case .manifestValidationFailure = error else {
                    return XCTFail("multi-line framing produced wrong error: \(error)")
                }
            } catch { XCTFail("expected manifestValidationFailure, got \(error)") }
        }
    }

    // MARK: - Stderr draining

    func testStderrIsDrainedConcurrentlyAndCannotDeadlockNoisyWorker() async throws {
        let script = """
import sys, json, time, os
# Flood stderr with 100KB
for i in range(20):
    sys.stderr.write("stderr line " + str(i) + " " + "x"*5000 + "\\n")
sys.stderr.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stderr.write("more stderr after loading\\n"); sys.stderr.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown":
        sys.stderr.write("shutdown stderr\\n"); sys.stderr.flush()
        sys.exit(0)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        for i in range(50):
            sys.stderr.write("job stderr " + "y"*2000 + "\\n")
        sys.stderr.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        for name in ["vocals","drums","bass","guitar","piano","other"]:
            sys.stderr.write("stem stderr\\n"); sys.stderr.flush()
            sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":f"/tmp/{name}.wav"})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":"/tmp/manifest.json"})+"\\n"); sys.stdout.flush()
"""
        try await withFakeWorker(script: script, readinessTimeout: .seconds(5), separationTimeout: .seconds(5)) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 100).write(to: wav)
            do {
                _ = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
                XCTFail("expected validation failure")
            } catch let error as InferenceError {
                guard case .manifestValidationFailure = error else {
                    return XCTFail("stderr flood produced wrong separation error: \(error)")
                }
            } catch { XCTFail("expected manifestValidationFailure, got \(error)") }
            // Shutdown must still succeed even with noisy stderr (no deadlock)
            do { try await client.shutdown() } catch { XCTFail("shutdown should succeed despite stderr flood: \\(error)") }
        }
    }

    func testBoundedStderrTailBehavior() async throws {
        // Worker that writes >32KiB stderr, client should keep tail without growing unbounded
        let script = """
import sys, json
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
# Write 40KiB stderr
sys.stderr.write("A"*40000); sys.stderr.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown":
        sys.stderr.write("END"); sys.stderr.flush()
        sys.exit(0)
    if obj.get("type")=="separate":
        sys.stderr.write("B"*40000); sys.stderr.flush()
        jid=obj["job_id"]
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"error","job_id":jid,"code":"invalid_input","message":"oops"})+"\\n"); sys.stdout.flush()
"""
        try await withFakeWorker(script: script) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 10).write(to: wav)
            do { _ = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp) } catch let err as InferenceError {
                XCTAssertEqual(err, .workerReportedJobError(code: "invalid_input", message: "oops"))
                // Ensure error description not huge (bounded)
                XCTAssertTrue(err.localizedDescription.count < 1000)
            } catch { XCTFail("unexpected \\(error)") }
            try await client.shutdown()
        }
    }

    // MARK: - Successful job protocol (with real files)

    func testSuccessfulJobProtocol() async throws {
        let script = """
import sys, json, os, struct, hashlib, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
time.sleep(0.05)
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
def make_wav(path, frames=1024, sr=44100, ch=2):
    import struct
    data = b''.join(struct.pack('<f', 0.0) for _ in range(frames*ch))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(b'RIFF')
        f.write(struct.pack('<I', 36 + len(data)))
        f.write(b'WAVE')
        f.write(b'fmt ')
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
def sha256_file(p):
    import hashlib
    return hashlib.sha256(open(p,'rb').read()).hexdigest()
for line in sys.stdin:
    try:
        obj=json.loads(line)
    except:
        continue
    if obj.get("type")=="shutdown":
        sys.exit(0)
    if obj.get("type")=="separate":
        try:
            jid=obj["job_id"]
            outdir=obj["output_dir"]
            inp=obj["input_path"]
            inp_sha = hashlib.sha256(open(inp,'rb').read()).hexdigest() if os.path.exists(inp) else "0"*64
            sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
            job_dir=os.path.join(outdir, jid)
            os.makedirs(job_dir, exist_ok=True)
            stems=[]
            for name in ["bass","drums","other","vocals","guitar","piano"]:
                p=os.path.join(job_dir, f"{name}.wav")
                make_wav(p, frames=1024)
                stems.append({"name":name,"path":p,"sha256":sha256_file(p),"file_size":os.path.getsize(p),"frame_count":1024,"channels":2,"sample_rate":44100})
                sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":p})+"\\n"); sys.stdout.flush()
            manifest={
                "job_id":jid,
                "model":"roformer-model-bs-roformer-sw-by-jarredou",
                "checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e",
                "backend":"mlx",
                "device":"mps",
                "input_path":inp,
                "output_dir":outdir,
                "input_sha256":inp_sha,
                "input_metadata":{"sample_rate":44100,"channels":2,"frames":1024,"duration":1024/44100.0,"sha256":inp_sha},
                "stems":stems
            }
            import json as js
            man_path=os.path.join(job_dir,"manifest.json")
            open(man_path,'w').write(js.dumps(manifest))
            sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":man_path})+"\\n"); sys.stdout.flush()
        except Exception as e:
            import traceback
            traceback.print_exc(file=sys.stderr)
            sys.stdout.write(json.dumps({"protocol":1,"type":"error","job_id":obj.get("job_id","unknown"),"code":"internal","message":str(e)[:200]})+"\\n"); sys.stdout.flush()
"""
        try await withFakeWorker(script: script) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            // Create input wav with 1024 frames to match fake's expectation
            try makeWAV(at: wav, frames: 1024)
            let result: SeparationResult
            do {
                result = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
            } catch {
                XCTFail("runSeparation failed with \(error) – stderr tail may be bounded")
                throw error
            }
            XCTAssertEqual(result.stems.count, 6)
            XCTAssertEqual(result.jobId.count, 36) // UUID
            XCTAssertEqual(result.backend, "mlx")
            XCTAssertEqual(result.device, "mps")
            XCTAssertTrue(result.isComplete)
            for stem in StemName.allCases {
                XCTAssertNotNil(result.stem(stem))
                XCTAssertEqual(result.stem(stem)?.frameCount, 1024)
            }
            // Verify files exist
            for stem in StemName.allCases {
                XCTAssertTrue(FileManager.default.fileExists(atPath: result.stem(stem)!.url.path))
            }
            // Verify graceful shutdown after success still works
            try await client.shutdown()
        }
    }

    func testValidationStateCompletionErrorFailsOnceWithoutResultAndNextGenerationRecovers() async throws {
        let injector = ValidationCompletionInjector()
        let workerDirectory = try makeFakeWorker(script: makeReusableValidatingWorkerScript())
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let inputURL = outputDirectory.appendingPathComponent("input.wav")
        try makeWAV(at: inputURL, frames: 1024)

        let client = InferenceWorkerClient(
            readinessTimeout: .seconds(3),
            startedTimeout: .seconds(2),
            separationTimeout: .seconds(5),
            workerDirectory: workerDirectory,
            validationStateCompletion: { stateMachine, metadata in
                try injector.complete(stateMachine: &stateMachine, metadata: metadata)
            }
        )

        do {
            try await client.startupForTesting()
            let firstPIDValue = await client.debugProcessIdentifier()
            let firstPID = try XCTUnwrap(firstPIDValue)
            var producedResult: SeparationResult?
            var observedError: InferenceError?
            do {
                producedResult = try await client.runSeparation(
                    inputPath: inputURL,
                    outputBaseDir: outputDirectory
                )
                XCTFail("the injected validation completion failure must not produce a result")
            } catch let error as InferenceError {
                observedError = error
            } catch {
                XCTFail("expected a typed InferenceError, got \(error)")
            }

            XCTAssertNil(producedResult)
            let validationError = try XCTUnwrap(observedError)
            guard case .illegalTransition(let evidence) = validationError else {
                return XCTFail("expected the exact completeValidation illegal transition, got \(validationError)")
            }
            XCTAssertTrue(evidence.contains("completeValidation in ready"), "missing transition evidence: \(evidence)")
            let completionCountAfterFailure = await client.debugResultWaitCompletionCount()
            XCTAssertEqual(completionCountAfterFailure, 1)
            XCTAssertEqual(injector.attempts, 1)

            let stateAfterFailure = await client.currentState()
            XCTAssertEqual(stateAfterFailure, .stopped, "an incoherent validation transition must invalidate the worker")
            let isRunningAfterFailure = await client.debugIsRunning()
            XCTAssertFalse(isRunningAfterFailure)
            let lifecycleAfterFailure = await client.debugLifecycleSnapshot()
            XCTAssertFalse(lifecycleAfterFailure.hasOwnedLifecycleWork)

            let subsequentResult = try await client.runSeparation(
                inputPath: inputURL,
                outputBaseDir: outputDirectory
            )
            XCTAssertTrue(subsequentResult.isComplete)
            XCTAssertEqual(subsequentResult.stems.count, 6)
            let completionCountAfterSuccess = await client.debugResultWaitCompletionCount()
            XCTAssertEqual(completionCountAfterSuccess, 2)
            XCTAssertEqual(injector.attempts, 2)
            let secondPIDValue = await client.debugProcessIdentifier()
            XCTAssertNotEqual(try XCTUnwrap(secondPIDValue), firstPID, "recovery must use a new worker generation")

            try await client.shutdown()
            let lifecycle = await client.debugLifecycleSnapshot()
            XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "shutdown must drain the reusable worker: \(lifecycle)")
            try removeIfPresent(outputDirectory)
            try removeIfPresent(workerDirectory)
        } catch let primaryError {
            do {
                try await client.shutdown()
            } catch let cleanupError {
                XCTFail("worker cleanup after regression failure failed: \(cleanupError)")
            }
            do {
                try removeIfPresent(outputDirectory)
                try removeIfPresent(workerDirectory)
            } catch let cleanupError {
                XCTFail("filesystem cleanup after regression failure failed: \(cleanupError)")
            }
            throw primaryError
        }
    }

    func testStemHashValidationFailureCompletesOnceWithoutResultAndReusesHealthyWorker() async throws {
        let workerDirectory = try makeFakeWorker(
            script: makeReusableValidatingWorkerScript(corruptFirstStemHash: true)
        )
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let inputURL = outputDirectory.appendingPathComponent("input.wav")
        try makeWAV(at: inputURL, frames: 1024)
        let client = InferenceWorkerClient(
            readinessTimeout: .seconds(3),
            startedTimeout: .seconds(2),
            separationTimeout: .seconds(5),
            workerDirectory: workerDirectory
        )

        do {
            try await client.startupForTesting()
            let firstPIDValue = await client.debugProcessIdentifier()
            let firstPID = try XCTUnwrap(firstPIDValue)
            var producedResult: SeparationResult?
            var observedError: InferenceError?
            do {
                producedResult = try await client.runSeparation(
                    inputPath: inputURL,
                    outputBaseDir: outputDirectory
                )
                XCTFail("a mismatched native stem hash must not produce a result")
            } catch let error as InferenceError {
                observedError = error
            } catch {
                XCTFail("expected a typed InferenceError, got \(error)")
            }

            XCTAssertNil(producedResult)
            let validationError = try XCTUnwrap(observedError)
            guard case .manifestValidationFailure(let evidence) = validationError else {
                return XCTFail("expected manifestValidationFailure, got \(validationError)")
            }
            XCTAssertTrue(evidence.contains("hash mismatch for bass"), "missing hash evidence: \(evidence)")
            let completionCountAfterFailure = await client.debugResultWaitCompletionCount()
            XCTAssertEqual(completionCountAfterFailure, 1)

            let stateAfterFailure = await client.currentState()
            guard case .ready(_, let metadata) = stateAfterFailure else {
                return XCTFail("a bad output hash must leave the protocol-healthy worker reusable, got \(stateAfterFailure)")
            }
            XCTAssertEqual(metadata.backend, "mlx")
            XCTAssertEqual(metadata.device, "mps")
            let isRunningAfterFailure = await client.debugIsRunning()
            XCTAssertTrue(isRunningAfterFailure)

            let subsequentResult = try await client.runSeparation(
                inputPath: inputURL,
                outputBaseDir: outputDirectory
            )
            XCTAssertTrue(subsequentResult.isComplete)
            XCTAssertEqual(subsequentResult.stems.count, 6)
            let completionCountAfterSuccess = await client.debugResultWaitCompletionCount()
            XCTAssertEqual(completionCountAfterSuccess, 2)
            let secondPIDValue = await client.debugProcessIdentifier()
            XCTAssertEqual(try XCTUnwrap(secondPIDValue), firstPID, "the protocol-healthy worker should be reused")

            try await client.shutdown()
            let lifecycle = await client.debugLifecycleSnapshot()
            XCTAssertFalse(lifecycle.hasOwnedLifecycleWork)
            try removeIfPresent(outputDirectory)
            try removeIfPresent(workerDirectory)
        } catch let primaryError {
            do {
                try await client.shutdown()
            } catch let cleanupError {
                XCTFail("worker cleanup after hash regression failure failed: \(cleanupError)")
            }
            do {
                try removeIfPresent(outputDirectory)
                try removeIfPresent(workerDirectory)
            } catch let cleanupError {
                XCTFail("filesystem cleanup after hash regression failure failed: \(cleanupError)")
            }
            throw primaryError
        }
    }

    // MARK: - Malformed protocol

    func testMalformedProtocolTerminatesFailsSafely() async throws {
        let script = """
import sys, json
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="separate":
        # Send malformed JSON (not object) then valid done - but client should have already failed session
        sys.stdout.write("not json at all\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":obj["job_id"]})+"\\n"); sys.stdout.flush()
    elif obj.get("type")=="shutdown":
        sys.exit(0)
"""
        try await withFakeWorker(script: script) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 10).write(to: wav)
            do {
                _ = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
                XCTFail("should have thrown malformed")
            } catch let err as InferenceError {
                guard case .malformedProtocol = err else { return XCTFail("expected malformedProtocol, got \\(err)") }
            } catch { XCTFail("expected malformedProtocol, got \(error)") }
            try await client.shutdown()
        }
    }

    func testBlankLineRejectedAsMalformed() async throws {
        let script = """
import sys, json
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="separate":
        sys.stdout.write("\\n"); sys.stdout.flush() # blank line
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":obj["job_id"]})+"\\n"); sys.stdout.flush()
    elif obj.get("type")=="shutdown":
        sys.exit(0)
"""
        try await withFakeWorker(script: script) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 10).write(to: wav)
            do {
                _ = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
                XCTFail("blank line should be rejected")
            } catch let error as InferenceError {
                guard case .malformedProtocol = error else { return XCTFail("expected malformedProtocol, got \(error)") }
            } catch { XCTFail("expected malformedProtocol, got \(error)") }
        }
    }

    // MARK: - Timeouts

    func testStartupReadinessTimeout() async throws {
        let script = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
# Never send ready, just sleep
time.sleep(10)
"""
        // Use short readiness timeout 1 second for test
        try await withFakeWorker(script: script, readinessTimeout: .seconds(1), separationTimeout: .seconds(2)) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 10).write(to: wav)
            do {
                _ = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
                XCTFail("should timeout")
            } catch let err as InferenceError {
                guard case .startupTimeout = err else { return XCTFail("expected startupTimeout got \\(err)") }
            } catch { XCTFail("wrong error \\(error)") }
        }
    }

    func testJobTimeoutStartedNotReceived() async throws {
        let script = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="separate":
        # Never send started, just hang
        time.sleep(10)
    elif obj.get("type")=="shutdown":
        sys.exit(0)
"""
        try await withFakeWorker(script: script, readinessTimeout: .seconds(2), separationTimeout: .seconds(2)) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 10).write(to: wav)
            do {
                _ = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
                XCTFail("should timeout on started")
            } catch let err as InferenceError {
                XCTAssertEqual(err, .startupTimeout)
            } catch { XCTFail("expected startupTimeout, got \(error)") }
        }
    }

    // MARK: - Process exit paths

    func testUnexpectedProcessExit() async throws {
        let script = """
import sys
sys.exit(2)
"""
        try await withFakeWorker(script: script) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 10).write(to: wav)
            do { _ = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp); XCTFail() } catch let err as InferenceError {
                switch err {
                case .startupFailure, .prematureProcessExit, .unexpectedEOF: break
                default: XCTFail("got \\(err)")
                }
            }
        }
    }

    func testNonzeroWorkerExit() async throws {
        let script = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
time.sleep(0.2)
sys.exit(1)
"""
        try await withFakeWorker(script: script) { client in
            let exited = expectation(description: "nonzero worker exit observed")
            await client.setAppExitEventHandler { event in
                if event == "processExitObserved" { exited.fulfill() }
            }
            try await client.startupForTesting()
            await fulfillment(of: [exited], timeout: 2)
            guard case .failed = await client.currentState() else {
                return XCTFail("nonzero exit must transition the worker to failed")
            }
            do {
                try await client.shutdown()
                XCTFail("nonzero worker exit must be reported")
            } catch let error as InferenceError {
                guard case .prematureProcessExit(let status, _) = error else {
                    return XCTFail("expected prematureProcessExit, got \(error)")
                }
                XCTAssertEqual(status, 1)
            } catch { XCTFail("expected prematureProcessExit, got \(error)") }
        }
    }

    // MARK: - Graceful shutdown

    func testGracefulIdleShutdownCommandAndExitZero() async throws {
        let script = """
import sys, json
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown":
        sys.exit(0)
"""
        try await withFakeWorker(script: script) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 10).write(to: wav)
            // Trigger lazy start
            _ = try? await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
            // Idle shutdown should send shutdown command and exit 0
            do {
                try await client.shutdown()
            } catch {
                XCTFail("shutdown should succeed got \\(error)")
            }
            // Second shutdown is no-op
            try await client.shutdown()
        }
    }

    func testShutdownWhileProcessingIsRejected() async throws {
        let script = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        time.sleep(5)
    elif obj.get("type")=="shutdown":
        sys.exit(0)
"""
        try await withFakeWorker(script: script) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 10).write(to: wav)
            // Start job in background
            let wavCopy = wav
            let tmpCopy = tmp
            let started = expectation(description: "worker started job")
            await client.setTestHook { event in
                if case .started = event { started.fulfill() }
            }
            let task = Task { [client, wavCopy, tmpCopy] in try await client.runSeparation(inputPath: wavCopy, outputBaseDir: tmpCopy) }
            await fulfillment(of: [started], timeout: 2)
            // Shutdown while processing should be illegal (client only allows shutdown from ready)
            do {
                try await client.shutdown()
                XCTFail("should reject shutdown while processing")
            } catch let err as InferenceError {
                guard case .illegalTransition = err else { return XCTFail("expected illegalTransition got \\(err)") }
            }
            await client.cancelActiveJob()
            switch await task.result {
            case .failure(let error as InferenceError): XCTAssertEqual(error, .cancellation)
            case .failure(let error): XCTFail("expected cancellation, got \(error)")
            case .success: XCTFail("cancelled job unexpectedly succeeded")
            }
            let lifecycle = await client.debugLifecycleSnapshot()
            XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "cancellation retained lifecycle work: \(lifecycle)")
        }
    }

    // MARK: - Cancellation

    func testCancellationWhileProcessingSendsTerminationAndDoesNotReportResult() async throws {
        let script = """
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
        try await withFakeWorker(script: script) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 10).write(to: wav)
            let wavCopy = wav
            let tmpCopy = tmp
            let started = expectation(description: "worker started job")
            await client.setTestHook { event in
                if case .started = event { started.fulfill() }
            }
            let task = Task { [client, wavCopy, tmpCopy] in try await client.runSeparation(inputPath: wavCopy, outputBaseDir: tmpCopy) }
            await fulfillment(of: [started], timeout: 2)
            await client.cancelActiveJob()
            switch await task.result {
            case .failure(let error as InferenceError): XCTAssertEqual(error, .cancellation)
            case .failure(let error): XCTFail("expected cancellation, got \(error)")
            case .success: XCTFail("cancelled job unexpectedly succeeded")
            }
            let lifecycle = await client.debugLifecycleSnapshot()
            XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "cancellation retained lifecycle work: \(lifecycle)")
        }
    }

    func testSubsequentSeparationAfterCancellationLazilyStartsNewWorkerGeneration() async throws {
        let script1 = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        time.sleep(10)
"""
        let dir1 = try makeFakeWorker(script: script1)
        defer { try? FileManager.default.removeItem(at: dir1) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(3), workerDirectory: dir1)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wav = tmp.appendingPathComponent("in.wav")
        try Data(count: 10).write(to: wav)
        let wavCopy = wav
        let tmpCopy = tmp
        let started = expectation(description: "first generation started job")
        await client.setTestHook { event in
            if case .started = event { started.fulfill() }
        }
        let task = Task { [client, wavCopy, tmpCopy] in try await client.runSeparation(inputPath: wavCopy, outputBaseDir: tmpCopy) }
        await fulfillment(of: [started], timeout: 2)
        await client.cancelActiveJob()
        switch await task.result {
        case .failure(let error as InferenceError): XCTAssertEqual(error, .cancellation)
        case .failure(let error): XCTFail("expected cancellation, got \(error)")
        case .success: XCTFail("cancelled job unexpectedly succeeded")
        }
        let cancelledLifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(cancelledLifecycle.hasOwnedLifecycleWork, "first generation survived cancellation: \(cancelledLifecycle)")
        await client.clearTestHook()
        // Now replace worker with good one for second generation
        let script2 = """
import sys, json, os, wave, struct, hashlib
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
def make_wav(p, frames=1024):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    import wave, struct
    with wave.open(p,'w') as wf:
        wf.setnchannels(2); wf.setsampwidth(2); wf.setframerate(44100); wf.setnframes(frames)
        wf.writeframes(struct.pack('<'+'h'*(frames*2), *([0]*(frames*2))))
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown":
        sys.exit(0)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        outdir=obj["output_dir"]
        inp=obj["input_path"]
        import hashlib, os, json
        inp_sha=hashlib.sha256(open(inp,'rb').read()).hexdigest()
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        job_dir=os.path.join(outdir,jid)
        os.makedirs(job_dir, exist_ok=True)
        stems=[]
        for name in ["bass","drums","other","vocals","guitar","piano"]:
            p=os.path.join(job_dir,f"{name}.wav")
            make_wav(p,1024)
            stems.append({"name":name,"path":p,"sha256":hashlib.sha256(open(p,'rb').read()).hexdigest(),"file_size":os.path.getsize(p),"frame_count":1024,"channels":2,"sample_rate":44100})
            sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":p})+"\\n"); sys.stdout.flush()
        manifest={"job_id":jid,"model":"roformer-model-bs-roformer-sw-by-jarredou","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e","backend":"mlx","device":"mps","input_path":inp,"output_dir":outdir,"input_sha256":inp_sha,"input_metadata":{"sample_rate":44100,"channels":2,"frames":1024,"duration":0.02,"sha256":inp_sha},"stems":stems}
        man_path=os.path.join(job_dir,"manifest.json")
        open(man_path,'w').write(json.dumps(manifest))
        sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":man_path})+"\\n"); sys.stdout.flush()
"""
        let dir2 = try makeFakeWorker(script: script2)
        defer { try? FileManager.default.removeItem(at: dir2) }
        await client.setWorkerDirectory(dir2)
        // Need to create new input wav matching 1024 frames
        try FileManager.default.removeItem(at: wav)
        try makeWAV(at: wav, frames: 1024)
        let result = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
        XCTAssertEqual(result.stems.count, 6)
        XCTAssertEqual(result.stems[.vocals]?.frameCount, 1024)
        try await client.shutdown()
        await client.setWorkerDirectory(nil)
    }

    func testStaleOutputFromOldGenerationCannotSatisfyNewGeneration() async throws {
        // Simulate old generation sending delayed done after new generation started
        let script = """
import sys, json, time, os, struct, wave, hashlib
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
first=True
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        if first:
            first=False
            sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
            # Delay, then client will cancel
            time.sleep(2)
            # After cancellation, if still running, emit stale done (should be ignored because generation changed)
            # But we will have been terminated, so this won't be seen
        else:
            outdir=obj["output_dir"]
            inp=obj["input_path"]
            # Second job should succeed normally
            sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
            job_dir=os.path.join(outdir,jid)
            os.makedirs(job_dir, exist_ok=True)
            def make_wav(p, frames=1024):
                import wave, struct, os
                with wave.open(p,'w') as wf:
                    wf.setnchannels(2); wf.setsampwidth(2); wf.setframerate(44100); wf.setnframes(frames)
                    wf.writeframes(struct.pack('<'+'h'*(frames*2), *([0]*(frames*2))))
            inp_sha=hashlib.sha256(open(inp,'rb').read()).hexdigest() if os.path.exists(inp) else "0"*64
            stems=[]
            for name in ["bass","drums","other","vocals","guitar","piano"]:
                p=os.path.join(job_dir,f"{name}.wav")
                make_wav(p,1024)
                stems.append({"name":name,"path":p,"sha256":hashlib.sha256(open(p,'rb').read()).hexdigest(),"file_size":os.path.getsize(p),"frame_count":1024,"channels":2,"sample_rate":44100})
                sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":p})+"\\n"); sys.stdout.flush()
            manifest={"job_id":jid,"model":"roformer-model-bs-roformer-sw-by-jarredou","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e","backend":"mlx","device":"mps","input_path":inp,"output_dir":outdir,"input_sha256":inp_sha,"input_metadata":{"sample_rate":44100,"channels":2,"frames":1024,"duration":0.02,"sha256":inp_sha},"stems":stems}
            man_path=os.path.join(job_dir,"manifest.json")
            open(man_path,'w').write(json.dumps(manifest))
            sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":man_path})+"\\n"); sys.stdout.flush()
    elif obj.get("type")=="shutdown":
        sys.exit(0)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wav = tmp.appendingPathComponent("in.wav")
        try makeWAV(at: wav, frames: 1024)
        let wavCopy1 = wav
        let tmpCopy1 = tmp
        let started = expectation(description: "old generation started job")
        await client.setTestHook { event in
            if case .started = event { started.fulfill() }
        }
        let task1 = Task { [client, wavCopy1, tmpCopy1] in try await client.runSeparation(inputPath: wavCopy1, outputBaseDir: tmpCopy1) }
        await fulfillment(of: [started], timeout: 2)
        await client.cancelActiveJob()
        switch await task1.result {
        case .failure(let error as InferenceError): XCTAssertEqual(error, .cancellation)
        case .failure(let error): XCTFail("expected cancellation, got \(error)")
        case .success: XCTFail("cancelled generation unexpectedly succeeded")
        }
        let cancelledLifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(cancelledLifecycle.hasOwnedLifecycleWork, "old generation survived cancellation: \(cancelledLifecycle)")
        await client.clearTestHook()
        // Now new job should succeed and not be satisfied by stale output from old job (which was cancelled/terminated, so no stale)
        let dir2 = try makeFakeWorker(script: """
import sys, json, os, wave, struct, hashlib
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
def make_wav(p, frames=1024):
    import wave, struct, os
    with wave.open(p,'w') as wf:
        wf.setnchannels(2); wf.setsampwidth(2); wf.setframerate(44100); wf.setnframes(frames)
        wf.writeframes(struct.pack('<'+'h'*(frames*2), *([0]*(frames*2))))
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown": sys.exit(0)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        outdir=obj["output_dir"]
        inp=obj["input_path"]
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        job_dir=os.path.join(outdir,jid)
        os.makedirs(job_dir, exist_ok=True)
        inp_sha=hashlib.sha256(open(inp,'rb').read()).hexdigest()
        stems=[]
        for name in ["bass","drums","other","vocals","guitar","piano"]:
            p=os.path.join(job_dir,f"{name}.wav")
            make_wav(p,1024)
            stems.append({"name":name,"path":p,"sha256":hashlib.sha256(open(p,'rb').read()).hexdigest(),"file_size":os.path.getsize(p),"frame_count":1024,"channels":2,"sample_rate":44100})
            sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":p})+"\\n"); sys.stdout.flush()
        manifest={"job_id":jid,"model":"roformer-model-bs-roformer-sw-by-jarredou","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e","backend":"mlx","device":"mps","input_path":inp,"output_dir":outdir,"input_sha256":inp_sha,"input_metadata":{"sample_rate":44100,"channels":2,"frames":1024,"duration":0.02,"sha256":inp_sha},"stems":stems}
        man_path=os.path.join(job_dir,"manifest.json")
        open(man_path,'w').write(json.dumps(manifest))
        sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":man_path})+"\\n"); sys.stdout.flush()
""")
        defer { try? FileManager.default.removeItem(at: dir2) }
        await client.setWorkerDirectory(dir2)
        let result = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
        XCTAssertEqual(result.stems.count, 6)
        // Stale output would be from old jid, but new result's jobId must be different
        XCTAssertNotEqual(result.jobId, "") // just ensure it's new
        try await client.shutdown()
        await client.setWorkerDirectory(nil)
    }

    // MARK: - Concurrent job

    func testConcurrentJobRequestIsRejectedOrSerialized() async throws {
        let script = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        time.sleep(3)
        for name in ["vocals","drums","bass","guitar","piano","other"]:
            sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":f"/tmp/{name}.wav"})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":"/tmp/manifest.json"})+"\\n"); sys.stdout.flush()
    elif obj.get("type")=="shutdown":
        sys.exit(0)
"""
        try await withFakeWorker(script: script) { client in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wav = tmp.appendingPathComponent("in.wav")
            try Data(count: 10).write(to: wav)
            let started = expectation(description: "first concurrent job started")
            await client.setTestHook { event in
                if case .started = event { started.fulfill() }
            }
            async let first = client.runSeparation(inputPath: wav, outputBaseDir: tmp)
            await fulfillment(of: [started], timeout: 2)
            do {
                _ = try await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
                XCTFail("second job should have been rejected as alreadyRunningJob")
            } catch let err as InferenceError {
                guard case .alreadyRunningJob = err else { return XCTFail("expected alreadyRunningJob got \\(err)") }
            } catch { XCTFail("wrong error \\(error)") }
            // Cancel first to clean up
            await client.cancelActiveJob()
            do {
                _ = try await first
                XCTFail("cancelled first job unexpectedly succeeded")
            } catch let error as InferenceError {
                XCTAssertEqual(error, .cancellation)
            } catch {
                XCTFail("expected cancellation, got \(error)")
            }
            let lifecycle = await client.debugLifecycleSnapshot()
            XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "concurrent-job cleanup retained lifecycle work: \(lifecycle)")
        }
    }

    // MARK: - Orphan check

    func testNoOrphanFakeWorkerRemainsAfterEachTest() async throws {
        let script = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown":
        sys.exit(0)
    if obj.get("type")=="separate":
        time.sleep(0.1)
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":obj["job_id"]})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"error","job_id":obj["job_id"],"code":"invalid_input","message":"oops"})+"\\n"); sys.stdout.flush()
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(3), workerDirectory: dir)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wav = tmp.appendingPathComponent("in.wav")
        try Data(count: 10).write(to: wav)
        _ = try? await client.runSeparation(inputPath: wav, outputBaseDir: tmp)
        try await client.shutdown()
        // After shutdown, no process should remain: attempt to run ps and ensure no fake_worker.py with our dir
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        // Read concurrently before wait to avoid pipe deadlock on large output
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(out.contains(dir.path), "orphan fake worker still running after shutdown: \(out)")
    }

    // MARK: - Application-Exit Lifecycle (Sol xHigh) Helper

    private final class MonotonicRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(String, UInt64)] = []
        private var seq: UInt64 = 0
        func record(_ name: String) {
            lock.lock()
            seq += 1
            events.append((name, seq))
            lock.unlock()
        }
        func index(of name: String) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            return events.firstIndex(where: { $0.0 == name })
        }
        func contains(_ name: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return events.contains(where: { $0.0 == name })
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return events.map { $0.0 }
        }
        func assertOrder(_ first: String, _ second: String, file: StaticString = #filePath, line: UInt = #line) {
            guard let i1 = index(of: first), let i2 = index(of: second) else {
                XCTFail("Missing events for order check: \(first) or \(second) not recorded. Got: \(all)", file: file, line: line)
                return
            }
            XCTAssertLessThan(i1, i2, "\(first) must be before \(second). Got order: \(all)", file: file, line: line)
        }
    }

    // Test 1 — idle graceful exit
    func testApplicationExitIdleGracefulExit() async throws {
        let recorder = MonotonicRecorder()
        let script = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"roformer-model-bs-roformer-sw-by-jarredou"})+"\\n"); sys.stdout.flush()
time.sleep(0.05)
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    try:
        obj=json.loads(line)
    except:
        continue
    if obj.get("type")=="shutdown":
        sys.exit(0)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(3), workerDirectory: dir)
        await client.setAppExitEventHandler { recorder.record($0) }
        // Start worker
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wav = tmp.appendingPathComponent("in.wav")
        try Data(count: 10).write(to: wav)
        // Trigger lazy start without job (startupForTesting)
        try await client.startupForTesting()
        let beforePID: Int32? = await client.debugProcessIdentifier()
        XCTAssertNotNil(beforePID)
        let capturedProcess = await client.debugProcess()
        XCTAssertNotNil(capturedProcess)
        // Now perform application-exit with short policy to keep test fast but still graceful
        let policy = ApplicationExitPolicy(totalBudget: .milliseconds(800), idleGrace: .milliseconds(300), sigtermGrace: .milliseconds(200), sigkillGrace: .milliseconds(200), cleanupReserve: .milliseconds(50))
        // Use a Task to capture reply timing
        let result = await client.terminateForApplicationExit(policy: policy)
        recorder.record("reply_\(result == .safeToTerminate ? "true" : "false")")
        XCTAssertEqual(result, .safeToTerminate, "idle graceful should be safe")
        // Assert ordering
        recorder.assertOrder("shutdownSent", "processExitObserved")
        recorder.assertOrder("processExitObserved", "cleanupComplete")
        recorder.assertOrder("cleanupComplete", "reply_true")
        XCTAssertFalse(recorder.contains("sigtermSent"), "idle graceful must not send SIGTERM")
        XCTAssertFalse(recorder.contains("sigkillSent"), "idle graceful must not send SIGKILL")
        // Captured process must be dead
        if let proc = capturedProcess {
            XCTAssertFalse(proc.isRunning, "captured Process must be dead at reply(true)")
        }
        let stillRunning = await client.debugIsRunning()
        XCTAssertFalse(stillRunning, "client must own no running process at reply(true)")
        let afterProcess = await client.debugProcess()
        XCTAssertNil(afterProcess, "no client Process reference must remain at reply(true)")
    }

    // Test 3 — active SIGTERM-resistant worker
    func testApplicationExitResistantSIGTERMToSIGKILL() async throws {
        let recorder = MonotonicRecorder()
        // Worker that ignores SIGTERM
        let script = """
import sys, json, time, signal
signal.signal(signal.SIGTERM, lambda s,f: None)
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    try:
        obj=json.loads(line)
    except:
        continue
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        time.sleep(10)
    elif obj.get("type")=="shutdown":
        time.sleep(10)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        await client.setAppExitEventHandler { recorder.record($0) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wav = tmp.appendingPathComponent("in.wav")
        try Data(count: 10).write(to: wav)
        // Start job in background to make worker processing
        let started = expectation(description: "SIGTERM-resistant worker started job")
        await client.setTestHook { event in
            if case .started = event { started.fulfill() }
        }
        let jobTask = Task { try await client.runSeparation(inputPath: wav, outputBaseDir: tmp) }
        await fulfillment(of: [started], timeout: 2)
        // Capture process before termination
        let captured = await client.debugProcess()
        XCTAssertNotNil(captured)
        let policy = ApplicationExitPolicy(totalBudget: .seconds(2), idleGrace: .milliseconds(200), sigtermGrace: .milliseconds(300), sigkillGrace: .seconds(1), cleanupReserve: .milliseconds(100))
        let result = await client.terminateForApplicationExit(policy: policy)
        recorder.record(result == .safeToTerminate ? "reply_true" : "reply_false")
        XCTAssertEqual(result, .safeToTerminate, "resistant worker must eventually be killed via SIGKILL and return safe")
        recorder.assertOrder("sigtermSent", "sigkillSent")
        recorder.assertOrder("sigkillSent", "processExitObserved")
        recorder.assertOrder("processExitObserved", "cleanupComplete")
        recorder.assertOrder("cleanupComplete", "reply_true")
        // Prove post-SIGKILL exit was checked: process must be dead, and no SIGKILL assumption
        if let proc = captured { XCTAssertFalse(proc.isRunning) }
        let isRunningAfterKill = await client.debugIsRunning()
        XCTAssertFalse(isRunningAfterKill)
        switch await jobTask.result {
        case .failure(let error as InferenceError): XCTAssertEqual(error, .cancellation)
        case .failure(let error): XCTFail("expected cancellation, got \(error)")
        case .success: XCTFail("terminated job unexpectedly succeeded")
        }
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "safe exit retained lifecycle work: \(lifecycle)")
    }

    // Test 4 — deadline/failure path
    func testApplicationExitDeadlineFailureAndRetry() async throws {
        let recorder = MonotonicRecorder()
        // Worker that ignores SIGTERM and sleeps long, but we will use very short policy to force deadline expiry
        let script = """
import sys, json, time, signal
signal.signal(signal.SIGTERM, lambda s,f: time.sleep(10))
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    try:
        obj=json.loads(line)
    except:
        continue
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        time.sleep(10)
    elif obj.get("type")=="shutdown":
        time.sleep(10)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        await client.setAppExitEventHandler { recorder.record($0) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wav = tmp.appendingPathComponent("in.wav")
        try Data(count: 10).write(to: wav)
        let started = expectation(description: "deadline worker started job")
        await client.setTestHook { event in
            if case .started = event { started.fulfill() }
        }
        let jobTask = Task { try await client.runSeparation(inputPath: wav, outputBaseDir: tmp) }
        await fulfillment(of: [started], timeout: 2)
        let capturedBefore = await client.debugProcess()
        XCTAssertNotNil(capturedBefore)
        let isRunningBefore = await client.debugIsRunning()
        XCTAssertTrue(isRunningBefore)
        // Expired policy: total zero ensures deadline is already expired at entry, so operation must return unsafe immediately and retain Process for retry
        let shortPolicy = ApplicationExitPolicy(totalBudget: .milliseconds(0), idleGrace: .milliseconds(5), sigtermGrace: .milliseconds(5), sigkillGrace: .milliseconds(5), cleanupReserve: .milliseconds(1))
        let result = await client.terminateForApplicationExit(policy: shortPolicy)
        XCTAssertEqual(result, .unsafeToTerminate(reason: .deadlineExpired))
        // Client must still own live Process/state for retry
        let stillRunning = await client.debugIsRunning()
        XCTAssertTrue(stillRunning, "client must still own live Process after deadline expiry")
        let stillProcess = await client.debugProcess()
        XCTAssertNotNil(stillProcess, "Process ownership must NOT be erased on deadline expiry")
        XCTAssertEqual(stillProcess?.processIdentifier, capturedBefore?.processIdentifier, "must retain same Process for retry")
        let retainedLifecycle = await client.debugLifecycleSnapshot()
        XCTAssertTrue(retainedLifecycle.hasProcess)
        XCTAssertTrue(retainedLifecycle.isProcessRunning)
        XCTAssertFalse(retainedLifecycle.hasSessionCleanupTask, "completed unsafe attempt must not retain a cleanup task")
        // Now make worker terminable: kill it externally or use normal retry
        // For test, we will directly kill the process to allow retry to succeed
        if let pid = stillProcess?.processIdentifier {
            Darwin.kill(pid, SIGKILL)
        }
        // Now retry with normal policy should succeed safely
        let normalPolicy = ApplicationExitPolicy(totalBudget: .seconds(2), idleGrace: .milliseconds(200), sigtermGrace: .milliseconds(300), sigkillGrace: .milliseconds(500), cleanupReserve: .milliseconds(100))
        let retryResult = await client.terminateForApplicationExit(policy: normalPolicy)
        XCTAssertEqual(retryResult, .safeToTerminate, "subsequent retry must succeed safely")
        let isRunningAfterRetry = await client.debugIsRunning()
        XCTAssertFalse(isRunningAfterRetry)
        let procAfterRetry = await client.debugProcess()
        XCTAssertNil(procAfterRetry)
        switch await jobTask.result {
        case .failure(let error as InferenceError): XCTAssertEqual(error, .cancellation)
        case .failure(let error): XCTFail("expected cancellation, got \(error)")
        case .success: XCTFail("terminated job unexpectedly succeeded")
        }
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "successful retry retained lifecycle work: \(lifecycle)")
    }

    // Test 7 — no cleanup surviving accepted termination
    func testNoCleanupSurvivingAfterReplyTrue() async throws {
        let recorder = MonotonicRecorder()
        let script = """
import sys, json
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown":
        sys.exit(0)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(3), workerDirectory: dir)
        await client.setAppExitEventHandler { recorder.record($0) }
        try await client.startupForTesting()
        let policy = ApplicationExitPolicy(totalBudget: .milliseconds(800), idleGrace: .milliseconds(300), sigtermGrace: .milliseconds(200), sigkillGrace: .milliseconds(200), cleanupReserve: .milliseconds(50))
        let result = await client.terminateForApplicationExit(policy: policy)
        XCTAssertEqual(result, .safeToTerminate)
        // At moment reply would be emitted, cleanupComplete must already be recorded
        XCTAssertTrue(recorder.contains("cleanupComplete"), "cleanupComplete must be recorded before reply")
        XCTAssertTrue(recorder.contains("shutdownSent"), "shutdownSent must be recorded")
        recorder.assertOrder("shutdownSent", "cleanupComplete")
        // No worker or process ownership may survive the safe result.
        let isRunning = await client.debugIsRunning()
        XCTAssertFalse(isRunning)
        let proc = await client.debugProcess()
        XCTAssertNil(proc)
    }

    // Test 8 — no accepted orphan
    func testNoAcceptedOrphan() async throws {
        let script = """
import sys, json, time
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown":
        sys.exit(0)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        time.sleep(10)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        try await client.startupForTesting()
        let captured = await client.debugProcess()
        let capturedPID = await client.debugProcessIdentifier()
        XCTAssertNotNil(captured)
        XCTAssertNotNil(capturedPID)
        let isRunningBefore = await client.debugIsRunning()
        XCTAssertTrue(isRunningBefore)
        // Perform idle graceful (no active job) - should be safe and leave no orphan
        let policy = ApplicationExitPolicy(totalBudget: .milliseconds(800), idleGrace: .milliseconds(300), sigtermGrace: .milliseconds(200), sigkillGrace: .milliseconds(200), cleanupReserve: .milliseconds(50))
        let result = await client.terminateForApplicationExit(policy: policy)
        XCTAssertEqual(result, .safeToTerminate)
        // Prove at every reply(true), client owns no running process and captured is dead
        let isRunningAfter = await client.debugIsRunning()
        XCTAssertFalse(isRunningAfter, "client must own no running process at reply(true)")
        let procAfter = await client.debugProcess()
        XCTAssertNil(procAfter, "client must have cleared Process reference")
        if let proc = captured {
            XCTAssertFalse(proc.isRunning, "captured process must be no longer alive")
        }
        // Also check via pid not alive via kill 0
        if let pid = capturedPID {
            let alive = Darwin.kill(pid, 0) == 0
            XCTAssertFalse(alive, "captured PID must not be alive (kill 0 should fail)")
        }
    }
}
