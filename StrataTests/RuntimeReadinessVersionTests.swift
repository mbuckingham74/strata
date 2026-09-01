import XCTest
@testable import Strata
import Foundation

final class RuntimeReadinessVersionTests: XCTestCase {

    private func makeWorkerConfig(pythonPath: String = "/tmp/worker/.venv/bin/python3") -> WorkerLaunchConfiguration {
        let dir = URL(fileURLWithPath: "/tmp/worker")
        let python = URL(fileURLWithPath: pythonPath)
        return WorkerLaunchConfiguration(
            workerDirectory: dir,
            pythonExecutable: python,
            arguments: ["-m", "demux_worker"],
            currentDirectory: dir,
            environmentAdditions: ["PYTHONUNBUFFERED": "1"]
        )
    }

    private func checker(
        ffmpegExecutable: Bool = true,
        ytDlpExecutable: Bool = true,
        nodeExecutable: Bool = true,
        ffmpegVersion: String? = ExternalToolCompatibility.ffmpegSupportedVersion,
        ytDlpVersion: String? = ExternalToolCompatibility.ytDlpSupportedVersion,
        nodeVersion: String? = ExternalToolCompatibility.nodeSupportedVersion,
        workerAvailable: Bool = true,
        pythonPath: String = "/tmp/worker/.venv/bin/python3",
        resolveThrows: Bool = false
    ) -> RuntimeReadinessChecker {
        let config = makeWorkerConfig(pythonPath: pythonPath)
        return RuntimeReadinessChecker(
            isExecutable: { path in
                if path == RuntimeReadiness.ffmpegPath { return ffmpegExecutable }
                if path == RuntimeReadiness.ytDlpPath { return ytDlpExecutable }
                if path == RuntimeReadiness.nodePath { return nodeExecutable }
                if path == pythonPath { return workerAvailable }
                return false
            },
            resolveWorker: {
                if resolveThrows {
                    throw InferenceError.launchConfiguration("worker directory does not exist or not a directory: /missing")
                }
                return config
            },
            runVersion: { path in
                if path == RuntimeReadiness.ffmpegPath { return ffmpegVersion }
                if path == RuntimeReadiness.ytDlpPath { return ytDlpVersion }
                if path == RuntimeReadiness.nodePath { return nodeVersion }
                return nil
            }
        )
    }

    // MARK: - Parsing

    func testParseFFmpegVersion_extracts() {
        let out = "ffmpeg version 9.0.1 Copyright (c) 2000-2026"
        XCTAssertEqual(ExternalToolCompatibility.parseFFmpegVersion(from: out), "9.0.1")
    }

    func testParseFFmpegVersion_multiline() {
        let out = "ffmpeg version 9.0.1\nbuilt with gcc 14\n"
        XCTAssertEqual(ExternalToolCompatibility.parseFFmpegVersion(from: out), "9.0.1")
    }

    func testParseFFmpegVersion_fails() {
        XCTAssertNil(ExternalToolCompatibility.parseFFmpegVersion(from: "not ffmpeg"))
        XCTAssertNil(ExternalToolCompatibility.parseFFmpegVersion(from: ""))
        XCTAssertNil(ExternalToolCompatibility.parseFFmpegVersion(from: "ffmpeg version "))
    }

    func testParseYtDlpVersion_trimmed() {
        XCTAssertEqual(ExternalToolCompatibility.parseYtDlpVersion(from: "2026.08.19\n"), "2026.08.19")
        XCTAssertEqual(ExternalToolCompatibility.parseYtDlpVersion(from: " 2026.08.19 "), "2026.08.19")
        XCTAssertNil(ExternalToolCompatibility.parseYtDlpVersion(from: "   "))
        XCTAssertNil(ExternalToolCompatibility.parseYtDlpVersion(from: ""))
    }

    func testParseNodeVersion_stripsV() {
        XCTAssertEqual(ExternalToolCompatibility.parseNodeVersion(from: "v26.8.1\n"), "26.8.1")
        XCTAssertEqual(ExternalToolCompatibility.parseNodeVersion(from: "v26.8.1"), "26.8.1")
        XCTAssertEqual(ExternalToolCompatibility.parseNodeVersion(from: "26.8.1"), "26.8.1")
        XCTAssertEqual(ExternalToolCompatibility.parseNodeVersion(from: "  v26.8.1  "), "26.8.1")
        XCTAssertNil(ExternalToolCompatibility.parseNodeVersion(from: ""))
        XCTAssertNil(ExternalToolCompatibility.parseNodeVersion(from: "   "))
        XCTAssertNil(ExternalToolCompatibility.parseNodeVersion(from: "v   "))
    }

    // MARK: - Supported vs mismatched vs unreadable

    func testSupportedVersions_ready() {
        let r = checker().check()
        XCTAssertTrue(r.ffmpegAvailable)
        XCTAssertTrue(r.ytDlpAvailable)
        XCTAssertTrue(r.nodeAvailable)
        XCTAssertTrue(r.isSeparationReady)
        XCTAssertTrue(r.isYouTubeAcquisitionReady)
        XCTAssertEqual(r.sidebarStatus, "Separation ready · runs on this Mac")
        XCTAssertEqual(r.ffmpegInstalledVersion, ExternalToolCompatibility.ffmpegSupportedVersion)
        XCTAssertEqual(r.ytDlpInstalledVersion, ExternalToolCompatibility.ytDlpSupportedVersion)
        XCTAssertEqual(r.nodeInstalledVersion, ExternalToolCompatibility.nodeSupportedVersion)
    }

    func testFFmpegMismatch_notReady_statusContainsVersions() {
        let r = checker(ffmpegVersion: "9.0.0").check()
        XCTAssertFalse(r.ffmpegAvailable)
        XCTAssertEqual(r.ffmpegInstalledVersion, "9.0.0")
        XCTAssertFalse(r.isLocalSeparationReady)
        XCTAssertFalse(r.isMp3ExportReady)
        XCTAssertTrue(r.isWavExportReady)
        XCTAssertFalse(r.isYouTubeAcquisitionReady)
        // preview should still be ready (yt-dlp+node independent of ffmpeg)
        XCTAssertTrue(r.isYouTubePreviewReady)
        XCTAssertFalse(r.isYouTubeMp3Ready)
        XCTAssertTrue(r.sidebarStatus.contains("FFmpeg"))
        XCTAssertTrue(r.sidebarStatus.contains("mismatch"))
        XCTAssertTrue(r.sidebarStatus.contains("9.0.0"))
        XCTAssertTrue(r.sidebarStatus.contains(ExternalToolCompatibility.ffmpegSupportedVersion))
        XCTAssertTrue(r.sidebarStatus.contains(RuntimeReadiness.ffmpegPath))
        // priority: ffmpeg mismatch over worker
        XCTAssertTrue(r.sidebarStatus.contains(RuntimeReadiness.ffmpegPath))
    }

    func testFFmpegUnreadable_notReady() {
        let r = checker(ffmpegVersion: nil).check()
        XCTAssertFalse(r.ffmpegAvailable)
        XCTAssertEqual(r.ffmpegInstalledVersion, "unknown")
        XCTAssertFalse(r.isLocalSeparationReady)
        XCTAssertFalse(r.isMp3ExportReady)
        XCTAssertTrue(r.isWavExportReady)
        XCTAssertTrue(r.sidebarStatus.contains("FFmpeg"))
        XCTAssertTrue(r.sidebarStatus.contains(ExternalToolCompatibility.ffmpegSupportedVersion))
        XCTAssertTrue(r.sidebarStatus.contains(RuntimeReadiness.ffmpegPath))
    }

    func testYtDlpMismatch_keepsLocalSeparation() {
        let r = checker(ytDlpVersion: "2026.08.18").check()
        XCTAssertTrue(r.ffmpegAvailable)
        XCTAssertFalse(r.ytDlpAvailable)
        XCTAssertEqual(r.ytDlpInstalledVersion, "2026.08.18")
        XCTAssertTrue(r.isLocalSeparationReady, "yt-dlp mismatch must NOT disable local separation")
        XCTAssertTrue(r.isLoadedSeparationReady)
        XCTAssertTrue(r.isMp3ExportReady)
        XCTAssertTrue(r.isWavExportReady)
        XCTAssertFalse(r.isYouTubePreviewReady)
        XCTAssertFalse(r.isYouTubeAcquisitionReady)
        XCTAssertFalse(r.isYouTubeMp3Ready)
        XCTAssertFalse(r.isYouTubeSeparationReady)
        XCTAssertTrue(r.sidebarStatus.contains("yt-dlp"))
        XCTAssertTrue(r.sidebarStatus.contains("2026.08.18"))
        XCTAssertTrue(r.sidebarStatus.contains(ExternalToolCompatibility.ytDlpSupportedVersion))
        XCTAssertTrue(r.sidebarStatus.contains(RuntimeReadiness.ytDlpPath))
    }

    func testYtDlpUnreadable_disablesYouTube() {
        let r = checker(ytDlpVersion: nil).check()
        XCTAssertFalse(r.ytDlpAvailable)
        XCTAssertEqual(r.ytDlpInstalledVersion, "unknown")
        XCTAssertFalse(r.isYouTubePreviewReady)
        XCTAssertTrue(r.isLocalSeparationReady)
        XCTAssertTrue(r.sidebarStatus.contains("yt-dlp"))
    }

    func testNodeMismatch_keepsLocalSeparation() {
        let r = checker(nodeVersion: "26.8.0").check()
        XCTAssertFalse(r.nodeAvailable)
        XCTAssertEqual(r.nodeInstalledVersion, "26.8.0")
        XCTAssertTrue(r.isLocalSeparationReady)
        XCTAssertTrue(r.isLoadedSeparationReady)
        XCTAssertFalse(r.isYouTubePreviewReady)
        XCTAssertFalse(r.isYouTubeAcquisitionReady)
        XCTAssertTrue(r.isMp3ExportReady)
        XCTAssertTrue(r.sidebarStatus.contains("Node"))
        XCTAssertTrue(r.sidebarStatus.contains("26.8.0"))
        XCTAssertTrue(r.sidebarStatus.contains(ExternalToolCompatibility.nodeSupportedVersion))
        XCTAssertTrue(r.sidebarStatus.contains(RuntimeReadiness.nodePath))
    }

    func testNodeUnreadable() {
        let r = checker(nodeVersion: nil).check()
        XCTAssertFalse(r.nodeAvailable)
        XCTAssertEqual(r.nodeInstalledVersion, "unknown")
        XCTAssertFalse(r.isYouTubePreviewReady)
        XCTAssertTrue(r.isLocalSeparationReady)
    }

    // MARK: - Priority and gating

    func testFFmpegMismatch_priorityOverWorker() {
        let r = checker(ffmpegVersion: "9.0.0", workerAvailable: false).check()
        // Both not ready, but sidebar should prioritize ffmpeg
        XCTAssertTrue(r.sidebarStatus.contains(RuntimeReadiness.ffmpegPath))
        XCTAssertFalse(r.sidebarStatus.contains("worker Python"))
    }

    func testWorkerPriorityOverYtDlpMismatch() {
        let r = checker(ytDlpVersion: "2026.08.18", workerAvailable: false).check()
        XCTAssertTrue(r.sidebarStatus.contains("worker Python"))
        XCTAssertFalse(r.sidebarStatus.contains("yt-dlp"))
    }

    func testYtDlpMismatch_priorityOverNode() {
        let r = checker(ytDlpVersion: "2026.08.18", nodeVersion: "26.8.0").check()
        XCTAssertTrue(r.sidebarStatus.contains(RuntimeReadiness.ytDlpPath))
        XCTAssertFalse(r.sidebarStatus.contains(RuntimeReadiness.nodePath))
    }

    func testNodeMismatch_onlyWhenOthersReady() {
        let r = checker(nodeVersion: "26.8.0").check()
        XCTAssertTrue(r.sidebarStatus.contains(RuntimeReadiness.nodePath))
        XCTAssertTrue(r.sidebarStatus.contains("Node"))
    }

    func testFFmpegMismatch_disablesOnlyDependents() {
        let r = checker(ffmpegVersion: "9.0.0").check()
        // Dependents of ffmpeg: local separation, mp3, acquisition, youtube mp3/separation
        XCTAssertFalse(r.isLocalSeparationReady)
        XCTAssertFalse(r.isMp3ExportReady)
        XCTAssertFalse(r.isExportReady)
        XCTAssertFalse(r.isYouTubeAcquisitionReady)
        XCTAssertFalse(r.isYouTubeMp3Ready)
        XCTAssertFalse(r.isYouTubeSeparationReady)
        // Independents: loaded separation (only worker), wav, preview
        XCTAssertTrue(r.isLoadedSeparationReady)
        XCTAssertTrue(r.isWavExportReady)
        XCTAssertTrue(r.isYouTubePreviewReady, "Preview independent of FFmpeg")
    }

    func testYtDlpMismatch_disablesOnlyYouTube() {
        let r = checker(ytDlpVersion: "9.9.9").check()
        XCTAssertTrue(r.isLocalSeparationReady)
        XCTAssertTrue(r.isLoadedSeparationReady)
        XCTAssertTrue(r.isMp3ExportReady)
        XCTAssertTrue(r.isWavExportReady)
        XCTAssertFalse(r.isYouTubePreviewReady)
        XCTAssertFalse(r.isYouTubeAcquisitionReady)
        XCTAssertFalse(r.isYouTubeMp3Ready)
    }

    func testNodeMismatch_disablesOnlyYouTube() {
        let r = checker(nodeVersion: "0.0.0").check()
        XCTAssertTrue(r.isLocalSeparationReady)
        XCTAssertFalse(r.isYouTubePreviewReady)
        XCTAssertFalse(r.isYouTubeAcquisitionReady)
    }

    func testMissingFFmpeg_stillMissingStatus() {
        let r = checker(ffmpegExecutable: false, ffmpegVersion: nil).check()
        XCTAssertFalse(r.ffmpegAvailable)
        XCTAssertNil(r.ffmpegInstalledVersion)
        XCTAssertTrue(r.sidebarStatus.contains("missing FFmpeg"))
        XCTAssertTrue(r.sidebarStatus.contains(RuntimeReadiness.ffmpegPath))
        XCTAssertFalse(r.sidebarStatus.contains("mismatch"))
    }

    func testExternalToolCompatibilityConstants() {
        XCTAssertEqual(ExternalToolCompatibility.ffmpegSupportedVersion, "9.0.1")
        XCTAssertEqual(ExternalToolCompatibility.ytDlpSupportedVersion, "2026.08.19")
        XCTAssertEqual(ExternalToolCompatibility.nodeSupportedVersion, "26.8.1")
        XCTAssertEqual(ExternalToolCompatibility.uvSupportedVersion, "0.12.8")
    }

    // MARK: - Live version pipe draining + timeout (blocker fix)

    func testVersionTimeout_isBoundedUnder5s() {
        XCTAssertEqual(RuntimeReadinessChecker.versionTimeout, 2.0, accuracy: 0.001)
        XCTAssertLessThan(RuntimeReadinessChecker.versionTimeout, 5.0)
        XCTAssertGreaterThan(RuntimeReadinessChecker.versionTimeout, 0.1)
    }

    func testCaptureVersionOutput_hungProcessTimesOut() {
        let start = Date()
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/bin/sleep",
            arguments: ["10"],
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result, "hung process must return nil on timeout")
        XCTAssertLessThan(elapsed, 2.0, "timeout must not hang; elapsed \(elapsed)")
        XCTAssertGreaterThanOrEqual(elapsed, 0.4, "should wait at least timeout")
    }

    func testCaptureVersionOutput_hungProcessWithStderrDoesNotHang() {
        let start = Date()
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 10"],
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 2.0)
    }

    func testLiveVersion_unknownPathReturnsNilQuickly() {
        let start = Date()
        let result = RuntimeReadinessChecker.liveVersion(for: "/tmp/nonexistent-tool-xyz")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testCaptureVersionOutput_largeStdoutDoesNotDeadlock() {
        let start = Date()
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/bin/sh",
            arguments: ["-c", "yes | head -n 200000"],
            timeout: 2.0
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotNil(result, "large output should succeed, not deadlock")
        XCTAssertLessThan(elapsed, 2.0, "large output should not hit timeout")
        if let out = result {
            XCTAssertGreaterThan(out.count, 100_000)
            XCTAssertTrue(out.hasPrefix("y\n") || out.hasPrefix("y"))
        }
    }

    func testCaptureVersionOutput_largeStderrDrainedConcurrently() {
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/bin/sh",
            arguments: ["-c", "for i in $(seq 1 50000); do echo err >&2; done; echo done"],
            timeout: 2.0
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    func testCaptureVersionOutput_largeMixedOutputDoesNotDeadlock() {
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/bin/sh",
            arguments: ["-c", "yes | head -n 100000 >&1; yes | head -n 100000 >&2; echo ok"],
            timeout: 2.0
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("ok") ?? false)
    }

    func testCaptureVersionOutput_nonZeroExitReturnsNil() {
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/bin/sh",
            arguments: ["-c", "exit 1"],
            timeout: 1.0
        )
        XCTAssertNil(result)
    }

    func testCaptureVersionOutput_missingExecutableReturnsNil() {
        let start = Date()
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/nonexistent/path/tool",
            arguments: ["--version"],
            timeout: 1.0
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testCaptureVersionOutput_undecodableOutputReturnsNil() {
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf '\\377\\376'"],
            timeout: 1.0
        )
        XCTAssertNil(result)
    }

    func testCaptureVersionOutput_validEchoSucceeds() {
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/bin/echo",
            arguments: ["hello"],
            timeout: 1.0
        )
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testCheck_timeoutMapsToUnknown() {
        let checker = RuntimeReadinessChecker(
            isExecutable: { _ in true },
            resolveWorker: {
                WorkerLaunchConfiguration(
                    workerDirectory: URL(fileURLWithPath: "/tmp/worker"),
                    pythonExecutable: URL(fileURLWithPath: "/tmp/worker/.venv/bin/python3"),
                    arguments: ["-m", "demux_worker"],
                    currentDirectory: URL(fileURLWithPath: "/tmp/worker"),
                    environmentAdditions: [:]
                )
            },
            runVersion: { _ in nil }
        )
        let r = checker.check()
        XCTAssertFalse(r.ffmpegAvailable)
        XCTAssertEqual(r.ffmpegInstalledVersion, "unknown")
        XCTAssertFalse(r.isSeparationReady)
        XCTAssertTrue(r.sidebarStatus.contains("unknown") || r.sidebarStatus.contains("mismatch"))
    }

    // MARK: - Timeout cleanup: descendant-held pipe must not hang

    func testCaptureVersionOutput_timeoutWithDescendantHoldingPipeReturnsQuickly() {
        // Spawns a child that forks a descendant holding stdout open (traps TERM, sleeps).
        // Without proper cleanup (no readToEnd), this would hang until EOF (~10s).
        let start = Date()
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/bin/sh",
            arguments: ["-c", "(trap '' TERM; sleep 10) & wait"],
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result, "timed-out process with descendant must return nil")
        XCTAssertLessThan(elapsed, 2.0, "must not hang on descendant-held pipe; elapsed \(elapsed)")
        XCTAssertGreaterThanOrEqual(elapsed, 0.4, "should wait at least timeout")
    }

    func testCaptureVersionOutput_timeoutWithDescendantHoldingPipe_viaPython() {
        // Alternate descendant-holding-pipe pattern via python subprocess (if available)
        // Python forks sleep(10) which inherits stdout pipe. Timeout must still be bounded.
        let start = Date()
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/bin/sh",
            arguments: ["-c", "python3 -c 'import subprocess, time; p=subprocess.Popen([\"sleep\",\"10\"]); p.wait()'"],
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)
        // If python3 not available, process exits non-zero and returns nil quickly — still bounded
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 2.5, "descendant via python must not hang; elapsed \(elapsed)")
    }

    func testCaptureVersionOutput_exitedProcessWithDescendantHoldingPipeDoesNotHang() {
        // Child exits quickly but leaves descendant holding pipe open; capture must return
        // immediately available data without waiting for EOF from descendant.
        let start = Date()
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/bin/sh",
            arguments: ["-c", "(sleep 10) & echo hello"],
            timeout: 2.0
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotNil(result, "should return immediately available data despite descendant")
        XCTAssertTrue(result?.contains("hello") ?? false, "output should contain hello, got \(String(describing: result))")
        XCTAssertLessThan(elapsed, 1.5, "must not wait for descendant EOF; elapsed \(elapsed)")
    }

    func testCaptureVersionOutput_versionTimeoutBudgetWithDescendant() {
        // Validate bounded escalation at default versionTimeout (2.0s + 0.6s grace max ~= 2.6s)
        let start = Date()
        let result = RuntimeReadinessChecker.captureVersionOutput(
            executablePath: "/bin/sh",
            arguments: ["-c", "(trap '' TERM; sleep 10) & wait"],
            timeout: RuntimeReadinessChecker.versionTimeout
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 3.0, "versionTimeout+escalation must remain bounded; elapsed \(elapsed)")
        XCTAssertGreaterThanOrEqual(elapsed, 1.9)
    }
}
