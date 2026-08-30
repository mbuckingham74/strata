import XCTest
@testable import Demux
import Foundation
import CryptoKit
import AVFoundation

/// Focused regression for Luna Blocker 1 — native trust anchor pinning
final class SeparationResultTrustedIdentityTests: XCTestCase {

    private func makeWAV(at url: URL, frames: UInt32) throws {
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

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func createValidScenarioWithTrustedIdentity(frames: UInt32 = 2048) throws -> (base: URL, jobId: String, jobDir: URL, manifestURL: URL, inputURL: URL, inputSHA: String, ready: ReadyMetadata, job: JobInfo, stems: [StemName: URL]) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let jobId = UUID().uuidString.lowercased()
        let jd = base.appendingPathComponent(jobId, isDirectory: true)
        try FileManager.default.createDirectory(at: jd, withIntermediateDirectories: true)
        let inputURL = base.appendingPathComponent("mixture.wav")
        try makeWAV(at: inputURL, frames: frames)
        let inputSHA = try sha256(inputURL)
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

    // 1. exact pinned model + checkpoint accepted
    func testExactPinnedModelAndCheckpointAccepted() throws {
        let sc = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        // Should validate with trusted identity and native precomputed SHA
        XCTAssertNoThrow(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems, expectedInputSHA256: sc.inputSHA))
        let result = try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems, expectedInputSHA256: sc.inputSHA)
        XCTAssertEqual(result.model, TrustedInferenceIdentity.model)
        XCTAssertEqual(result.checkpointSHA256.lowercased(), TrustedInferenceIdentity.checkpointSHA256.lowercased())
        XCTAssertEqual(result.backend, TrustedInferenceIdentity.backend)
        XCTAssertEqual(result.device, TrustedInferenceIdentity.device)
    }

    // 2. manifest model missing => rejected
    func testManifestModelMissingRejected() throws {
        let sc = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj.removeValue(forKey: "model")
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, expectedInputSHA256: sc.inputSHA)) { err in
            guard case InferenceError.manifestValidationFailure(let msg) = err else { return XCTFail("wrong error \(err)") }
            XCTAssertTrue(msg.lowercased().contains("model"))
        }
    }

    // 3. wrong model => rejected
    func testWrongModelRejected() throws {
        let sc = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["model"] = "wrong-model-xyz"
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, expectedInputSHA256: sc.inputSHA))
    }

    // 4. checkpoint SHA missing => rejected
    func testCheckpointMissingRejected() throws {
        let sc = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj.removeValue(forKey: "checkpoint_sha256")
        // Also try missing alternate key already absent
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, expectedInputSHA256: sc.inputSHA)) { err in
            guard case InferenceError.manifestValidationFailure(let msg) = err else { return XCTFail() }
            XCTAssertTrue(msg.lowercased().contains("checkpoint"))
        }
    }

    // 5. wrong checkpoint SHA => rejected
    func testWrongCheckpointRejected() throws {
        let sc = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["checkpoint_sha256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, expectedInputSHA256: sc.inputSHA))
        // Wrong but case variation should still be wrong if not equal trusted
        var obj2 = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        // restore valid then set wrong with different value
        obj2["checkpoint_sha256"] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        try JSONSerialization.data(withJSONObject: obj2).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, expectedInputSHA256: sc.inputSHA))
    }

    // 6. backend missing/wrong => rejected
    func testBackendMissingOrWrongRejected() throws {
        let sc = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["backend"] = "torch"
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, expectedInputSHA256: sc.inputSHA))

        // Missing backend: remove key -> decode fails => manifestValidationFailure
        let sc2 = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        var obj2 = try JSONSerialization.jsonObject(with: Data(contentsOf: sc2.manifestURL)) as! [String: Any]
        obj2.removeValue(forKey: "backend")
        try JSONSerialization.data(withJSONObject: obj2).write(to: sc2.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready, expectedInputSHA256: sc2.inputSHA))

        // Ready backend wrong also rejected
        let badReady = ReadyMetadata(backend: "torch", device: TrustedInferenceIdentity.device, checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256, model: nil)
        let sc3 = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc3.base) }
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc3.manifestURL, job: sc3.job, readyMetadata: badReady, expectedInputSHA256: sc3.inputSHA))
    }

    // 7. device missing/wrong => rejected
    func testDeviceMissingOrWrongRejected() throws {
        let sc = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["device"] = "cpu"
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, expectedInputSHA256: sc.inputSHA))

        let sc2 = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        var obj2 = try JSONSerialization.jsonObject(with: Data(contentsOf: sc2.manifestURL)) as! [String: Any]
        obj2.removeValue(forKey: "device")
        try JSONSerialization.data(withJSONObject: obj2).write(to: sc2.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready, expectedInputSHA256: sc2.inputSHA))

        let badReady = ReadyMetadata(backend: TrustedInferenceIdentity.backend, device: "cpu", checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256, model: nil)
        let sc3 = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc3.base) }
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc3.manifestURL, job: sc3.job, readyMetadata: badReady, expectedInputSHA256: sc3.inputSHA))
    }

    // 8. input SHA missing => rejected
    func testInputSHAMissingRejected() throws {
        let sc = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj.removeValue(forKey: "input_sha256")
        // Also remove from input_metadata sha to avoid metadata check passing
        var meta = obj["input_metadata"] as! [String: Any]
        meta.removeValue(forKey: "sha256")
        obj["input_metadata"] = meta
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, expectedInputSHA256: sc.inputSHA)) { err in
            guard case InferenceError.manifestValidationFailure(let msg) = err else { return XCTFail() }
            XCTAssertTrue(msg.lowercased().contains("input"))
        }
        // Empty string also treated as missing
        let sc2 = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        var obj2 = try JSONSerialization.jsonObject(with: Data(contentsOf: sc2.manifestURL)) as! [String: Any]
        obj2["input_sha256"] = ""
        try JSONSerialization.data(withJSONObject: obj2).write(to: sc2.manifestURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready, expectedInputSHA256: sc2.inputSHA))
    }

    // 9. manifest input SHA differing from native precomputed input SHA => rejected
    func testManifestInputSHADifferingFromNativePrecomputedRejected() throws {
        let sc = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        // Native precomputed is sc.inputSHA (hash of mixture.wav before job)
        // Mutate manifest to different SHA
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["input_sha256"] = String(repeating: "f", count: 64)
        var meta = obj["input_metadata"] as! [String: Any]
        meta["sha256"] = String(repeating: "f", count: 64)
        obj["input_metadata"] = meta
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        // Pass expected = native precomputed (sc.inputSHA) which differs from manifest
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, expectedInputSHA256: sc.inputSHA))

        // Also test native file mutation: change file after expected capture, actual != expected => rejected
        let sc2 = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc2.base) }
        // Tamper input file after capture
        try "mutated".data(using: .utf8)!.write(to: sc2.inputURL)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc2.manifestURL, job: sc2.job, readyMetadata: sc2.ready, expectedInputSHA256: sc2.inputSHA))
        // Also test manifest correct but expected differs (future input)
        let sc3 = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc3.base) }
        let otherSHA = String(repeating: "1", count: 64)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc3.manifestURL, job: sc3.job, readyMetadata: sc3.ready, expectedInputSHA256: otherSHA))
    }

    // 10. worker ready + manifest can BOTH consistently advertise same bogus checkpoint and native STILL rejects
    func testBogusCheckpointEvenWhenWorkerAndManifestAgreeRejected() throws {
        let sc = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        let bogus = String(repeating: "b", count: 64)
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["checkpoint_sha256"] = bogus
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        let bogusReady = ReadyMetadata(backend: TrustedInferenceIdentity.backend, device: TrustedInferenceIdentity.device, checkpointSHA256: bogus, model: nil)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: bogusReady, expectedInputSHA256: sc.inputSHA)) { err in
            guard case InferenceError.manifestValidationFailure(let msg) = err else { return XCTFail() }
            XCTAssertTrue(msg.lowercased().contains("checkpoint"))
        }
        // Also test both bogus but different from trusted anchor, even if they match each other
        let bogus2 = String(repeating: "c", count: 64)
        var obj2 = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj2["checkpoint_sha256"] = bogus2
        try JSONSerialization.data(withJSONObject: obj2).write(to: sc.manifestURL)
        let bogusReady2 = ReadyMetadata(backend: TrustedInferenceIdentity.backend, device: TrustedInferenceIdentity.device, checkpointSHA256: bogus2, model: nil)
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: bogusReady2, expectedInputSHA256: sc.inputSHA))
    }

    // 11. correct canonical fixture identity still validates (trusted model+checkpoint+inputSHA)
    func testCorrectCanonicalFixtureIdentityStillValidates() throws {
        let sc = try createValidScenarioWithTrustedIdentity(frames: 4096)
        defer { try? FileManager.default.removeItem(at: sc.base) }
        // Ensure trusted values match what validator expects
        XCTAssertEqual(TrustedInferenceIdentity.model, "roformer-model-bs-roformer-sw-by-jarredou")
        XCTAssertEqual(TrustedInferenceIdentity.checkpointSHA256, "24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e")
        // Validate with expectedInputSHA256 = actual file SHA (native capture)
        let computedSHA = try sha256(sc.inputURL)
        XCTAssertEqual(computedSHA.lowercased(), sc.inputSHA.lowercased())
        let result = try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems, expectedInputSHA256: computedSHA)
        XCTAssertEqual(result.model, TrustedInferenceIdentity.model)
        XCTAssertEqual(result.checkpointSHA256.lowercased(), TrustedInferenceIdentity.checkpointSHA256.lowercased())
        // Also ensure backend/device correct
        XCTAssertEqual(result.backend, "mlx")
        XCTAssertEqual(result.device, "mps")
        // Ensure stems complete
        XCTAssertEqual(result.stems.count, 6)
    }

    // 12. unknown extra manifest fields remain tolerated
    func testUnknownExtraManifestFieldsTolerated() throws {
        let sc = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sc.manifestURL)) as! [String: Any]
        obj["unknown_field"] = "extra"
        obj["schema_version"] = 99
        obj["extra_nested"] = ["a": 1, "b": 2]
        var stems = obj["stems"] as! [[String: Any]]
        stems[0]["extra_field"] = "tolerated"
        stems[1]["another_unknown"] = 12345
        obj["stems"] = stems
        var meta = obj["input_metadata"] as! [String: Any]
        meta["extra"] = "tolerate"
        obj["input_metadata"] = meta
        // Also top-level extra
        obj["future_field"] = ["x": true]
        try JSONSerialization.data(withJSONObject: obj).write(to: sc.manifestURL)
        XCTAssertNoThrow(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, receivedStems: sc.stems, expectedInputSHA256: sc.inputSHA))
    }

    // Additional: ensure input SHA mutation during job is detected when expected was captured before
    func testInputMutationDuringJobDetectedViaExpected() throws {
        let sc = try createValidScenarioWithTrustedIdentity()
        defer { try? FileManager.default.removeItem(at: sc.base) }
        // Capture expected before mutation
        let expectedBefore = sc.inputSHA
        // Mutate file
        try makeWAV(at: sc.inputURL, frames: 9999)
        let mutatedSHA = try sha256(sc.inputURL)
        XCTAssertNotEqual(expectedBefore.lowercased(), mutatedSHA.lowercased())
        // Validator with expectedBefore vs mutated file should reject
        XCTAssertThrowsError(try SeparationValidator.validatedResult(manifestURL: sc.manifestURL, job: sc.job, readyMetadata: sc.ready, expectedInputSHA256: expectedBefore))
        // Also manifest was created with old SHA, so actual file mismatch also triggers
    }
}
