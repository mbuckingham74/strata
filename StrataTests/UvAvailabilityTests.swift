import XCTest
@testable import Strata
import Foundation

// MARK: - UvAvailabilityTests

final class UvAvailabilityTests: XCTestCase {

    private final class ProbeBox: @unchecked Sendable {
        var isExecutableCalls: [String] = []
        var fileExistsCalls: [String] = []
        var createdDirectories: [String] = []
        var runCalls: [(executable: String, args: [String], env: [String: String]?)] = []
    }

    private func makeIsExecutable(box: ProbeBox, mapping: @Sendable @escaping (String) -> Bool) -> @Sendable (String) -> Bool {
        return { path in
            box.isExecutableCalls.append(path)
            return mapping(path)
        }
    }

    private func makeFileExists(box: ProbeBox, mapping: @Sendable @escaping (String) -> Bool) -> @Sendable (String) -> Bool {
        return { path in
            box.fileExistsCalls.append(path)
            return mapping(path)
        }
    }

    private func makeCreateDirectory(box: ProbeBox, shouldThrow: Bool = false) -> @Sendable (URL) throws -> Void {
        return { url in
            box.createdDirectories.append(url.path)
            if shouldThrow {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "createDirectory failed"])
            }
        }
    }

    private func makeRunProcess(box: ProbeBox, handler: @Sendable @escaping (URL, [String], [String: String]?) -> UvAvailability.ProcessOutcome) -> @Sendable (URL, [String], [String: String]?) -> UvAvailability.ProcessOutcome {
        return { url, args, env in
            box.runCalls.append((url.path, args, env))
            return handler(url, args, env)
        }
    }

    // MARK: - 1. Managed paths

    func testManagedPaths() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let sut = UvAvailability(applicationSupportURL: support)
        XCTAssertEqual(sut.managedDirectoryURL?.path, "/tmp/fakeSupport/Strata/Tools/uv")
        XCTAssertEqual(sut.managedExecutableURL?.path, "/tmp/fakeSupport/Strata/Tools/uv/uv")
        // Must be flat, not bin/uv
        XCTAssertFalse(sut.managedExecutableURL!.path.hasSuffix("/bin/uv"), "managed executable must be flat uv, not bin/uv")
        XCTAssertTrue(sut.managedExecutableURL!.path.hasSuffix("/uv"))
        XCTAssertEqual(sut.managedExecutableURL?.lastPathComponent, "uv")
    }

    func testManagedPathsNilSupport() {
        let sut = UvAvailability(applicationSupportURL: nil)
        XCTAssertNil(sut.managedDirectoryURL)
        XCTAssertNil(sut.managedExecutableURL)
    }

    // MARK: - 2. CandidatePaths priority

    func testCandidatePathsPriority() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let sut = UvAvailability(applicationSupportURL: support)
        let candidates = sut.candidatePaths
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0], "/tmp/fakeSupport/Strata/Tools/uv/uv")
        XCTAssertEqual(candidates[1], "/opt/homebrew/bin/uv")
        XCTAssertEqual(candidates[2], "/usr/local/bin/uv")
    }

    func testCandidatePathsWithoutSupportStillHasSystemPaths() {
        let sut = UvAvailability(applicationSupportURL: nil)
        let candidates = sut.candidatePaths
        XCTAssertEqual(candidates, ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"])
    }

    // MARK: - 3. parseUvVersion

    func testParseUvVersionExtractsCorrectly() {
        XCTAssertEqual(ExternalToolCompatibility.parseUvVersion(from: "uv 0.12.8 (hash)"), "0.12.8")
        XCTAssertEqual(ExternalToolCompatibility.parseUvVersion(from: "uv 0.12.8"), "0.12.8")
        XCTAssertEqual(ExternalToolCompatibility.parseUvVersion(from: "uv 0.12.8\n"), "0.12.8")
        XCTAssertEqual(ExternalToolCompatibility.parseUvVersion(from: "uv 0.12.8 (abc123) extra"), "0.12.8")
    }

    func testParseUvVersionEdgeCases() {
        XCTAssertNil(ExternalToolCompatibility.parseUvVersion(from: ""))
        XCTAssertNil(ExternalToolCompatibility.parseUvVersion(from: "   "))
        XCTAssertNil(ExternalToolCompatibility.parseUvVersion(from: "not uv"))
        XCTAssertNil(ExternalToolCompatibility.parseUvVersion(from: "uv"))
        XCTAssertNil(ExternalToolCompatibility.parseUvVersion(from: "uv abc"))
        // First line only
        XCTAssertEqual(ExternalToolCompatibility.parseUvVersion(from: "uv 0.12.8\n second line uv 0.15.0"), "0.12.8")
        // Leading whitespace
        XCTAssertEqual(ExternalToolCompatibility.parseUvVersion(from: "  uv 0.12.8"), "0.12.8")
        // Multi-digit
        XCTAssertEqual(ExternalToolCompatibility.parseUvVersion(from: "uv 10.20.30"), "10.20.30")
        // Handles newline and spaces
        XCTAssertEqual(ExternalToolCompatibility.parseUvVersion(from: "uv 0.12.8   "), "0.12.8")
    }

    // MARK: - 4. Uses existing managed uv when usable

    func testEnsureAvailableUsesManagedWhenUsableDoesNotInstall() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managedPath = "/tmp/fakeSupport/Strata/Tools/uv/uv"
        let box = ProbeBox()
        let sut = UvAvailability(
            applicationSupportURL: support,
            isExecutable: makeIsExecutable(box: box, mapping: { $0 == managedPath }),
            fileExists: makeFileExists(box: box, mapping: { _ in false }),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, handler: { url, args, _ in
                if url.path == managedPath && args == ["--version"] {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: "uv 0.12.8 (abc)", stderr: nil)
                }
                // Should not reach install
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: "unexpected")
            })
        )
        let result = sut.ensureAvailable()
        if case .success(let url) = result {
            XCTAssertEqual(url.path, managedPath)
        } else {
            XCTFail("Expected success, got \(result)")
        }
        // No install via /bin/sh
        XCTAssertFalse(box.runCalls.contains(where: { $0.executable == "/bin/sh" }), "Must NOT call /bin/sh when managed usable")
        XCTAssertTrue(box.createdDirectories.isEmpty, "Must NOT create directories when usable exists")
        // Verify only one run call (version check for managed)
        XCTAssertEqual(box.runCalls.count, 1)
        XCTAssertEqual(box.runCalls.first?.executable, managedPath)
    }

    // MARK: - 5. Uses Homebrew when managed missing but Homebrew usable

    func testEnsureAvailableUsesHomebrewWhenManagedMissing() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managedPath = "/tmp/fakeSupport/Strata/Tools/uv/uv"
        let homebrewPath = "/opt/homebrew/bin/uv"
        let box = ProbeBox()
        let sut = UvAvailability(
            applicationSupportURL: support,
            isExecutable: makeIsExecutable(box: box, mapping: { path in
                // managed not executable, homebrew executable
                if path == managedPath { return false }
                if path == homebrewPath { return true }
                return false
            }),
            fileExists: makeFileExists(box: box, mapping: { _ in false }),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, handler: { url, args, _ in
                if url.path == homebrewPath && args == ["--version"] {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: "uv 0.12.8", stderr: nil)
                }
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: "unexpected")
            })
        )
        let result = sut.ensureAvailable()
        if case .success(let url) = result {
            XCTAssertEqual(url.path, homebrewPath)
        } else {
            XCTFail("Expected Homebrew success, got \(result)")
        }
        XCTAssertFalse(box.runCalls.contains(where: { $0.executable == "/bin/sh" }), "Must NOT install when Homebrew usable")
        XCTAssertTrue(box.createdDirectories.isEmpty)
        // Should not have probed managed version (since not executable) and should have probed homebrew
        XCTAssertTrue(box.isExecutableCalls.contains(managedPath))
        XCTAssertTrue(box.isExecutableCalls.contains(homebrewPath))
    }

    // MARK: - 6. Installs when no usable existing

    func testEnsureAvailableInstallsWhenNoUsable() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managedPath = "/tmp/fakeSupport/Strata/Tools/uv/uv"
        let destPath = "/tmp/fakeSupport/Strata/Tools/uv"
        let box = ProbeBox()
        // Stateful: first loop candidates not usable, after install verifiable
        let sut = UvAvailability(
            applicationSupportURL: support,
            isExecutable: makeIsExecutable(box: box, mapping: { path in
                // Before install, no candidate executable; after install, managed becomes executable
                // Use call count to distinguish: first checks (3 candidates) return false, later verification returns true
                // Simpler: track if we have already installed (runCalls contains /bin/sh)
                if path == managedPath {
                    // After install has been attempted, return true
                    let hasInstalled = box.runCalls.contains(where: { $0.executable == "/bin/sh" })
                    return hasInstalled
                }
                return false
            }),
            fileExists: makeFileExists(box: box, mapping: { _ in false }),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, handler: { url, _, _ in
                if url.path == managedPath {
                    // After install, return correct version
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: "uv 0.12.8", stderr: nil)
                }
                if url.path == "/opt/homebrew/bin/uv" || url.path == "/usr/local/bin/uv" {
                    return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: "not found")
                }
                if url.path == "/bin/sh" {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: nil, stderr: nil)
                }
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: "unexpected")
            })
        )
        let result = sut.ensureAvailable()
        if case .success(let url) = result {
            XCTAssertEqual(url.path, managedPath)
        } else {
            XCTFail("Expected install success, got \(result)")
        }
        // createDirectory called with correct dest
        XCTAssertTrue(box.createdDirectories.contains(destPath), "createDirectory must be called with \(destPath), got \(box.createdDirectories)")
        XCTAssertEqual(box.createdDirectories.count, 1, "Should only create managed dest, not parents or other dirs")
        // Verify shell command via runCalls
        let shCalls = box.runCalls.filter { $0.executable == "/bin/sh" }
        XCTAssertEqual(shCalls.count, 1)
        XCTAssertEqual(shCalls.first?.args.first, "-c")
        let cmd = shCalls.first!.args[1]
        XCTAssertTrue(cmd.contains("https://astral.sh/uv/0.12.8/install.sh"), "Command must contain pinned URL, got \(cmd)")
        XCTAssertTrue(cmd.contains("UV_UNMANAGED_INSTALL"), "Must contain UV_UNMANAGED_INSTALL, got \(cmd)")
        XCTAssertTrue(cmd.contains("\"\(destPath)\""), "Must contain quoted dest path, got \(cmd)")
        // Must NOT contain Homebrew or PATH modification strings nor shell profile
        XCTAssertFalse(cmd.contains("Homebrew"), "Must not contain Homebrew")
        XCTAssertFalse(cmd.lowercased().contains("brew"), "Must not contain brew")
        XCTAssertFalse(cmd.contains("export PATH"), "Must not modify PATH")
        XCTAssertFalse(cmd.contains(".zshrc"), "Must not touch shell profiles")
        XCTAssertFalse(cmd.contains(".bashrc"), "Must not touch shell profiles")
        XCTAssertFalse(cmd.contains(".bash_profile"), "Must not touch shell profiles")
        XCTAssertTrue(shCalls.first!.args[1].contains("0.12.8"))
        XCTAssertTrue(shCalls.first!.args[1].contains("UV_UNMANAGED_INSTALL"))
    }

    // MARK: - 7. Installs via unmanaged mechanism with pinned version exactly

    func testEnsureAvailableInstallsViaUnmanagedPinnedVersion() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managedPath = "/tmp/fakeSupport/Strata/Tools/uv/uv"
        let destPath = "/tmp/fakeSupport/Strata/Tools/uv"
        let box = ProbeBox()
        let sut = UvAvailability(
            applicationSupportURL: support,
            isExecutable: makeIsExecutable(box: box, mapping: { path in
                if path == managedPath {
                    return box.runCalls.contains(where: { $0.executable == "/bin/sh" })
                }
                return false
            }),
            fileExists: makeFileExists(box: box, mapping: { _ in false }),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, handler: { url, args, _ in
                if url.path == "/bin/sh" {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: nil, stderr: nil)
                }
                if url.path == managedPath && args == ["--version"] {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: "uv 0.12.8", stderr: nil)
                }
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            })
        )
        let result = sut.ensureAvailable()
        XCTAssertEqual(result, .success(URL(fileURLWithPath: managedPath)))
        // Verify pinned version exactly
        let shCalls = box.runCalls.filter { $0.executable == "/bin/sh" }
        XCTAssertEqual(shCalls.count, 1)
        let call = shCalls.first!
        XCTAssertEqual(call.executable, "/bin/sh")
        XCTAssertEqual(call.args.count, 2)
        XCTAssertEqual(call.args[0], "-c")
        let shell = call.args[1]
        XCTAssertTrue(shell.contains("0.12.8"), "Shell must contain pinned version 0.12.8")
        XCTAssertTrue(shell.contains("UV_UNMANAGED_INSTALL"), "Shell must contain UV_UNMANAGED_INSTALL")
        XCTAssertTrue(shell.contains(destPath), "Shell must contain dest path")
        XCTAssertTrue(shell.contains("https://astral.sh/uv/0.12.8/install.sh"))
        // Ensure flat dest, not bin/uv
        XCTAssertFalse(shell.contains("\(destPath)/bin/uv"))
    }

    // MARK: - 8. Install failure when /bin/sh returns non-zero

    func testInstallFailureWhenShellReturnsNonZero() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let box = ProbeBox()
        let sut = UvAvailability(
            applicationSupportURL: support,
            isExecutable: makeIsExecutable(box: box, mapping: { _ in false }),
            fileExists: makeFileExists(box: box, mapping: { _ in false }),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, handler: { url, _, _ in
                if url.path == "/bin/sh" {
                    return UvAvailability.ProcessOutcome(terminationStatus: 42, stdout: nil, stderr: "curl failed")
                }
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            })
        )
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .installFailed(let code, let msg) = err {
                XCTAssertEqual(code, 42)
                XCTAssertTrue(msg?.contains("curl failed") ?? false)
            } else {
                XCTFail("Expected installFailed, got \(err)")
            }
        } else {
            XCTFail("Expected failure")
        }
    }

    // MARK: - 9. Verification after install fails if not executable

    func testVerificationFailsIfNotExecutableAfterInstall() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managedPath = "/tmp/fakeSupport/Strata/Tools/uv/uv"
        let box = ProbeBox()
        let sut = UvAvailability(
            applicationSupportURL: support,
            isExecutable: makeIsExecutable(box: box, mapping: { _ in false }), // always false, even after install
            fileExists: makeFileExists(box: box, mapping: { _ in false }),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, handler: { url, _, _ in
                if url.path == "/bin/sh" {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: nil, stderr: nil)
                }
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            })
        )
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .verificationFailed(let msg) = err {
                XCTAssertTrue(msg.contains(managedPath) || msg.contains("not executable"))
            } else {
                XCTFail("Expected verificationFailed, got \(err)")
            }
        } else {
            XCTFail("Expected failure")
        }
    }

    // MARK: - 10. Version mismatch after install

    func testVerificationFailsIfVersionMismatchAfterInstall() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managedPath = "/tmp/fakeSupport/Strata/Tools/uv/uv"
        let box = ProbeBox()
        let sut = UvAvailability(
            applicationSupportURL: support,
            isExecutable: makeIsExecutable(box: box, mapping: { path in
                if path == managedPath {
                    return box.runCalls.contains(where: { $0.executable == "/bin/sh" })
                }
                return false
            }),
            fileExists: makeFileExists(box: box, mapping: { _ in false }),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, handler: { url, args, _ in
                if url.path == "/bin/sh" {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: nil, stderr: nil)
                }
                if url.path == managedPath && args == ["--version"] {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: "uv 0.11.0", stderr: nil)
                }
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            })
        )
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .verificationFailed(let msg) = err {
                XCTAssertTrue(msg.contains("0.12.8") || msg.contains("mismatch"))
            } else {
                XCTFail("Expected verificationFailed for mismatch, got \(err)")
            }
        } else {
            XCTFail("Expected failure for version mismatch")
        }
    }

    // Updated policy: any parseable existing uv is usable — do NOT require pinned version.
    // Mismatched versions must be reused, not trigger install.

    func testVersionMismatchViaWrongVersionInCandidateTriggersInstall() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managedPath = "/tmp/fakeSupport/Strata/Tools/uv/uv"
        let homebrewPath = "/opt/homebrew/bin/uv"
        // Case 1: managed parseable but mismatched (0.10.0) should be reused, no install
        let box = ProbeBox()
        let sut = UvAvailability(
            applicationSupportURL: support,
            isExecutable: { path in
                box.isExecutableCalls.append(path)
                if path == managedPath { return true }
                if path == homebrewPath { return true }
                return false
            },
            fileExists: { path in box.fileExistsCalls.append(path); return false },
            createDirectory: { url in box.createdDirectories.append(url.path) },
            runProcess: { url, args, env in
                box.runCalls.append((url.path, args, env))
                if url.path == managedPath && args == ["--version"] {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: "uv 0.10.0", stderr: nil)
                }
                if url.path == homebrewPath && args == ["--version"] {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: "uv 0.11.0", stderr: nil)
                }
                if url.path == "/bin/sh" {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: nil, stderr: nil)
                }
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            }
        )
        let result = sut.ensureAvailable()
        if case .success(let url) = result {
            XCTAssertEqual(url.path, managedPath, "Mismatched but parseable managed version must be reused")
        } else {
            XCTFail("Expected reuse of mismatched managed version, got \(result)")
        }
        XCTAssertFalse(box.runCalls.contains(where: { $0.executable == "/bin/sh" }), "Must NOT install when mismatched version exists — any parseable version is usable")
        XCTAssertTrue(box.createdDirectories.isEmpty)

        // Case 2: managed missing, homebrew mismatched (0.11.0) should be reused
        let box2 = ProbeBox()
        let sut2 = UvAvailability(
            applicationSupportURL: support,
            isExecutable: { path in
                box2.isExecutableCalls.append(path)
                if path == managedPath { return false }
                if path == homebrewPath { return true }
                return false
            },
            fileExists: { path in box2.fileExistsCalls.append(path); return false },
            createDirectory: { url in box2.createdDirectories.append(url.path) },
            runProcess: { url, args, env in
                box2.runCalls.append((url.path, args, env))
                if url.path == homebrewPath && args == ["--version"] {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: "uv 0.11.0", stderr: nil)
                }
                if url.path == "/bin/sh" {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: nil, stderr: nil)
                }
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            }
        )
        let result2 = sut2.ensureAvailable()
        if case .success(let url) = result2 {
            XCTAssertEqual(url.path, homebrewPath)
        } else {
            XCTFail("Expected reuse of homebrew mismatched version")
        }
        XCTAssertFalse(box2.runCalls.contains(where: { $0.executable == "/bin/sh" }))
    }

    func testEnsureAvailableReusesAnyParseableVersionNewerAndOlder() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managedPath = "/tmp/fakeSupport/Strata/Tools/uv/uv"
        for version in ["uv 0.9.0", "uv 0.11.0", "uv 0.13.0", "uv 1.0.0", "uv 10.20.30"] {
            let box = ProbeBox()
            let sut = UvAvailability(
                applicationSupportURL: support,
                isExecutable: makeIsExecutable(box: box, mapping: { $0 == managedPath }),
                fileExists: makeFileExists(box: box, mapping: { _ in false }),
                createDirectory: makeCreateDirectory(box: box),
                runProcess: makeRunProcess(box: box, handler: { url, args, _ in
                    if url.path == managedPath && args == ["--version"] {
                        return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: version, stderr: nil)
                    }
                    return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: "unexpected")
                })
            )
            let result = sut.ensureAvailable()
            if case .success(let url) = result {
                XCTAssertEqual(url.path, managedPath, "Version \(version) should be reused")
            } else {
                XCTFail("Expected reuse for version \(version), got \(result)")
            }
            XCTAssertFalse(box.runCalls.contains(where: { $0.executable == "/bin/sh" }), "Version \(version) must not trigger install")
        }
    }

    // MARK: - 11. Failure when Application Support is nil

    func testEnsureAvailableFailsWhenApplicationSupportNil() {
        let box = ProbeBox()
        let sut = UvAvailability(
            applicationSupportURL: nil,
            isExecutable: makeIsExecutable(box: box, mapping: { _ in false }),
            fileExists: makeFileExists(box: box, mapping: { _ in false }),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, handler: { _, _, _ in
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            })
        )
        let result = sut.ensureAvailable()
        if case .failure(let err) = result {
            if case .missingApplicationSupport = err {
                // expected
            } else {
                XCTFail("Expected missingApplicationSupport, got \(err)")
            }
        } else {
            XCTFail("Expected failure when support nil")
        }
        // Even with nil, candidatePaths still probes system uvs before failing to install
        // The failure after probing should be missingApplicationSupport from installManaged
        XCTAssertFalse(box.createdDirectories.contains(where: { $0.contains("Documents") }))
    }

    // MARK: - 12. Never probes Documents/Projects and never creates outside managed dest

    func testNeverProbesDocumentsOrProjectsAndOnlyCreatesManagedDest() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let destPath = "/tmp/fakeSupport/Strata/Tools/uv"
        let managedPath = destPath + "/uv"
        let box = ProbeBox()
        let sut = UvAvailability(
            applicationSupportURL: support,
            isExecutable: makeIsExecutable(box: box, mapping: { path in
                if path == managedPath {
                    return box.runCalls.contains(where: { $0.executable == "/bin/sh" })
                }
                return false
            }),
            fileExists: makeFileExists(box: box, mapping: { path in
                // Ensure we catch any Documents/Projects probing
                XCTAssertFalse(path.contains("Documents"), "fileExists must not probe Documents: \(path)")
                XCTAssertFalse(path.contains("Projects"), "fileExists must not probe Projects: \(path)")
                return false
            }),
            createDirectory: { url in
                box.createdDirectories.append(url.path)
                XCTAssertFalse(url.path.contains("Documents"), "createDirectory must not touch Documents: \(url.path)")
                XCTAssertFalse(url.path.contains("Projects"), "createDirectory must not touch Projects: \(url.path)")
                XCTAssertEqual(url.path, destPath, "Must only create managed dest \(destPath), got \(url.path)")
            },
            runProcess: makeRunProcess(box: box, handler: { url, args, env in
                XCTAssertFalse(url.path.contains("Documents"), "runProcess executable must not contain Documents: \(url.path)")
                XCTAssertFalse(url.path.contains("Projects"), "runProcess executable must not contain Projects: \(url.path)")
                for a in args {
                    XCTAssertFalse(a.contains("Documents"), "runProcess arg must not contain Documents: \(a)")
                    XCTAssertFalse(a.contains("Projects"), "runProcess arg must not contain Projects: \(a)")
                }
                if let e = env {
                    for (_, v) in e {
                        XCTAssertFalse(v.contains("Documents"))
                        XCTAssertFalse(v.contains("Projects"))
                    }
                }
                if url.path == "/bin/sh" {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: nil, stderr: nil)
                }
                if url.path == managedPath && args == ["--version"] {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: "uv 0.12.8", stderr: nil)
                }
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            })
        )
        let result = sut.ensureAvailable()
        XCTAssertEqual(result, .success(URL(fileURLWithPath: managedPath)))
        // Global checks after execution
        for p in box.isExecutableCalls {
            XCTAssertFalse(p.contains("Documents"), "isExecutable must not probe Documents: \(p)")
            XCTAssertFalse(p.contains("Projects"), "isExecutable must not probe Projects: \(p)")
        }
        for p in box.fileExistsCalls {
            XCTAssertFalse(p.contains("Documents"))
            XCTAssertFalse(p.contains("Projects"))
        }
        for d in box.createdDirectories {
            XCTAssertFalse(d.contains("Documents"))
            XCTAssertFalse(d.contains("Projects"))
            XCTAssertEqual(d, destPath)
        }
        for call in box.runCalls {
            XCTAssertFalse(call.executable.contains("Documents"))
            XCTAssertFalse(call.executable.contains("Projects"))
            for a in call.args {
                XCTAssertFalse(a.contains("Documents"))
                XCTAssertFalse(a.contains("Projects"))
            }
        }
    }

    func testEnsureAvailableDoesNotCreateOutsideManagedWhenUsable() {
        let support = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managedPath = "/tmp/fakeSupport/Strata/Tools/uv/uv"
        let box = ProbeBox()
        let sut = UvAvailability(
            applicationSupportURL: support,
            isExecutable: makeIsExecutable(box: box, mapping: { $0 == managedPath }),
            fileExists: makeFileExists(box: box, mapping: { _ in false }),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, handler: { url, args, _ in
                if url.path == managedPath {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: "uv 0.12.8", stderr: nil)
                }
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            })
        )
        _ = sut.ensureAvailable()
        XCTAssertTrue(box.createdDirectories.isEmpty, "No directory creation when already usable")
        for d in box.createdDirectories {
            XCTAssertFalse(d.contains("Projects"))
            XCTAssertFalse(d.contains("Documents"))
        }
    }

    // MARK: - Additional verification: install command never modifies profiles

    func testInstallCommandNeverModifiesShellProfilesOrPath() {
        let support = URL(fileURLWithPath: "/tmp/supportXYZ")
        let destPath = "/tmp/supportXYZ/Strata/Tools/uv"
        let box = ProbeBox()
        let sut = UvAvailability(
            applicationSupportURL: support,
            isExecutable: makeIsExecutable(box: box, mapping: { path in
                if path == destPath + "/uv" {
                    return box.runCalls.contains(where: { $0.executable == "/bin/sh" })
                }
                return false
            }),
            fileExists: makeFileExists(box: box, mapping: { _ in false }),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, handler: { url, args, _ in
                if url.path == "/bin/sh" {
                    let cmd = args[1]
                    XCTAssertTrue(cmd.contains("UV_UNMANAGED_INSTALL=\"\(destPath)\""), "Must contain quoted UV_UNMANAGED_INSTALL")
                    XCTAssertTrue(cmd.contains("https://astral.sh/uv/0.12.8/install.sh"))
                    XCTAssertFalse(cmd.contains("Homebrew"))
                    XCTAssertFalse(cmd.contains("PATH="))
                    XCTAssertFalse(cmd.contains("export"))
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: nil, stderr: nil)
                }
                if url.path == destPath + "/uv" {
                    return UvAvailability.ProcessOutcome(terminationStatus: 0, stdout: "uv 0.12.8", stderr: nil)
                }
                return UvAvailability.ProcessOutcome(terminationStatus: 1, stdout: nil, stderr: nil)
            })
        )
        _ = sut.ensureAvailable()
        let shCalls = box.runCalls.filter { $0.executable == "/bin/sh" }
        XCTAssertEqual(shCalls.count, 1)
        let cmd = shCalls.first!.args[1]
        XCTAssertTrue(cmd.contains("curl -LsSf https://astral.sh/uv/0.12.8/install.sh"))
        XCTAssertTrue(cmd.contains("env UV_UNMANAGED_INSTALL=\"\(destPath)\" sh"))
    }
}

// MARK: - WorkerProvisioner uv injection tests (requirement 13)

final class UvAvailabilityWorkerProvisionerTests: XCTestCase {

    private final class ProbeBox: @unchecked Sendable {
        var fileExistsPaths: [String] = []
        var isExecutableCalls: [String] = []
        var createdDirectories: [String] = []
        var runCalls: [(executable: String, args: [String], env: [String: String]?)] = []
    }

    private func makeProvisioner(
        resourceURL: URL?,
        supportURL: URL?,
        uvURL: URL?,
        box: ProbeBox,
        validFileExists: Set<String>,
        validIsExecutable: Set<String>,
        syncOutcome: WorkerProvisioner.ProcessOutcome = .init(terminationStatus: 0, stdout: nil, stderr: nil),
        pythonOutcome: WorkerProvisioner.ProcessOutcome = .init(terminationStatus: 0, stdout: nil, stderr: nil)
    ) -> WorkerProvisioner {
        return WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            uvExecutableURL: uvURL,
            fileExists: { path in
                box.fileExistsPaths.append(path)
                return validFileExists.contains(path)
            },
            isExecutable: { path in
                box.isExecutableCalls.append(path)
                return validIsExecutable.contains(path)
            },
            createDirectory: { url in
                box.createdDirectories.append(url.path)
            },
            runProcess: { url, args, env in
                box.runCalls.append((url.path, args, env))
                if url.path.hasSuffix("bin/python3") {
                    return pythonOutcome
                }
                // uv sync call
                return syncOutcome
            }
        )
    }

    func testWorkerProvisionerUsesCustomUvPath() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let customUv = URL(fileURLWithPath: "/tmp/custom/uv")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let python = "/tmp/support/Strata/InferenceWorker/.venv/bin/python3"
        let box = ProbeBox()
        let validFiles: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            python
        ]
        let validExec: Set<String> = [customUv.path, python]
        let provisioner = makeProvisioner(
            resourceURL: resourceURL,
            supportURL: supportURL,
            uvURL: customUv,
            box: box,
            validFileExists: validFiles,
            validIsExecutable: validExec
        )
        let result = provisioner.provision()
        XCTAssertEqual(result, .success)
        XCTAssertEqual(provisioner.uvExecutableURL.path, "/tmp/custom/uv")
        XCTAssertEqual(box.runCalls.count, 2)
        let syncCall = box.runCalls[0]
        XCTAssertEqual(syncCall.executable, "/tmp/custom/uv", "Must use custom injected uv path, not hardcoded")
        XCTAssertNotEqual(syncCall.executable, WorkerProvisioner.uvExecutablePath)
        XCTAssertEqual(syncCall.args.first, "sync")
        // Env should contain UV_PROJECT_ENVIRONMENT pointing to venv
        XCTAssertEqual(syncCall.env, ["UV_PROJECT_ENVIRONMENT": "/tmp/support/Strata/InferenceWorker/.venv"])
    }

    func testWorkerProvisionerUsesManagedInjectedPath() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/fakeSupport")
        let managedUv = URL(fileURLWithPath: "/tmp/fakeSupport/Strata/Tools/uv/uv")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let python = "/tmp/fakeSupport/Strata/InferenceWorker/.venv/bin/python3"
        let box = ProbeBox()
        let validFiles: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            python
        ]
        let validExec: Set<String> = [managedUv.path, python]
        let provisioner = makeProvisioner(
            resourceURL: resourceURL,
            supportURL: supportURL,
            uvURL: managedUv,
            box: box,
            validFileExists: validFiles,
            validIsExecutable: validExec
        )
        let result = provisioner.provision()
        XCTAssertEqual(result, .success)
        XCTAssertEqual(provisioner.uvExecutableURL.path, managedUv.path)
        let syncCall = box.runCalls[0]
        XCTAssertEqual(syncCall.executable, managedUv.path)
        XCTAssertTrue(syncCall.executable.contains("Strata/Tools/uv/uv"), "Injected managed path must be used flat, not bin/uv")
        XCTAssertFalse(syncCall.executable.hasSuffix("bin/uv") && syncCall.executable.contains("Strata/Tools"))
        // Ensure not using legacy
        XCTAssertNotEqual(syncCall.executable, "/opt/homebrew/bin/uv")
    }

    func testWorkerProvisionerDefaultUsesLegacyPath() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let python = "/tmp/support/Strata/InferenceWorker/.venv/bin/python3"
        let box = ProbeBox()
        let validFiles: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            python
        ]
        let validExec: Set<String> = [WorkerProvisioner.uvExecutablePath, python]
        // No injection -> default legacy
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            uvExecutableURL: nil,
            fileExists: { path in box.fileExistsPaths.append(path); return validFiles.contains(path) },
            isExecutable: { path in box.isExecutableCalls.append(path); return validExec.contains(path) },
            createDirectory: { url in box.createdDirectories.append(url.path) },
            runProcess: { url, args, env in
                box.runCalls.append((url.path, args, env))
                if url.path.hasSuffix("bin/python3") { return .init(terminationStatus: 0, stdout: nil, stderr: nil) }
                return .init(terminationStatus: 0, stdout: nil, stderr: nil)
            }
        )
        XCTAssertEqual(provisioner.uvExecutableURL.path, WorkerProvisioner.uvExecutablePath)
        XCTAssertEqual(provisioner.uvExecutableURL.path, "/opt/homebrew/bin/uv")
        let result = provisioner.provision()
        XCTAssertEqual(result, .success)
        let syncCall = box.runCalls[0]
        XCTAssertEqual(syncCall.executable, "/opt/homebrew/bin/uv")
    }

    func testWorkerProvisionerInjectedPathIsUsedEvenWhenLegacyExists() {
        // If we inject managed path, it must be used even if legacy would also be valid
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let injected = URL(fileURLWithPath: "/tmp/custom2/uv")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let python = "/tmp/support/Strata/InferenceWorker/.venv/bin/python3"
        let box = ProbeBox()
        let validFiles: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            python
        ]
        // Both injected and legacy are considered executable, but injected must win
        let validExec: Set<String> = [injected.path, WorkerProvisioner.uvExecutablePath, python]
        let provisioner = makeProvisioner(
            resourceURL: resourceURL,
            supportURL: supportURL,
            uvURL: injected,
            box: box,
            validFileExists: validFiles,
            validIsExecutable: validExec
        )
        _ = provisioner.provision()
        XCTAssertEqual(box.runCalls[0].executable, injected.path)
        XCTAssertNotEqual(box.runCalls[0].executable, WorkerProvisioner.uvExecutablePath)
    }
}
