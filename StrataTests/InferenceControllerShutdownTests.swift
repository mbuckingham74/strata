import XCTest
@testable import Strata
import Foundation
import AVFoundation
import CryptoKit

@MainActor
final class InferenceControllerShutdownTests: XCTestCase {

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

    // 1. shutdown while idle/ready => graceful worker shutdown
    func testShutdownWhileIdleGraceful() async throws {
        let script = """
import sys, json
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"roformer-model-bs-roformer-sw-by-jarredou"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="shutdown":
        sys.exit(0)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        # idle test shouldn't receive separate, but handle
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        sys.stdout.write(json.dumps({"protocol":1,"type":"error","job_id":jid,"code":"invalid","message":"not expected"})+"\\n"); sys.stdout.flush()
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(3), workerDirectory: dir)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let controller = InferenceController(client: client, outputBase: base)
        // Trigger lazy startup via client DEBUG seam
        try await client.startupForTesting()
        let isRunningBefore = await client.debugIsRunning()
        XCTAssertTrue(isRunningBefore, "worker should be running after startup")
        await controller.shutdownWorker()
        // After idle shutdown, worker must be terminated gracefully (exit 0)
        let isRunningAfter = await client.debugIsRunning()
        XCTAssertFalse(isRunningAfter, "worker should not be running after idle graceful shutdown")
        // Controller should be idle and not failed
        XCTAssertEqual(controller.state, .idle)
        // Repeated shutdown should not throw or leave orphan
        await controller.shutdownWorker()
        XCTAssertEqual(controller.state, .idle)
        let stillNotRunning = await client.debugIsRunning()
        XCTAssertFalse(stillNotRunning)
        // Ensure no fake process remains via ps check
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(out.contains(dir.path), "orphan fake worker still running after idle shutdown")
    }

    // 2. shutdown while actively processing => cancelActiveJob semantics execute and worker terminates
    func testShutdownWhileActiveProcessingCancelsAndTerminates() async throws {
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
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let controller = InferenceController(client: client, outputBase: base)
        let wav = base.appendingPathComponent("in.wav")
        try makeWAV(at: wav, frames: 1024)
        let started = expectation(description: "worker started active separation")
        await client.setTestHook { event in
            if case .started = event { started.fulfill() }
        }
        // Start separation in background
        controller.startSeparation(inputURL: wav)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(controller.isSeparating, "controller should be separating")
        let processingBefore = await client.isProcessing()
        XCTAssertTrue(processingBefore, "client should be processing")
        // Active shutdown
        await controller.shutdownWorker()
        // After active shutdown, worker must be terminated (cancel semantics)
        let isRunningAfter = await client.debugIsRunning()
        XCTAssertFalse(isRunningAfter, "worker should be terminated after active shutdown")
        XCTAssertEqual(controller.state, .idle, "controller should be idle after active shutdown, not failed with premature exit")
        // No result should be published
        XCTAssertNil(controller.result, "active shutdown must not publish SeparationResult")
        // Error message should not be prematureProcessExit
        if let msg = controller.errorMessage {
            XCTAssertFalse(msg.lowercased().contains("premature"), "should not surface prematureProcessExit after active cancel, got \(msg)")
            XCTAssertFalse(msg.lowercased().contains("exit"), "should not surface premature exit")
        }
        // Ensure no orphan
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(out.contains(dir.path))
        // Verify idempotent second shutdown
        await controller.shutdownWorker()
        XCTAssertEqual(controller.state, .idle)
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "active shutdown retained worker lifecycle work: \(lifecycle)")
    }

    // 3. active shutdown does not publish result + 4. not premature exit + 5. non-running + 6. no orphan already covered above
    // Provide dedicated test for no result publishing with delayed success path
    func testActiveShutdownDoesNotPublishResultEvenIfWorkerWouldLaterSucceed() async throws {
        let script = """
import sys, json, os, time, struct, hashlib
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
def make_wav(p, frames=1024):
    import wave, struct, os
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with wave.open(p,'w') as wf:
        wf.setnchannels(2); wf.setsampwidth(2); wf.setframerate(44100); wf.setnframes(frames)
        wf.writeframes(struct.pack('<'+'h'*(frames*2), *([0]*(frames*2))))
for line in sys.stdin:
    obj=json.loads(line)
    if obj.get("type")=="separate":
        jid=obj["job_id"]
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        time.sleep(1.5)
        # If not cancelled, would produce success
        outdir=obj["output_dir"]
        inp=obj["input_path"]
        job_dir=os.path.join(outdir,jid)
        os.makedirs(job_dir, exist_ok=True)
        import hashlib
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
    elif obj.get("type")=="shutdown":
        sys.exit(0)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(6), workerDirectory: dir)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let controller = InferenceController(client: client, outputBase: base)
        let wav = base.appendingPathComponent("in2.wav")
        try makeWAV(at: wav, frames: 1024)
        let started = expectation(description: "worker started separation before shutdown")
        await client.setTestHook { event in
            if case .started = event { started.fulfill() }
        }
        controller.startSeparation(inputURL: wav)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(controller.isSeparating)
        await controller.shutdownWorker()
        XCTAssertNil(controller.result, "result must remain nil after active shutdown even though worker would have succeeded later")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.errorMessage?.lowercased().contains("premature") ?? false)
        let running = await client.debugIsRunning()
        XCTAssertFalse(running)
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "active shutdown retained worker lifecycle work: \(lifecycle)")
    }

    // 7. repeated shutdown safe/idempotent
    func testRepeatedShutdownIsSafeAndIdempotent() async throws {
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
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let controller = InferenceController(client: client, outputBase: base)
        try await client.startupForTesting()
        let isRunningBeforeRepeat = await client.debugIsRunning()
        XCTAssertTrue(isRunningBeforeRepeat)
        await controller.shutdownWorker()
        await controller.shutdownWorker()
        await controller.shutdownWorker()
        XCTAssertEqual(controller.state, .idle)
        let isRunningAfterRepeat = await client.debugIsRunning()
        XCTAssertFalse(isRunningAfterRepeat)
        // Concurrent duplicate terminations (like AppKit)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { await controller.shutdownWorker() }
            }
        }
        XCTAssertEqual(controller.state, .idle)
        let isRunningAfterConcurrent = await client.debugIsRunning()
        XCTAssertFalse(isRunningAfterConcurrent)
    }

    // 8. existing cancellation -> lazy new generation remains green
    func testCancellationThenNewGenerationSucceeds() async throws {
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
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let controller = InferenceController(client: client, outputBase: base)
        let wav = base.appendingPathComponent("in.wav")
        try makeWAV(at: wav, frames: 1024)
        let started = expectation(description: "first generation started separation")
        await client.setTestHook { event in
            if case .started = event { started.fulfill() }
        }
        controller.startSeparation(inputURL: wav)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(controller.isSeparating)
        await client.clearTestHook()
        controller.cancel()
        let cancellationCleanup = try XCTUnwrap(controller.debugCleanupChainTail())
        await cancellationCleanup.value
        let isRunningAfterCancelCheck = await client.debugIsRunning()
        XCTAssertFalse(isRunningAfterCancelCheck, "worker should be terminated after cancel")
        let cancelledLifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(cancelledLifecycle.hasOwnedLifecycleWork, "cancelled generation retained worker lifecycle work: \(cancelledLifecycle)")
        // New generation with good worker
        let script2 = """
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
    if obj.get("type")=="shutdown":
        sys.exit(0)
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
"""
        let dir2 = try makeFakeWorker(script: script2)
        defer { try? FileManager.default.removeItem(at: dir2) }
        await client.setWorkerDirectory(dir2)
        // Need fresh wav for new generation with float32 via makeWAV (AVAudio) to pass validation (but fake creates int16 wav with wave module, not float32 - will fail AVAudioFile validation)
        // Our makeWAV creates float32, fake's wave creates int16 (sampwidth 2) which our validator will reject as format mismatch (expects float32). For test we need fake to mimic float wavs that pass AVAudio validation.
        // Instead we override to create float wavs via our Swift helper? The fake's manifest points to files it created via wave int16; validator will try AVAudioFile open and fail.
        // We need to ensure fake creates valid float32 wavs that pass validator. Use custom float creation similar to successful job but with correct format.
        // For simplicity, we will create stems via Swift after fake signals started? Alternative: make fake use float via struct float packing with WAVE fmt 3.
        // Adjust dir2 script to use float wave creation as in earlier successful script
        // We will reuse a script that creates float wavs via RIFF header (as in testSuccessfulJobProtocol)
        // Re-create dir2 with float-friendly script
        try? FileManager.default.removeItem(at: dir2)
        let floatScript = """
import sys, json, os, struct, hashlib
sys.stdout.write(json.dumps({"protocol":1,"type":"loading_model","model":"m"})+"\\n"); sys.stdout.flush()
sys.stdout.write(json.dumps({"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"})+"\\n"); sys.stdout.flush()
def make_wav(path, frames=1024, sr=44100, ch=2):
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
        jid=obj["job_id"]
        outdir=obj["output_dir"]
        inp=obj["input_path"]
        inp_sha = hashlib.sha256(open(inp,'rb').read()).hexdigest()
        sys.stdout.write(json.dumps({"protocol":1,"type":"started","job_id":jid})+"\\n"); sys.stdout.flush()
        job_dir=os.path.join(outdir, jid)
        os.makedirs(job_dir, exist_ok=True)
        stems=[]
        for name in ["bass","drums","other","vocals","guitar","piano"]:
            p=os.path.join(job_dir, f"{name}.wav")
            make_wav(p, frames=1024)
            stems.append({"name":name,"path":p,"sha256":sha256_file(p),"file_size":os.path.getsize(p),"frame_count":1024,"channels":2,"sample_rate":44100})
            sys.stdout.write(json.dumps({"protocol":1,"type":"stem","job_id":jid,"name":name,"path":p})+"\\n"); sys.stdout.flush()
        manifest={"job_id":jid,"model":"roformer-model-bs-roformer-sw-by-jarredou","checkpoint_sha256":"24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e","backend":"mlx","device":"mps","input_path":inp,"output_dir":outdir,"input_sha256":inp_sha,"input_metadata":{"sample_rate":44100,"channels":2,"frames":1024,"duration":0.02,"sha256":inp_sha},"stems":stems}
        man_path=os.path.join(job_dir,"manifest.json")
        open(man_path,'w').write(json.dumps(manifest))
        sys.stdout.write(json.dumps({"protocol":1,"type":"done","job_id":jid,"output_manifest":man_path})+"\\n"); sys.stdout.flush()
"""
        // Recreate wrapper for float script
        let newDir = try makeFakeWorker(script: floatScript)
        defer { try? FileManager.default.removeItem(at: newDir) }
        await client.setWorkerDirectory(newDir)
        try makeWAV(at: wav, frames: 1024)
        controller.startSeparation(inputURL: wav)
        let secondOperation = try XCTUnwrap(controller.debugCurrentTask())
        await secondOperation.value
        XCTAssertEqual(controller.state, .completed, "second generation after cancel should complete, got \(controller.state)")
        XCTAssertNotNil(controller.result)
        XCTAssertEqual(controller.result?.stems.count, 6)
        await controller.shutdownWorker()
        let isRunningAfterGen = await client.debugIsRunning()
        XCTAssertFalse(isRunningAfterGen)
    }

    // Additional: verify controller does not publish prematureProcessExit after cancel
    func testCancelDoesNotSurfacePrematureExit() async throws {
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
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(3), workerDirectory: dir)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let controller = InferenceController(client: client, outputBase: base)
        let wav = base.appendingPathComponent("in.wav")
        try makeWAV(at: wav, frames: 1024)
        let started = expectation(description: "worker started separation before cancellation")
        await client.setTestHook { event in
            if case .started = event { started.fulfill() }
        }
        controller.startSeparation(inputURL: wav)
        await fulfillment(of: [started], timeout: 2)
        controller.cancel()
        let cancellationCleanup = try XCTUnwrap(controller.debugCleanupChainTail())
        await cancellationCleanup.value
        // After cancel, state should be cancelled, not premature exit
        if case .failed(let msg) = controller.state {
            XCTAssertEqual(msg, "Cancelled", "cancel should surface Cancelled not premature exit")
            XCTAssertFalse(msg.lowercased().contains("premature"))
        } else {
            XCTFail("expected failed Cancelled got \(controller.state)")
        }
        let isRunningAfterCancel2 = await client.debugIsRunning()
        XCTAssertFalse(isRunningAfterCancel2)
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "cancellation retained worker lifecycle work: \(lifecycle)")
    }

    // MARK: - Sol xHigh Application-Exit Temporal Helpers

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
                XCTFail("Missing events for order \(first) < \(second). Got: \(all)", file: file, line: line)
                return
            }
            XCTAssertLessThan(i1, i2, "\(first) must be before \(second). Got: \(all)", file: file, line: line)
        }
    }

    // Test 2 — active SIGTERM-cooperative worker
    func testActiveCooperativeSIGTERMOrdering() async throws {
        let recorder = MonotonicRecorder()
        let script = """
import sys, json, time, signal
signal.signal(signal.SIGTERM, lambda s,f: sys.exit(0))
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
        time.sleep(0.5)
        sys.exit(0)
"""
        let dir = try makeFakeWorker(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = InferenceWorkerClient(readinessTimeout: .seconds(3), startedTimeout: .seconds(2), separationTimeout: .seconds(5), workerDirectory: dir)
        await client.setAppExitEventHandler { recorder.record($0) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let controller = InferenceController(client: client, outputBase: base)
        controller.setControllerTestEventHandler { recorder.record($0) }
        let wav = base.appendingPathComponent("in.wav")
        try makeWAV(at: wav, frames: 1024)
        let started = expectation(description: "cooperative worker started separation")
        await client.setTestHook { event in
            if case .started = event { started.fulfill() }
        }
        controller.startSeparation(inputURL: wav)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(controller.isSeparating)
        let policy = ApplicationExitPolicy(totalBudget: .seconds(2), idleGrace: .milliseconds(200), sigtermGrace: .milliseconds(400), sigkillGrace: .milliseconds(500), cleanupReserve: .milliseconds(100))
        let result = await controller.terminateForApplicationExit(policy: policy)
        recorder.record(result == .safeToTerminate ? "reply_true" : "reply_false")
        XCTAssertEqual(result, .safeToTerminate, "cooperative SIGTERM should result in safe")
        // Ordering: generationInvalidated < separationTaskCancelled < SIGTERM < exit < cleanup < reply
        recorder.assertOrder("controllerGenerationInvalidated", "separationTaskCancelled")
        recorder.assertOrder("separationTaskCancelled", "sigtermSent")
        recorder.assertOrder("sigtermSent", "processExitObserved")
        recorder.assertOrder("processExitObserved", "cleanupComplete")
        recorder.assertOrder("cleanupComplete", "reply_true")
        XCTAssertNil(controller.result, "no late SeparationResult must be published")
        XCTAssertFalse(recorder.contains("sigkillSent"), "cooperative should not need SIGKILL")
        let isRunningCoop = await client.debugIsRunning()
        XCTAssertFalse(isRunningCoop)
        XCTAssertFalse(controller.debugHasPendingCancellationCleanup())
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork, "safe application exit retained worker lifecycle work: \(lifecycle)")
    }

    func testApplicationExitCompletesCleanupBeforeReturningSafe() async throws {
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
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let controller = InferenceController(client: client, outputBase: base)
        try await client.startupForTesting()
        let recorder = MonotonicRecorder()
        await client.setAppExitEventHandler { recorder.record($0) }
        let result = await controller.terminateForApplicationExit(policy: .testShort(total: .milliseconds(800), idle: .milliseconds(200), sigterm: .milliseconds(150), sigkill: .milliseconds(150), reserve: .milliseconds(50)))
        XCTAssertEqual(result, .safeToTerminate)
        XCTAssertTrue(recorder.contains("cleanupComplete"))
        let isRunningNoDetach = await client.debugIsRunning()
        XCTAssertFalse(isRunningNoDetach)
        let lifecycle = await client.debugLifecycleSnapshot()
        XCTAssertFalse(lifecycle.hasOwnedLifecycleWork)
    }
}
