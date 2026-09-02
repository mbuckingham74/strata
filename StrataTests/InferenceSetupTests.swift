import XCTest
@testable import Strata
import Foundation
import Darwin

// MARK: - Sendable boxes for closure capture

private final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
    func set(_ v: Int) { lock.lock(); _value = v; lock.unlock() }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: URL?
    var value: URL? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ url: URL?) { lock.lock(); _value = url; lock.unlock() }
}

private final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ s: String?) { lock.lock(); _value = s; lock.unlock() }
}

// MARK: - Helpers to make readiness

private func makeWorkerConfig(pythonPath: String = "/tmp/fakeWorker/.venv/bin/python3") -> WorkerLaunchConfiguration {
    let dir = URL(fileURLWithPath: "/tmp/fakeWorker")
    let python = URL(fileURLWithPath: pythonPath)
    return WorkerLaunchConfiguration(
        workerDirectory: dir,
        pythonExecutable: python,
        arguments: ["-m", "demux_worker"],
        currentDirectory: dir,
        environmentAdditions: ["PYTHONUNBUFFERED": "1"]
    )
}

private func makeReadiness(workerAvailable: Bool, ffmpegAvailable: Bool = true, ytDlpAvailable: Bool = true, nodeAvailable: Bool = true, pythonPath: String = "/tmp/fakeWorker/.venv/bin/python3") -> RuntimeReadiness {
    RuntimeReadiness(
        workerAvailable: workerAvailable,
        workerError: workerAvailable ? nil : "python not executable at \(pythonPath)",
        workerPythonPath: pythonPath,
        ffmpegAvailable: ffmpegAvailable,
        ytDlpAvailable: ytDlpAvailable,
        nodeAvailable: nodeAvailable
    )
}

private func makeChecker(workerAvailable: Bool, ffmpegAvailable: Bool = true, ytDlpAvailable: Bool = true, nodeAvailable: Bool = true, pythonPath: String = "/tmp/fakeWorker/.venv/bin/python3") -> RuntimeReadinessChecker {
    let cfg = makeWorkerConfig(pythonPath: pythonPath)
    return RuntimeReadinessChecker(
        isExecutable: { path in
            if path == RuntimeReadiness.ffmpegPath { return ffmpegAvailable }
            if path == RuntimeReadiness.ytDlpPath { return ytDlpAvailable }
            if path == RuntimeReadiness.nodePath { return nodeAvailable }
            if path == pythonPath { return workerAvailable }
            return false
        },
        resolveWorker: { cfg }
    )
}

@MainActor
final class InferenceSetupTests: XCTestCase {

    // MARK: - needsSetup

    func testNeedsSetup_falseWhenChecking() async {
        let controller = InferenceController()
        XCTAssertNil(controller.runtimeReadiness)
        XCTAssertFalse(controller.needsSetup, "nil readiness (checking) must not request setup")
        XCTAssertFalse(controller.setupStage.isFailed)
        XCTAssertEqual(controller.setupStage, .idle)
    }

    func testNeedsSetup_trueWhenWorkerNotReady() async {
        let controller = InferenceController()
        let checker = makeChecker(workerAvailable: false)
        await controller.refreshRuntimeReadiness(checker: checker)
        XCTAssertNotNil(controller.runtimeReadiness)
        XCTAssertFalse(controller.isWorkerReady)
        XCTAssertTrue(controller.needsSetup)
    }

    func testNeedsSetup_falseWhenWorkerReady() async {
        let controller = InferenceController()
        let checker = makeChecker(workerAvailable: true)
        await controller.refreshRuntimeReadiness(checker: checker)
        XCTAssertTrue(controller.isWorkerReady)
        XCTAssertFalse(controller.needsSetup)
    }

    // MARK: - runSetup success path

    func testRunSetupSuccess_callsEnsureProvisionRefresh_andEndsIdleReady() async {
        let controller = InferenceController()
        // Start not-ready so needsSetup true
        let notReady = makeChecker(workerAvailable: false)
        await controller.refreshRuntimeReadiness(checker: notReady)
        XCTAssertTrue(controller.needsSetup)

        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let ensureCount = CountBox()
        let provisionCount = CountBox()
        let provisionURL = URLBox()
        let refreshCount = CountBox()
        let readyChecker = makeChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        await controller.runSetup(
            ensureUvAvailable: {
                ensureCount.increment()
                return .success(uvURL)
            },
            provisionWorker: { url in
                provisionCount.increment()
                provisionURL.set(url)
                return .success
            },
            refreshReadiness: {
                refreshCount.increment()
                await ctrl.refreshRuntimeReadiness(checker: readyChecker)
            }
        )

        XCTAssertEqual(ensureCount.value, 1)
        XCTAssertEqual(provisionCount.value, 1)
        XCTAssertEqual(provisionURL.value, uvURL, "provision must receive resolved uv URL")
        XCTAssertEqual(refreshCount.value, 1, "refresh must be called once on success")
        XCTAssertEqual(controller.setupStage, .idle)
        XCTAssertNil(controller.setupErrorMessage)
        XCTAssertTrue(controller.isWorkerReady)
        XCTAssertFalse(controller.needsSetup)
        XCTAssertFalse(controller.isSetupInProgress)
    }

    // MARK: - runSetup failure when ensureAvailable fails

    func testRunSetupEnsureFails_showsFailedAndDoesNotCallProvisionOrRefresh_tryAgainSucceeds() async {
        let controller = InferenceController()
        let notReady = makeChecker(workerAvailable: false)
        await controller.refreshRuntimeReadiness(checker: notReady)

        let ensureCount = CountBox()
        let provisionCount = CountBox()
        let refreshCount = CountBox()
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let readyChecker = makeChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        // First attempt fails at ensure
        await controller.runSetup(
            ensureUvAvailable: {
                ensureCount.increment()
                return .failure(.installFailed(exitCode: 1, message: "network down"))
            },
            provisionWorker: { _ in
                provisionCount.increment()
                return .success
            },
            refreshReadiness: {
                refreshCount.increment()
                await ctrl.refreshRuntimeReadiness(checker: readyChecker)
            }
        )

        XCTAssertEqual(ensureCount.value, 1)
        XCTAssertEqual(provisionCount.value, 0, "provision must NOT be called when ensure fails")
        XCTAssertEqual(refreshCount.value, 0, "refresh must NOT be called when ensure fails")
        XCTAssertTrue(controller.setupStage.isFailed)
        XCTAssertNotNil(controller.setupErrorMessage)
        XCTAssertTrue(controller.setupErrorMessage?.contains("network down") ?? false)
        XCTAssertFalse(controller.isWorkerReady)
        XCTAssertFalse(controller.isSetupInProgress)

        // Try Again (second call) succeeds
        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            provisionWorker: { _ in .success },
            refreshReadiness: {
                await ctrl.refreshRuntimeReadiness(checker: readyChecker)
            }
        )
        XCTAssertEqual(controller.setupStage, .idle)
        XCTAssertTrue(controller.isWorkerReady)
    }

    // MARK: - runSetup failure when provision fails (syncFailed) with truncation + Try Again

    func testRunSetupProvisionSyncFailed_showsFailedTruncatedAndDoesNotRefresh_tryAgainWorks() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: makeChecker(workerAvailable: false))

        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let longMsg = String(repeating: "x", count: 600)
        let refreshCount = CountBox()
        nonisolated(unsafe) let ctrl = controller
        let readyChecker = makeChecker(workerAvailable: true)

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            provisionWorker: { _ in .failure(.syncFailed(exitCode: 1, message: longMsg)) },
            refreshReadiness: {
                refreshCount.increment()
                await ctrl.refreshRuntimeReadiness(checker: readyChecker)
            }
        )

        XCTAssertTrue(controller.setupStage.isFailed)
        XCTAssertEqual(refreshCount.value, 0, "refresh must NOT be called when provision fails")
        if case .failed(let msg) = controller.setupStage {
            XCTAssertLessThanOrEqual(msg.count, 500, "error must be truncated to 500")
            XCTAssertTrue(msg.contains("uv sync failed") || msg.contains("x"))
        } else {
            XCTFail("expected failed stage")
        }
        XCTAssertFalse(controller.isSetupInProgress)

        // Try Again succeeds
        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            provisionWorker: { _ in .success },
            refreshReadiness: { await ctrl.refreshRuntimeReadiness(checker: readyChecker) }
        )
        XCTAssertEqual(controller.setupStage, .idle)
        XCTAssertTrue(controller.isWorkerReady)
    }

    func testRunSetupProvisionPrepareModelFailed_truncatedAndDoesNotRefresh() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: makeChecker(workerAvailable: false))
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let longMsg = String(repeating: "y", count: 700)
        let refreshCount = CountBox()
        nonisolated(unsafe) let ctrl = controller
        let readyChecker = makeChecker(workerAvailable: true)

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            provisionWorker: { _ in .failure(.prepareModelFailed(exitCode: 2, message: longMsg)) },
            refreshReadiness: {
                refreshCount.increment()
                await ctrl.refreshRuntimeReadiness(checker: readyChecker)
            }
        )

        XCTAssertTrue(controller.setupStage.isFailed)
        XCTAssertEqual(refreshCount.value, 0)
        if case .failed(let msg) = controller.setupStage {
            XCTAssertLessThanOrEqual(msg.count, 500)
            XCTAssertTrue(msg.contains("prepare-model") || msg.contains("y"))
        } else { XCTFail("expected failed") }

        // Try Again works
        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            provisionWorker: { _ in .success },
            refreshReadiness: { await ctrl.refreshRuntimeReadiness(checker: readyChecker) }
        )
        XCTAssertEqual(controller.setupStage, .idle)
    }

    // MARK: - runSetup failure when refresh leaves not ready

    func testRunSetupRefreshLeavesNotReady_showsFailedWithSidebarHint() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: makeChecker(workerAvailable: false))
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        // ready checker that still reports not ready (ffmpeg available but worker not)
        let stillNotReady = makeChecker(workerAvailable: false, ffmpegAvailable: true)
        // Capture sidebarStatus for hint
        let expectedHint = stillNotReady.check().sidebarStatus
        nonisolated(unsafe) let ctrl = controller

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            provisionWorker: { _ in .success },
            refreshReadiness: {
                await ctrl.refreshRuntimeReadiness(checker: stillNotReady)
            }
        )

        XCTAssertTrue(controller.setupStage.isFailed)
        XCTAssertFalse(controller.isWorkerReady)
        // Hint should be sidebarStatus prefix truncated to 500
        if case .failed(let msg) = controller.setupStage {
            XCTAssertEqual(msg, String(expectedHint.prefix(500)))
            XCTAssertTrue(msg.contains("Setup needed") || msg.contains("worker"))
        } else { XCTFail("expected failed") }
        XCTAssertFalse(controller.isSetupInProgress)
    }

    // MARK: - setupStage progresses truthfully

    func testSetupStageProgressesThroughCheckingInstallingPreparingFinalizingToIdle() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: makeChecker(workerAvailable: false))
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let readyChecker = makeChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        // Collect observed stages by polling during runSetup
        let observedBox = StringBox()
        var observed: [InferenceSetupStage] = []
        // Use delays inside closures to make intermediate stages observable
        let ensureDelay: UInt64 = 80_000_000 // 80ms
        let provisionDelay: UInt64 = 80_000_000
        let refreshDelay: UInt64 = 80_000_000

        // Launch runSetup in a Task so we can poll
        let task = Task {
            await ctrl.runSetup(
                ensureUvAvailable: {
                    // Simulate work - usleep is sync and allowed in async contexts (Swift 6 bans Thread.sleep)
                    usleep(UInt32(ensureDelay / 1_000))
                    return .success(uvURL)
                },
                provisionWorker: { url in
                    usleep(UInt32(provisionDelay / 1_000))
                    // Verify uv correct
                    observedBox.set(url.path)
                    return .success
                },
                refreshReadiness: {
                    usleep(UInt32(refreshDelay / 1_000))
                    await ctrl.refreshRuntimeReadiness(checker: readyChecker)
                }
            )
        }

        // Poll stage transitions
        // Don't break on initial idle; require having seen checkingTools first so early idle doesn't cause missed stages
        for _ in 0..<200 {
            let stage = controller.setupStage
            if observed.isEmpty || observed.last != stage {
                observed.append(stage)
            }
            if observed.contains(.checkingTools) && controller.setupStage == .idle && !controller.isSetupInProgress { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
            if task.isCancelled { break }
        }
        await task.value
        // Final poll
        if observed.last != controller.setupStage {
            observed.append(controller.setupStage)
        }

        // Verify uv passed correctly
        XCTAssertEqual(observedBox.value, uvURL.path)

        // Verify truthful progression: checkingTools -> provisioning -> finalizing -> idle (single opaque provisioning stage)
        let filtered = observed // already unique by insertion
        XCTAssertTrue(filtered.contains(.checkingTools), "must observe checkingTools, got \(filtered)")
        XCTAssertTrue(filtered.contains(.provisioning), "must observe provisioning, got \(filtered)")
        XCTAssertTrue(filtered.contains(.finalizing), "must observe finalizing, got \(filtered)")
        XCTAssertEqual(filtered.last, .idle)

        // Verify order: indices increasing for required stages (use last idle after finalizing, ignore initial idle)
        func idx(_ s: InferenceSetupStage) -> Int? { filtered.firstIndex(of: s) }
        if let a = idx(.checkingTools), let b = idx(.provisioning), let d = idx(.finalizing), let e = filtered.lastIndex(of: .idle) {
            XCTAssertTrue(a < b && b < d && d < e, "order must be checking -> provisioning -> finalizing -> idle, got \(filtered)")
        } else {
            XCTFail("missing required stage in observed \(filtered)")
        }
    }

    // MARK: - isSetupInProgress prevents re-entrance

    func testIsSetupInProgress_preventsReentrance() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: makeChecker(workerAvailable: false))
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let ensureCount = CountBox()
        let readyChecker = makeChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        // First runSetup will sleep inside provision to stay in-progress
        let task = Task {
            await ctrl.runSetup(
                ensureUvAvailable: {
                    ensureCount.increment()
                    usleep(150_000)
                    return .success(uvURL)
                },
                provisionWorker: { _ in
                    usleep(150_000)
                    return .success
                },
                refreshReadiness: {
                    await ctrl.refreshRuntimeReadiness(checker: readyChecker)
                }
            )
        }

        // Wait until in-progress
        for _ in 0..<20 {
            if controller.isSetupInProgress { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(controller.isSetupInProgress, "first runSetup should be in progress")

        // Second call while in progress should be ignored
        await controller.runSetup(
            ensureUvAvailable: {
                ensureCount.increment()
                return .success(uvURL)
            },
            provisionWorker: { _ in .success },
            refreshReadiness: { await ctrl.refreshRuntimeReadiness(checker: readyChecker) }
        )
        // ensureCount should still be 1 because second call was ignored before increment
        XCTAssertEqual(ensureCount.value, 1, "second runSetup while in progress must be ignored")

        await task.value
        XCTAssertFalse(controller.isSetupInProgress)
        XCTAssertEqual(controller.setupStage, .idle)
    }

    // MARK: - Do NOT disturb Library/session

    func testNeedsSetupDoesNotAffectSessionStoreProjects() async {
        // Create isolated persistence root to avoid touching real Documents
        let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmpRoot)
        let sessionStore = SessionStore(persistence: persistence)
        XCTAssertEqual(sessionStore.projects.count, 0)

        // Create a dummy project to ensure projects not cleared by inference setup
        let project = try! StrataProject(
            schemaVersion: 1,
            id: UUID().uuidString.lowercased(),
            createdAt: Date(),
            lastOpenedAt: Date(),
            displayTitle: "Keep Me",
            source: StrataProjectSource(kind: .localFile, locator: "/tmp/some.wav", metadata: nil),
            gains: makeGains()
        )
        // Create minimal assets so persist succeeds
        let input = tmpRoot.appendingPathComponent("input.wav")
        let manifest = tmpRoot.appendingPathComponent("manifest.json")
        try? Data().write(to: input)
        try? "{}".data(using: .utf8)!.write(to: manifest)
        // Use separate stem URLs (reuse input for simplicity but need 6 distinct files existing)
        var stemURLs: [StemName: URL] = [:]
        for stem in StemName.allCases {
            let u = tmpRoot.appendingPathComponent("\(stem.rawValue).wav")
            try? Data().write(to: u)
            stemURLs[stem] = u
        }
        try? persistence.persistAssets(for: project, mixtureSourceURL: input, manifestSourceURL: manifest, stemSourceURLs: stemURLs, artworkSourceURL: nil)
        sessionStore.refresh()
        XCTAssertEqual(sessionStore.projects.count, 1)
        let beforeIDs = sessionStore.projects.map { $0.id }

        // Now exercise InferenceController needsSetup true but session unchanged
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: makeChecker(workerAvailable: false))
        XCTAssertTrue(controller.needsSetup)
        // Verify session store untouched
        XCTAssertEqual(sessionStore.projects.count, 1)
        XCTAssertEqual(sessionStore.projects.map { $0.id }, beforeIDs)
        XCTAssertNotNil(sessionStore.projects.first?.displayTitle)

        // Also after failed setup, session still untouched
        await controller.runSetup(
            ensureUvAvailable: { .failure(.installFailed(exitCode: 1, message: "fail")) },
            provisionWorker: { _ in .success },
            refreshReadiness: { await controller.refreshRuntimeReadiness(checker: makeChecker(workerAvailable: false)) }
        )
        XCTAssertTrue(controller.setupStage.isFailed)
        XCTAssertEqual(sessionStore.projects.count, 1, "setup failure must not clear Library")
    }

    // MARK: - Luna regression: completed session must remain visible when worker not ready

    func testCompletedResultRemainsVisibleWhenWorkerNotReady_prioritizesStemsOverSetup() async {
        let controller = InferenceController()
        // Build a minimal SeparationResult fixture (no file validation needed for controller state)
        let stems: [StemName: StemArtifact] = Dictionary(uniqueKeysWithValues: StemName.allCases.map { name in
            (name, StemArtifact(name: name, url: URL(fileURLWithPath: "/tmp/\(name.rawValue).wav"), sha256: String(repeating: "a", count: 64), fileSize: 123, frameCount: 2048, channels: 2, sampleRate: 44100))
        })
        let result = SeparationResult(
            jobId: "test-job",
            inputURL: URL(fileURLWithPath: "/tmp/input.wav"),
            jobDirectoryURL: URL(fileURLWithPath: "/tmp/job"),
            manifestURL: URL(fileURLWithPath: "/tmp/manifest.json"),
            stems: stems,
            backend: TrustedInferenceIdentity.backend,
            device: TrustedInferenceIdentity.device,
            checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256,
            model: TrustedInferenceIdentity.model
        )
        let project = try! StrataProject(
            schemaVersion: 1,
            id: UUID().uuidString.lowercased(),
            createdAt: Date(),
            lastOpenedAt: Date(),
            displayTitle: "Reopened Session",
            source: StrataProjectSource(kind: .localFile, locator: "/tmp/input.wav", metadata: nil),
            gains: makeGains()
        )
        // Simulate reopen: adoptCompleted sets .completed + result
        controller.adoptCompleted(project: project, result: result, artworkURL: nil)
        XCTAssertEqual(controller.state, .completed)
        XCTAssertNotNil(controller.result)
        XCTAssertTrue(controller.result?.isComplete ?? false)

        // Now make worker not ready (as after relaunch without provisioning)
        let notReadyChecker = makeChecker(workerAvailable: false)
        await controller.refreshRuntimeReadiness(checker: notReadyChecker)
        XCTAssertFalse(controller.isWorkerReady)
        XCTAssertTrue(controller.needsSetup, "worker not ready should request setup when not completed")
        XCTAssertNotNil(controller.runtimeReadiness)

        // View logic: completedResult takes priority over setup
        let isCompletedState = (controller.state == .completed && controller.result != nil)
        XCTAssertTrue(isCompletedState, "completed state must remain true even when worker not ready")

        func shouldShowSetup(for ctrl: InferenceController, isCompleted: Bool) -> Bool {
            if isCompleted { return false }
            if let readiness = ctrl.runtimeReadiness, !readiness.isWorkerReady { return true }
            return false
        }
        func shouldShowCompleted(for ctrl: InferenceController, isCompleted: Bool) -> Bool {
            isCompleted
        }

        XCTAssertTrue(shouldShowCompleted(for: controller, isCompleted: isCompletedState), "view should prioritize completed UI")
        XCTAssertFalse(shouldShowSetup(for: controller, isCompleted: isCompletedState), "view must NOT show setup when completed result exists, even if worker not ready")

        // Also verify non-completed path still shows setup when worker not ready
        let freshController = InferenceController()
        await freshController.refreshRuntimeReadiness(checker: notReadyChecker)
        let freshIsCompleted = (freshController.state == .completed && freshController.result != nil)
        XCTAssertFalse(freshIsCompleted)
        XCTAssertTrue(shouldShowSetup(for: freshController, isCompleted: freshIsCompleted), "non-completed worker-not-ready must show setup")

        // When checking (nil readiness), completed still wins and non-completed shows checking not setup
        let checkingController = InferenceController()
        // leave runtimeReadiness nil (checking)
        XCTAssertNil(checkingController.runtimeReadiness)
        // Simulate completed even while checking
        checkingController.adoptCompleted(project: project, result: result, artworkURL: nil)
        let checkingIsCompleted = (checkingController.state == .completed && checkingController.result != nil)
        XCTAssertTrue(checkingIsCompleted)
        XCTAssertFalse(shouldShowSetup(for: checkingController, isCompleted: checkingIsCompleted), "checking with completed must not show setup")
    }

    // Helper for gains
    private func makeGains() -> [StemName: Double] {
        var g: [StemName: Double] = [:]
        for s in StemName.allCases { g[s] = 1.0 }
        return g
    }
}
