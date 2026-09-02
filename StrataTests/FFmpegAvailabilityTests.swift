import XCTest
@testable import Strata
import Foundation

// MARK: - FFmpegAvailabilityTests

private func ffmpegVersionRaw(_ version: String) -> String {
    "ffmpeg version \(version) Copyright (c) 2000-2026 the FFmpeg developers"
}

final class FFmpegAvailabilityTests: XCTestCase {

    private final class ProbeBox: @unchecked Sendable {
        var isExecutableCalls: [String] = []
        var fileExistsCalls: [String] = []
        var createdDirectories: [String] = []
        var runCalls: [(executable: String, args: [String])] = []
        var downloads: [(remote: String, local: String)] = []
        var extracts: [(archive: String, dest: String)] = []
        var moves: [(from: String, to: String)] = []
        var removed: [String] = []
        var stagedPaths: Set<String> = []
    }

    private func makeSUT(
        support: URL? = URL(fileURLWithPath: "/tmp/fakeSupport"),
        box: ProbeBox,
        executables: Set<String> = [],
        existing: Set<String> = [],
        versions: [String: String] = [:],
        stagedExecutable: Bool = true,
        stagedVersionRaw: String? = nil,
        stagedVersionExit: Int32 = 0,
        downloadError: Error? = nil,
        extractError: Error? = nil,
        moveError: Error? = nil
    ) -> FFmpegAvailability {
        FFmpegAvailability(
            applicationSupportURL: support,
            isExecutable: { path in
                box.isExecutableCalls.append(path)
                if path.contains(".tmp-ffmpeg") { return stagedExecutable && box.stagedPaths.contains(path) }
                if box.stagedPaths.contains(path) { return stagedExecutable }
                return executables.contains(path)
            },
            fileExists: { path in
                box.fileExistsCalls.append(path)
                if path.contains(".tmp-ffmpeg") { return box.stagedPaths.contains(path) }
                return existing.contains(path)
            },
            createDirectory: { url in
                box.createdDirectories.append(url.path)
            },
            runProcess: { url, args, _ in
                box.runCalls.append((url.path, args))
                if url.path.contains(".tmp-ffmpeg") || url.path == support?.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg").path {
                    // Staged or freshly installed managed binary probe
                    if stagedVersionExit != 0 {
                        return FFmpegAvailability.ProcessOutcome(terminationStatus: stagedVersionExit, stdout: nil, stderr: "probe failed")
                    }
                    if let raw = stagedVersionRaw {
                        return FFmpegAvailability.ProcessOutcome(terminationStatus: 0, stdout: raw, stderr: nil)
                    }
                }
                if args == ["-version"], let raw = versions[url.path] {
                    return FFmpegAvailability.ProcessOutcome(terminationStatus: 0, stdout: raw, stderr: nil)
                }
                return FFmpegAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: "not found")
            },
            downloadFile: { remote, local in
                box.downloads.append((remote.absoluteString, local.path))
                if let err = downloadError { throw err }
            },
            extractBinary: { archive, dest in
                box.extracts.append((archive.path, dest.path))
                if let err = extractError { throw err }
                box.stagedPaths.insert(dest.path)
            },
            moveFile: { from, to in
                box.moves.append((from.path, to.path))
                if let err = moveError { throw err }
                box.stagedPaths.remove(from.path)
                box.stagedPaths.insert(to.path)
            },
            removeFile: { url in
                box.removed.append(url.path)
                box.stagedPaths.remove(url.path)
            }
        )
    }

    private func versionRaw(_ version: String) -> String {
        ffmpegVersionRaw(version)
    }

    // MARK: - Managed paths

    func testManagedPaths() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let box = ProbeBox()
        let sut = makeSUT(support: support, box: box)
        XCTAssertEqual(sut.managedDirectoryURL?.path, "/tmp/fakeSupport/Strata/Tools/ffmpeg")
        XCTAssertEqual(sut.managedExecutableURL?.path, "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg")
        XCTAssertFalse(sut.managedExecutableURL!.path.hasSuffix("/bin/ffmpeg"))
        XCTAssertEqual(sut.managedExecutableURL?.lastPathComponent, "ffmpeg")
    }

    func testManagedPathsNilSupport() {
        let box = ProbeBox()
        let sut = makeSUT(support: nil, box: box)
        XCTAssertNil(sut.managedDirectoryURL)
        XCTAssertNil(sut.managedExecutableURL)
    }

    func testCandidatePathsPriorityMatchesResolver() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let box = ProbeBox()
        let sut = makeSUT(support: support, box: box)
        XCTAssertEqual(sut.candidatePaths, [
            "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        ])
        // Same order as ExternalToolResolver
        let resolver = ExternalToolResolver(
            applicationSupportURL: support,
            isExecutable: { _ in false },
            runVersion: { _ in nil }
        )
        XCTAssertEqual(sut.candidatePaths, resolver.ffmpegCandidatePaths)
    }

    func testDownloadURLPinnedToSupportedVersion() {
        let version = ExternalToolCompatibility.ffmpegSupportedVersion
        let url = FFmpegAvailability.downloadURL(forVersion: version)
        XCTAssertTrue(url.absoluteString.contains(version), "Download URL must be pinned to \(version)")
        XCTAssertFalse(url.absoluteString.contains("Projects"))
        XCTAssertFalse(url.absoluteString.contains("Documents"))
        let box = ProbeBox()
        let sut = makeSUT(box: box)
        XCTAssertEqual(sut.downloadURL, FFmpegAvailability.downloadURL(forVersion: version))
    }

    // MARK: - Reuse when valid

    func testEnsureAvailableReusesManagedWhenCompatible() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg"
        let box = ProbeBox()
        let sut = makeSUT(
            support: support,
            box: box,
            executables: [managed],
            versions: [managed: versionRaw(ExternalToolCompatibility.ffmpegSupportedVersion)]
        )
        XCTAssertEqual(sut.ensureAvailable(), .success(URL(fileURLWithPath: managed)))
        XCTAssertTrue(box.downloads.isEmpty, "Must NOT download when managed is compatible")
        XCTAssertTrue(box.extracts.isEmpty)
        XCTAssertTrue(box.moves.isEmpty)
        XCTAssertTrue(box.createdDirectories.isEmpty)
    }

    func testEnsureAvailableReusesSystemWhenManagedMissing() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let homebrew = "/opt/homebrew/bin/ffmpeg"
        let box = ProbeBox()
        let sut = makeSUT(
            support: support,
            box: box,
            executables: [homebrew],
            versions: [homebrew: versionRaw(ExternalToolCompatibility.ffmpegSupportedVersion)]
        )
        XCTAssertEqual(sut.ensureAvailable(), .success(URL(fileURLWithPath: homebrew)))
        XCTAssertTrue(box.downloads.isEmpty)
        XCTAssertTrue(box.moves.isEmpty)
        XCTAssertTrue(box.createdDirectories.isEmpty)
    }

    func testEnsureAvailableSkipsIncompatibleManagedForCompatibleSystem() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg"
        let homebrew = "/opt/homebrew/bin/ffmpeg"
        let box = ProbeBox()
        let sut = makeSUT(
            support: support,
            box: box,
            executables: [managed, homebrew],
            versions: [
                managed: versionRaw("8.0.0"),
                homebrew: versionRaw(ExternalToolCompatibility.ffmpegSupportedVersion)
            ]
        )
        XCTAssertEqual(sut.ensureAvailable(), .success(URL(fileURLWithPath: homebrew)))
        XCTAssertTrue(box.downloads.isEmpty, "Compatible system copy must win over download")
    }

    // MARK: - Installs when missing

    func testEnsureAvailableInstallsWhenMissing() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg"
        let managedDir = "/tmp/fakeSupport/Strata/Tools/ffmpeg"
        let version = ExternalToolCompatibility.ffmpegSupportedVersion
        let box = ProbeBox()
        let sut = makeSUT(
            support: support,
            box: box,
            stagedVersionRaw: versionRaw(version)
        )
        let result = sut.ensureAvailable()
        XCTAssertEqual(result, .success(URL(fileURLWithPath: managed)))
        // Creates only the managed directory
        XCTAssertEqual(box.createdDirectories, [managedDir])
        // Downloads to a same-dir temp file, never the final path
        XCTAssertEqual(box.downloads.count, 1)
        XCTAssertTrue(box.downloads[0].remote.contains(version))
        let tmpArchive = box.downloads[0].local
        XCTAssertNotEqual(tmpArchive, managed)
        XCTAssertEqual(URL(fileURLWithPath: tmpArchive).deletingLastPathComponent().path, managedDir)
        // Extracts archive -> same-dir staged binary
        XCTAssertEqual(box.extracts.count, 1)
        XCTAssertEqual(box.extracts[0].archive, tmpArchive)
        let tmpBinary = box.extracts[0].dest
        XCTAssertNotEqual(tmpBinary, managed)
        XCTAssertEqual(URL(fileURLWithPath: tmpBinary).deletingLastPathComponent().path, managedDir)
        // Atomic rename staged -> managed
        XCTAssertEqual(box.moves.count, 1)
        XCTAssertEqual(box.moves[0].from, tmpBinary)
        XCTAssertEqual(box.moves[0].to, managed)
        // Archive temp cleaned up
        XCTAssertTrue(box.removed.contains(tmpArchive))
    }

    func testInstalledManagedIsDiscoveredByResolverAndCheck() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg"
        let version = ExternalToolCompatibility.ffmpegSupportedVersion
        let box = ProbeBox()
        let sut = makeSUT(support: support, box: box, stagedVersionRaw: versionRaw(version))
        XCTAssertEqual(sut.ensureAvailable(), .success(URL(fileURLWithPath: managed)))

        // Existing ExternalToolResolver must discover the installed copy as managed.
        let resolver = ExternalToolResolver(
            applicationSupportURL: support,
            isExecutable: { $0 == managed },
            runVersion: { path in
                guard path == managed else { return nil }
                return ExternalToolCompatibility.parseFFmpegVersion(from: ffmpegVersionRaw(version))
            }
        )
        let resolved = resolver.resolveFFmpeg()
        XCTAssertTrue(resolved.isAvailable)
        XCTAssertEqual(resolved.executableURL?.path, managed)
        XCTAssertEqual(resolved.origin, .managed)

        // Existing RuntimeReadiness.check() must report FFmpeg available.
        let workerPython = "/tmp/fakeWorker/.venv/bin/python3"
        let workerConfig = WorkerLaunchConfiguration(
            workerDirectory: URL(fileURLWithPath: "/tmp/fakeWorker"),
            pythonExecutable: URL(fileURLWithPath: workerPython),
            arguments: ["-m", "demux_worker"],
            currentDirectory: URL(fileURLWithPath: "/tmp/fakeWorker"),
            environmentAdditions: [:]
        )
        let checker = RuntimeReadinessChecker(
            resolver: resolver,
            resolveWorker: {
                WorkerLaunchConfiguration(
                    workerDirectory: workerConfig.workerDirectory,
                    pythonExecutable: workerConfig.pythonExecutable,
                    arguments: workerConfig.arguments,
                    currentDirectory: workerConfig.currentDirectory,
                    environmentAdditions: workerConfig.environmentAdditions
                )
            }
        )
        // Worker python check uses the resolver's isExecutable; report worker missing is fine here.
        let readiness = checker.check()
        XCTAssertTrue(readiness.ffmpegAvailable)
        XCTAssertEqual(readiness.ffmpegExecutableURL?.path, managed)
        XCTAssertEqual(readiness.ffmpegOrigin, .managed)
    }

    // MARK: - Atomicity / verification

    func testVersionMismatchAfterInstallFailsAndNeverMovesIntoPlace() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg"
        let version = ExternalToolCompatibility.ffmpegSupportedVersion
        let box = ProbeBox()
        let sut = makeSUT(support: support, box: box, stagedVersionRaw: versionRaw("8.0.0"))
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .verificationFailed(let msg) = err {
                XCTAssertTrue(msg.contains(version) || msg.contains("mismatch"))
            } else {
                XCTFail("Expected verificationFailed, got \(err)")
            }
        } else {
            XCTFail("Expected failure for version mismatch")
        }
        XCTAssertTrue(box.moves.isEmpty, "Mismatched staged binary must never be renamed into place")
        XCTAssertFalse(box.isExecutableCalls.contains(managed) && box.stagedPaths.contains(managed),
                       "Partial install must never validate as ready at \(managed)")
    }

    func testEmptyVersionOutputBeforeMoveFailsWithoutMove() {
        let box = ProbeBox()
        let sut = makeSUT(box: box, stagedVersionRaw: "")
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .verificationFailed = err { /* expected */ } else {
                XCTFail("Expected verificationFailed for empty version output, got \(err)")
            }
        } else {
            XCTFail("Expected failure for empty version output")
        }
        XCTAssertTrue(box.moves.isEmpty, "Empty version output must never move into place")
        XCTAssertTrue(box.stagedPaths.isEmpty, "Staged temp must be cleaned up")
    }

    func testUnparseableVersionOutputBeforeMoveFailsWithoutMove() {
        let box = ProbeBox()
        let sut = makeSUT(box: box, stagedVersionRaw: "not an ffmpeg binary")
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .verificationFailed = err { /* expected */ } else {
                XCTFail("Expected verificationFailed for unparseable version output, got \(err)")
            }
        } else {
            XCTFail("Expected failure for unparseable version output")
        }
        XCTAssertTrue(box.moves.isEmpty, "Unparseable version output must never move into place")
        XCTAssertTrue(box.stagedPaths.isEmpty, "Staged temp must be cleaned up")
    }

    private func makePostMoveSUT(box: ProbeBox, managedRaw: String?) -> FFmpegAvailability {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg"
        let version = ExternalToolCompatibility.ffmpegSupportedVersion
        return FFmpegAvailability(
            applicationSupportURL: support,
            isExecutable: { path in
                box.isExecutableCalls.append(path)
                if box.stagedPaths.contains(path) { return true }
                return false
            },
            fileExists: { path in
                box.fileExistsCalls.append(path)
                return box.stagedPaths.contains(path)
            },
            createDirectory: { url in
                box.createdDirectories.append(url.path)
            },
            runProcess: { url, args, _ in
                box.runCalls.append((url.path, args))
                if url.path.contains(".tmp-ffmpeg") {
                    return FFmpegAvailability.ProcessOutcome(terminationStatus: 0, stdout: ffmpegVersionRaw(version), stderr: nil)
                }
                if url.path == managed {
                    // Post-move probe: exit 0 with empty/unparseable output
                    return FFmpegAvailability.ProcessOutcome(terminationStatus: 0, stdout: managedRaw, stderr: nil)
                }
                return FFmpegAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            },
            downloadFile: { remote, local in
                box.downloads.append((remote.absoluteString, local.path))
            },
            extractBinary: { archive, dest in
                box.extracts.append((archive.path, dest.path))
                box.stagedPaths.insert(dest.path)
            },
            moveFile: { from, to in
                box.moves.append((from.path, to.path))
                box.stagedPaths.remove(from.path)
                box.stagedPaths.insert(to.path)
            },
            removeFile: { url in
                box.removed.append(url.path)
                box.stagedPaths.remove(url.path)
            }
        )
    }

    func testPostMoveEmptyVersionFailsAndRemovesManagedInstall() {
        let managed = "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg"
        let box = ProbeBox()
        let sut = makePostMoveSUT(box: box, managedRaw: "")
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .verificationFailed = err { /* expected */ } else {
                XCTFail("Expected verificationFailed for empty post-move version output, got \(err)")
            }
        } else {
            XCTFail("Expected failure for empty post-move version output")
        }
        XCTAssertEqual(box.moves.count, 1)
        XCTAssertTrue(box.removed.contains(managed), "Bad managed install must be removed")
        XCTAssertFalse(box.stagedPaths.contains(managed), "Invalid binary must not remain at managed path")
    }

    func testPostMoveUnparseableVersionFailsAndRemovesManagedInstall() {
        let managed = "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg"
        let box = ProbeBox()
        let sut = makePostMoveSUT(box: box, managedRaw: "garbage with no version")
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .verificationFailed = err { /* expected */ } else {
                XCTFail("Expected verificationFailed for unparseable post-move version output, got \(err)")
            }
        } else {
            XCTFail("Expected failure for unparseable post-move version output")
        }
        XCTAssertEqual(box.moves.count, 1)
        XCTAssertTrue(box.removed.contains(managed), "Bad managed install must be removed")
        XCTAssertFalse(box.stagedPaths.contains(managed), "Invalid binary must not remain at managed path")
    }

    func testNotExecutableAfterExtractFailsVerification() {
        let box = ProbeBox()
        let sut = makeSUT(box: box, stagedExecutable: false, stagedVersionRaw: versionRaw(ExternalToolCompatibility.ffmpegSupportedVersion))
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .verificationFailed = err { /* expected */ } else {
                XCTFail("Expected verificationFailed, got \(err)")
            }
        } else {
            XCTFail("Expected failure when staged binary not executable")
        }
        XCTAssertTrue(box.moves.isEmpty)
    }

    func testDownloadFailureSurfacesInstallFailedWithoutMove() {
        struct DownloadBoom: Error {}
        let box = ProbeBox()
        let sut = makeSUT(box: box, downloadError: DownloadBoom())
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .installFailed = err { /* expected */ } else {
                XCTFail("Expected installFailed, got \(err)")
            }
        } else {
            XCTFail("Expected failure when download throws")
        }
        XCTAssertTrue(box.extracts.isEmpty)
        XCTAssertTrue(box.moves.isEmpty, "Failed download must never reach rename")
        XCTAssertFalse(box.downloads.isEmpty)
        // Temps cleaned up, final never staged
        XCTAssertTrue(box.stagedPaths.isEmpty)
    }

    func testExtractFailureSurfacesWithoutMove() {
        struct ExtractBoom: Error {}
        let box = ProbeBox()
        let sut = makeSUT(box: box, extractError: ExtractBoom())
        let result = sut.ensureAvailable()
        if case .failure = result { /* expected */ } else {
            XCTFail("Expected failure when extraction throws")
        }
        XCTAssertTrue(box.moves.isEmpty)
        XCTAssertTrue(box.stagedPaths.isEmpty)
    }

    func testEnsureAvailableFailsWhenApplicationSupportNil() {
        let box = ProbeBox()
        let sut = makeSUT(support: nil, box: box)
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .missingApplicationSupport = err { /* expected */ } else {
                XCTFail("Expected missingApplicationSupport, got \(err)")
            }
        } else {
            XCTFail("Expected failure when support nil")
        }
        XCTAssertTrue(box.downloads.isEmpty)
        XCTAssertTrue(box.moves.isEmpty)
    }

    // MARK: - Never touches Projects

    func testNeverTouchesProjectsOrDocuments() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managedDir = "/tmp/fakeSupport/Strata/Tools/ffmpeg"
        let version = ExternalToolCompatibility.ffmpegSupportedVersion
        let box = ProbeBox()
        let sut = FFmpegAvailability(
            applicationSupportURL: support,
            isExecutable: { path in
                XCTAssertFalse(path.contains("Projects"), "isExecutable must not probe Projects: \(path)")
                XCTAssertFalse(path.contains("Documents"), "isExecutable must not probe Documents: \(path)")
                box.isExecutableCalls.append(path)
                if box.stagedPaths.contains(path) { return true }
                if path.contains(".tmp-ffmpeg") { return box.stagedPaths.contains(path) }
                return false
            },
            fileExists: { path in
                XCTAssertFalse(path.contains("Projects"))
                XCTAssertFalse(path.contains("Documents"))
                box.fileExistsCalls.append(path)
                return box.stagedPaths.contains(path)
            },
            createDirectory: { url in
                XCTAssertFalse(url.path.contains("Projects"))
                XCTAssertFalse(url.path.contains("Documents"))
                XCTAssertEqual(url.path, managedDir)
                box.createdDirectories.append(url.path)
            },
            runProcess: { url, args, _ in
                XCTAssertFalse(url.path.contains("Projects"))
                XCTAssertFalse(url.path.contains("Documents"))
                box.runCalls.append((url.path, args))
                if url.path.contains(".tmp-ffmpeg") || url.path.hasSuffix("Strata/Tools/ffmpeg/ffmpeg") {
                    return FFmpegAvailability.ProcessOutcome(terminationStatus: 0, stdout: ffmpegVersionRaw(version), stderr: nil)
                }
                return FFmpegAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            },
            downloadFile: { remote, local in
                XCTAssertFalse(local.path.contains("Projects"))
                XCTAssertFalse(local.path.contains("Documents"))
                box.downloads.append((remote.absoluteString, local.path))
            },
            extractBinary: { archive, dest in
                XCTAssertFalse(archive.path.contains("Projects"))
                XCTAssertFalse(dest.path.contains("Projects"))
                box.extracts.append((archive.path, dest.path))
                box.stagedPaths.insert(dest.path)
            },
            moveFile: { from, to in
                XCTAssertFalse(from.path.contains("Projects"))
                XCTAssertFalse(to.path.contains("Projects"))
                box.moves.append((from.path, to.path))
                box.stagedPaths.remove(from.path)
                box.stagedPaths.insert(to.path)
            },
            removeFile: { url in
                XCTAssertFalse(url.path.contains("Projects"))
                box.removed.append(url.path)
                box.stagedPaths.remove(url.path)
            }
        )
        let result = sut.ensureAvailable()
        XCTAssertEqual(result, .success(URL(fileURLWithPath: managedDir + "/ffmpeg")))
        for paths in [box.isExecutableCalls, box.fileExistsCalls, box.createdDirectories, box.removed] {
            for p in paths {
                XCTAssertFalse(p.contains("Projects"), "Must never touch Projects: \(p)")
                XCTAssertFalse(p.contains("Documents"), "Must never touch Documents: \(p)")
            }
        }
        for call in box.runCalls + box.downloads.map({ ($0.local, []) }) {
            XCTAssertFalse(call.0.contains("Projects"))
        }
    }
}

// MARK: - FFmpegSetupTests (runSetup wiring)

private final class FFmpegCountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}

private func ffmpegSetupWorkerChecker(workerAvailable: Bool) -> RuntimeReadinessChecker {
    let dir = URL(fileURLWithPath: "/tmp/ffmpegSetupWorker")
    let python = URL(fileURLWithPath: "/tmp/ffmpegSetupWorker/.venv/bin/python3")
    let config = WorkerLaunchConfiguration(
        workerDirectory: dir,
        pythonExecutable: python,
        arguments: ["-m", "demux_worker"],
        currentDirectory: dir,
        environmentAdditions: [:]
    )
    return RuntimeReadinessChecker(
        isExecutable: { $0 == python.path ? workerAvailable : false },
        resolveWorker: { config }
    )
}

private func ffmpegResolvedTool(available: Bool) -> ResolvedExternalTool {
    let support = URL(fileURLWithPath: "/tmp/fakeSupport")
    if available {
        return ResolvedExternalTool(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            version: ExternalToolCompatibility.ffmpegSupportedVersion,
            origin: .system,
            managedURL: support.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg"),
            installedVersion: nil,
            attemptedPath: nil
        )
    }
    return ResolvedExternalTool(
        executableURL: nil,
        version: nil,
        origin: nil,
        managedURL: support.appendingPathComponent("Strata/Tools/ffmpeg/ffmpeg"),
        installedVersion: nil,
        attemptedPath: nil
    )
}

@MainActor
final class FFmpegSetupTests: XCTestCase {

    func testRunSetupSkipsFFmpegEnsureWhenResolved() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: ffmpegSetupWorkerChecker(workerAvailable: false))
        let ensureCount = FFmpegCountBox()
        let provisionCount = FFmpegCountBox()
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let readyChecker = ffmpegSetupWorkerChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedTool(available: true) },
            ensureFfmpegAvailable: {
                ensureCount.increment()
                return .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg"))
            },
            provisionWorker: { _ in
                provisionCount.increment()
                return .success
            },
            refreshReadiness: { await ctrl.refreshRuntimeReadiness(checker: readyChecker) }
        )

        XCTAssertEqual(ensureCount.value, 0, "Compatible resolved FFmpeg must skip provisioning")
        XCTAssertEqual(provisionCount.value, 1)
        XCTAssertEqual(controller.setupStage, .idle)
        XCTAssertTrue(controller.isWorkerReady)
    }

    func testRunSetupProvisionsFFmpegWhenUnresolved() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: ffmpegSetupWorkerChecker(workerAvailable: false))
        let ensureCount = FFmpegCountBox()
        let managed = URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg")
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let readyChecker = ffmpegSetupWorkerChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedTool(available: false) },
            ensureFfmpegAvailable: {
                ensureCount.increment()
                return .success(managed)
            },
            provisionWorker: { _ in .success },
            refreshReadiness: { await ctrl.refreshRuntimeReadiness(checker: readyChecker) }
        )

        XCTAssertEqual(ensureCount.value, 1, "Unresolved FFmpeg must trigger provisioning")
        XCTAssertEqual(controller.setupStage, .idle)
    }

    func testRunSetupFFmpegFailureSurfacesTruncatedAndStops_tryAgainSucceeds() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: ffmpegSetupWorkerChecker(workerAvailable: false))
        let provisionCount = FFmpegCountBox()
        let refreshCount = FFmpegCountBox()
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let longMsg = String(repeating: "f", count: 600)
        let readyChecker = ffmpegSetupWorkerChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedTool(available: false) },
            ensureFfmpegAvailable: { .failure(.verificationFailed(longMsg)) },
            provisionWorker: { _ in
                provisionCount.increment()
                return .success
            },
            refreshReadiness: {
                refreshCount.increment()
                await ctrl.refreshRuntimeReadiness(checker: readyChecker)
            }
        )

        XCTAssertTrue(controller.setupStage.isFailed)
        XCTAssertEqual(provisionCount.value, 0, "Worker provisioning must NOT run after FFmpeg failure")
        XCTAssertEqual(refreshCount.value, 0, "Refresh must NOT run after FFmpeg failure")
        if case .failed(let msg) = controller.setupStage {
            XCTAssertLessThanOrEqual(msg.count, 500, "FFmpeg error must be truncated to 500")
        } else {
            XCTFail("expected failed stage")
        }
        XCTAssertFalse(controller.isSetupInProgress)

        // Try Again succeeds once FFmpeg resolves
        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedTool(available: true) },
            ensureFfmpegAvailable: { .failure(.verificationFailed("must not be called")) },
            provisionWorker: { _ in .success },
            refreshReadiness: { await ctrl.refreshRuntimeReadiness(checker: readyChecker) }
        )
        XCTAssertEqual(controller.setupStage, .idle)
        XCTAssertTrue(controller.isWorkerReady)
    }

    func testRunSetupFFmpegInstallFailureSurfaces() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: ffmpegSetupWorkerChecker(workerAvailable: false))
        let provisionCount = FFmpegCountBox()
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedTool(available: false) },
            ensureFfmpegAvailable: { .failure(.installFailed(exitCode: 1, message: "curl failed")) },
            provisionWorker: { _ in
                provisionCount.increment()
                return .success
            },
            refreshReadiness: nil
        )

        XCTAssertTrue(controller.setupStage.isFailed)
        XCTAssertTrue(controller.setupErrorMessage?.contains("curl failed") ?? false)
        XCTAssertEqual(provisionCount.value, 0)
        XCTAssertFalse(controller.isSetupInProgress)
    }
}
