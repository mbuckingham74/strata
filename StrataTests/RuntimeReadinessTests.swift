import XCTest
@testable import Strata
import Foundation

final class RuntimeReadinessTests: XCTestCase {

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
        ffmpeg: Bool,
        ytDlp: Bool,
        node: Bool = true,
        workerAvailable: Bool? = true,
        pythonPath: String = "/tmp/worker/.venv/bin/python3",
        resolveThrows: Bool = false
    ) -> RuntimeReadinessChecker {
        let config = makeWorkerConfig(pythonPath: pythonPath)
        return RuntimeReadinessChecker(
            isExecutable: { path in
                if path == RuntimeReadiness.ffmpegPath { return ffmpeg }
                if path == RuntimeReadiness.ytDlpPath { return ytDlp }
                if path == RuntimeReadiness.nodePath { return node }
                if path == pythonPath { return workerAvailable ?? false }
                return false
            },
            resolveWorker: {
                if resolveThrows {
                    throw InferenceError.launchConfiguration("worker directory does not exist or not a directory: /missing")
                }
                return config
            }
        )
    }

    // MARK: - Truth table

    func testAllAvailable_isFullyReady() {
        let r = checker(ffmpeg: true, ytDlp: true, workerAvailable: true).check()
        XCTAssertTrue(r.ffmpegAvailable)
        XCTAssertTrue(r.ytDlpAvailable)
        XCTAssertTrue(r.workerAvailable)
        XCTAssertTrue(r.isSeparationReady)
        XCTAssertTrue(r.isLocalSeparationReady)
        XCTAssertTrue(r.isLoadedSeparationReady, "loaded separation requires only worker")
        XCTAssertTrue(r.isYouTubeAcquisitionReady)
        XCTAssertTrue(r.isExportReady)
        XCTAssertTrue(r.isMp3ExportReady)
        XCTAssertTrue(r.isWavExportReady, "WAV export never requires FFmpeg")
        XCTAssertEqual(r.sidebarStatus, "Separation ready · runs on this Mac")
    }

    func testMissingFFmpeg_disablesAll() {
        let r = checker(ffmpeg: false, ytDlp: true, workerAvailable: true).check()
        XCTAssertFalse(r.ffmpegAvailable)
        XCTAssertFalse(r.isLocalSeparationReady, "FFmpeg missing must disable local separation (needs canonicalization)")
        XCTAssertTrue(r.isLoadedSeparationReady, "FFmpeg missing must NOT disable already-loaded separation (already canonical)")
        XCTAssertFalse(r.isYouTubeAcquisitionReady, "FFmpeg missing must disable YouTube acquisition")
        XCTAssertFalse(r.isMp3ExportReady, "MP3 requires FFmpeg")
        XCTAssertTrue(r.isWavExportReady, "WAV stem/mix copy does not require FFmpeg")
        XCTAssertFalse(r.isExportReady)
        XCTAssertTrue(r.sidebarStatus.contains("FFmpeg"))
        XCTAssertTrue(r.sidebarStatus.contains("FFmpeg"))
    }

    func testMissingFFmpeg_disablesEvenWhenYtDlpMissing() {
        let r = checker(ffmpeg: false, ytDlp: false, workerAvailable: true).check()
        XCTAssertFalse(r.isLocalSeparationReady)
        XCTAssertTrue(r.isLoadedSeparationReady)
        XCTAssertFalse(r.isYouTubeAcquisitionReady)
        XCTAssertFalse(r.isMp3ExportReady)
        XCTAssertTrue(r.isWavExportReady)
        XCTAssertTrue(r.sidebarStatus.contains("FFmpeg"))
        // FFmpeg takes priority over yt-dlp in status
        XCTAssertFalse(r.sidebarStatus.contains("yt-dlp"))
    }

    func testMissingYtDlp_keepsLocalSeparation() {
        let r = checker(ffmpeg: true, ytDlp: false, workerAvailable: true).check()
        XCTAssertTrue(r.isSeparationReady, "missing yt-dlp must NOT disable local separation")
        XCTAssertTrue(r.isLocalSeparationReady)
        XCTAssertTrue(r.isLoadedSeparationReady)
        XCTAssertFalse(r.isYouTubeAcquisitionReady)
        XCTAssertTrue(r.isMp3ExportReady, "MP3 export needs only FFmpeg")
        XCTAssertTrue(r.isWavExportReady)
        XCTAssertTrue(r.sidebarStatus.contains("yt-dlp"))
        XCTAssertTrue(r.sidebarStatus.contains("YouTube disabled"))
    }

    func testMissingWorker_disablesSeparationKeepsYtDlpIrrelevant() {
        let r = checker(ffmpeg: true, ytDlp: true, workerAvailable: false).check()
        XCTAssertFalse(r.workerAvailable)
        XCTAssertFalse(r.isLocalSeparationReady, "missing worker must disable local separation")
        XCTAssertFalse(r.isLoadedSeparationReady, "missing worker must disable loaded separation too")
        XCTAssertFalse(r.isSeparationReady)
        // YouTube acquisition does not require worker, but separation from loaded does
        XCTAssertTrue(r.isYouTubeAcquisitionReady, "YouTube ingest still ready when worker missing")
        XCTAssertTrue(r.isMp3ExportReady)
        XCTAssertTrue(r.isWavExportReady)
        XCTAssertTrue(r.sidebarStatus.contains("worker Python"))
        XCTAssertTrue(r.sidebarStatus.contains("/tmp/worker/.venv/bin/python3"))
    }

    func testMissingWorkerAndFFmpeg_priorityIsFFmpeg() {
        let r = checker(ffmpeg: false, ytDlp: true, workerAvailable: false).check()
        XCTAssertFalse(r.isLocalSeparationReady)
        XCTAssertFalse(r.isLoadedSeparationReady)
        XCTAssertFalse(r.isSeparationReady)
        XCTAssertFalse(r.isYouTubeAcquisitionReady)
        XCTAssertFalse(r.isMp3ExportReady)
        XCTAssertTrue(r.isWavExportReady, "WAV still available even when both worker and FFmpeg missing")
        XCTAssertTrue(r.sidebarStatus.contains("FFmpeg"))
    }

    func testMissingWorkerPythonPathIncluded() {
        let python = "/custom/path/.venv/bin/python3"
        let r = checker(ffmpeg: true, ytDlp: true, workerAvailable: false, pythonPath: python).check()
        XCTAssertEqual(r.workerPythonPath, python)
        XCTAssertTrue(r.sidebarStatus.contains(python))
    }

    func testWorkerResolveThrows_includesErrorAndPathHint() {
        let r = checker(ffmpeg: true, ytDlp: true, resolveThrows: true).check()
        XCTAssertFalse(r.workerAvailable)
        XCTAssertFalse(r.isSeparationReady)
        XCTAssertNotNil(r.workerError)
        XCTAssertTrue(r.sidebarStatus.contains("Setup needed"))
        // When resolve throws, status should contain error text with path
        XCTAssertTrue(r.sidebarStatus.contains("/missing") || r.sidebarStatus.contains("worker"))
    }

    func testWorkerResolveThrows_stillReportsFFmpegAndYtDlp() {
        let r = checker(ffmpeg: true, ytDlp: false, resolveThrows: true).check()
        XCTAssertFalse(r.workerAvailable)
        XCTAssertTrue(r.ffmpegAvailable)
        XCTAssertFalse(r.ytDlpAvailable)
        // FFmpeg missing would take priority, but here FFmpeg present so worker status shown
        XCTAssertTrue(r.sidebarStatus.contains("worker") || r.sidebarStatus.contains("Setup needed"))
    }

    // MARK: - InferenceController integration

    @MainActor
    func testInferenceControllerRefresh_setsReadiness() async {
        let controller = InferenceController()
        XCTAssertNil(controller.runtimeReadiness, "initially nil (checking)")
        let c = checker(ffmpeg: true, ytDlp: true, workerAvailable: true)
        await controller.refreshRuntimeReadiness(checker: c)
        XCTAssertNotNil(controller.runtimeReadiness)
        XCTAssertTrue(controller.isSeparationReady)
        XCTAssertTrue(controller.isYouTubeAcquisitionReady)
        XCTAssertTrue(controller.isExportReady)
    }

    @MainActor
    func testInferenceControllerRefresh_ytDlpMissing_keepsSeparationReady() async {
        let controller = InferenceController()
        let c = checker(ffmpeg: true, ytDlp: false, workerAvailable: true)
        await controller.refreshRuntimeReadiness(checker: c)
        XCTAssertTrue(controller.isSeparationReady, "local separation must stay enabled when only yt-dlp missing")
        XCTAssertFalse(controller.isYouTubeAcquisitionReady)
        XCTAssertTrue(controller.isExportReady)
    }

    @MainActor
    func testInferenceControllerRefresh_missingFFmpeg_disablesAllGatings() async {
        let controller = InferenceController()
        let c = checker(ffmpeg: false, ytDlp: false, workerAvailable: true)
        await controller.refreshRuntimeReadiness(checker: c)
        XCTAssertFalse(controller.isLocalSeparationReady, "local separation needs FFmpeg")
        XCTAssertTrue(controller.isLoadedSeparationReady, "loaded canonical source separation needs only worker")
        XCTAssertFalse(controller.isSeparationReady)
        XCTAssertFalse(controller.isYouTubeAcquisitionReady)
        XCTAssertFalse(controller.isMp3ExportReady)
        XCTAssertTrue(controller.isWavExportReady, "WAV mix/copy always available")
        XCTAssertFalse(controller.isExportReady)
    }

    @MainActor
    func testInferenceControllerRefresh_missingWorker_disablesSeparationNotYouTubeAcquisition() async {
        let controller = InferenceController()
        let c = checker(ffmpeg: true, ytDlp: true, workerAvailable: false)
        await controller.refreshRuntimeReadiness(checker: c)
        XCTAssertFalse(controller.isSeparationReady)
        XCTAssertTrue(controller.isYouTubeAcquisitionReady)
        // export stays ready
        XCTAssertTrue(controller.isExportReady)
    }

    @MainActor
    func testInferenceControllerRefresh_usingIsExecutableClosure() async {
        let controller = InferenceController()
        let python = "/tmp/worker/.venv/bin/python3"
        let config = makeWorkerConfig(pythonPath: python)
        await controller.refreshRuntimeReadiness(
            isExecutable: { path in
                if path == RuntimeReadiness.ffmpegPath { return true }
                if path == RuntimeReadiness.ytDlpPath { return false }
                if path == RuntimeReadiness.nodePath { return true }
                if path == python { return true }
                return false
            },
            resolveWorker: { config }
        )
        XCTAssertTrue(controller.isSeparationReady)
        XCTAssertFalse(controller.isYouTubeAcquisitionReady)
    }

    // MARK: - Corrected gating distinctions

    func testWavExportRemainsAvailableWhenFFmpegMissing() {
        let r = checker(ffmpeg: false, ytDlp: false, workerAvailable: true).check()
        XCTAssertTrue(r.isWavExportReady, "WAV export must not require FFmpeg")
        XCTAssertFalse(r.isMp3ExportReady, "MP3 export must require FFmpeg")
        XCTAssertFalse(r.isExportReady, "isExportReady is alias for MP3")
    }

    func testWavMixRemainsAvailableWhenFFmpegMissing() {
        let r = checker(ffmpeg: false, ytDlp: true, workerAvailable: true).check()
        XCTAssertTrue(r.isWavExportReady)
        XCTAssertFalse(r.isMp3ExportReady)
    }

    func testLoadedSeparationRequiresOnlyWorker() {
        // ffmpeg false but worker true -> loaded separation still ready
        let r = checker(ffmpeg: false, ytDlp: true, workerAvailable: true).check()
        XCTAssertTrue(r.isLoadedSeparationReady, "loaded canonical source separation requires only worker")
        XCTAssertTrue(r.isWorkerReady)
        XCTAssertFalse(r.isLocalSeparationReady, "local separation still needs FFmpeg for canonicalization")
        // converse: worker false -> loaded not ready even if ffmpeg true
        let r2 = checker(ffmpeg: true, ytDlp: true, workerAvailable: false).check()
        XCTAssertFalse(r2.isLoadedSeparationReady)
        XCTAssertFalse(r2.isWorkerReady)
    }

    func testLocalSeparationRequiresWorkerAndFFmpeg() {
        let r1 = checker(ffmpeg: true, ytDlp: true, workerAvailable: true).check()
        XCTAssertTrue(r1.isLocalSeparationReady)
        let r2 = checker(ffmpeg: false, ytDlp: true, workerAvailable: true).check()
        XCTAssertFalse(r2.isLocalSeparationReady)
        let r3 = checker(ffmpeg: true, ytDlp: true, workerAvailable: false).check()
        XCTAssertFalse(r3.isLocalSeparationReady)
    }

    func testMp3RequiresFFmpeg_WavDoesNot() {
        let withFfmpeg = checker(ffmpeg: true, ytDlp: true, workerAvailable: true).check()
        XCTAssertTrue(withFfmpeg.isMp3ExportReady)
        XCTAssertTrue(withFfmpeg.isWavExportReady)
        let withoutFfmpeg = checker(ffmpeg: false, ytDlp: true, workerAvailable: true).check()
        XCTAssertFalse(withoutFfmpeg.isMp3ExportReady)
        XCTAssertTrue(withoutFfmpeg.isWavExportReady)
    }

    // MARK: - Sidebar status does not claim YouTube 100% local

    func testSidebarStatusSuccessfulSeparation_describesLocal() {
        let r = checker(ffmpeg: true, ytDlp: true, workerAvailable: true).check()
        XCTAssertTrue(r.sidebarStatus.contains("runs on this Mac"))
        XCTAssertFalse(r.sidebarStatus.contains("100% local"))
    }

    // MARK: - Node runtime required for YouTube acquisition

    func testMissingNode_disablesYouTubeAcquisitionKeepsLocalSeparation() {
        let r = checker(ffmpeg: true, ytDlp: true, node: false, workerAvailable: true).check()
        XCTAssertTrue(r.nodeAvailable == false)
        XCTAssertFalse(r.isYouTubeAcquisitionReady, "Node missing must disable YouTube acquisition")
        XCTAssertTrue(r.isLocalSeparationReady, "missing Node must NOT disable local separation")
        XCTAssertTrue(r.isLoadedSeparationReady)
        XCTAssertTrue(r.isMp3ExportReady)
        XCTAssertTrue(r.isWavExportReady)
        XCTAssertTrue(r.sidebarStatus.contains("Node"))
        XCTAssertTrue(r.sidebarStatus.contains("Node"))
        XCTAssertTrue(r.sidebarStatus.contains("YouTube disabled"))
    }

    func testYouTubeAcquisitionRequiresAllThree() {
        let all = checker(ffmpeg: true, ytDlp: true, node: true, workerAvailable: true).check()
        XCTAssertTrue(all.isYouTubeAcquisitionReady)
        let noFfmpeg = checker(ffmpeg: false, ytDlp: true, node: true, workerAvailable: true).check()
        XCTAssertFalse(noFfmpeg.isYouTubeAcquisitionReady)
        let noYtDlp = checker(ffmpeg: true, ytDlp: false, node: true, workerAvailable: true).check()
        XCTAssertFalse(noYtDlp.isYouTubeAcquisitionReady)
        let noNode = checker(ffmpeg: true, ytDlp: true, node: false, workerAvailable: true).check()
        XCTAssertFalse(noNode.isYouTubeAcquisitionReady)
        let none = checker(ffmpeg: false, ytDlp: false, node: false, workerAvailable: true).check()
        XCTAssertFalse(none.isYouTubeAcquisitionReady)
    }

    func testSidebarStatusPriority_ffmpegOverWorkerOverYtDlpOverNode() {
        // ffmpeg missing takes priority over node
        let r1 = checker(ffmpeg: false, ytDlp: true, node: false, workerAvailable: true).check()
        XCTAssertTrue(r1.sidebarStatus.contains("FFmpeg"))
        XCTAssertFalse(r1.sidebarStatus.contains("Node"))
        // worker missing takes priority over yt-dlp and node
        let r2 = checker(ffmpeg: true, ytDlp: false, node: false, workerAvailable: false).check()
        XCTAssertTrue(r2.sidebarStatus.contains("worker Python"))
        XCTAssertFalse(r2.sidebarStatus.contains("yt-dlp"))
        XCTAssertFalse(r2.sidebarStatus.contains("Node"))
        // yt-dlp missing takes priority over node
        let r3 = checker(ffmpeg: true, ytDlp: false, node: false, workerAvailable: true).check()
        XCTAssertTrue(r3.sidebarStatus.contains("yt-dlp"))
        XCTAssertFalse(r3.sidebarStatus.contains("Node"))
        // node missing only when ffmpeg, worker, yt-dlp present
        let r4 = checker(ffmpeg: true, ytDlp: true, node: false, workerAvailable: true).check()
        XCTAssertTrue(r4.sidebarStatus.contains("Node"))
    }

    func testMissingFFmpeg_disablesYouTubeEvenWhenNodeMissing() {
        let r = checker(ffmpeg: false, ytDlp: false, node: false, workerAvailable: true).check()
        XCTAssertFalse(r.isYouTubeAcquisitionReady)
        XCTAssertTrue(r.sidebarStatus.contains("FFmpeg"))
    }

    func testNodeAvailableFlag() {
        let r = checker(ffmpeg: true, ytDlp: true, node: true, workerAvailable: true).check()
        XCTAssertTrue(r.nodeAvailable)
        XCTAssertEqual(RuntimeReadiness.nodePath, "/opt/homebrew/bin/node")
    }

    // MARK: - Granular YouTube readiness per metadata-first workflow

    func testYouTubePreviewReady_requiresOnlyYtDlpAndNode() {
        // preview = ytDlp && node, independent of ffmpeg and worker
        let all = checker(ffmpeg: true, ytDlp: true, node: true, workerAvailable: true).check()
        XCTAssertTrue(all.isYouTubePreviewReady)
        let noFfmpeg = checker(ffmpeg: false, ytDlp: true, node: true, workerAvailable: true).check()
        XCTAssertTrue(noFfmpeg.isYouTubePreviewReady, "Preview must NOT require FFmpeg")
        let noWorker = checker(ffmpeg: true, ytDlp: true, node: true, workerAvailable: false).check()
        XCTAssertTrue(noWorker.isYouTubePreviewReady, "Preview must NOT require worker")
        let noFfmpegNoWorker = checker(ffmpeg: false, ytDlp: true, node: true, workerAvailable: false).check()
        XCTAssertTrue(noFfmpegNoWorker.isYouTubePreviewReady, "Preview only needs yt-dlp+node")
        let noYtDlp = checker(ffmpeg: true, ytDlp: false, node: true, workerAvailable: true).check()
        XCTAssertFalse(noYtDlp.isYouTubePreviewReady)
        let noNode = checker(ffmpeg: true, ytDlp: true, node: false, workerAvailable: true).check()
        XCTAssertFalse(noNode.isYouTubePreviewReady)
        let none = checker(ffmpeg: false, ytDlp: false, node: false, workerAvailable: false).check()
        XCTAssertFalse(none.isYouTubePreviewReady)
    }

    func testYouTubeMp3Ready_requiresPreviewPlusFFmpeg() {
        // mp3 = preview && ffmpeg
        let ok = checker(ffmpeg: true, ytDlp: true, node: true, workerAvailable: true).check()
        XCTAssertTrue(ok.isYouTubeMp3Ready)
        let okNoWorker = checker(ffmpeg: true, ytDlp: true, node: true, workerAvailable: false).check()
        XCTAssertTrue(okNoWorker.isYouTubeMp3Ready, "MP3 must NOT require worker")
        let noFfmpeg = checker(ffmpeg: false, ytDlp: true, node: true, workerAvailable: true).check()
        XCTAssertFalse(noFfmpeg.isYouTubeMp3Ready, "MP3 must require FFmpeg")
        let noYtDlp = checker(ffmpeg: true, ytDlp: false, node: true, workerAvailable: true).check()
        XCTAssertFalse(noYtDlp.isYouTubeMp3Ready)
        let noNode = checker(ffmpeg: true, ytDlp: true, node: false, workerAvailable: true).check()
        XCTAssertFalse(noNode.isYouTubeMp3Ready)
        // also verify it combines preview and mp3Export
        XCTAssertEqual(ok.isYouTubeMp3Ready, ok.isYouTubePreviewReady && ok.isMp3ExportReady)
    }

    func testYouTubeSeparationReady_requiresMp3PlusWorker() {
        // separation = mp3 && worker
        let ok = checker(ffmpeg: true, ytDlp: true, node: true, workerAvailable: true).check()
        XCTAssertTrue(ok.isYouTubeSeparationReady)
        let noWorker = checker(ffmpeg: true, ytDlp: true, node: true, workerAvailable: false).check()
        XCTAssertFalse(noWorker.isYouTubeSeparationReady, "Separation must require worker")
        let noFfmpeg = checker(ffmpeg: false, ytDlp: true, node: true, workerAvailable: true).check()
        XCTAssertFalse(noFfmpeg.isYouTubeSeparationReady, "Separation must require FFmpeg via MP3")
        let noYtDlp = checker(ffmpeg: true, ytDlp: false, node: true, workerAvailable: true).check()
        XCTAssertFalse(noYtDlp.isYouTubeSeparationReady)
        let noNode = checker(ffmpeg: true, ytDlp: true, node: false, workerAvailable: true).check()
        XCTAssertFalse(noNode.isYouTubeSeparationReady)
        XCTAssertEqual(ok.isYouTubeSeparationReady, ok.isYouTubeMp3Ready && ok.isWorkerReady)
        XCTAssertEqual(ok.isYouTubeSeparationReady, ok.isYouTubeMp3Ready && ok.isLoadedSeparationReady)
    }

    func testYouTubePreviewDoesNotRequireFFmpeg_whileAcquisitionDoes() {
        // Distinction: preview stays ready when ffmpeg missing, acquisition does not
        let r = checker(ffmpeg: false, ytDlp: true, node: true, workerAvailable: true).check()
        XCTAssertTrue(r.isYouTubePreviewReady, "Preview should stay ready without FFmpeg")
        XCTAssertFalse(r.isYouTubeAcquisitionReady, "Acquisition (legacy) requires FFmpeg")
        XCTAssertFalse(r.isYouTubeMp3Ready)
        XCTAssertFalse(r.isYouTubeSeparationReady)
    }

    // MARK: - Sidebar footer presentation (first-launch)

    func testSidebarFooterHidesWorkerDiagnosticsWhenNotReady() {
        func sidebarFooterText(for readiness: RuntimeReadiness?) -> String {
            guard let r = readiness else { return "Checking setup…" }
            if !r.isWorkerReady { return "Setup needed" }
            return r.sidebarStatus
        }

        // Case 1: worker not executable — sidebarStatus contains path detail
        let missingWorker = checker(ffmpeg: true, ytDlp: true, workerAvailable: false).check()
        XCTAssertFalse(missingWorker.isWorkerReady)
        XCTAssertTrue(missingWorker.sidebarStatus.contains("worker Python"), "diagnostics preserved in model")
        XCTAssertTrue(missingWorker.sidebarStatus.contains("/tmp/worker/.venv/bin/python3"))
        let footer1 = sidebarFooterText(for: missingWorker)
        XCTAssertEqual(footer1, "Setup needed")
        XCTAssertFalse(footer1.contains("Launch configuration"))
        XCTAssertFalse(footer1.contains("missing worker Python"))
        XCTAssertFalse(footer1.contains("/tmp/worker"))

        // Case 2: launch configuration error — sidebarStatus contains diagnostic path
        let launchError = checker(ffmpeg: true, ytDlp: true, resolveThrows: true).check()
        XCTAssertFalse(launchError.isWorkerReady)
        XCTAssertNotNil(launchError.workerError)
        XCTAssertTrue(launchError.sidebarStatus.contains("Setup needed"))
        // diagnostics preserved in model (error contains path)
        XCTAssertTrue(launchError.sidebarStatus.contains("/missing") || launchError.sidebarStatus.contains("worker"))
        let footer2 = sidebarFooterText(for: launchError)
        XCTAssertEqual(footer2, "Setup needed")
        XCTAssertFalse(footer2.contains("Launch configuration"))
        XCTAssertFalse(footer2.contains("/missing"))
        XCTAssertFalse(footer2.contains("missing worker Python"))

        // Nil readiness still shows checking state
        XCTAssertEqual(sidebarFooterText(for: nil), "Checking setup…")

        // When worker ready, footer preserves detailed status (e.g. yt-dlp missing)
        let ytDlpMissing = checker(ffmpeg: true, ytDlp: false, workerAvailable: true).check()
        XCTAssertTrue(ytDlpMissing.isWorkerReady)
        XCTAssertEqual(sidebarFooterText(for: ytDlpMissing), ytDlpMissing.sidebarStatus)
        XCTAssertTrue(ytDlpMissing.sidebarStatus.contains("yt-dlp"))
    }

    @MainActor
    func testPendingState_nilReadinessMeansChecking() {
        let controller = InferenceController()
        XCTAssertNil(controller.runtimeReadiness)
        // UI would show Checking setup… when nil
    }
}
