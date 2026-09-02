import XCTest
@testable import Strata
import Foundation

final class RuntimeReadinessModelTests: XCTestCase {

    private func makeWorkerConfig(pythonPath: String = "/tmp/worker/.venv/bin/python3") -> WorkerLaunchConfiguration {
        let dir = URL(fileURLWithPath: "/tmp/worker")
        return WorkerLaunchConfiguration(
            workerDirectory: dir,
            pythonExecutable: URL(fileURLWithPath: pythonPath),
            arguments: ["-m", "demux_worker"],
            currentDirectory: dir,
            environmentAdditions: ["PYTHONUNBUFFERED": "1"]
        )
    }

    private func makeChecker(
        modelsRoot: URL,
        existingPaths: Set<String>,
        sizes: [String: Int64],
        hashes: [String: String]? = nil,
        workerAvailable: Bool = true
    ) -> RuntimeReadinessChecker {
        let config = makeWorkerConfig()
        let checkpoint = TrustedInferenceIdentity.checkpointURL(modelsRoot: modelsRoot).path
        let configPath = TrustedInferenceIdentity.configURL(modelsRoot: modelsRoot).path
        let resolvedHashes = hashes ?? [
            checkpoint: TrustedInferenceIdentity.checkpointSHA256,
            configPath: TrustedInferenceIdentity.configSHA256,
        ]
        return RuntimeReadinessChecker(
            isExecutable: { path in
                if path == RuntimeReadiness.ffmpegPath { return true }
                if path == RuntimeReadiness.ytDlpPath { return true }
                if path == RuntimeReadiness.nodePath { return true }
                if path == config.pythonExecutable.path { return workerAvailable }
                return false
            },
            resolveWorker: { config },
            fileExists: { existingPaths.contains($0) },
            fileSize: { sizes[$0] },
            fileSHA256: { resolvedHashes[$0] },
            modelsRoot: modelsRoot
        )
    }

    private func canonicalPaths(modelsRoot: URL) -> (checkpoint: String, config: String) {
        (
            TrustedInferenceIdentity.checkpointURL(modelsRoot: modelsRoot).path,
            TrustedInferenceIdentity.configURL(modelsRoot: modelsRoot).path
        )
    }

    func testCanonicalIdentityMirrorsWorkerConstants() {
        XCTAssertEqual(TrustedInferenceIdentity.model, "roformer-model-bs-roformer-sw-by-jarredou")
        XCTAssertEqual(TrustedInferenceIdentity.checkpointFilename, "BS-Rofo-SW-Fixed.ckpt")
        XCTAssertEqual(TrustedInferenceIdentity.checkpointBytes, 699_412_152)
        XCTAssertEqual(TrustedInferenceIdentity.checkpointSHA256, "24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e")
        XCTAssertEqual(TrustedInferenceIdentity.configFilename, "BS-Rofo-SW-Fixed.yaml")
        XCTAssertEqual(TrustedInferenceIdentity.configBytes, 4613)
        XCTAssertEqual(TrustedInferenceIdentity.configSHA256, "f9fada9f94e5ba2d2e4600196299459294bc5f532b314c209cc156ac63e4329b")
    }

    func testCanonicalPathsLiveUnderModelsRoot() {
        let root = URL(fileURLWithPath: "/tmp/DemuxModelsTest", isDirectory: true)
        let checkpoint = TrustedInferenceIdentity.checkpointURL(modelsRoot: root).path
        let config = TrustedInferenceIdentity.configURL(modelsRoot: root).path
        XCTAssertEqual(checkpoint, root.appendingPathComponent("\(TrustedInferenceIdentity.model)/\(TrustedInferenceIdentity.checkpointFilename)").path)
        XCTAssertEqual(config, root.appendingPathComponent("\(TrustedInferenceIdentity.model)/\(TrustedInferenceIdentity.configFilename)").path)
    }

    func testMissingFiles_reportsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checker = makeChecker(modelsRoot: root, existingPaths: [], sizes: [:], workerAvailable: true)
        let r = checker.check()
        XCTAssertFalse(r.modelAvailable)
        XCTAssertNotNil(r.modelError)
        XCTAssertTrue(r.modelError!.contains("missing"))
        XCTAssertTrue(r.workerAvailable, "model missing must not affect workerAvailable")
        XCTAssertEqual(r.modelCheckpointPath, TrustedInferenceIdentity.checkpointURL(modelsRoot: root).path)
    }

    func testValidStubbedFiles_reportsAvailableIndependentOfWorker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (ckpt, cfg) = canonicalPaths(modelsRoot: root)
        // Create empty sentinel files so existence is real; sizes are stubbed to avoid writing 700MB.
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: ckpt).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: ckpt), options: .atomic)
        try Data().write(to: URL(fileURLWithPath: cfg), options: .atomic)
        let sizes: [String: Int64] = [
            ckpt: TrustedInferenceIdentity.checkpointBytes,
            cfg: TrustedInferenceIdentity.configBytes,
        ]
        let withWorker = makeChecker(modelsRoot: root, existingPaths: [ckpt, cfg], sizes: sizes, workerAvailable: true).check()
        XCTAssertTrue(withWorker.modelAvailable)
        XCTAssertNil(withWorker.modelError)
        XCTAssertEqual(withWorker.modelCheckpointPath, ckpt)

        let withoutWorker = makeChecker(modelsRoot: root, existingPaths: [ckpt, cfg], sizes: sizes, workerAvailable: false).check()
        XCTAssertTrue(withoutWorker.modelAvailable, "model readiness must be independent of workerAvailable")
        XCTAssertFalse(withoutWorker.workerAvailable)
        XCTAssertNil(withoutWorker.modelError)
    }

    func testCheckpointSizeMismatch_reportsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (ckpt, cfg) = canonicalPaths(modelsRoot: root)
        let sizes: [String: Int64] = [
            ckpt: TrustedInferenceIdentity.checkpointBytes - 1,
            cfg: TrustedInferenceIdentity.configBytes,
        ]
        let r = makeChecker(modelsRoot: root, existingPaths: [ckpt, cfg], sizes: sizes).check()
        XCTAssertFalse(r.modelAvailable)
        XCTAssertNotNil(r.modelError)
        XCTAssertTrue(r.modelError!.contains("mismatch"))
        XCTAssertEqual(r.modelCheckpointPath, ckpt)
    }

    func testConfigSizeMismatch_reportsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (ckpt, cfg) = canonicalPaths(modelsRoot: root)
        let sizes: [String: Int64] = [
            ckpt: TrustedInferenceIdentity.checkpointBytes,
            cfg: 0,
        ]
        let r = makeChecker(modelsRoot: root, existingPaths: [ckpt, cfg], sizes: sizes).check()
        XCTAssertFalse(r.modelAvailable)
        XCTAssertTrue((r.modelError ?? "").contains("mismatch"))
    }

    func testMissingConfig_reportsUnavailableWithDetails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (ckpt, _) = canonicalPaths(modelsRoot: root)
        let r = makeChecker(
            modelsRoot: root,
            existingPaths: [ckpt],
            sizes: [ckpt: TrustedInferenceIdentity.checkpointBytes]
        ).check()
        XCTAssertFalse(r.modelAvailable)
        XCTAssertTrue((r.modelError ?? "").contains("config"))
    }

    func testSameSizeWrongCheckpointContent_reportsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (ckpt, cfg) = canonicalPaths(modelsRoot: root)
        let sizes: [String: Int64] = [
            ckpt: TrustedInferenceIdentity.checkpointBytes,
            cfg: TrustedInferenceIdentity.configBytes,
        ]
        let hashes: [String: String] = [
            ckpt: String(repeating: "0", count: 64),
            cfg: TrustedInferenceIdentity.configSHA256,
        ]
        let r = makeChecker(modelsRoot: root, existingPaths: [ckpt, cfg], sizes: sizes, hashes: hashes).check()
        XCTAssertFalse(r.modelAvailable)
        XCTAssertTrue((r.modelError ?? "").contains("hash"))
        XCTAssertEqual(r.modelCheckpointPath, ckpt)
    }

    func testSameSizeWrongConfigContent_reportsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (ckpt, cfg) = canonicalPaths(modelsRoot: root)
        let sizes: [String: Int64] = [
            ckpt: TrustedInferenceIdentity.checkpointBytes,
            cfg: TrustedInferenceIdentity.configBytes,
        ]
        let hashes: [String: String] = [
            ckpt: TrustedInferenceIdentity.checkpointSHA256,
            cfg: String(repeating: "1", count: 64),
        ]
        let r = makeChecker(modelsRoot: root, existingPaths: [ckpt, cfg], sizes: sizes, hashes: hashes).check()
        XCTAssertFalse(r.modelAvailable)
        XCTAssertTrue((r.modelError ?? "").contains("hash"))
    }
}
