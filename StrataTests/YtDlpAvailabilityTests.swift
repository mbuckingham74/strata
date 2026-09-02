import XCTest
@testable import Strata
import Foundation

// MARK: - YtDlpAvailabilityTests

final class YtDlpAvailabilityTests: XCTestCase {

    private final class ProbeBox: @unchecked Sendable {
        var isExecutableCalls: [String] = []
        var fileExistsCalls: [String] = []
        var createdDirectories: [String] = []
        var runCalls: [(executable: String, args: [String])] = []
        var downloads: [(remote: String, local: String)] = []
        var chmods: [String] = []
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
        chmodError: Error? = nil,
        moveError: Error? = nil
    ) -> YtDlpAvailability {
        YtDlpAvailability(
            applicationSupportURL: support,
            isExecutable: { path in
                box.isExecutableCalls.append(path)
                if path.contains(".tmp-yt-dlp") { return stagedExecutable && box.stagedPaths.contains(path) }
                if box.stagedPaths.contains(path) { return stagedExecutable }
                return executables.contains(path)
            },
            fileExists: { path in
                box.fileExistsCalls.append(path)
                if path.contains(".tmp-yt-dlp") { return box.stagedPaths.contains(path) }
                return existing.contains(path)
            },
            createDirectory: { url in
                box.createdDirectories.append(url.path)
            },
            runProcess: { url, args, _ in
                box.runCalls.append((url.path, args))
                if url.path.contains(".tmp-yt-dlp") || url.path == support?.appendingPathComponent("Strata/Tools/yt-dlp/yt-dlp").path {
                    if stagedVersionExit != 0 {
                        return YtDlpAvailability.ProcessOutcome(terminationStatus: stagedVersionExit, stdout: nil, stderr: "probe failed")
                    }
                    if let raw = stagedVersionRaw {
                        return YtDlpAvailability.ProcessOutcome(terminationStatus: 0, stdout: raw, stderr: nil)
                    }
                }
                if args == ["--version"], let raw = versions[url.path] {
                    return YtDlpAvailability.ProcessOutcome(terminationStatus: 0, stdout: raw, stderr: nil)
                }
                return YtDlpAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: "not found")
            },
            downloadFile: { remote, local in
                box.downloads.append((remote.absoluteString, local.path))
                if let err = downloadError { throw err }
            },
            makeExecutable: { url in
                box.chmods.append(url.path)
                if let err = chmodError { throw err }
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
        XCTAssertEqual(sut.managedDirectoryURL?.path, "/tmp/fakeSupport/Strata/Tools/yt-dlp")
        XCTAssertEqual(sut.managedExecutableURL?.path, "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp")
        XCTAssertEqual(sut.managedExecutableURL?.lastPathComponent, "yt-dlp")
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
            "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp",
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp"
        ])
        let resolver = ExternalToolResolver(
            applicationSupportURL: support,
            isExecutable: { _ in false },
            runVersion: { _ in nil }
        )
        XCTAssertEqual(sut.candidatePaths, resolver.ytDlpCandidatePaths)
    }

    func testDownloadURLPinnedToSupportedVersion() {
        let version = ExternalToolCompatibility.ytDlpSupportedVersion
        XCTAssertEqual(version, "2026.08.19")
        let url = YtDlpAvailability.downloadURL(forVersion: version)
        XCTAssertEqual(url.absoluteString, "https://github.com/yt-dlp/yt-dlp/releases/download/\(version)/yt-dlp_macos")
        XCTAssertFalse(url.absoluteString.contains("Projects"))
        XCTAssertFalse(url.absoluteString.contains("Documents"))
        let box = ProbeBox()
        let sut = makeSUT(box: box)
        XCTAssertEqual(sut.downloadURL, YtDlpAvailability.downloadURL(forVersion: version))
    }

    // MARK: - Reuse when valid

    func testEnsureAvailableReusesManagedWhenCompatible() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp"
        let box = ProbeBox()
        let sut = makeSUT(
            support: support,
            box: box,
            executables: [managed],
            versions: [managed: ExternalToolCompatibility.ytDlpSupportedVersion]
        )
        XCTAssertEqual(sut.ensureAvailable(), .success(URL(fileURLWithPath: managed)))
        XCTAssertTrue(box.downloads.isEmpty, "Must NOT download when managed is compatible")
        XCTAssertTrue(box.moves.isEmpty)
        XCTAssertTrue(box.createdDirectories.isEmpty)
    }

    func testEnsureAvailableReusesSystemWhenManagedMissing() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let homebrew = "/opt/homebrew/bin/yt-dlp"
        let box = ProbeBox()
        let sut = makeSUT(
            support: support,
            box: box,
            executables: [homebrew],
            versions: [homebrew: ExternalToolCompatibility.ytDlpSupportedVersion]
        )
        XCTAssertEqual(sut.ensureAvailable(), .success(URL(fileURLWithPath: homebrew)))
        XCTAssertTrue(box.downloads.isEmpty)
        XCTAssertTrue(box.moves.isEmpty)
        XCTAssertTrue(box.createdDirectories.isEmpty)
    }

    func testEnsureAvailableSkipsIncompatibleManagedForCompatibleSystem() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp"
        let homebrew = "/opt/homebrew/bin/yt-dlp"
        let box = ProbeBox()
        let sut = makeSUT(
            support: support,
            box: box,
            executables: [managed, homebrew],
            versions: [
                managed: "2025.01.01",
                homebrew: ExternalToolCompatibility.ytDlpSupportedVersion
            ]
        )
        XCTAssertEqual(sut.ensureAvailable(), .success(URL(fileURLWithPath: homebrew)))
        XCTAssertTrue(box.downloads.isEmpty, "Compatible system copy must win over download")
    }

    // MARK: - Installs when missing

    func testEnsureAvailableInstallsWhenMissing() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp"
        let managedDir = "/tmp/fakeSupport/Strata/Tools/yt-dlp"
        let version = ExternalToolCompatibility.ytDlpSupportedVersion
        let box = ProbeBox()
        // Simulate download staging the temp binary
        let sut = YtDlpAvailability(
            applicationSupportURL: support,
            isExecutable: { path in
                box.isExecutableCalls.append(path)
                if path.contains(".tmp-yt-dlp") || path == managed { return box.stagedPaths.contains(path) }
                return false
            },
            fileExists: { path in
                box.fileExistsCalls.append(path)
                return box.stagedPaths.contains(path)
            },
            createDirectory: { url in box.createdDirectories.append(url.path) },
            runProcess: { url, args, _ in
                box.runCalls.append((url.path, args))
                if args == ["--version"] && box.stagedPaths.contains(url.path) {
                    return YtDlpAvailability.ProcessOutcome(terminationStatus: 0, stdout: version, stderr: nil)
                }
                return YtDlpAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: "not found")
            },
            downloadFile: { remote, local in
                box.downloads.append((remote.absoluteString, local.path))
                box.stagedPaths.insert(local.path)
            },
            makeExecutable: { url in box.chmods.append(url.path) },
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
        let result = sut.ensureAvailable()
        XCTAssertEqual(result, .success(URL(fileURLWithPath: managed)))
        XCTAssertEqual(box.createdDirectories, [managedDir])
        XCTAssertEqual(box.downloads.count, 1)
        XCTAssertTrue(box.downloads[0].remote.contains(version))
        XCTAssertTrue(box.downloads[0].remote.contains("github.com/yt-dlp/yt-dlp/releases/download/\(version)/yt-dlp_macos"))
        let tmpBinary = box.downloads[0].local
        XCTAssertNotEqual(tmpBinary, managed)
        XCTAssertEqual(URL(fileURLWithPath: tmpBinary).deletingLastPathComponent().path, managedDir)
        XCTAssertEqual(box.moves.count, 1)
        XCTAssertEqual(box.moves[0].from, tmpBinary)
        XCTAssertEqual(box.moves[0].to, managed)
        XCTAssertFalse(box.stagedPaths.contains(tmpBinary))
        XCTAssertTrue(box.stagedPaths.contains(managed))
    }

    func testInstalledManagedIsDiscoveredByResolver() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp"
        let version = ExternalToolCompatibility.ytDlpSupportedVersion
        let resolver = ExternalToolResolver(
            applicationSupportURL: support,
            isExecutable: { $0 == managed },
            runVersion: { path in
                guard path == managed else { return nil }
                return ExternalToolCompatibility.parseYtDlpVersion(from: version)
            }
        )
        let resolved = resolver.resolveYtDlp()
        XCTAssertTrue(resolved.isAvailable)
        XCTAssertEqual(resolved.executableURL?.path, managed)
        XCTAssertEqual(resolved.origin, .managed)
    }

    // MARK: - Atomicity / verification

    func testVersionMismatchAfterInstallFailsAndNeverMovesIntoPlace() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp"
        let version = ExternalToolCompatibility.ytDlpSupportedVersion
        let box = ProbeBox()
        let sut = YtDlpAvailability(
            applicationSupportURL: support,
            isExecutable: { path in
                box.isExecutableCalls.append(path)
                if box.stagedPaths.contains(path) { return true }
                return false
            },
            fileExists: { path in box.stagedPaths.contains(path) },
            createDirectory: { _ in },
            runProcess: { url, args, _ in
                box.runCalls.append((url.path, args))
                if url.path.contains(".tmp-yt-dlp") {
                    return YtDlpAvailability.ProcessOutcome(terminationStatus: 0, stdout: "2025.01.01", stderr: nil)
                }
                return YtDlpAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            },
            downloadFile: { remote, local in
                box.downloads.append((remote.absoluteString, local.path))
                box.stagedPaths.insert(local.path)
            },
            makeExecutable: { _ in },
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
        // Stage temp on download
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let stagingSUT = YtDlpAvailability(
            applicationSupportURL: support,
            isExecutable: { path in box.stagedPaths.contains(path) },
            fileExists: { path in box.stagedPaths.contains(path) },
            createDirectory: { _ in },
            runProcess: { url, args, _ in
                if url.path.contains(".tmp-yt-dlp") || url.path.hasSuffix("Strata/Tools/yt-dlp/yt-dlp") {
                    if let raw = "" as String? {
                        _ = raw
                    }
                    return YtDlpAvailability.ProcessOutcome(terminationStatus: 0, stdout: "", stderr: nil)
                }
                return YtDlpAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            },
            downloadFile: { remote, local in
                box.downloads.append((remote.absoluteString, local.path))
                box.stagedPaths.insert(local.path)
            },
            makeExecutable: { _ in },
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
        _ = sut
        let result = stagingSUT.ensureAvailable()
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
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let sut = YtDlpAvailability(
            applicationSupportURL: support,
            isExecutable: { path in box.stagedPaths.contains(path) },
            fileExists: { path in box.stagedPaths.contains(path) },
            createDirectory: { _ in },
            runProcess: { url, _, _ in
                if url.path.contains(".tmp-yt-dlp") {
                    return YtDlpAvailability.ProcessOutcome(terminationStatus: 0, stdout: "   \n  ", stderr: nil)
                }
                return YtDlpAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            },
            downloadFile: { remote, local in
                box.downloads.append((remote.absoluteString, local.path))
                box.stagedPaths.insert(local.path)
            },
            makeExecutable: { _ in },
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
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .verificationFailed = err { /* expected */ } else {
                XCTFail("Expected verificationFailed for unparseable version output, got \(err)")
            }
        } else {
            XCTFail("Expected failure for whitespace-only version output")
        }
        XCTAssertTrue(box.moves.isEmpty)
        XCTAssertTrue(box.stagedPaths.isEmpty)
    }

    private func makePostMoveSUT(box: ProbeBox, managedRaw: String?) -> YtDlpAvailability {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managed = "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp"
        let version = ExternalToolCompatibility.ytDlpSupportedVersion
        return YtDlpAvailability(
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
                if url.path.contains(".tmp-yt-dlp") {
                    return YtDlpAvailability.ProcessOutcome(terminationStatus: 0, stdout: version, stderr: nil)
                }
                if url.path == managed {
                    return YtDlpAvailability.ProcessOutcome(terminationStatus: 0, stdout: managedRaw, stderr: nil)
                }
                return YtDlpAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            },
            downloadFile: { remote, local in
                box.downloads.append((remote.absoluteString, local.path))
                box.stagedPaths.insert(local.path)
            },
            makeExecutable: { url in box.chmods.append(url.path) },
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
        let managed = "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp"
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
        let managed = "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp"
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

    func testNotExecutableAfterDownloadFailsVerification() {
        let box = ProbeBox()
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let version = ExternalToolCompatibility.ytDlpSupportedVersion
        let sut = YtDlpAvailability(
            applicationSupportURL: support,
            isExecutable: { _ in false },
            fileExists: { path in box.stagedPaths.contains(path) },
            createDirectory: { _ in },
            runProcess: { url, _, _ in
                YtDlpAvailability.ProcessOutcome(terminationStatus: 0, stdout: version, stderr: nil)
            },
            downloadFile: { remote, local in
                box.downloads.append((remote.absoluteString, local.path))
                box.stagedPaths.insert(local.path)
            },
            makeExecutable: { _ in },
            moveFile: { from, to in
                box.moves.append((from.path, to.path))
            },
            removeFile: { url in
                box.removed.append(url.path)
                box.stagedPaths.remove(url.path)
            }
        )
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
        let managedDir = "/tmp/fakeSupport/Strata/Tools/yt-dlp"
        let version = ExternalToolCompatibility.ytDlpSupportedVersion
        let box = ProbeBox()
        let sut = YtDlpAvailability(
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
                XCTAssertEqual(url.path, managedDir)
                box.createdDirectories.append(url.path)
            },
            runProcess: { url, args, _ in
                XCTAssertFalse(url.path.contains("Projects"))
                XCTAssertFalse(url.path.contains("Documents"))
                box.runCalls.append((url.path, args))
                if url.path.contains(".tmp-yt-dlp") || url.path.hasSuffix("Strata/Tools/yt-dlp/yt-dlp") {
                    return YtDlpAvailability.ProcessOutcome(terminationStatus: 0, stdout: version, stderr: nil)
                }
                return YtDlpAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            },
            downloadFile: { remote, local in
                XCTAssertFalse(local.path.contains("Projects"))
                XCTAssertFalse(local.path.contains("Documents"))
                box.downloads.append((remote.absoluteString, local.path))
                box.stagedPaths.insert(local.path)
            },
            makeExecutable: { url in
                XCTAssertFalse(url.path.contains("Projects"))
                box.chmods.append(url.path)
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
        XCTAssertEqual(result, .success(URL(fileURLWithPath: managedDir + "/yt-dlp")))
        for paths in [box.isExecutableCalls, box.fileExistsCalls, box.createdDirectories, box.removed] {
            for p in paths {
                XCTAssertFalse(p.contains("Projects"), "Must never touch Projects: \(p)")
                XCTAssertFalse(p.contains("Documents"), "Must never touch Documents: \(p)")
            }
        }
    }
}

// MARK: - YtDlpSetupTests (runSetup wiring)

private final class YtDlpCountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}

private func ytDlpSetupWorkerChecker(workerAvailable: Bool) -> RuntimeReadinessChecker {
    let dir = URL(fileURLWithPath: "/tmp/ytDlpSetupWorker")
    let python = URL(fileURLWithPath: "/tmp/ytDlpSetupWorker/.venv/bin/python3")
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

private func ytDlpResolvedTool(available: Bool) -> ResolvedExternalTool {
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

private func ffmpegResolvedToolForYtDlpTests(available: Bool) -> ResolvedExternalTool {
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
final class YtDlpSetupTests: XCTestCase {

    func testRunSetupSkipsYtDlpEnsureWhenResolved() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: ytDlpSetupWorkerChecker(workerAvailable: false))
        let ensureCount = YtDlpCountBox()
        let provisionCount = YtDlpCountBox()
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let readyChecker = ytDlpSetupWorkerChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedToolForYtDlpTests(available: true) },
            ensureFfmpegAvailable: { .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg")) },
            resolveYtDlp: { ytDlpResolvedTool(available: true) },
            ensureYtDlpAvailable: {
                ensureCount.increment()
                return .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp"))
            },
            provisionWorker: { _ in
                provisionCount.increment()
                return .success
            },
            refreshReadiness: { await ctrl.refreshRuntimeReadiness(checker: readyChecker) }
        )

        XCTAssertEqual(ensureCount.value, 0, "Compatible resolved yt-dlp must skip provisioning")
        XCTAssertEqual(provisionCount.value, 1)
        XCTAssertEqual(controller.setupStage, .idle)
        XCTAssertTrue(controller.isWorkerReady)
    }

    func testRunSetupProvisionsYtDlpWhenUnresolved() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: ytDlpSetupWorkerChecker(workerAvailable: false))
        let ensureCount = YtDlpCountBox()
        let managed = URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/yt-dlp/yt-dlp")
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let readyChecker = ytDlpSetupWorkerChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedToolForYtDlpTests(available: true) },
            ensureFfmpegAvailable: { .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg")) },
            resolveYtDlp: { ytDlpResolvedTool(available: false) },
            ensureYtDlpAvailable: {
                ensureCount.increment()
                return .success(managed)
            },
            provisionWorker: { _ in .success },
            refreshReadiness: { await ctrl.refreshRuntimeReadiness(checker: readyChecker) }
        )

        XCTAssertEqual(ensureCount.value, 1, "Unresolved yt-dlp must trigger provisioning")
        XCTAssertEqual(controller.setupStage, .idle)
    }

    func testRunSetupYtDlpFailureSurfacesTruncatedAndStops() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: ytDlpSetupWorkerChecker(workerAvailable: false))
        let provisionCount = YtDlpCountBox()
        let refreshCount = YtDlpCountBox()
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")
        let longMsg = String(repeating: "y", count: 600)
        let readyChecker = ytDlpSetupWorkerChecker(workerAvailable: true)
        nonisolated(unsafe) let ctrl = controller

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedToolForYtDlpTests(available: true) },
            ensureFfmpegAvailable: { .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg")) },
            resolveYtDlp: { ytDlpResolvedTool(available: false) },
            ensureYtDlpAvailable: { .failure(.verificationFailed(longMsg)) },
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
        XCTAssertEqual(provisionCount.value, 0, "Worker provisioning must NOT run after yt-dlp failure")
        XCTAssertEqual(refreshCount.value, 0, "Refresh must NOT run after yt-dlp failure")
        if case .failed(let msg) = controller.setupStage {
            XCTAssertLessThanOrEqual(msg.count, 500, "yt-dlp error must be truncated to 500")
        } else {
            XCTFail("expected failed stage")
        }
        XCTAssertFalse(controller.isSetupInProgress)

        // Try Again succeeds once yt-dlp resolves
        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedToolForYtDlpTests(available: true) },
            ensureFfmpegAvailable: { .failure(.verificationFailed("must not be called")) },
            resolveYtDlp: { ytDlpResolvedTool(available: true) },
            ensureYtDlpAvailable: { .failure(.verificationFailed("must not be called")) },
            provisionWorker: { _ in .success },
            refreshReadiness: { await ctrl.refreshRuntimeReadiness(checker: readyChecker) }
        )
        XCTAssertEqual(controller.setupStage, .idle)
        XCTAssertTrue(controller.isWorkerReady)
    }

    func testRunSetupYtDlpInstallFailureSurfaces() async {
        let controller = InferenceController()
        await controller.refreshRuntimeReadiness(checker: ytDlpSetupWorkerChecker(workerAvailable: false))
        let provisionCount = YtDlpCountBox()
        let uvURL = URL(fileURLWithPath: "/tmp/fake/uv")

        await controller.runSetup(
            ensureUvAvailable: { .success(uvURL) },
            resolveFFmpeg: { ffmpegResolvedToolForYtDlpTests(available: true) },
            ensureFfmpegAvailable: { .success(URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/ffmpeg/ffmpeg")) },
            resolveYtDlp: { ytDlpResolvedTool(available: false) },
            ensureYtDlpAvailable: { .failure(.installFailed(exitCode: 1, message: "curl failed")) },
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
