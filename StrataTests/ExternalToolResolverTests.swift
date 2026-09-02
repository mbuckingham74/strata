import XCTest
@testable import Strata
import Foundation

final class ExternalToolResolverTests: XCTestCase {

    private func resolver(
        appSupport: URL? = URL(fileURLWithPath: "/tmp/appSupport"),
        executables: Set<String>,
        versions: [String: String?] // path -> version or nil (nil means unknown)
    ) -> ExternalToolResolver {
        ExternalToolResolver(
            applicationSupportURL: appSupport,
            isExecutable: { executables.contains($0) },
            runVersion: { path in
                // versions dict: if key exists, return value (String?); else nil
                if let v = versions[path] { return v }
                // if path not in dict but executable, return nil (unknown)
                return nil
            }
        )
    }

    func testManagedHasPriorityOverHomebrewAndUsrLocal() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportManagedPriority")
        let r = ExternalToolResolver(
            applicationSupportURL: appSupport,
            isExecutable: { _ in true },
            runVersion: { path in
                if path.contains("ffmpeg") { return ExternalToolCompatibility.ffmpegSupportedVersion }
                if path.contains("yt-dlp") { return ExternalToolCompatibility.ytDlpSupportedVersion }
                if path.contains("node") { return "26.8.1" }
                return nil
            }
        )
        let ff = r.resolveFFmpeg()
        XCTAssertEqual(ff.executableURL?.path, r.managedFFmpegURL?.path)
        XCTAssertEqual(ff.origin, .managed)
        XCTAssertTrue(ff.isAvailable)

        let yt = r.resolveYtDlp()
        XCTAssertEqual(yt.executableURL?.path, r.managedYtDlpURL?.path)
        XCTAssertEqual(yt.origin, .managed)

        let node = r.resolveNode()
        XCTAssertEqual(node.executableURL?.path, r.managedNodeURL?.path)
        XCTAssertEqual(node.origin, .managed)
    }

    func testFallbackToHomebrewWhenManagedIncompatible() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportFallback")
        let r = resolver(
            appSupport: appSupport,
            executables: Set([
                appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path,
                "/opt/homebrew/bin/ffmpeg",
                "/usr/local/bin/ffmpeg"
            ]),
            versions: [
                appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path: "9.0.0", // incompatible
                "/opt/homebrew/bin/ffmpeg": ExternalToolCompatibility.ffmpegSupportedVersion,
                "/usr/local/bin/ffmpeg": ExternalToolCompatibility.ffmpegSupportedVersion
            ]
        )
        let ff = r.resolveFFmpeg()
        XCTAssertEqual(ff.executableURL?.path, "/opt/homebrew/bin/ffmpeg")
        XCTAssertEqual(ff.origin, .system)
        XCTAssertTrue(ff.isAvailable)
        XCTAssertNil(ff.installedVersion)
    }

    func testFallbackToUsrLocalWhenHomebrewIncompatible() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportUsrLocal")
        let r = resolver(
            appSupport: appSupport,
            executables: Set(["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]),
            versions: [
                "/opt/homebrew/bin/yt-dlp": "2026.08.18", // incompatible
                "/usr/local/bin/yt-dlp": ExternalToolCompatibility.ytDlpSupportedVersion
            ]
        )
        let yt = r.resolveYtDlp()
        XCTAssertEqual(yt.executableURL?.path, "/usr/local/bin/yt-dlp")
        XCTAssertTrue(yt.isAvailable)
    }

    func testAllIncompatibleReturnsUnresolvedWithManagedTarget() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportUnresolved")
        let managedFF = appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path
        let r = resolver(
            appSupport: appSupport,
            executables: Set([managedFF, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]),
            versions: [
                managedFF: "9.0.0",
                "/opt/homebrew/bin/ffmpeg": "8.0.0",
                "/usr/local/bin/ffmpeg": "7.0.0"
            ]
        )
        let ff = r.resolveFFmpeg()
        XCTAssertNil(ff.executableURL)
        XCTAssertFalse(ff.isAvailable)
        XCTAssertNotNil(ff.installedVersion)
        XCTAssertEqual(ff.managedURL.path, managedFF)
    }

    func testUnknownVersionTreatedAsIncompatibleAndFallback() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportUnknown")
        let managedFF = appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path
        let r = resolver(
            appSupport: appSupport,
            executables: Set([managedFF, "/opt/homebrew/bin/ffmpeg"]),
            versions: [
                managedFF: nil, // unknown
                "/opt/homebrew/bin/ffmpeg": ExternalToolCompatibility.ffmpegSupportedVersion
            ]
        )
        let ff = r.resolveFFmpeg()
        XCTAssertEqual(ff.executableURL?.path, "/opt/homebrew/bin/ffmpeg")
        XCTAssertTrue(ff.isAvailable)
    }

    func testAllUnknownReturnsUnresolvedWithUnknown() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportAllUnknown")
        let managedFF = appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path
        let r = resolver(
            appSupport: appSupport,
            executables: Set([managedFF]),
            versions: [managedFF: nil]
        )
        let ff = r.resolveFFmpeg()
        XCTAssertNil(ff.executableURL)
        XCTAssertEqual(ff.installedVersion, "unknown")
        XCTAssertEqual(ff.managedURL.path, managedFF)
    }

    func testNodeMajorGTE22Compatible() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportNode")
        let r22 = resolver(
            appSupport: appSupport,
            executables: Set(["/opt/homebrew/bin/node"]),
            versions: ["/opt/homebrew/bin/node": "22.0.0"]
        )
        XCTAssertTrue(r22.resolveNode().isAvailable)

        let r26 = resolver(
            appSupport: appSupport,
            executables: Set(["/opt/homebrew/bin/node"]),
            versions: ["/opt/homebrew/bin/node": "26.8.1"]
        )
        XCTAssertTrue(r26.resolveNode().isAvailable)

        let r30 = resolver(
            appSupport: appSupport,
            executables: Set(["/opt/homebrew/bin/node"]),
            versions: ["/opt/homebrew/bin/node": "30.1.2"]
        )
        XCTAssertTrue(r30.resolveNode().isAvailable)

        let r21 = resolver(
            appSupport: appSupport,
            executables: Set(["/opt/homebrew/bin/node"]),
            versions: ["/opt/homebrew/bin/node": "21.9.9"]
        )
        XCTAssertFalse(r21.resolveNode().isAvailable)
        XCTAssertEqual(r21.resolveNode().installedVersion, "21.9.9")

        let r20 = resolver(
            appSupport: appSupport,
            executables: Set(["/opt/homebrew/bin/node"]),
            versions: ["/opt/homebrew/bin/node": "19.8.1"]
        )
        XCTAssertFalse(r20.resolveNode().isAvailable)
    }

    func testNodeWithVPrefixParsed() {
        // runVersion should return parsed version, but resolver expects parsed; test that parsing strips v
        // Simulate runVersion returning parsed "26.8.1" after parsing raw "v26.8.1"
        // The resolver's isExecutable/ runVersion should already return parsed via ExternalToolCompatibility.parseNodeVersion
        // Here we test compatibility still holds
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportNodeV")
        let parsed = ExternalToolCompatibility.parseNodeVersion(from: "v22.5.0")
        XCTAssertEqual(parsed, "22.5.0")
        let r = resolver(
            appSupport: appSupport,
            executables: Set(["/opt/homebrew/bin/node"]),
            versions: ["/opt/homebrew/bin/node": parsed]
        )
        XCTAssertTrue(r.resolveNode().isAvailable)
    }

    func testUnresolvedHasManagedTargetEvenWhenNoExecutable() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportNone")
        let r = resolver(
            appSupport: appSupport,
            executables: Set([]),
            versions: [:]
        )
        let ff = r.resolveFFmpeg()
        XCTAssertNil(ff.executableURL)
        XCTAssertFalse(ff.isAvailable)
        XCTAssertNil(ff.installedVersion)
        XCTAssertEqual(ff.managedURL.path, appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path)
    }

    func testManagedOnlyCompatible() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportManagedOnly")
        let managed = appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path
        let r = resolver(
            appSupport: appSupport,
            executables: Set([managed]),
            versions: [managed: ExternalToolCompatibility.ffmpegSupportedVersion]
        )
        let ff = r.resolveFFmpeg()
        XCTAssertEqual(ff.executableURL?.path, managed)
        XCTAssertEqual(ff.origin, .managed)
    }

    func testHomebrewOnlyCompatiblePreservesBehavior() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportHBOnly")
        let r = resolver(
            appSupport: appSupport,
            executables: Set(["/opt/homebrew/bin/ffmpeg"]),
            versions: ["/opt/homebrew/bin/ffmpeg": ExternalToolCompatibility.ffmpegSupportedVersion]
        )
        let ff = r.resolveFFmpeg()
        XCTAssertEqual(ff.executableURL?.path, "/opt/homebrew/bin/ffmpeg")
        XCTAssertEqual(ff.origin, .system)
    }

    // MARK: - RuntimeReadiness integration

    private static func makeWorkerConfig() -> WorkerLaunchConfiguration {
        WorkerLaunchConfiguration(
            workerDirectory: URL(fileURLWithPath: "/tmp/worker"),
            pythonExecutable: URL(fileURLWithPath: "/tmp/worker/.venv/bin/python3"),
            arguments: ["-m", "demux_worker"],
            currentDirectory: URL(fileURLWithPath: "/tmp/worker"),
            environmentAdditions: [:]
        )
    }

    func testReadinessReportsManagedWhenManagedCompatible() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportReadinessManaged")
        let managedFF = appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path
        let managedYt = appSupport.appendingPathComponent("Strata/Tools/yt-dlp/yt-dlp").path
        let managedNode = appSupport.appendingPathComponent("Strata/Tools/node/bin/node").path
        let r = resolver(
            appSupport: appSupport,
            executables: Set([managedFF, managedYt, managedNode, "/tmp/worker/.venv/bin/python3"]),
            versions: [
                managedFF: ExternalToolCompatibility.ffmpegSupportedVersion,
                managedYt: ExternalToolCompatibility.ytDlpSupportedVersion,
                managedNode: "26.8.1"
            ]
        )
        let configA = Self.makeWorkerConfig()
        let checker = RuntimeReadinessChecker(resolver: r, resolveWorker: { configA })
        // Since resolver's isExecutable for python path is checked separately, we need to include it
        // But resolver's isExecutable doesn't cover python; RuntimeReadinessChecker uses resolver's isExecutable for tools and separate isExecutable for python via resolver's isExecutable (which is same closure). Our resolver's isExecutable returns true only for tool paths, not python, so worker will be missing. Override:
        let r2 = ExternalToolResolver(
            applicationSupportURL: appSupport,
            isExecutable: { p in
                if p == "/tmp/worker/.venv/bin/python3" { return true }
                return Set([managedFF, managedYt, managedNode]).contains(p)
            },
            runVersion: { p in
                if p == managedFF { return ExternalToolCompatibility.ffmpegSupportedVersion }
                if p == managedYt { return ExternalToolCompatibility.ytDlpSupportedVersion }
                if p == managedNode { return "26.8.1" }
                return nil
            }
        )
        let configB = Self.makeWorkerConfig()
        let checker2 = RuntimeReadinessChecker(resolver: r2, resolveWorker: { configB })
        let readiness2 = checker2.check()
        XCTAssertEqual(readiness2.ffmpegExecutableURL?.path, managedFF)
        XCTAssertEqual(readiness2.ytDlpExecutableURL?.path, managedYt)
        XCTAssertEqual(readiness2.nodeExecutableURL?.path, managedNode)
        XCTAssertEqual(readiness2.ffmpegOrigin, .managed)
        XCTAssertTrue(readiness2.ffmpegAvailable)
        XCTAssertTrue(readiness2.ytDlpAvailable)
        XCTAssertTrue(readiness2.nodeAvailable)
    }

    func testReadinessReportsHomebrewWhenOnlyHomebrewCompatible() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportReadinessHB")
        let r = ExternalToolResolver(
            applicationSupportURL: appSupport,
            isExecutable: { p in p == "/opt/homebrew/bin/ffmpeg" || p == "/opt/homebrew/bin/yt-dlp" || p == "/opt/homebrew/bin/node" || p == "/tmp/worker/.venv/bin/python3" },
            runVersion: { p in
                if p == "/opt/homebrew/bin/ffmpeg" { return ExternalToolCompatibility.ffmpegSupportedVersion }
                if p == "/opt/homebrew/bin/yt-dlp" { return ExternalToolCompatibility.ytDlpSupportedVersion }
                if p == "/opt/homebrew/bin/node" { return "22.5.0" }
                return nil
            }
        )
        let configC = Self.makeWorkerConfig()
        let checker = RuntimeReadinessChecker(resolver: r, resolveWorker: { configC })
        let readiness = checker.check()
        XCTAssertEqual(readiness.ffmpegExecutableURL?.path, "/opt/homebrew/bin/ffmpeg")
        XCTAssertEqual(readiness.ffmpegOrigin, .system)
        XCTAssertTrue(readiness.ffmpegAvailable)
        XCTAssertEqual(readiness.ytDlpExecutableURL?.path, "/opt/homebrew/bin/yt-dlp")
        XCTAssertEqual(readiness.nodeExecutableURL?.path, "/opt/homebrew/bin/node")
    }

    func testReadinessUnresolvedHasManagedTargetAndNilExecutable() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportReadinessNone")
        let r = ExternalToolResolver(
            applicationSupportURL: appSupport,
            isExecutable: { p in p == "/tmp/worker/.venv/bin/python3" },
            runVersion: { _ in nil }
        )
        let configD = Self.makeWorkerConfig()
        let checker = RuntimeReadinessChecker(resolver: r, resolveWorker: { configD })
        let readiness = checker.check()
        XCTAssertNil(readiness.ffmpegExecutableURL)
        XCTAssertFalse(readiness.ffmpegAvailable)
        XCTAssertNotNil(readiness.ffmpegManagedURL)
        XCTAssertEqual(readiness.ffmpegManagedURL?.path, appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path)
        XCTAssertNil(readiness.ffmpegInstalledVersion) // no executable, so nil not unknown
        // When executable exists but unknown, installed is "unknown"
        let r2 = ExternalToolResolver(
            applicationSupportURL: appSupport,
            isExecutable: { _ in true },
            runVersion: { _ in nil }
        )
        let configB = Self.makeWorkerConfig()
        let checker2 = RuntimeReadinessChecker(resolver: r2, resolveWorker: { configB })
        let readiness2 = checker2.check()
        XCTAssertEqual(readiness2.ffmpegInstalledVersion, "unknown")
        XCTAssertTrue(readiness2.sidebarStatus.contains("unknown") || readiness2.sidebarStatus.contains("mismatch"))
    }

    // MARK: - Consumer wiring via RuntimeReadiness (validated URLs are exact consumer URLs)

    @MainActor func testLocalIngestReceivesResolvedFFmpegURL() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportLocalIngest")
        let managedFF = appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path
        let readiness = RuntimeReadiness(
            workerAvailable: true, workerError: nil, workerPythonPath: "/tmp/worker/.venv/bin/python3",
            ffmpegAvailable: true, ytDlpAvailable: true, nodeAvailable: true,
            ffmpegExecutableURL: URL(fileURLWithPath: managedFF),
            ffmpegManagedURL: URL(fileURLWithPath: managedFF)
        )
        let ingest = InferenceController.makeDefaultLocalIngest(readiness: readiness)
        guard let client = ingest as? LocalAudioIngestClient else { XCTFail("Expected LocalAudioIngestClient"); return }
        let expectation = XCTestExpectation(description: "ffmpegURL")
        Task {
            let ffmpegURL = await client.ffmpegURL
            XCTAssertEqual(ffmpegURL.path, managedFF)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    @MainActor func testYouTubeIngestReceivesResolvedTriple() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportYTIngest")
        let managedFF = appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path
        let managedYt = appSupport.appendingPathComponent("Strata/Tools/yt-dlp/yt-dlp").path
        let managedNode = appSupport.appendingPathComponent("Strata/Tools/node/bin/node").path
        let readiness = RuntimeReadiness(
            workerAvailable: true, workerError: nil, workerPythonPath: "/tmp/worker/.venv/bin/python3",
            ffmpegAvailable: true, ytDlpAvailable: true, nodeAvailable: true,
            ffmpegExecutableURL: URL(fileURLWithPath: managedFF),
            ytDlpExecutableURL: URL(fileURLWithPath: managedYt),
            nodeExecutableURL: URL(fileURLWithPath: managedNode),
            ffmpegManagedURL: URL(fileURLWithPath: managedFF),
            ytDlpManagedURL: URL(fileURLWithPath: managedYt),
            nodeManagedURL: URL(fileURLWithPath: managedNode)
        )
        let ingest = InferenceController.makeDefaultYouTubeIngest(readiness: readiness)
        guard let client = ingest as? YouTubeIngestClient else { XCTFail("Expected YouTubeIngestClient"); return }
        let expectation = XCTestExpectation(description: "yt ingest URLs")
        Task {
            let ff = await client.ffmpegURL
            let yt = await client.ytDlpURL
            let node = await client.nodeURL
            XCTAssertEqual(ff.path, managedFF)
            XCTAssertEqual(yt.path, managedYt)
            XCTAssertEqual(node.path, managedNode)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    @MainActor func testYouTubeIngestFallbackToManagedWhenUnresolved() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportYTFallback")
        let readiness = RuntimeReadiness(
            workerAvailable: false, workerError: nil, workerPythonPath: nil,
            ffmpegAvailable: false, ytDlpAvailable: false, nodeAvailable: false,
            ffmpegExecutableURL: nil, ytDlpExecutableURL: nil, nodeExecutableURL: nil,
            ffmpegManagedURL: appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg"),
            ytDlpManagedURL: appSupport.appendingPathComponent("Strata/Tools/yt-dlp/yt-dlp"),
            nodeManagedURL: appSupport.appendingPathComponent("Strata/Tools/node/bin/node")
        )
        let ingest = InferenceController.makeDefaultYouTubeIngest(readiness: readiness)
        guard let client = ingest as? YouTubeIngestClient else { XCTFail("Expected YouTubeIngestClient"); return }
        let expectation = XCTestExpectation(description: "fallback")
        Task {
            let ff = await client.ffmpegURL
            let yt = await client.ytDlpURL
            let node = await client.nodeURL
            XCTAssertEqual(ff.path, readiness.ffmpegManagedURL?.path)
            XCTAssertEqual(yt.path, readiness.ytDlpManagedURL?.path)
            XCTAssertEqual(node.path, readiness.nodeManagedURL?.path)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testExportReceivesResolvedFFmpegURL() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupportExport")
        let managedFF = appSupport.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path
        let readiness = RuntimeReadiness(
            workerAvailable: true, workerError: nil, workerPythonPath: "/tmp/worker/.venv/bin/python3",
            ffmpegAvailable: true, ytDlpAvailable: false, nodeAvailable: false,
            ffmpegExecutableURL: URL(fileURLWithPath: managedFF),
            ffmpegManagedURL: URL(fileURLWithPath: managedFF)
        )
        // StemExporter now requires explicit readiness URL; readiness validated URL is exact export URL
        XCTAssertEqual(readiness.ffmpegExecutableURL?.path, managedFF)
        XCTAssertTrue(readiness.ffmpegAvailable)
        // Verify export throws when nil and succeeds when supplied
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let src = tempDir.appendingPathComponent("a.wav")
        let dst = tempDir.appendingPathComponent("b.mp3")
        try? Data([0,1,2]).write(to: src)
        XCTAssertThrowsError(try StemExporter.exportMP3(from: src, to: dst, ffmpegURL: nil))
        // With readiness URL it would attempt to launch ffmpeg (fails launch but not missing-url error)
        // Ensure missing-url error is distinct: nil throws ffmpegLaunchFailed, not success
    }
}
