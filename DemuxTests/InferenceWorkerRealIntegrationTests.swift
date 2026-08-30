import XCTest
@testable import Demux
import Foundation
import CryptoKit
import AVFoundation

// MARK: - Sentinel (test-only, never production)

private struct M3SentinelConfig: Codable, Sendable {
    let version: Int
    let mode: String
    let mixturePath: String
    let workerDirectory: String
}

final class InferenceWorkerRealIntegrationTests: XCTestCase {

    // Test-only sentinel proof — supports startupOnly and fullSeparation.
    func testRealWorkerSeparationProof() async throws {
        let overallStart = ContinuousClock.now

        print("[DEMUX-STARTUP] testRealWorkerSeparationProof started at \(Date())")
        await XCTContext.runActivity(named: "Demux M3 proof") { _ in
            print("[DEMUX-STARTUP] entered XCTContext activity")
        }

        // MARK: 1. Sentinel one-shot claim
        let sentinelPath = "/private/tmp/demux-m3-real-integration.json"
        let fm = FileManager.default
        let claimedPath = "/private/tmp/demux-m3-real-integration.claimed.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).json"
        let sentinelURL = URL(fileURLWithPath: sentinelPath)
        let claimedURL = URL(fileURLWithPath: claimedPath)

        print("[DEMUX-STARTUP] attempting to claim sentinel at \(sentinelPath)")
        do {
            try fm.moveItem(at: sentinelURL, to: claimedURL)
            print("[DEMUX-STARTUP] sentinel successfully claimed -> \(claimedPath)")
        } catch {
            print("[DEMUX-STARTUP] sentinel missing, XCTSkip: \(error)")
            throw XCTSkip("missing sentinel => XCTSkip: \(error.localizedDescription)")
        }
        defer {
            try? fm.removeItem(at: claimedURL)
            print("[DEMUX-STARTUP] claimed sentinel cleaned")
        }

        // MARK: 2. Parse and strictly validate sentinel
        let rawData: Data
        do {
            rawData = try Data(contentsOf: claimedURL)
            print("[DEMUX-STARTUP] sentinel raw: \(String(data: rawData, encoding: .utf8) ?? "<non-utf8>")")
        } catch {
            XCTFail("failed to read claimed sentinel: \(error)")
            return
        }

        let cfg: M3SentinelConfig
        do {
            cfg = try JSONDecoder().decode(M3SentinelConfig.self, from: rawData)
        } catch {
            XCTFail("sentinel decode failed (strict Codable required): \(error)")
            return
        }

        guard cfg.version == 1 else {
            XCTFail("version must equal 1, got \(cfg.version)")
            return
        }
        guard cfg.mode == "startupOnly" || cfg.mode == "fullSeparation" else {
            XCTFail("mode must equal startupOnly or fullSeparation, got \(cfg.mode)")
            return
        }
        guard cfg.mixturePath.hasPrefix("/private/tmp/") && cfg.mixturePath.hasPrefix("/") else {
            XCTFail("mixturePath must be absolute /private/tmp path, got \(cfg.mixturePath)")
            return
        }
        guard cfg.workerDirectory.hasPrefix("/private/tmp/") && cfg.workerDirectory.hasPrefix("/") else {
            XCTFail("workerDirectory must be absolute /private/tmp path, got \(cfg.workerDirectory)")
            return
        }
        guard !cfg.mixturePath.contains("..") && !cfg.workerDirectory.contains("..") else {
            XCTFail("paths must not contain traversal")
            return
        }

        print("[DEMUX-REAL] sentinel validated: version=1 mode=\(cfg.mode) mixturePath=\(cfg.mixturePath) workerDirectory=\(cfg.workerDirectory)")

        let mixtureURL = URL(fileURLWithPath: cfg.mixturePath).standardizedFileURL
        let workerDirURL = URL(fileURLWithPath: cfg.workerDirectory).standardizedFileURL

        // MARK: 3. Verify fixture exists and SHA
        let expectedSHA = "d26d5aec719080bb14f52c9ba65b41303773ddcec50c151c24d50d738c092969"
        guard fm.fileExists(atPath: mixtureURL.path) else {
            XCTFail("mixturePath does not exist: \(mixtureURL.path)")
            return
        }
        let fixtureData = try Data(contentsOf: mixtureURL)
        let actualSHA = SHA256.hash(data: fixtureData).map { String(format: "%02x", $0) }.joined()
        print("[DEMUX-REAL] fixture SHA actual=\(actualSHA) expected=\(expectedSHA)")
        XCTAssertEqual(actualSHA.lowercased(), expectedSHA.lowercased(), "Fixture SHA mismatch")

        let audioFile = try AVAudioFile(forReading: mixtureURL)
        print("[DEMUX-REAL] fixture audio sr=\(audioFile.processingFormat.sampleRate) ch=\(audioFile.processingFormat.channelCount) frames=\(audioFile.length)")
        XCTAssertEqual(audioFile.processingFormat.sampleRate, 44100)
        XCTAssertEqual(audioFile.processingFormat.channelCount, 2)
        XCTAssertEqual(audioFile.length, 882_000)

        // MARK: 4. Verify worker via production WorkerLaunchConfiguration
        let config: WorkerLaunchConfiguration
        do {
            config = try WorkerLaunchConfiguration.resolved(workerDirectoryOverride: workerDirURL.path, isDebug: true)
        } catch {
            XCTFail("WorkerLaunchConfiguration resolved failed: \(error)")
            return
        }
        // Sentinel workerDirectory is single source of truth — derive all assertions from expectedWorkerRoot
        let expectedWorkerRoot = workerDirURL.standardizedFileURL
        let expectedWorkerRootResolved = expectedWorkerRoot.resolvingSymlinksInPath()
        let expectedPython = expectedWorkerRoot.appendingPathComponent(".venv/bin/python3").standardizedFileURL
        let expectedPythonResolved = expectedPython.resolvingSymlinksInPath()
        print("[DEMUX-REAL] expectedWorkerRoot raw: \(expectedWorkerRoot.path) resolved: \(expectedWorkerRootResolved.path)")
        print("[DEMUX-REAL] expected python raw: \(expectedPython.path) resolved: \(expectedPythonResolved.path)")
        print("[DEMUX-REAL] real worker executable is: \(config.processExecutableURL.path)")
        print("[DEMUX-REAL] worker arguments are: \(config.processArguments)")
        print("[DEMUX-REAL] cwd is: \(config.processCurrentDirectoryURL.path)")
        let rawExec = config.processExecutableURL.path
        let rawCwd = config.processCurrentDirectoryURL.path
        let resolvedExec = config.processExecutableURL.resolvingSymlinksInPath().path
        let resolvedCwd = config.processCurrentDirectoryURL.resolvingSymlinksInPath().path
        let resolvedExpectedPython = expectedPythonResolved.path
        let resolvedExpectedRoot = expectedWorkerRootResolved.path
        print("[DEMUX-REAL] resolved exec: \(resolvedExec) cwd: \(resolvedCwd) (raw exec \(rawExec) raw cwd \(rawCwd)) expected python resolved \(resolvedExpectedPython) expected root resolved \(resolvedExpectedRoot)")
        XCTAssertTrue(resolvedExec == resolvedExpectedPython, "Executable must be \(resolvedExpectedPython) (derived from sentinel workerDirectory), got raw \(rawExec) resolved \(resolvedExec)")
        XCTAssertEqual(config.processArguments, ["-m", "demux_worker"])
        XCTAssertTrue(resolvedCwd == resolvedExpectedRoot, "cwd must be \(resolvedExpectedRoot) (derived from sentinel), got raw \(rawCwd) resolved \(resolvedCwd)")
        XCTAssertEqual(config.processEnvironment?["PYTHONUNBUFFERED"], "1")
        XCTAssertFalse(config.processExecutableURL.path.contains("Documents"))
        XCTAssertFalse(config.processExecutableURL.path.contains("Downloads"))
        XCTAssertFalse(config.processCurrentDirectoryURL.path.contains("Documents"))

        let workerPythonCheck = Process()
        workerPythonCheck.executableURL = config.processExecutableURL
        workerPythonCheck.arguments = ["-c", "import demux_worker; print(demux_worker.__file__)"]
        workerPythonCheck.currentDirectoryURL = config.processCurrentDirectoryURL
        let checkPipe = Pipe()
        workerPythonCheck.standardOutput = checkPipe
        workerPythonCheck.standardError = Pipe()
        do {
            try workerPythonCheck.run()
            workerPythonCheck.waitUntilExit()
            let out = String(data: checkPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            print("[DEMUX-REAL] demux_worker.__file__ = \(out)")
            let outURL = URL(fileURLWithPath: out).standardizedFileURL.resolvingSymlinksInPath()
            func isComponentSafeContained(candidatePath: String, rootPath: String) -> Bool {
                let c = URL(fileURLWithPath: candidatePath).standardizedFileURL.resolvingSymlinksInPath().path
                let r = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath().path
                if c == r { return true }
                if r == "/" { return c.hasPrefix("/") }
                return c.hasPrefix(r + "/")
            }
            let contained = isComponentSafeContained(candidatePath: outURL.path, rootPath: resolvedExpectedRoot) || isComponentSafeContained(candidatePath: out, rootPath: expectedWorkerRoot.path)
            XCTAssertTrue(contained, "demux_worker.__file__ must be path-component-contained beneath sentinel workerDirectory \(resolvedExpectedRoot), got \(out) resolved \(outURL.path)")
            XCTAssertFalse(out.contains("Documents"))
            XCTAssertFalse(out.contains("Downloads"))
            if out.contains("Documents") || out.contains("Downloads") || !contained {
                XCTFail("worker module points outside sentinel workerDirectory \(resolvedExpectedRoot): \(out) resolved \(outURL.path)")
                return
            }
        } catch {
            XCTFail("failed to check demux_worker.__file__: \(error)")
            return
        }

        // Branch by mode
        if cfg.mode == "fullSeparation" {
            await runFullSeparation(
                overallStart: overallStart,
                mixtureURL: mixtureURL,
                workerDirURL: workerDirURL,
                expectedSHA: expectedSHA
            )
            return
        }

        // MARK: 5. Startup-only proof
        print("[DEMUX-STARTUP] mode startupOnly — running startup proof")
        let client = InferenceWorkerClient(readinessTimeout: .seconds(15), workerDirectory: workerDirURL)

        final class EventBox: @unchecked Sendable {
            var events: [InferenceEvent] = []
            let queue = DispatchQueue(label: "observed")
            func append(_ ev: InferenceEvent) {
                queue.sync { events.append(ev) }
                switch ev {
                case .loadingModel(let e):
                    print("[DEMUX-STARTUP] event loading_model model=\(e.model)")
                case .ready(let e):
                    print("[DEMUX-STARTUP] event ready backend=\(e.backend) device=\(e.device) sha=\(e.checkpoint_sha256)")
                case .started(let e):
                    print("[DEMUX-STARTUP] event started job_id=\(e.job_id)")
                case .stem(let e):
                    print("[DEMUX-STARTUP] event stem name=\(e.name.rawValue) path=\(e.path)")
                case .done(let e):
                    print("[DEMUX-STARTUP] event done job_id=\(e.job_id) manifest=\(e.output_manifest)")
                case .error(let e):
                    print("[DEMUX-STARTUP] event error job_id=\(e.job_id) code=\(e.code) message=\(e.message)")
                }
            }
            func snapshot() -> [InferenceEvent] { queue.sync { events } }
        }
        let box = EventBox()
        await client.setTestHook { ev in box.append(ev) }

        print("[DEMUX-STARTUP] installing event observer/hook completed")
        print("[DEMUX-STARTUP] requesting real worker readiness (15s timeout)")

        let startupStart = ContinuousClock.now
        do {
            try await client.startupForTesting()
            let elapsed = ContinuousClock.now - startupStart
            print("[DEMUX-STARTUP] readiness succeeded in \(elapsed)")
        } catch {
            let elapsed = ContinuousClock.now - startupStart
            print("[DEMUX-STARTUP] readiness FAILED after \(elapsed): \(error)")
            print("[DEMUX-STARTUP] observed events before failure: \(box.snapshot())")
            try? await client.shutdown()
            XCTFail("readiness failed after \(elapsed): \(error) events: \(box.snapshot())")
            return
        }

        let info = await client.debugProcessInfo()
        print("[DEMUX-STARTUP] process info executable=\(info.executable?.path ?? "nil") args=\(info.arguments ?? []) cwd=\(info.cwd?.path ?? "nil") pid=\(info.pid.map(String.init) ?? "nil") isRunning=\(info.isRunning)")
        if let exec = info.executable?.path, let cwd = info.cwd?.path {
            let resolvedExec2 = info.executable?.resolvingSymlinksInPath().path ?? exec
            let resolvedCwd2 = info.cwd?.resolvingSymlinksInPath().path ?? cwd
            print("[DEMUX-STARTUP] resolved process exec=\(resolvedExec2) cwd=\(resolvedCwd2)")
        }

        let expectedWorkerRootResolved2 = expectedWorkerRootResolved.path
        let expectedPythonResolvedStr = expectedPythonResolved.path
        let procExec = info.executable?.path ?? ""
        let procCwd = info.cwd?.path ?? ""
        let procResolvedExec = info.executable?.resolvingSymlinksInPath().path ?? procExec
        let procResolvedCwd = info.cwd?.resolvingSymlinksInPath().path ?? procCwd
        XCTAssertTrue(procResolvedExec == expectedPythonResolvedStr, "proc executable must be derived sentinel workerDirectory \(expectedPythonResolvedStr), got raw \(procExec) resolved \(procResolvedExec)")
        XCTAssertEqual(info.arguments, ["-m", "demux_worker"])
        XCTAssertTrue(procResolvedCwd == expectedWorkerRootResolved2, "proc cwd must be derived sentinel workerDirectory \(expectedWorkerRootResolved2), got raw \(procCwd) resolved \(procResolvedCwd)")
        XCTAssertTrue(info.isRunning, "worker should be running after readiness")

        let observed = box.snapshot()
        print("[DEMUX-STARTUP] observed \(observed.count) events total")

        let hasLoading = observed.contains { if case .loadingModel = $0 { return true } else { return false } }
        print("[DEMUX-STARTUP] loading_model observed: \(hasLoading)")
        XCTAssertTrue(hasLoading, "loading_model is not observed")

        var readyEvents: [ReadyEvent] = []
        for ev in observed { if case .ready(let e) = ev { readyEvents.append(e) } }
        print("[DEMUX-STARTUP] ready observed count: \(readyEvents.count)")
        XCTAssertFalse(readyEvents.isEmpty, "ready is not observed")
        guard let ready = readyEvents.first else {
            try? await client.shutdown()
            XCTFail("no ready event")
            return
        }
        print("[DEMUX-STARTUP] ready backend=\(ready.backend) device=\(ready.device)")
        XCTAssertEqual(ready.backend, "mlx", "backend must be mlx")
        XCTAssertEqual(ready.device, "mps", "device must be mps")

        if let meta = await client.debugReadyMetadata() {
            print("[DEMUX-STARTUP] debugReadyMetadata backend=\(meta.backend) device=\(meta.device)")
            XCTAssertEqual(meta.backend, "mlx")
            XCTAssertEqual(meta.device, "mps")
        } else {
            print("[DEMUX-STARTUP] debugReadyMetadata is nil")
        }

        await XCTContext.runActivity(named: "startup events") { activity in
            let desc = observed.map { ev -> String in
                switch ev {
                case .loadingModel(let e): return "loading_model:\(e.model)"
                case .ready(let e): return "ready:\(e.backend)/\(e.device)"
                case .started(let e): return "started:\(e.job_id)"
                case .stem(let e): return "stem:\(e.name.rawValue)"
                case .done(let e): return "done:\(e.job_id)"
                case .error(let e): return "error:\(e.code)"
                }
            }.joined(separator: ", ")
            activity.add(XCTAttachment(string: "[DEMUX-STARTUP] events: \(desc)"))
            print("[DEMUX-STARTUP] XCTActivity startup events: \(desc)")
        }

        print("[DEMUX-STARTUP] requesting graceful shutdown")
        let shutdownStart = ContinuousClock.now
        do {
            try await client.shutdown()
            let elapsed = ContinuousClock.now - shutdownStart
            print("[DEMUX-STARTUP] graceful shutdown succeeded in \(elapsed)")
        } catch {
            let elapsed = ContinuousClock.now - shutdownStart
            print("[DEMUX-STARTUP] graceful shutdown FAILED after \(elapsed): \(error)")
            XCTFail("graceful shutdown failed: \(error)")
            return
        }

        let stillRunning = await client.debugIsRunning()
        print("[DEMUX-STARTUP] worker isRunning after shutdown: \(stillRunning)")
        XCTAssertFalse(stillRunning, "worker should not be running after shutdown")

        print("[DEMUX-STARTUP] orphan check via ps (derived root \(expectedWorkerRootResolved2))")
        // Capture PID before shutdown if needed, but use sentinel-derived root for check
        var out = ""
        do {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-A", "-o", "command"]
            let pipe = Pipe()
            ps.standardOutput = pipe
            ps.standardError = Pipe()
            try ps.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            out = String(data: data, encoding: .utf8) ?? ""
            print("[DEMUX-STARTUP] ps exit \(ps.terminationStatus) output len \(out.count)")
        } catch {
            out = "ps failed: \(error)"
            print("[DEMUX-STARTUP] ps failed: \(error)")
        }
        print("[DEMUX-STARTUP] ps output after shutdown (first 2000 chars):\n\(String(out.prefix(2000)))")
        let hasOrphan = out.contains("demux_worker") && (out.contains(expectedWorkerRoot.path) || out.contains(expectedWorkerRootResolved2))
        print("[DEMUX-STARTUP] orphan check hasOrphan=\(hasOrphan) (checked derived root \(expectedWorkerRoot.path) resolved \(expectedWorkerRootResolved2))")
        XCTAssertFalse(hasOrphan, "integration-owned Python worker remains for root \(expectedWorkerRootResolved2): \(out.prefix(1000))")
        if hasOrphan { XCTFail("orphan worker remains") }
        let hasGenericDemux = out.contains("demux_worker")
        print("[DEMUX-STARTUP] generic demux_worker still in ps? \(hasGenericDemux)")

        let totalElapsed = ContinuousClock.now - overallStart
        print("[DEMUX-STARTUP] total startup-proof elapsed time: \(totalElapsed)")
        print("[DEMUX-STARTUP] PASS - startup proof complete")
        await XCTContext.runActivity(named: "startup proof result") { activity in
            activity.add(XCTAttachment(string: "PASS startup proof elapsed \(totalElapsed) executable \(info.executable?.path ?? "") cwd \(info.cwd?.path ?? "") ready backend \(ready.backend) device \(ready.device)"))
        }
    }

    // MARK: - Full separation

    private func runFullSeparation(
        overallStart: ContinuousClock.Instant,
        mixtureURL: URL,
        workerDirURL: URL,
        expectedSHA: String
    ) async {
        print("[DEMUX-FULL] mode fullSeparation — running ONE real inference")
        let outputBaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Demux/M3Separations")
        print("[DEMUX-FULL] output base: \(outputBaseURL.path)")
        do {
            try FileManager.default.createDirectory(at: outputBaseURL, withIntermediateDirectories: true)
        } catch {
            XCTFail("failed to create output base: \(error)")
            return
        }

        // Production stack: InferenceWorkerClient with generous timeouts, WorkerLaunchConfiguration via override
        let client = InferenceWorkerClient(
            readinessTimeout: .seconds(120),
            startedTimeout: .seconds(30),
            separationTimeout: .seconds(300),
            workerDirectory: workerDirURL
        )

        final class EventBox: @unchecked Sendable {
            var events: [InferenceEvent] = []
            var loadingModelEvents: [LoadingModelEvent] = []
            var readyEvents: [ReadyEvent] = []
            var startedEvents: [StartedEvent] = []
            var stemEvents: [StemEvent] = []
            var doneEvents: [DoneEvent] = []
            var errorEvents: [WorkerErrorEvent] = []
            let queue = DispatchQueue(label: "fullObserved")
            func append(_ ev: InferenceEvent) {
                queue.sync {
                    events.append(ev)
                    switch ev {
                    case .loadingModel(let e): loadingModelEvents.append(e)
                    case .ready(let e): readyEvents.append(e)
                    case .started(let e): startedEvents.append(e)
                    case .stem(let e): stemEvents.append(e)
                    case .done(let e): doneEvents.append(e)
                    case .error(let e): errorEvents.append(e)
                    }
                }
                switch ev {
                case .loadingModel(let e):
                    print("[DEMUX-FULL] event loading_model model=\(e.model)")
                case .ready(let e):
                    print("[DEMUX-FULL] event ready backend=\(e.backend) device=\(e.device) sha=\(e.checkpoint_sha256)")
                case .started(let e):
                    print("[DEMUX-FULL] event started job_id=\(e.job_id)")
                case .stem(let e):
                    print("[DEMUX-FULL] event stem name=\(e.name.rawValue) path=\(e.path) job_id=\(e.job_id)")
                case .done(let e):
                    print("[DEMUX-FULL] event done job_id=\(e.job_id) manifest=\(e.output_manifest)")
                case .error(let e):
                    print("[DEMUX-FULL] event error job_id=\(e.job_id) code=\(e.code) message=\(e.message)")
                }
            }
            func snapshot() -> [InferenceEvent] { queue.sync { events } }
        }
        let box = EventBox()
        await client.setTestHook { ev in box.append(ev) }
        print("[DEMUX-FULL] hook installed, invoking production separate()")

        let inferenceStart = ContinuousClock.now
        let result: SeparationResult
        do {
            result = try await client.separate(inputPath: mixtureURL, outputBaseDir: outputBaseURL)
            let elapsed = ContinuousClock.now - inferenceStart
            print("[DEMUX-FULL] separate() returned in \(elapsed) jobId=\(result.jobId) manifest=\(result.manifestURL.path)")
            print("[DEMUX-FULL] inference elapsed time: \(elapsed)")
        } catch {
            let elapsed = ContinuousClock.now - inferenceStart
            print("[DEMUX-FULL] separate() FAILED after \(elapsed): \(error)")
            print("[DEMUX-FULL] observed events before failure: \(box.snapshot())")
            let info = await client.debugProcessInfo()
            print("[DEMUX-FULL] debugProcessInfo isRunning=\(info.isRunning) pid=\(info.pid.map(String.init) ?? "nil")")
            try? await client.shutdown()
            XCTFail("fullSeparation failed after \(elapsed): \(error) events: \(box.snapshot())")
            return
        }

        // Process info for evidence
        let info = await client.debugProcessInfo()
        print("[DEMUX-FULL] process info executable=\(info.executable?.path ?? "nil") args=\(info.arguments ?? []) cwd=\(info.cwd?.path ?? "nil") pid=\(info.pid.map(String.init) ?? "nil") isRunning=\(info.isRunning)")
        if let exec = info.executable?.path, let cwd = info.cwd?.path {
            let rExec = info.executable?.resolvingSymlinksInPath().path ?? exec
            let rCwd = info.cwd?.resolvingSymlinksInPath().path ?? cwd
            print("[DEMUX-FULL] resolved process exec=\(rExec) cwd=\(rCwd)")
        }
        XCTAssertTrue(info.isRunning, "worker should be running after separation (before shutdown)")

        let observed = box.snapshot()
        print("[DEMUX-FULL] observed \(observed.count) events total")

        // MARK: Protocol sequence validation
        // 1. loading_model
        let hasLoading = !box.loadingModelEvents.isEmpty
        print("[DEMUX-FULL] loading_model observed: \(hasLoading) count=\(box.loadingModelEvents.count)")
        XCTAssertTrue(hasLoading, "loading_model is not observed")
        if let lm = box.loadingModelEvents.first {
            print("[DEMUX-FULL] loading_model model=\(lm.model)")
        }

        // 2. ready backend/device
        print("[DEMUX-FULL] ready observed count: \(box.readyEvents.count)")
        XCTAssertFalse(box.readyEvents.isEmpty, "ready is not observed")
        guard let ready = box.readyEvents.first else {
            try? await client.shutdown(); XCTFail("no ready event"); return
        }
        print("[DEMUX-FULL] ready backend=\(ready.backend) device=\(ready.device) sha=\(ready.checkpoint_sha256)")
        XCTAssertEqual(ready.backend, "mlx", "backend must be mlx")
        XCTAssertEqual(ready.device, "mps", "device must be mps")
        let expectedCheckpoint = "24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"
        print("[DEMUX-FULL] ready checkpoint sha check expected=\(expectedCheckpoint) actual=\(ready.checkpoint_sha256)")
        XCTAssertEqual(ready.checkpoint_sha256.lowercased(), expectedCheckpoint.lowercased(), "checkpoint SHA mismatch in ready")
        if let meta = await client.debugReadyMetadata() {
            print("[DEMUX-FULL] debugReadyMetadata backend=\(meta.backend) device=\(meta.device) checkpoint=\(meta.checkpointSHA256)")
            XCTAssertEqual(meta.backend, "mlx")
            XCTAssertEqual(meta.device, "mps")
            XCTAssertEqual(meta.checkpointSHA256.lowercased(), expectedCheckpoint.lowercased())
        }

        // 3. started
        print("[DEMUX-FULL] started observed count: \(box.startedEvents.count)")
        XCTAssertEqual(box.startedEvents.count, 1, "must be exactly one started event")
        guard let started = box.startedEvents.first else { try? await client.shutdown(); XCTFail("no started"); return }
        print("[DEMUX-FULL] started job_id=\(started.job_id)")
        XCTAssertEqual(started.job_id, result.jobId, "started job_id must equal result jobId")
        XCTAssertEqual(started.job_id.lowercased(), started.job_id, "job_id must be lowercase")
        XCTAssertFalse(started.job_id.contains("/"))

        // 4. exactly six UNIQUE stem events
        print("[DEMUX-FULL] stem observed count: \(box.stemEvents.count)")
        XCTAssertEqual(box.stemEvents.count, 6, "must be exactly six stem events")
        let stemNames = box.stemEvents.map { $0.name.rawValue }
        print("[DEMUX-FULL] six stem events in observed order: \(stemNames.joined(separator: ", "))")
        let uniqueStems = Set(stemNames)
        XCTAssertEqual(uniqueStems.count, 6, "stems must be unique, got duplicates in \(stemNames)")
        let requiredSet = Set(["vocals","drums","bass","guitar","piano","other"])
        XCTAssertEqual(uniqueStems, requiredSet, "stem set must be exactly \(requiredSet), got \(uniqueStems)")
        for ev in box.stemEvents {
            XCTAssertEqual(ev.job_id, result.jobId, "stem job_id mismatch expected \(result.jobId) got \(ev.job_id)")
            XCTAssertFalse(ev.path.contains("Documents"))
            XCTAssertFalse(ev.path.contains("Downloads"))
        }
        // Reject duplicate/unknown already via set equality and StemName closed set
        // Check ordering: done after all stems
        XCTAssertTrue(box.errorEvents.isEmpty, "no error events expected, got \(box.errorEvents)")

        // 5. done ordering
        print("[DEMUX-FULL] done observed count: \(box.doneEvents.count)")
        XCTAssertEqual(box.doneEvents.count, 1, "must be exactly one done")
        guard let done = box.doneEvents.first else { try? await client.shutdown(); XCTFail("no done"); return }
        print("[DEMUX-FULL] done job_id=\(done.job_id) manifest=\(done.output_manifest)")
        XCTAssertEqual(done.job_id, result.jobId, "done job_id must equal result jobId")
        // Ensure done after stems — verify observed order: last stem index < done index
        if let doneIndex = observed.firstIndex(where: { if case .done = $0 { return true } else { return false } }) {
            let lastStemIndex = observed.lastIndex(where: { if case .stem = $0 { return true } else { return false } }) ?? -1
            print("[DEMUX-FULL] done index=\(doneIndex) lastStem index=\(lastStemIndex)")
            XCTAssertTrue(doneIndex > lastStemIndex, "done must be after all six stems")
        }
        // Ensure staged -> no duplicate stem after done
        // Also check started before stems
        if let startedIndex = observed.firstIndex(where: { if case .started = $0 { return true } else { return false } }),
           let firstStemIndex = observed.firstIndex(where: { if case .stem = $0 { return true } else { return false } }) {
            XCTAssertTrue(startedIndex < firstStemIndex, "started must be before first stem")
        }

        await XCTContext.runActivity(named: "full separation events") { activity in
            let desc = observed.map { ev -> String in
                switch ev {
                case .loadingModel(let e): return "loading_model:\(e.model)"
                case .ready(let e): return "ready:\(e.backend)/\(e.device)"
                case .started(let e): return "started:\(e.job_id)"
                case .stem(let e): return "stem:\(e.name.rawValue)"
                case .done(let e): return "done:\(e.job_id)"
                case .error(let e): return "error:\(e.code)"
                }
            }.joined(separator: ", ")
            activity.add(XCTAttachment(string: "[DEMUX-FULL] events: \(desc)"))
            print("[DEMUX-FULL] XCTActivity full events: \(desc)")
        }

        // MARK: Manifest/result validation
        print("[DEMUX-FULL] validating manifest/result jobId=\(result.jobId)")
        XCTAssertEqual(result.jobId, started.job_id)
        XCTAssertEqual(result.jobId, done.job_id)
        XCTAssertEqual(result.model, "roformer-model-bs-roformer-sw-by-jarredou", "model mismatch")
        XCTAssertEqual(result.checkpointSHA256.lowercased(), expectedCheckpoint.lowercased(), "checkpoint mismatch in result")
        XCTAssertEqual(result.backend, "mlx")
        XCTAssertEqual(result.device, "mps")
        XCTAssertTrue(result.isComplete, "result must be complete")
        XCTAssertEqual(result.stems.count, 6, "result stems count must be 6")

        // Manifest decode
        let manifestURL = result.manifestURL
        print("[DEMUX-FULL] manifest URL: \(manifestURL.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path), "manifest missing")
        let manifestData = try! Data(contentsOf: manifestURL)
        let rawManifest = try! JSONDecoder().decode(RawManifest.self, from: manifestData)
        print("[DEMUX-FULL] manifest decoded job_id=\(rawManifest.jobId) model=\(rawManifest.model ?? "nil") backend=\(rawManifest.backend) device=\(rawManifest.device) stems=\(rawManifest.stems.count)")
        XCTAssertEqual(rawManifest.jobId, result.jobId, "manifest job_id mismatch")
        XCTAssertEqual(rawManifest.model, "roformer-model-bs-roformer-sw-by-jarredou")
        XCTAssertEqual(rawManifest.checkpointSHA256?.lowercased(), expectedCheckpoint.lowercased())
        XCTAssertEqual(rawManifest.backend, "mlx")
        XCTAssertEqual(rawManifest.device, "mps")
        XCTAssertEqual(rawManifest.stems.count, 6)
        let manifestStemNames = Set(rawManifest.stems.map { $0.name })
        XCTAssertEqual(manifestStemNames, requiredSet, "manifest stem set mismatch")
        if let inputSHA = rawManifest.inputSHA256 {
            print("[DEMUX-FULL] manifest inputSHA=\(inputSHA) expected=\(expectedSHA)")
            XCTAssertEqual(inputSHA.lowercased(), expectedSHA.lowercased(), "manifest input SHA mismatch")
        } else {
            print("[DEMUX-FULL] manifest inputSHA missing, checking input_metadata sha")
            if let metaSHA = rawManifest.inputMetadata?.sha256 {
                XCTAssertEqual(metaSHA.lowercased(), expectedSHA.lowercased())
            }
        }

        // Path inside finalized job directory, existence, SHA, audio format
        let jobDir = result.jobDirectoryURL
        print("[DEMUX-FULL] job directory: \(jobDir.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.path))
        XCTAssertEqual(jobDir.resolvingSymlinksInPath().path, manifestURL.deletingLastPathComponent().resolvingSymlinksInPath().path, "manifest dir must be job dir")
        XCTAssertEqual(manifestURL.lastPathComponent, "manifest.json")

        var observedFrameCounts = Set<UInt64>()
        for rec in rawManifest.stems {
            guard let stemName = StemName(rawValue: rec.name) else { XCTFail("unknown stem \(rec.name)"); continue }
            let stemURL = URL(fileURLWithPath: rec.path).standardizedFileURL
            let resolvedStemDir = stemURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let expectedJobDirResolved = jobDir.resolvingSymlinksInPath().standardizedFileURL
            print("[DEMUX-FULL] validating stem \(stemName.rawValue) path=\(rec.path)")
            XCTAssertEqual(resolvedStemDir, expectedJobDirResolved, "stem path not inside job dir \(rec.path) not in \(jobDir.path)")
            XCTAssertEqual(stemURL.lastPathComponent, "\(stemName.rawValue).wav")
            XCTAssertTrue(FileManager.default.fileExists(atPath: stemURL.path), "stem file missing \(stemURL.path)")
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: stemURL.path, isDirectory: &isDir)
            XCTAssertFalse(isDir.boolValue, "stem not file \(stemURL.path)")

            // Check received stem path matches manifest if provided in box
            if let received = box.stemEvents.first(where: { $0.name == stemName }) {
                let canonReceived = URL(fileURLWithPath: received.path).standardizedFileURL.resolvingSymlinksInPath()
                let canonManifest = stemURL.resolvingSymlinksInPath()
                XCTAssertEqual(canonReceived, canonManifest, "stem path mismatch for \(stemName.rawValue)")
            }

            // Validate SHA
            let fileSHA = try! sha256File(at: stemURL)
            if let expectedSHARec = rec.sha256 {
                print("[DEMUX-FULL] stem \(stemName.rawValue) sha file=\(fileSHA) manifest=\(expectedSHARec)")
                XCTAssertEqual(fileSHA.lowercased(), expectedSHARec.lowercased(), "hash mismatch for \(stemName.rawValue)")
            }
            // Also compare to result artifact
            if let artifact = result.stems[stemName] {
                XCTAssertEqual(artifact.sha256.lowercased(), fileSHA.lowercased(), "artifact sha mismatch for \(stemName.rawValue)")
                XCTAssertEqual(artifact.url.resolvingSymlinksInPath().path, stemURL.resolvingSymlinksInPath().path)
            }

            // Validate file size if present
            if let expectedSize = rec.fileSize {
                let attrs = try! FileManager.default.attributesOfItem(atPath: stemURL.path)
                let actualSize: UInt64 = (attrs[.size] as? UInt64) ?? (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                XCTAssertEqual(actualSize, expectedSize, "size mismatch for \(stemName.rawValue)")
            }

            // Audio format validation
            let audio = try! AVAudioFile(forReading: stemURL)
            let sr = UInt32(audio.processingFormat.sampleRate)
            let ch = UInt32(audio.processingFormat.channelCount)
            let frames = UInt64(audio.length)
            print("[DEMUX-FULL] stem \(stemName.rawValue) audio sr=\(sr) ch=\(ch) frames=\(frames)")
            XCTAssertEqual(sr, 44100, "sample rate must be 44100 for \(stemName.rawValue)")
            XCTAssertEqual(ch, 2, "channels must be stereo for \(stemName.rawValue)")
            XCTAssertEqual(frames, 882000, "for THIS fixture every stem must be exactly 882000 frames, got \(frames) for \(stemName.rawValue)")
            XCTAssertGreaterThan(frames, 0)
            observedFrameCounts.insert(frames)

            if let fc = rec.frameCount {
                XCTAssertEqual(fc, frames, "manifest frame_count \(fc) != file length \(frames)")
            }
            if let srRec = rec.sampleRate { XCTAssertEqual(srRec, 44100) }
            if let chRec = rec.channels { XCTAssertEqual(chRec, 2) }

            // Also check inputMetadata frames if present
            if let canon = rawManifest.inputMetadata?.frames {
                XCTAssertEqual(canon, 882000, "input metadata frames must be 882000")
            }
        }

        XCTAssertEqual(observedFrameCounts.count, 1, "all stem frame counts must agree, got \(observedFrameCounts)")
        XCTAssertEqual(observedFrameCounts.first, 882000, "all stems must be 882000")
        if let inputFrames = rawManifest.inputMetadata?.frames {
            XCTAssertEqual(inputFrames, 882000)
            XCTAssertEqual(observedFrameCounts.first, inputFrames, "stem frames must match input metadata")
        }

        // Immutable validated SeparationResult checks
        print("[DEMUX-FULL] SeparationResult validated jobId=\(result.jobId) model=\(result.model) backend=\(result.backend) device=\(result.device)")
        for (name, artifact) in result.stems {
            print("[DEMUX-FULL] artifact \(name.rawValue) url=\(artifact.url.path) sha=\(artifact.sha256) frames=\(artifact.frameCount) sr=\(artifact.sampleRate) ch=\(artifact.channels)")
            XCTAssertEqual(artifact.sampleRate, 44100)
            XCTAssertEqual(artifact.channels, 2)
            XCTAssertEqual(artifact.frameCount, 882000)
            XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
        }

        let totalElapsed = ContinuousClock.now - overallStart
        let inferenceElapsed = ContinuousClock.now - inferenceStart
        print("[DEMUX-FULL] total full-proof elapsed: \(totalElapsed) inference elapsed: \(inferenceElapsed)")
        await XCTContext.runActivity(named: "full proof result") { activity in
            activity.add(XCTAttachment(string: "PASS full proof elapsed \(totalElapsed) inference \(inferenceElapsed) jobId \(result.jobId)"))
        }

        // MARK: Graceful shutdown proof
        print("[DEMUX-FULL] requesting graceful shutdown")
        let shutdownStart = ContinuousClock.now
        do {
            try await client.shutdown()
            let elapsed = ContinuousClock.now - shutdownStart
            print("[DEMUX-FULL] graceful shutdown succeeded in \(elapsed)")
        } catch {
            let elapsed = ContinuousClock.now - shutdownStart
            print("[DEMUX-FULL] graceful shutdown FAILED after \(elapsed): \(error)")
            XCTFail("graceful shutdown failed: \(error)")
            return
        }

        let stillRunning = await client.debugIsRunning()
        print("[DEMUX-FULL] worker isRunning after shutdown: \(stillRunning)")
        XCTAssertFalse(stillRunning, "worker should not be running after shutdown")

        print("[DEMUX-FULL] orphan check via ps (derived root \(workerDirURL.path))")
        let expectedFullRoot = workerDirURL.standardizedFileURL
        let expectedFullRootResolved = expectedFullRoot.resolvingSymlinksInPath().path
        var out = ""
        do {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-A", "-o", "command"]
            let pipe = Pipe()
            ps.standardOutput = pipe
            ps.standardError = Pipe()
            try ps.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            out = String(data: data, encoding: .utf8) ?? ""
            print("[DEMUX-FULL] ps exit \(ps.terminationStatus) output len \(out.count)")
        } catch {
            out = "ps failed: \(error)"
            print("[DEMUX-FULL] ps failed: \(error)")
        }
        print("[DEMUX-FULL] ps output after shutdown (first 2000 chars):\n\(String(out.prefix(2000)))")
        let hasOrphan = out.contains("demux_worker") && (out.contains(expectedFullRoot.path) || out.contains(expectedFullRootResolved))
        print("[DEMUX-FULL] orphan check hasOrphan=\(hasOrphan) derived root \(expectedFullRoot.path) resolved \(expectedFullRootResolved)")
        XCTAssertFalse(hasOrphan, "integration-owned Python worker remains for root \(expectedFullRootResolved): \(out.prefix(1000))")
        if hasOrphan { XCTFail("orphan worker remains") }
        print("[DEMUX-FULL] PASS - full separation proof complete")
    }
}
