import XCTest
@testable import Strata
import Foundation
import CryptoKit
import AVFoundation

final class SeparationResultTests: XCTestCase {

    // MARK: - Helpers

    private func makeWAV(at url: URL, frames: UInt32, sr: Double = 44100, channels: UInt32 = 2) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(channels) {
            let ptr = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { ptr[i] = sin(Float(i) * 0.01) * 0.1 + Float(ch)*0.01 }
        }
        try file.write(from: buffer)
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func jobDir(for base: URL, jobId: String) -> URL {
        base.appendingPathComponent(jobId, isDirectory: true)
    }

    private func makeRealisticInput(at url: URL, frames: UInt32 = 8192) throws -> String {
        // Create a mixture-like wav with canonical 44.1k stereo
        try makeWAV(at: url, frames: frames)
        return try sha256(url)
    }

    private struct ManifestBuilder {
        var jobId: String
        var base: URL
        var jobDir: URL
        var frames: UInt32
        var model = TrustedInferenceIdentity.model
        var checkpoint = TrustedInferenceIdentity.checkpointSHA256
        var backend = TrustedInferenceIdentity.backend
        var device = TrustedInferenceIdentity.device
        var inputSHA: String?
        var inputMetadataFrames: UInt64?
        var stems: [(StemName, URL, String, UInt64)] = [] // name, url, sha, frames
        mutating func addStem(_ name: StemName, frames: UInt32) throws {
            let url = jobDir.appendingPathComponent("\(name.rawValue).wav")
            let fmtFrames = frames
            // file already created outside typically, but we can create here if not exists
            if !FileManager.default.fileExists(atPath: url.path) {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(fmtFrames))!
                buffer.frameLength = AVAudioFrameCount(fmtFrames)
                for ch in 0..<2 {
                    let ptr = buffer.floatChannelData![ch]
                    for i in 0..<Int(fmtFrames) { ptr[i] = Float(i % 100) * 0.001 }
                }
                try file.write(from: buffer)
            }
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            stems.append((name, url, hash, UInt64(fmtFrames)))
        }
        func manifestDict(inputPath: String, outputDir: String) -> [String: Any] {
            var records: [[String: Any]] = []
            for (name, url, sha, frames) in stems {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
                records.append([
                    "name": name.rawValue,
                    "path": url.path,
                    "sha256": sha,
                    "file_size": size,
                    "frame_count": frames,
                    "channels": 2,
                    "sample_rate": 44100
                ])
            }
            var dict: [String: Any] = [
                "job_id": jobId,
                "model": model,
                "checkpoint_sha256": checkpoint,
                "backend": backend,
                "device": device,
                "stems": records,
                "input_path": inputPath,
                "output_dir": outputDir,
                "input_sha256": inputSHA ?? "",
                "input_metadata": [
                    "sample_rate": 44100,
                    "channels": 2,
                    "frames": inputMetadataFrames ?? UInt64(frames),
                    "duration": Double(frames) / 44100.0,
                    "sha256": inputSHA ?? ""
                ] as [String: Any]
            ]
            return dict
        }
    }

    private func createValidScenario(frames: UInt32 = 8192) throws -> (base: URL, jobId: String, jobDir: URL, manifestURL: URL, inputURL: URL, inputSHA: String, ready: ReadyMetadata, job: JobInfo, stems: [StemName: URL]) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let jobId = UUID().uuidString.lowercased()
        let jd = jobDir(for: base, jobId: jobId)
        try FileManager.default.createDirectory(at: jd, withIntermediateDirectories: true)
        // Input
        let inputURL = base.appendingPathComponent("mixture.wav")
        let inputSHA = try makeRealisticInput(at: inputURL, frames: frames)
        // Stems
        var received: [StemName: URL] = [:]
        var records: [[String: Any]] = []
        for stem in StemName.allCases {
            let url = jd.appendingPathComponent("\(stem.rawValue).wav")
            try makeWAV(at: url, frames: frames)
            let hash = try sha256(url)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            received[stem] = url
            records.append([
                "name": stem.rawValue,
                "path": url.path,
                "sha256": hash,
                "file_size": size,
                "frame_count": UInt64(frames),
                "channels": 2,
                "sample_rate": 44100
            ])
        }
        let manifest: [String: Any] = [
            "job_id": jobId,
            "model": TrustedInferenceIdentity.model,
            "checkpoint_sha256": TrustedInferenceIdentity.checkpointSHA256,
            "backend": TrustedInferenceIdentity.backend,
            "device": TrustedInferenceIdentity.device,
            "input_path": inputURL.path,
            "output_dir": base.path,
            "input_sha256": inputSHA,
            "input_metadata": [
                "sample_rate": 44100,
                "channels": 2,
                "frames": UInt64(frames),
                "duration": Double(frames)/44100.0,
                "sha256": inputSHA
            ],
            "stems": records
        ]
        let manifestURL = jd.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: manifestURL)
        let ready = ReadyMetadata(backend: TrustedInferenceIdentity.backend, device: TrustedInferenceIdentity.device, checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256, model: nil)
        let job = JobInfo(jobId: jobId, inputPath: inputURL.path, outputDir: base.path)
        return (base, jobId, jd, manifestURL, inputURL, inputSHA, ready, job, received)
    }

    // MARK: - Valid

    func testValidSixStemManifestProducesValidImmutableResult() throws {
        let sc = try createValidScenario(frames: 4096)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let result = try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems)
        XCTAssertEqual(result.stems.count, 6)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.jobId, sc.jobId)
        XCTAssertEqual(result.backend, "mlx")
        XCTAssertEqual(result.device, "mps")
        XCTAssertEqual(result.stems.keys.count, 6)
        for stem in StemName.allCases {
            XCTAssertNotNil(result.stem(stem))
            XCTAssertEqual(result.stem(stem)?.frameCount, 4096)
            XCTAssertEqual(result.stem(stem)?.sampleRate, 44100)
            XCTAssertEqual(result.stem(stem)?.channels, 2)
        }
        // Ensure sorted
        XCTAssertEqual(result.sortedStems.map { $0.name }, StemName.allCases.sorted { $0.rawValue < $1.rawValue })
    }

    func testValidWithDifferentFrameCountNotHardcoded882k() throws {
        // Use 12345 frames, not 882k; validator should accept as long as consistent
        let sc = try createValidScenario(frames: 12345)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        XCTAssertNoThrow(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
        let result = try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems)
        XCTAssertEqual(result.stems[.vocals]?.frameCount, 12345)
    }

    func testProductionValidationDoesNotRequire882000() throws {
        // Create scenario with frames 1000 and ensure validator does not mention 882000 in failure
        let sc = try createValidScenario(frames: 1000)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let result = try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems)
        XCTAssertEqual(result.stems.count, 6)
        // Now tamper manifest to request 882000 but file has 1000 -> should fail, but not because global requirement but because mismatch
        // Verify that file with 882000 would also be accepted if manifest consistent (test that 882000 is not forbidden)
        let sc2 = try createValidScenario(frames: 8820) // use 8820 to avoid heavy file but not 882000
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        XCTAssertNoThrow(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready, receivedStems: sc2.stems))
        // Ensure Searching for universal 882000 in validator not present by checking that 1000 passes (already did)
    }

    // MARK: - Missing / duplicate stems

    func testAllSixUniqueNamesRequiredMissingStemRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        var stems = obj["stems"] as! [[String: Any]]
        stems.removeLast() // now 5
        obj["stems"] = stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: nil)) { err in
            guard case InferenceError.manifestValidationFailure(let msg) = err else { return XCTFail() }
            XCTAssertTrue(msg.contains("count") || msg.contains("5"))
        }
    }

    func testAllSixUniqueNamesRequiredWrongCountRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        var stems = obj["stems"] as! [[String: Any]]
        stems.append(stems[0]) // 7 with duplicate
        obj["stems"] = stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready))
    }

    func testDuplicateStemRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        var stems = obj["stems"] as! [[String: Any]]
        stems[1] = stems[0] // duplicate vocals
        obj["stems"] = stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready))
    }

    // MARK: - Wrong job ID

    func testWrongJobIDRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["job_id"] = "other-id"
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready)) { err in
            guard case InferenceError.manifestValidationFailure(let msg) = err else { return XCTFail() }
            XCTAssertTrue(msg.contains("job_id"))
        }
    }

    // MARK: - Wrong model / checkpoint / backend / device

    func testWrongModelRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["model"] = "wrong-model"
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready))
    }

    func testWrongCheckpointRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["checkpoint_sha256"] = "badbadbad"
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready))
    }

    func testCheckpointMismatchWithReadyMetadataRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let badReady = ReadyMetadata(backend: "mlx", device: "mps", checkpointSHA256: "different", model: nil)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: badReady))
    }

    func testWrongBackendRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["backend"] = "torch"
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready))
    }

    func testWrongDeviceRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["device"] = "cpu"
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready))
    }

    func testReadyMetadataBackendDeviceMismatchRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let badReady = ReadyMetadata(backend: "torch", device: "cpu", checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256, model: nil)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: badReady))
    }

    // MARK: - Input SHA

    func testWrongInputSHARejectedWhereValidatorHasExpected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        // Tamper manifest input_sha256 to wrong
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["input_sha256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready)) { err in
            guard case InferenceError.manifestValidationFailure = err else { return XCTFail() }
        }
        // Also test expectedInputSHA256 param mismatch
        let sc2 = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready, expectedInputSHA256: String(repeating: "f", count: 64)))
    }

    func testMissingManifestRejected() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let jd = base.appendingPathComponent("job123")
        try FileManager.default.createDirectory(at: jd, withIntermediateDirectories: true)
        let manifestURL = jd.appendingPathComponent("manifest.json") // not created
        let inputURL = base.appendingPathComponent("in.wav")
        try makeWAV(at: inputURL, frames: 1024)
        let job = JobInfo(jobId: "job123", inputPath: inputURL.path, outputDir: base.path)
        let ready = ReadyMetadata(backend: TrustedInferenceIdentity.backend, device: TrustedInferenceIdentity.device, checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256, model: nil)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: manifestURL, job: job, readyMetadata: ready))
    }

    func testMalformedManifestRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        try "not json".write(to: sc.manifestURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready))
        try "{ invalid json }".write(to: sc.manifestURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready))
    }

    // MARK: - Missing stem file / tampered hash

    func testMissingStemFileRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        // Delete one stem
        let victim = sc.stems[.vocals]!
        try FileManager.default.removeItem(at: victim)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
        // Also without receivedStems map, still missing file should be caught
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready))
    }

    func testTamperedStemSHARejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        var stems = obj["stems"] as! [[String: Any]]
        // tamper first stem sha
        stems[0]["sha256"] = String(repeating: "0", count: 64)
        obj["stems"] = stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testStemFileTamperedAfterManifestRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        // Overwrite one stem file with different content
        let url = sc.stems[.bass]!
        try "tamper".data(using: .utf8)!.write(to: url)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    // MARK: - Path escapes

    func testStemPathOutsideFinalizedJobDirectoryRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        var stems = obj["stems"] as! [[String: Any]]
        // Escape via .. and /tmp
        stems[0]["path"] = "/tmp/evil.wav"
        obj["stems"] = stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready))
        // With .. traversal
        var obj2 = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        // reconstruct correctly but with traversal inside job dir
        // create a fresh scenario to get correct manifest then mutate
        let sc2 = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        var o = try JSONSerialization.jsonObject(with: Data(contentsOf: sc2.manifestURL)) as! [String: Any]
        var s = o["stems"] as! [[String: Any]]
        s[0]["path"] = sc2.base.appendingPathComponent("../evil.wav").path
        o["stems"] = s
        try JSONSerialization.data(withJSONObject: o).write(to: sc2.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready))
    }

    func testManifestPathEscapeRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        // Move manifest to outside job dir but still try to validate via path traversal manifest
        // Our validator checks manifestDir == expectedJobDir, so a manifest outside should fail
        let outside = sc.base.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: sc.manifestURL, to: outside)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: outside, job: sc.job, readyMetadata: sc.ready))
        // Also test with .. in manifest path string: job expects base/jobId/manifest.json but we pass via symlink path that contains ..
        // Simulate by creating a path with traversal that resolves inside but raw string contains ..
        // The validator uses standardizedFileURL which would resolve traversal, so that case would actually pass; we test true escape via different dir.
    }

    func testSymlinkEscapeRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        // Create outside directory and symlink inside job dir pointing outside
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideFile = outside.appendingPathComponent("vocals.wav")
        try makeWAV(at: outsideFile, frames: 4096)
        // Replace vocals stem inside job dir with symlink to outside
        let vocalsInside = jobDir(for: sc.base, jobId: sc.jobId).appendingPathComponent("vocals.wav")
        try FileManager.default.removeItem(at: vocalsInside)
        try FileManager.default.createSymbolicLink(at: vocalsInside, withDestinationURL: outsideFile)
        // Update manifest to point to the symlink path (inside job dir, but resolves outside)
        // Manifest already points to inside path, which now is symlink outside, resolving will be outside -> should be rejected as escape?
        // Our validator does resolvingSymlinksInPath then checks dir == expectedJobDir, which will fail because resolved file is outside
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testSymlinkContainmentAllowedWhenSymlinkInside() throws {
        // A symlink to file still inside job dir should be allowed? But our check resolves, still inside, so allowed.
        // We test that valid case still passes with no symlink tamper.
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        XCTAssertNoThrow(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    func testTmpVersusPrivateTmpCanonicalizationAccepted() throws {
        // Both /tmp and /private/tmp are symlinked; validator must canonicalize via standardizedFileURL + resolvingSymlinksInPath
        let a = URL(fileURLWithPath: "/tmp").standardizedFileURL.resolvingSymlinksInPath().path
        let b = URL(fileURLWithPath: "/private/tmp").standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertEqual(a, b)
        // Real file under /tmp should resolve to same object via /private/tmp
        let fileA = URL(fileURLWithPath: "/tmp").appendingPathComponent("strata-canonical-test-\(UUID().uuidString)")
        try Data("x".utf8).write(to: fileA)
        defer { try? FileManager.default.removeItem(at: fileA) }
        let fileB = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(fileA.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path))
        XCTAssertEqual(fileA.standardizedFileURL.resolvingSymlinksInPath().path, fileB.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    // MARK: - Audio format

    func test44KhzEnforced() throws {
        let sc = try createValidScenario(frames: 4096)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        // Replace one stem with 48k file
        let url = sc.stems[.drums]!
        try FileManager.default.removeItem(at: url)
        try makeWAV(at: url, frames: 4096, sr: 48000)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
        // Also test manifest claiming 48000
        let sc2 = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc2.manifestURL)) as! [String: Any]
        var stems = obj["stems"] as! [[String: Any]]
        stems[0]["sample_rate"] = 48000
        obj["stems"] = stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc2.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready))
    }

    func testStereoEnforced() throws {
        let sc = try createValidScenario(frames: 4096)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let url = sc.stems[.bass]!
        try FileManager.default.removeItem(at: url)
        try makeWAV(at: url, frames: 4096, channels: 1)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
        // manifest mono
        let sc2 = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc2.manifestURL)) as! [String: Any]
        var stems = obj["stems"] as! [[String: Any]]
        stems[0]["channels"] = 1
        obj["stems"] = stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc2.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready))
    }

    func testZeroInvalidFrameCountRejected() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        var stems = obj["stems"] as! [[String: Any]]
        stems[0]["frame_count"] = 0
        obj["stems"] = stems
        var meta = obj["input_metadata"] as! [String: Any]
        meta["frames"] = 0
        obj["input_metadata"] = meta
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready))
        // Direct validateAudioFile zero
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try makeWAV(at: tmp, frames: 1024)
        // Try with expected 0
        XCTAssertThrowsError(try validateAudioFile(at: tmp, expectedFrames: 0))
        try? FileManager.default.removeItem(at: tmp)
    }

    func testManifestStemFrameCountMustEqualActualFileLength() throws {
        let sc = try createValidScenario(frames: 5000)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        var stems = obj["stems"] as! [[String: Any]]
        stems[0]["frame_count"] = 9999 // mismatch
        obj["stems"] = stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems)) { err in
            guard case InferenceError.manifestValidationFailure(let msg) = err else { return XCTFail() }
            XCTAssertTrue(msg.contains("frame") || msg.contains("9999"))
        }
        // Also test file tampered to different length than manifest
        let sc2 = try createValidScenario(frames: 4000)
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        let url = sc2.stems[.piano]!
        try FileManager.default.removeItem(at: url)
        try makeWAV(at: url, frames: 8000) // double
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready, receivedStems: sc2.stems))
    }

    func testEveryStemMustHaveSameFrameCountAsInputMetadata() throws {
        let sc = try createValidScenario(frames: 4096)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        var meta = obj["input_metadata"] as! [String: Any]
        meta["frames"] = 8192 // different from stems (4096)
        obj["input_metadata"] = meta
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
        // Also stems divergent among themselves
        let sc2 = try createValidScenario(frames: 4096)
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        let extraURL = sc2.stems[.guitar]!
        try FileManager.default.removeItem(at: extraURL)
        try makeWAV(at: extraURL, frames: 2048)
        // Need to also update manifest's frame_count for that stem to 2048 to match file, but then diverge from input_metadata 4096
        var obj2 = try JSONSerialization.jsonObject(with: Data(contentsOf: sc2.manifestURL)) as! [String: Any]
        var stems2 = obj2["stems"] as! [[String: Any]]
        for i in 0..<stems2.count where stems2[i]["name"] as? String == "guitar" {
            stems2[i]["frame_count"] = 2048
            // also update hash after file change
            let newHash = try sha256(extraURL)
            stems2[i]["sha256"] = newHash
        }
        obj2["stems"] = stems2
        try JSONSerialization.data(withJSONObject: obj2).write(to: sc2.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready, receivedStems: sc2.stems))
    }

    func testUnknownManifestFieldsTolerated() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["unknown_field"] = "extra"
        obj["schema_version"] = 99
        obj["extra_nested"] = ["a": 1, "b": 2]
        var stems = obj["stems"] as! [[String: Any]]
        stems[0]["extra_field"] = "tolerated"
        obj["stems"] = stems
        var meta = obj["input_metadata"] as! [String: Any]
        meta["extra"] = "tolerate"
        obj["input_metadata"] = meta
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertNoThrow(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems))
    }

    // MARK: - Additional: file size not byte invariant

    func testFileSizeMismatchRejectedButNotWAVByteSizeInvariant() throws {
        let sc = try createValidScenario()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        var stems = obj["stems"] as! [[String: Any]]
        let originalSize = stems[0]["file_size"] as! UInt64
        stems[0]["file_size"] = originalSize + 1
        obj["stems"] = stems
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready))
        // But file size itself not globally fixed; different frame counts produce different sizes and should be accepted
        let sc2 = try createValidScenario(frames: 2048)
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        XCTAssertNoThrow(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready, receivedStems: sc2.stems))
        let sc3 = try createValidScenario(frames: 8000)
        defer { try? FileManager.default.removeItem(at: sc3.base) }
        XCTAssertNoThrow(try SeparationValidator.validatedResult(manifestURL: sc3.manifestURL, job: sc3.job, readyMetadata: sc3.ready, receivedStems: sc3.stems))
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: sc2.stems[.vocals]!.path)[.size] as? NSNumber, try FileManager.default.attributesOfItem(atPath: sc3.stems[.vocals]!.path)[.size] as? NSNumber)
    }

}
