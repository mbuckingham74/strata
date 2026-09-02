import XCTest
@testable import Strata
import Foundation

// MARK: - NodeAvailabilityTests

final class NodeAvailabilityTests: XCTestCase {

    private final class ProbeBox: @unchecked Sendable {
        var isExecutableCalls: [String] = []
        var fileExistsCalls: [String] = []
        var createdDirectories: [String] = []
        var runCalls: [(executable: String, args: [String])] = []
        var downloads: [(remote: String, local: String)] = []
        var checksums: [String] = []
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
        checksumError: Error? = nil,
        extractError: Error? = nil,
        moveError: Error? = nil
    ) -> NodeAvailability {
        NodeAvailability(
            applicationSupportURL: support,
            isExecutable: { path in
                box.isExecutableCalls.append(path)
                if path.contains(".tmp-node") { return stagedExecutable && box.stagedPaths.contains(path) }
                if box.stagedPaths.contains(path) { return stagedExecutable }
                return executables.contains(path)
            },
            fileExists: { path in
                box.fileExistsCalls.append(path)
                if path.contains(".tmp-node") { return box.stagedPaths.contains(path) }
                return existing.contains(path)
            },
            createDirectory: { url in
                box.createdDirectories.append(url.path)
            },
            runProcess: { url, args, _ in
                box.runCalls.append((url.path, args))
                if url.path.contains(".tmp-node") || url.path == support?.appendingPathComponent("Strata/Tools/node/bin/node").path {
                    if stagedVersionExit != 0 {
                        return NodeAvailability.ProcessOutcome(terminationStatus: stagedVersionExit, stdout: nil, stderr: "probe failed")
                    }
                    if let raw = stagedVersionRaw {
                        return NodeAvailability.ProcessOutcome(terminationStatus: 0, stdout: raw, stderr: nil)
                    }
                }
                if args == ["--version"], let raw = versions[url.path] {
                    return NodeAvailability.ProcessOutcome(terminationStatus: 0, stdout: raw, stderr: nil)
                }
                return NodeAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: "not found")
            },
            downloadFile: { remote, local in
                box.downloads.append((remote.absoluteString, local.path))
                if let err = downloadError { throw err }
            },
            verifyChecksum: { local in
                box.checksums.append(local.path)
                if let err = checksumError { throw err }
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

    // MARK: - Managed paths

    func testManagedPaths() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let box = ProbeBox()
        let sut = makeSUT(support: support, box: box)
        XCTAssertEqual(sut.managedDirectoryURL?.path, "/tmp/fakeSupport/Strata/Tools/node")
        XCTAssertEqual(sut.managedBinDirectoryURL?.path, "/tmp/fakeSupport/Strata/Tools/node/bin")
        XCTAssertEqual(sut.managedExecutableURL?.path, "/tmp/fakeSupport/Strata/Tools/node/bin/node")
        XCTAssertEqual(sut.managedExecutableURL?.lastPathComponent, "node")
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
            "/tmp/fakeSupport/Strata/Tools/node/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node"
        ])
        let resolver = ExternalToolResolver(
            applicationSupportURL: support,
            isExecutable: { _ in false },
            runVersion: { _ in nil }
        )
        XCTAssertEqual(sut.candidatePaths, resolver.nodeCandidatePaths)
    }

    func testDownloadURLPinnedToSupportedVersion() {
        let version = ExternalToolCompatibility.nodeSupportedVersion
        XCTAssertEqual(version, "26.8.1")
        let url = NodeAvailability.downloadURL(forVersion: version)
        XCTAssertEqual(url.absoluteString, "https://nodejs.org/dist/v26.8.1/node-v26.8.1-darwin-arm64.tar.gz")
        XCTAssertFalse(url.absoluteString.contains("Projects"))
        XCTAssertFalse(url.absoluteString.contains("Documents"))
        XCTAssertEqual(NodeAvailability.expectedSHA256, "6e577fd0d9db776db82306629e441a9dace416702622aebdd171c9dfaa41f4d2")
        let box = ProbeBox()
        let sut = makeSUT(box: box)
        XCTAssertEqual(sut.downloadURL, NodeAvailability.downloadURL(forVersion: version))
    }

    // MARK: - Reuse when compatible (major >= 22, no tightening)

    func testEnsureAvailableReusesManagedWhenCompatible() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/node/bin/node"
        let box = ProbeBox()
        let sut = makeSUT(
            support: support,
            box: box,
            executables: [managed],
            versions: [managed: "v26.8.1"]
        )
        XCTAssertEqual(sut.ensureAvailable(), .success(URL(fileURLWithPath: managed)))
        XCTAssertTrue(box.downloads.isEmpty, "Must NOT download when managed is compatible")
        XCTAssertTrue(box.moves.isEmpty)
        XCTAssertTrue(box.createdDirectories.isEmpty)
    }

    func testEnsureAvailableReusesSystemWhenManagedMissing() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let homebrew = "/opt/homebrew/bin/node"
        let box = ProbeBox()
        let sut = makeSUT(
            support: support,
            box: box,
            executables: [homebrew],
            versions: [homebrew: "v22.5.0"]
        )
        XCTAssertEqual(sut.ensureAvailable(), .success(URL(fileURLWithPath: homebrew)))
        XCTAssertTrue(box.downloads.isEmpty)
        XCTAssertTrue(box.moves.isEmpty)
        XCTAssertTrue(box.createdDirectories.isEmpty)
    }

    func testEnsureAvailableSkipsIncompatibleManagedForCompatibleSystem() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/node/bin/node"
        let homebrew = "/opt/homebrew/bin/node"
        let box = ProbeBox()
        let sut = makeSUT(
            support: support,
            box: box,
            executables: [managed, homebrew],
            versions: [
                managed: "v21.9.9",
                homebrew: "v26.8.1"
            ]
        )
        XCTAssertEqual(sut.ensureAvailable(), .success(URL(fileURLWithPath: homebrew)))
        XCTAssertTrue(box.downloads.isEmpty, "Compatible system copy must win over download")
    }

    // MARK: - Installs when missing

    func testEnsureAvailableInstallsWhenMissing() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/node/bin/node"
        let managedBinDir = "/tmp/fakeSupport/Strata/Tools/node/bin"
        let version = ExternalToolCompatibility.nodeSupportedVersion
        let box = ProbeBox()
        let sut = makeSUT(
            support: support,
            box: box,
            stagedVersionRaw: "v\(version)"
        )
        let result = sut.ensureAvailable()
        XCTAssertEqual(result, .success(URL(fileURLWithPath: managed)))
        // Creates only the managed bin directory
        XCTAssertEqual(box.createdDirectories, [managedBinDir])
        // Downloads to a same-dir temp file, never the final path
        XCTAssertEqual(box.downloads.count, 1)
        XCTAssertEqual(box.downloads[0].remote, "https://nodejs.org/dist/v\(version)/node-v\(version)-darwin-arm64.tar.gz")
        let tmpArchive = box.downloads[0].local
        XCTAssertNotEqual(tmpArchive, managed)
        XCTAssertEqual(URL(fileURLWithPath: tmpArchive).deletingLastPathComponent().path, managedBinDir)
        XCTAssertTrue(tmpArchive.contains(".tmp-node"))
        // Checksum verified against the downloaded archive
        XCTAssertEqual(box.checksums, [tmpArchive])
        // Extracts archive -> same-dir staged binary
        XCTAssertEqual(box.extracts.count, 1)
        XCTAssertEqual(box.extracts[0].archive, tmpArchive)
        let tmpBinary = box.extracts[0].dest
        XCTAssertNotEqual(tmpBinary, managed)
        XCTAssertEqual(URL(fileURLWithPath: tmpBinary).deletingLastPathComponent().path, managedBinDir)
        XCTAssertTrue(tmpBinary.contains(".tmp-node"))
        // Atomic rename staged -> managed
        XCTAssertEqual(box.moves.count, 1)
        XCTAssertEqual(box.moves[0].from, tmpBinary)
        XCTAssertEqual(box.moves[0].to, managed)
        // Archive temp cleaned up
        XCTAssertTrue(box.removed.contains(tmpArchive))
        XCTAssertFalse(box.stagedPaths.contains(tmpBinary))
        XCTAssertTrue(box.stagedPaths.contains(managed))
    }

    func testInstalledManagedIsDiscoveredByResolver() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/node/bin/node"
        let version = ExternalToolCompatibility.nodeSupportedVersion
        let resolver = ExternalToolResolver(
            applicationSupportURL: support,
            isExecutable: { $0 == managed },
            runVersion: { path in
                guard path == managed else { return nil }
                return ExternalToolCompatibility.parseNodeVersion(from: "v\(version)")
            }
        )
        let resolved = resolver.resolveNode()
        XCTAssertTrue(resolved.isAvailable)
        XCTAssertEqual(resolved.executableURL?.path, managed)
        XCTAssertEqual(resolved.origin, .managed)
    }

    // MARK: - Atomicity / verification

    func testVersionMismatchAfterInstallFailsAndNeverMovesIntoPlace() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/node/bin/node"
        let version = ExternalToolCompatibility.nodeSupportedVersion
        let box = ProbeBox()
        let sut = makeSUT(support: support, box: box, stagedVersionRaw: "v20.0.0")
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
        XCTAssertFalse(box.stagedPaths.contains(managed))
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
        let sut = makeSUT(box: box, stagedVersionRaw: "not a node binary")
        let result = sut.ensureAvailable()
        // "not a node binary" parses to itself via parseNodeVersion (no v-prefix strip),
        // which != 26.8.1, so it must still fail without moving into place.
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

    func testWhitespaceVersionOutputBeforeMoveFailsWithoutMove() {
        let box = ProbeBox()
        let sut = makeSUT(box: box, stagedVersionRaw: "   \n  ")
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .verificationFailed = err { /* expected */ } else {
                XCTFail("Expected verificationFailed for whitespace version output, got \(err)")
            }
        } else {
            XCTFail("Expected failure for whitespace-only version output")
        }
        XCTAssertTrue(box.moves.isEmpty)
        XCTAssertTrue(box.stagedPaths.isEmpty)
    }

    func testChecksumMismatchFailsWithoutExtractOrMove() {
        let box = ProbeBox()
        let managed = "/tmp/fakeSupport/Strata/Tools/node/bin/node"
        let sut = makeSUT(
            box: box,
            stagedVersionRaw: "v\(ExternalToolCompatibility.nodeSupportedVersion)",
            checksumError: NodeAvailabilityError.verificationFailed("checksum mismatch for node tarball")
        )
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .verificationFailed(let msg) = err {
                XCTAssertTrue(msg.contains("checksum"))
            } else {
                XCTFail("Expected verificationFailed, got \(err)")
            }
        } else {
            XCTFail("Expected failure for checksum mismatch")
        }
        XCTAssertFalse(box.downloads.isEmpty)
        XCTAssertTrue(box.extracts.isEmpty, "Checksum failure must never reach extraction")
        XCTAssertTrue(box.moves.isEmpty, "Checksum failure must never reach rename")
        XCTAssertFalse(box.stagedPaths.contains(managed))
        XCTAssertTrue(box.stagedPaths.isEmpty)
    }

    private func makePostMoveSUT(box: ProbeBox, managedRaw: String?) -> NodeAvailability {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/node/bin/node"
        let version = ExternalToolCompatibility.nodeSupportedVersion
        return NodeAvailability(
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
                if url.path.contains(".tmp-node") {
                    return NodeAvailability.ProcessOutcome(terminationStatus: 0, stdout: "v\(version)", stderr: nil)
                }
                if url.path == managed {
                    return NodeAvailability.ProcessOutcome(terminationStatus: 0, stdout: managedRaw, stderr: nil)
                }
                return NodeAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            },
            downloadFile: { remote, local in
                box.downloads.append((remote.absoluteString, local.path))
            },
            verifyChecksum: { local in
                box.checksums.append(local.path)
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
        let managed = "/tmp/fakeSupport/Strata/Tools/node/bin/node"
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
        XCTAssertFalse(box.stagedPaths.contains(managed))
    }

    func testPostMoveUnparseableVersionFailsAndRemovesManagedInstall() {
        let managed = "/tmp/fakeSupport/Strata/Tools/node/bin/node"
        let box = ProbeBox()
        let sut = makePostMoveSUT(box: box, managedRaw: "   ")
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .verificationFailed = err { /* expected */ } else {
                XCTFail("Expected verificationFailed for unparseable post-move version output, got \(err)")
            }
        } else {
            XCTFail("Expected failure for unparseable post-move version output")
        }
        XCTAssertEqual(box.moves.count, 1)
        XCTAssertTrue(box.removed.contains(managed))
        XCTAssertFalse(box.stagedPaths.contains(managed))
    }

    func testNotExecutableAfterExtractFailsVerification() {
        let box = ProbeBox()
        let sut = makeSUT(box: box, stagedExecutable: false, stagedVersionRaw: "v\(ExternalToolCompatibility.nodeSupportedVersion)")
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
        let managedBinDir = "/tmp/fakeSupport/Strata/Tools/node/bin"
        let version = ExternalToolCompatibility.nodeSupportedVersion
        let box = ProbeBox()
        let sut = NodeAvailability(
            applicationSupportURL: support,
            isExecutable: { path in
                XCTAssertFalse(path.contains("Projects"), "isExecutable must not probe Projects: \(path)")
                XCTAssertFalse(path.contains("Documents"), "isExecutable must not probe Documents: \(path)")
                box.isExecutableCalls.append(path)
                return box.stagedPaths.contains(path)
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
                XCTAssertEqual(url.path, managedBinDir)
                box.createdDirectories.append(url.path)
            },
            runProcess: { url, args, _ in
                XCTAssertFalse(url.path.contains("Projects"))
                XCTAssertFalse(url.path.contains("Documents"))
                box.runCalls.append((url.path, args))
                if url.path.contains(".tmp-node") || url.path.hasSuffix("Strata/Tools/node/bin/node") {
                    return NodeAvailability.ProcessOutcome(terminationStatus: 0, stdout: "v\(version)", stderr: nil)
                }
                return NodeAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            },
            downloadFile: { remote, local in
                XCTAssertFalse(local.path.contains("Projects"))
                XCTAssertFalse(local.path.contains("Documents"))
                box.downloads.append((remote.absoluteString, local.path))
            },
            verifyChecksum: { local in
                XCTAssertFalse(local.path.contains("Projects"))
                box.checksums.append(local.path)
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
        XCTAssertEqual(result, .success(URL(fileURLWithPath: managedBinDir + "/node")))
        for paths in [box.isExecutableCalls, box.fileExistsCalls, box.createdDirectories, box.removed] {
            for p in paths {
                XCTAssertFalse(p.contains("Projects"), "Must never touch Projects: \(p)")
                XCTAssertFalse(p.contains("Documents"), "Must never touch Documents: \(p)")
            }
        }
        for call in box.runCalls {
            XCTAssertFalse(call.executable.contains("Projects"))
        }
    }
}

// MARK: - NodeSetupTests (runSetup wiring)

private final class NodeCountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}

private func nodeSetupWorkerChecker(workerAvailable: Bool) -> RuntimeReadinessChecker {
    let dir = URL(fileURLWithPath: "/tmp/nodeSetupWorker")
    let python = URL(fileURLWithPath: "/tmp/nodeSetupWorker/.venv/bin/python3")
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

private func nodeResolvedTool(available: Bool, version: String? = nil) -> ResolvedExternalTool {
    let support = URL(fileURLWithPath: "/tmp/fakeSupport")
    if available {
        return ResolvedExternalTool(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            version: version ?? ExternalToolCompatibility.nodeSupportedVersion,
            origin: .system,
            managedURL: support.appendingPathComponent("Strata/Tools/node/bin/node"),
            installedVersion: nil,
            attemptedPath: nil
        )
    }
    return ResolvedExternalTool(
        executableURL: nil,
        version: nil,
        origin: nil,
        managedURL: support.appendingPathComponent("Strata/Tools/node/bin/node"),
        installedVersion: nil,
        attemptedPath: nil
    )
}

private func ffmpegResolvedToolForNodeTests(available: Bool) -> ResolvedExternalTool {
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

private func ytDlpResolvedToolForNodeTests(available: Bool) -> ResolvedExternalTool {
    let support = URL(fileURLWithPath: "/tmp/fakeSupport")
    if available {
        return ResolvedExternalTool(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            version: ExternalToolCompatibility.ytDlpSupportedVersion,
            origin: .system,
            managedURL: support.appendingPathComponent("Strata/Tools/yt-dlp/yt-dlp"),
            installedVersion: nil,
            attemptedPath: nil
        )
    }
    return ResolvedExternalTool(
        executableURL: nil,
        version: nil,
        origin: nil,
        managedURL: support.appendingPathComponent("Strata/Tools/yt-dlp/yt-dlp"),
        installedVersion: nil,
        attemptedPath: nil
    )
}

@MainActor
final class NodeSetupTests: XCTestCase {

    func testRunSetupSkipsNodeEnsureWhenResolved() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: nodeSetupWorkerChecker(workerAvailable: false))
        let ensureCount = NodeCountBox()
        let provisionCount = NodeCountBox()
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let readyChecker = nodeSetupWorkerChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedToolForNodeTests(available: true) },
            ensureFfmpegAvailable: { .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg")) },
            resolveYtDlp: { ytDlpResolvedToolForNodeTests(available: true) },
            ensureYtDlpAvailable: { .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp")) },
            resolveNode: { nodeResolvedTool(available: true, version: "22.5.0") },
            ensureNodeAvailable: {
                ensureCount.increment()
                return .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/node/bin/node"))
            },
            provisionWorker: { _ in
                provisionCount.increment()
                return .success
            },
            refreshReadiness: { await ctrl.refreshRuntimeReadiness(checker: readyChecker) }
        )

        XCTAssertEqual(ensureCount.value, 0, "Compatible resolved Node must skip provisioning")
        XCTAssertEqual(provisionCount.value, 1)
        XCTAssertEqual(controller.setupStage, .idle)
        XCTAssertTrue(controller.isWorkerReady)
    }

    func testRunSetupProvisionsNodeWhenUnresolved() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: nodeSetupWorkerChecker(workerAvailable: false))
        let ensureCount = NodeCountBox()
        let managed = URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/node/bin/node")
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let readyChecker = nodeSetupWorkerChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedToolForNodeTests(available: true) },
            ensureFfmpegAvailable: { .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg")) },
            resolveYtDlp: { ytDlpResolvedToolForNodeTests(available: true) },
            ensureYtDlpAvailable: { .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp")) },
            resolveNode: { nodeResolvedTool(available: false) },
            ensureNodeAvailable: {
                ensureCount.increment()
                return .success(managed)
            },
            provisionWorker: { _ in .success },
            refreshReadiness: { await ctrl.refreshRuntimeReadiness(checker: readyChecker) }
        )

        XCTAssertEqual(ensureCount.value, 1, "Unresolved Node must trigger provisioning")
        XCTAssertEqual(controller.setupStage, .idle)
    }

    func testRunSetupNodeFailureSurfacesTruncatedAndStops() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: nodeSetupWorkerChecker(workerAvailable: false))
        let provisionCount = NodeCountBox()
        let refreshCount = NodeCountBox()
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let longMsg = String(repeating: "n", count: 600)
        let readyChecker = nodeSetupWorkerChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedToolForNodeTests(available: true) },
            ensureFfmpegAvailable: { .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg")) },
            resolveYtDlp: { ytDlpResolvedToolForNodeTests(available: true) },
            ensureYtDlpAvailable: { .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp")) },
            resolveNode: { nodeResolvedTool(available: false) },
            ensureNodeAvailable: { .failure(.verificationFailed(longMsg)) },
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
        XCTAssertEqual(provisionCount.value, 0, "Worker provisioning must NOT run after Node failure")
        XCTAssertEqual(refreshCount.value, 0, "Refresh must NOT run after Node failure")
        if case .failed(let msg) = controller.setupStage {
            XCTAssertLessThanOrEqual(msg.count, 500, "Node error must be truncated to 500")
        } else {
            XCTFail("expected failed stage")
        }
        XCTAssertFalse(controller.isSetupInProgress)

        // Try Again succeeds once Node resolves
        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedToolForNodeTests(available: true) },
            ensureFfmpegAvailable: { .failure(.verificationFailed("must not be called")) },
            resolveYtDlp: { ytDlpResolvedToolForNodeTests(available: true) },
            ensureYtDlpAvailable: { .failure(.verificationFailed("must not be called")) },
            resolveNode: { nodeResolvedTool(available: true) },
            ensureNodeAvailable: { .failure(.verificationFailed("must not be called")) },
            provisionWorker: { _ in .success },
            refreshReadiness: { await ctrl.refreshRuntimeReadiness(checker: readyChecker) }
        )
        XCTAssertEqual(controller.setupStage, .idle)
        XCTAssertTrue(controller.isWorkerReady)
    }

    func testRunSetupNodeInstallFailureSurfaces() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: nodeSetupWorkerChecker(workerAvailable: false))
        let provisionCount = NodeCountBox()
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedToolForNodeTests(available: true) },
            ensureFfmpegAvailable: { .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg")) },
            resolveYtDlp: { ytDlpResolvedToolForNodeTests(available: true) },
            ensureYtDlpAvailable: { .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp")) },
            resolveNode: { nodeResolvedTool(available: false) },
            ensureNodeAvailable: { .failure(.installFailed(exitCode: 1, message: "curl failed")) },
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
