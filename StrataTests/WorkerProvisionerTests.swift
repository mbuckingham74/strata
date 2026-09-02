import XCTest
@testable import Strata
import Foundation

final class WorkerProvisionerTests: XCTestCase {

    private final class ProbeBox: @unchecked Sendable {
        var paths: [String] = []
        var createdDirectories: [String] = []
        var runCalls: [(executable: String, args: [String], env: [String: String]?)] = []
    }

    private func makeFileExists(validPaths: Set<String>, box: ProbeBox) -> @Sendable (String) -> Bool {
        return { path in
            box.paths.append(path)
            return validPaths.contains(path)
        }
    }

    private func makeIsExecutable(validPaths: Set<String>, box: ProbeBox) -> @Sendable (String) -> Bool {
        return { path in
            // track as well but not duplicate box.paths for executable checks separately if needed
            // Only uv and python executable checks use this
            if path == WorkerProvisioner.uvExecutablePath {
                return validPaths.contains(path)
            }
            if path.hasSuffix("python3") {
                return validPaths.contains(path)
            }
            return validPaths.contains(path)
        }
    }

    private func makeCreateDirectory(box: ProbeBox) -> @Sendable (URL) throws -> Void {
        return { url in
            box.createdDirectories.append(url.path)
        }
    }

    private func makeRunProcess(box: ProbeBox, syncResult: WorkerProvisioner.ProcessOutcome, prepareResult: WorkerProvisioner.ProcessOutcome? = nil) -> @Sendable (URL, [String], [String: String]?) -> WorkerProvisioner.ProcessOutcome {
        return { executable, args, env in
            box.runCalls.append((executable.path, args, env))
            if executable.path == WorkerProvisioner.uvExecutablePath {
                return syncResult
            } else if executable.path.hasSuffix("bin/python3") {
                return prepareResult ?? WorkerProvisioner.ProcessOutcome(terminationStatus: 0, stdout: nil, stderr: nil)
            } else {
                return WorkerProvisioner.ProcessOutcome(terminationStatus: 0, stdout: nil, stderr: nil)
            }
        }
    }

    // MARK: - Bundle resolution

    func testBundledProjectResolution() {
        let resourceURL = URL(fileURLWithPath: "/tmp/fakeBundle/Resources")
        let supportURL = URL(fileURLWithPath: "/tmp/fakeSupport")
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: [], box: box),
            isExecutable: makeIsExecutable(validPaths: [], box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        XCTAssertEqual(provisioner.bundledProjectURL?.path, "/tmp/fakeBundle/Resources/InferenceWorker")
        XCTAssertEqual(provisioner.bundledProjectURL?.standardizedFileURL.path, "/tmp/fakeBundle/Resources/InferenceWorker")
    }

    func testApplicationSupportDestination() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let box = ProbeBox()
        let p = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: [], box: box),
            isExecutable: makeIsExecutable(validPaths: [], box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        XCTAssertEqual(p.workerRootURL?.path, "/tmp/support/Strata/InferenceWorker")
        XCTAssertEqual(p.venvURL?.path, "/tmp/support/Strata/InferenceWorker/.venv")
        XCTAssertEqual(p.workerPythonURL?.path, "/tmp/support/Strata/InferenceWorker/.venv/bin/python3")
    }

    // MARK: - Exact uv argument construction

    func testExactUVArgumentAndEnvironmentConstruction() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let pyproject = "\(projectPath)/pyproject.toml"
        let lock = "\(projectPath)/uv.lock"
        let pyVer = "\(projectPath)/.python-version"
        let readme = "\(projectPath)/README.md"
        let src = "\(projectPath)/src"
        let supportWorker = "/tmp/support/Strata/InferenceWorker"
        let venv = "\(supportWorker)/.venv"
        let python = "\(venv)/bin/python3"
        let box = ProbeBox()
        let valid: Set<String> = [pyproject, lock, pyVer, readme, src, WorkerProvisioner.uvExecutablePath, python, supportWorker, venv]
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        let result = provisioner.provision()
        XCTAssertEqual(result, .success)
        XCTAssertEqual(box.runCalls.count, 2)
        let syncCall = box.runCalls[0]
        XCTAssertEqual(syncCall.executable, WorkerProvisioner.uvExecutablePath)
        XCTAssertEqual(syncCall.args, ["sync", "--project", projectPath, "--locked", "--no-dev", "--no-editable", "--managed-python", "--reinstall-package", "demux-worker"])
        XCTAssertEqual(syncCall.env, ["UV_PROJECT_ENVIRONMENT": venv])
        let prepareCall = box.runCalls[1]
        XCTAssertTrue(prepareCall.executable.hasSuffix("bin/python3"))
        XCTAssertEqual(prepareCall.args, ["-m", "demux_worker", "prepare-model"])
        // No Documents access
        for path in box.paths {
            XCTAssertFalse(path.contains("Documents"), "Must not access Documents, probed \(path)")
        }
        for dir in box.createdDirectories {
            XCTAssertFalse(dir.contains("Documents"), "Must not touch Documents")
        }
    }

    func testNoDestructiveAccessToSiblingProjects() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let valid: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            WorkerProvisioner.uvExecutablePath,
            "/tmp/support/Strata/InferenceWorker/.venv/bin/python3"
        ]
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        _ = provisioner.provision()
        // Only workerRoot should be created, never parent Strata or Projects
        for dir in box.createdDirectories {
            XCTAssertFalse(dir.hasSuffix("/Application Support/Strata"), "Must never delete/replace parent Strata \(dir)")
            XCTAssertFalse(dir.contains("/Projects"), "Must never touch Projects \(dir)")
            XCTAssertFalse(dir == "/tmp/support/Strata", "Must not manage parent Strata directly")
        }
        // Should only create Strata/InferenceWorker
        XCTAssertTrue(box.createdDirectories.contains("/tmp/support/Strata/InferenceWorker"))
        // Ensure no run call touches Projects
        for call in box.runCalls {
            XCTAssertFalse(call.executable.contains("Projects"))
            for arg in call.args { XCTAssertFalse(arg.contains("Projects")) }
            if let env = call.env {
                for (_, v) in env { XCTAssertFalse(v.contains("Projects")) }
            }
        }
        for path in box.paths {
            XCTAssertFalse(path.contains("Projects"), "Must not probe Projects")
        }
    }

    func testPrepareModelRunsOnlyAfterSuccessfulSync() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let valid: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            WorkerProvisioner.uvExecutablePath
        ]
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 1, stdout: nil, stderr: "sync failed"))
        )
        let result = provisioner.provision()
        if case .failure(let err) = result {
            if case .syncFailed(let code, _) = err {
                XCTAssertEqual(code, 1)
            } else {
                XCTFail("Expected syncFailed, got \(err)")
            }
        } else {
            XCTFail("Expected failure")
        }
        XCTAssertEqual(box.runCalls.count, 1, "prepare-model must not run after sync failure")
        XCTAssertEqual(box.runCalls[0].executable, WorkerProvisioner.uvExecutablePath)
    }

    func testPrepareModelRunsOnSuccess() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let python = "/tmp/support/Strata/InferenceWorker/.venv/bin/python3"
        let valid: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            WorkerProvisioner.uvExecutablePath,
            python
        ]
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil), prepareResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        let result = provisioner.provision()
        XCTAssertEqual(result, .success)
        XCTAssertEqual(box.runCalls.count, 2)
        XCTAssertTrue(box.runCalls[1].executable.hasSuffix("bin/python3"))
    }

    // MARK: - Failures for missing bundled project

    func testFailureMissingPyproject() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        // missing pyproject
        let valid: Set<String> = [
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            WorkerProvisioner.uvExecutablePath
        ]
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        let result = provisioner.provision()
        if case .failure(let err) = result {
            if case .missingBundledProject(let msg) = err {
                XCTAssertTrue(msg.contains("pyproject.toml"))
            } else { XCTFail("Expected missingBundledProject, got \(err)") }
        } else { XCTFail("Expected failure") }
        XCTAssertEqual(box.runCalls.count, 0, "Must not run uv when project missing")
    }

    func testFailureMissingUvLock() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let valid: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            WorkerProvisioner.uvExecutablePath
        ]
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        let result = provisioner.provision()
        if case .failure(let err) = result {
            if case .missingBundledProject(let msg) = err { XCTAssertTrue(msg.contains("uv.lock")) }
            else { XCTFail("Expected missingBundledProject") }
        } else { XCTFail("Expected failure") }
    }

    func testFailureMissingPythonVersion() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let valid: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            WorkerProvisioner.uvExecutablePath
        ]
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        let result = provisioner.provision()
        if case .failure(let err) = result {
            if case .missingBundledProject(let msg) = err { XCTAssertTrue(msg.contains(".python-version")) }
            else { XCTFail("Expected missingBundledProject") }
        } else { XCTFail("Expected failure") }
    }

    func testFailureMissingSrc() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let valid: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            WorkerProvisioner.uvExecutablePath
        ]
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        let result = provisioner.provision()
        if case .failure(let err) = result {
            if case .missingBundledProject(let msg) = err { XCTAssertTrue(msg.contains("src")) }
            else { XCTFail("Expected missingBundledProject") }
        } else { XCTFail("Expected failure") }
    }

    func testFailureMissingReadme() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let valid: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/src",
            WorkerProvisioner.uvExecutablePath
        ]
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        let result = provisioner.provision()
        if case .failure(let err) = result {
            if case .missingBundledProject(let msg) = err { XCTAssertTrue(msg.contains("README.md")) }
            else { XCTFail("Expected missingBundledProject for README, got \(err)") }
        } else { XCTFail("Expected failure for missing README") }
        XCTAssertEqual(box.runCalls.count, 0)
    }

    func testFailureMissingUV() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let valid: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src"
            // uv missing
        ]
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        let result = provisioner.provision()
        if case .failure(let err) = result {
            if case .missingUV(let msg) = err { XCTAssertTrue(msg.contains(WorkerProvisioner.uvExecutablePath)) }
            else { XCTFail("Expected missingUV, got \(err)") }
        } else { XCTFail("Expected failure") }
        XCTAssertEqual(box.runCalls.count, 0)
    }

    func testFailureMissingProvisionedPythonAfterSync() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let valid: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            WorkerProvisioner.uvExecutablePath
            // python missing
        ]
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        let result = provisioner.provision()
        if case .failure(let err) = result {
            if case .missingPython(let msg) = err { XCTAssertTrue(msg.contains("python3")) }
            else { XCTFail("Expected missingPython, got \(err)") }
        } else { XCTFail("Expected failure") }
        XCTAssertEqual(box.runCalls.count, 1, "Should have run uv but not prepare-model")
    }

    func testFailurePrepareModel() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let python = "/tmp/support/Strata/InferenceWorker/.venv/bin/python3"
        let valid: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            WorkerProvisioner.uvExecutablePath,
            python
        ]
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil), prepareResult: .init(terminationStatus: 2, stdout: nil, stderr: "prepare failed"))
        )
        let result = provisioner.provision()
        if case .failure(let err) = result {
            if case .prepareModelFailed(let code, _) = err { XCTAssertEqual(code, 2) }
            else { XCTFail("Expected prepareModelFailed") }
        } else { XCTFail("Expected failure") }
    }

    func testDoesNotAccessDocuments() {
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let projectPath = "/tmp/bundleRes/InferenceWorker"
        let python = "/tmp/support/Strata/InferenceWorker/.venv/bin/python3"
        let valid: Set<String> = [
            "\(projectPath)/pyproject.toml",
            "\(projectPath)/uv.lock",
            "\(projectPath)/.python-version",
            "\(projectPath)/README.md",
            "\(projectPath)/src",
            WorkerProvisioner.uvExecutablePath,
            python
        ]
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: valid, box: box),
            isExecutable: makeIsExecutable(validPaths: valid, box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        _ = provisioner.provision()
        for path in box.paths {
            XCTAssertFalse(path.contains("Documents"), "Must not access Documents: \(path)")
            XCTAssertFalse(path.contains("my-apps"), "Must not access repo checkout: \(path)")
        }
        for call in box.runCalls {
            XCTAssertFalse(call.executable.contains("Documents"))
            for arg in call.args { XCTAssertFalse(arg.contains("Documents")); XCTAssertFalse(arg.contains("my-apps")) }
        }
    }

    func testNilResourceURLFails() {
        let supportURL = URL(fileURLWithPath: "/tmp/support")
        let box = ProbeBox()
        let provisioner = WorkerProvisioner(
            resourceURL: nil,
            applicationSupportURL: supportURL,
            fileExists: makeFileExists(validPaths: [], box: box),
            isExecutable: makeIsExecutable(validPaths: [], box: box),
            createDirectory: makeCreateDirectory(box: box),
            runProcess: makeRunProcess(box: box, syncResult: .init(terminationStatus: 0, stdout: nil, stderr: nil))
        )
        let result = provisioner.provision()
        if case .failure(let err) = result {
            if case .missingBundledProject = err { } else { XCTFail("Expected missingBundledProject for nil resourceURL") }
        } else { XCTFail("Expected failure") }
    }
}
