import XCTest
@testable import Strata
import Foundation

final class WorkerLaunchConfigurationTests: XCTestCase {

    private final class ProbeBox: @unchecked Sendable {
        var paths: [String] = []
    }

    private func makeTracker(validPaths: Set<String>, box: ProbeBox) -> ((String) -> Bool, (String) -> Bool) {
        let fileExists: @Sendable (String) -> Bool = { path in
            box.paths.append(path)
            return validPaths.contains(path)
        }
        let isExecutable: @Sendable (String) -> Bool = { path in
            if validPaths.contains(path) && path.hasSuffix("python3") {
                return true
            }
            return validPaths.contains(path)
        }
        return (fileExists, isExecutable)
    }

    func testInstalledDebugDoesNotProbeDocumentsAndThrows() throws {
        let box = ProbeBox()
        let resourceURL = URL(fileURLWithPath: "/tmp/fakeBundle/Resources")
        let supportURL = URL(fileURLWithPath: "/tmp/fakeSupport")
        let valid: Set<String> = []
        let (fileExists, isExecutable) = makeTracker(validPaths: valid, box: box)

        do {
            _ = try WorkerLaunchConfiguration.resolved(
                workerDirectoryOverride: nil,
                srcRoot: nil,
                isDebug: true,
                bundlePath: "/Applications/Strata.app",
                resourceURL: resourceURL,
                applicationSupportURL: supportURL,
                fileExists: fileExists,
                isExecutable: isExecutable,
                sourceFilePath: "/Users/michaelbuckingham/Documents/my-apps/strata/Strata/Inference/WorkerLaunchConfiguration.swift",
                currentDirectoryPath: "/Users/michaelbuckingham/Documents/my-apps/strata"
            )
            XCTFail("Should have thrown launchConfiguration for installed without bundle worker")
        } catch let error as InferenceError {
            switch error {
            case .launchConfiguration(let msg):
                XCTAssertFalse(msg.contains("Documents"))
                XCTAssertFalse(msg.contains("my-apps/strata"))
                XCTAssertTrue(msg.contains("Worker not found"))
                XCTAssertTrue(msg.contains("Checked"))
                XCTAssertTrue(msg.contains("scripts/install-inference-worker.sh"))
                XCTAssertTrue(msg.contains("DEMUX_WORKER_DIRECTORY"))
                XCTAssertFalse(msg.contains("reinstall"))
                XCTAssertTrue(msg.contains("/tmp/fakeSupport/Strata/InferenceWorker"))
                XCTAssertTrue(msg.contains("/tmp/fakeBundle/Resources/InferenceWorker"))
            default:
                XCTFail("Expected launchConfiguration, got \(error)")
            }
        }
        for path in box.paths {
            XCTAssertFalse(path.contains("Documents"), "Installed must not probe Documents, probed \(path)")
            XCTAssertFalse(path.contains("my-apps/strata"), "Installed must not probe source-tree, probed \(path)")
            XCTAssertFalse(path.contains("my-apps"), "Installed must not probe my-apps, probed \(path)")
        }
        XCTAssertTrue(box.paths.count <= 4, "Installed should only probe app-owned candidates, got \(box.paths)")
        XCTAssertFalse(box.paths.contains(where: { $0.contains("WorkerLaunchConfiguration") }))
    }

    func testInstalledHomeApplicationsAlsoNotProbe() throws {
        let box = ProbeBox()
        let resourceURL = URL(fileURLWithPath: "/tmp/fakeBundle/Resources")
        let supportURL = URL(fileURLWithPath: "/tmp/fakeSupport")
        let (fileExists, isExecutable) = makeTracker(validPaths: [], box: box)

        do {
            _ = try WorkerLaunchConfiguration.resolved(
                workerDirectoryOverride: nil,
                srcRoot: "/Users/test/Documents/my-apps/strata",
                isDebug: true,
                bundlePath: "/Users/test/Applications/Strata.app",
                resourceURL: resourceURL,
                applicationSupportURL: supportURL,
                fileExists: fileExists,
                isExecutable: isExecutable,
                sourceFilePath: "/Users/test/Documents/my-apps/strata/Strata/Inference/WorkerLaunchConfiguration.swift",
                currentDirectoryPath: "/Users/test/Documents/my-apps/strata"
            )
            XCTFail("Should throw for installed home Applications")
        } catch {
            for path in box.paths {
                XCTAssertFalse(path.contains("Documents"))
            }
            XCTAssertFalse(box.paths.contains("/Users/test/Documents/my-apps/strata/InferenceWorker"))
            XCTAssertTrue(box.paths.count <= 4)
        }
    }

    func testInstalledBundleWorkerIsUsedWithoutDocumentProbe() throws {
        let box = ProbeBox()
        let resourceURL = URL(fileURLWithPath: "/tmp/fakeBundle/Resources")
        let supportURL = URL(fileURLWithPath: "/tmp/fakeSupport")
        let bundleWorker = "/tmp/fakeBundle/Resources/InferenceWorker"
        let bundlePython = "/tmp/fakeBundle/Resources/InferenceWorker/.venv/bin/python3"
        let valid: Set<String> = [bundleWorker, bundlePython]
        let (fileExists, isExecutable) = makeTracker(validPaths: valid, box: box)

        let config = try WorkerLaunchConfiguration.resolved(
            workerDirectoryOverride: nil,
            srcRoot: nil,
            isDebug: true,
            bundlePath: "/Applications/Strata.app",
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: fileExists,
            isExecutable: isExecutable,
            sourceFilePath: "/Users/michaelbuckingham/Documents/my-apps/strata/Strata/Inference/WorkerLaunchConfiguration.swift",
            currentDirectoryPath: "/Users/michaelbuckingham/Documents/my-apps/strata"
        )
        XCTAssertEqual(config.workerDirectory.path, bundleWorker)
        XCTAssertEqual(config.pythonExecutable.path, bundlePython)
        for path in box.paths {
            XCTAssertFalse(path.contains("Documents"))
            XCTAssertFalse(path.contains("my-apps"))
        }
        XCTAssertFalse(box.paths.contains(where: { $0.contains("WorkerLaunchConfiguration") }))
        // Installed prefers Application Support first; bundle fallback probes support dir first then bundle dir/python plus final validation
        XCTAssertTrue(box.paths.count <= 6, "Installed with only bundle valid should probe at most 6 paths (support+ bundle+validation), got \(box.paths)")
    }

    func testInstalledPrefersApplicationSupportOverBundle() throws {
        let box = ProbeBox()
        let resourceURL = URL(fileURLWithPath: "/tmp/fakeBundle/Resources")
        let supportURL = URL(fileURLWithPath: "/tmp/fakeSupport")
        let bundleWorker = "/tmp/fakeBundle/Resources/InferenceWorker"
        let bundlePython = "/tmp/fakeBundle/Resources/InferenceWorker/.venv/bin/python3"
        let supportWorker = "/tmp/fakeSupport/Strata/InferenceWorker"
        let supportPython = "/tmp/fakeSupport/Strata/InferenceWorker/.venv/bin/python3"
        let valid: Set<String> = [bundleWorker, bundlePython, supportWorker, supportPython]
        let (fileExists, isExecutable) = makeTracker(validPaths: valid, box: box)

        let config = try WorkerLaunchConfiguration.resolved(
            workerDirectoryOverride: nil,
            srcRoot: nil,
            isDebug: true,
            bundlePath: "/Applications/Strata.app",
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: fileExists,
            isExecutable: isExecutable,
            sourceFilePath: "/tmp/dev/Project/Strata/Inference/WorkerLaunchConfiguration.swift",
            currentDirectoryPath: "/tmp/dev/Project"
        )
        XCTAssertEqual(config.workerDirectory.path, supportWorker, "Installed should prefer Application Support over bundle resource")
        XCTAssertEqual(config.pythonExecutable.path, supportPython)
        for path in box.paths {
            XCTAssertFalse(path.contains("Documents"))
            XCTAssertFalse(path.contains("my-apps"))
        }
        XCTAssertFalse(box.paths.contains(where: { $0.contains("WorkerLaunchConfiguration") }))
    }

    func testInstalledSelectsApplicationSupportWhenPresent() throws {
        let box = ProbeBox()
        let resourceURL = URL(fileURLWithPath: "/tmp/fakeBundle/Resources")
        let supportURL = URL(fileURLWithPath: "/tmp/fakeSupport")
        let supportWorker = "/tmp/fakeSupport/Strata/InferenceWorker"
        let supportPython = "/tmp/fakeSupport/Strata/InferenceWorker/.venv/bin/python3"
        let valid: Set<String> = [supportWorker, supportPython]
        let (fileExists, isExecutable) = makeTracker(validPaths: valid, box: box)

        let config = try WorkerLaunchConfiguration.resolved(
            workerDirectoryOverride: nil,
            srcRoot: nil,
            isDebug: true,
            bundlePath: "/Applications/Strata.app",
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: fileExists,
            isExecutable: isExecutable,
            sourceFilePath: "/Users/michaelbuckingham/Documents/my-apps/strata/Strata/Inference/WorkerLaunchConfiguration.swift",
            currentDirectoryPath: "/Users/michaelbuckingham/Documents/my-apps/strata"
        )
        XCTAssertEqual(config.workerDirectory.path, supportWorker)
        XCTAssertEqual(config.pythonExecutable.path, supportPython)
        for path in box.paths {
            XCTAssertFalse(path.contains("Documents"), "Installed must not probe Documents, probed \(path)")
            XCTAssertFalse(path.contains("my-apps"), "Installed must not probe source tree, probed \(path)")
            XCTAssertFalse(path.contains("WorkerLaunchConfiguration"), "Installed must not probe source file path, probed \(path)")
        }
        XCTAssertTrue(box.paths.count <= 4, "Installed with only Application Support valid should probe at most 4 paths, got \(box.paths)")
        // Should not have needed to probe Documents/source tree at all
        XCTAssertTrue(box.paths.contains(supportWorker))
    }

    func testDevFindsWorkerViaFilePath() throws {
        let box = ProbeBox()
        let resourceURL = URL(fileURLWithPath: "/tmp/emptyBundle")
        let supportURL = URL(fileURLWithPath: "/tmp/emptySupport")
        let devWorker = "/tmp/dev/Project/InferenceWorker"
        let devPython = "/tmp/dev/Project/InferenceWorker/.venv/bin/python3"
        let valid: Set<String> = [devWorker, devPython]
        let (fileExists, isExecutable) = makeTracker(validPaths: valid, box: box)

        let config = try WorkerLaunchConfiguration.resolved(
            workerDirectoryOverride: nil,
            srcRoot: nil,
            isDebug: true,
            bundlePath: "/Users/test/Library/Developer/Xcode/DerivedData/Strata-xyz/Build/Products/Debug/Strata.app",
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: fileExists,
            isExecutable: isExecutable,
            sourceFilePath: "/tmp/dev/Project/Strata/Inference/WorkerLaunchConfiguration.swift",
            currentDirectoryPath: "/tmp/dev/Project"
        )
        XCTAssertEqual(config.workerDirectory.path, devWorker)
        XCTAssertTrue(box.paths.contains(devWorker) || box.paths.contains(devPython))
    }

    func testDevSRCROOTIsUsedWhenPresent() throws {
        let box = ProbeBox()
        let resourceURL = URL(fileURLWithPath: "/tmp/emptyBundle")
        let supportURL = URL(fileURLWithPath: "/tmp/emptySupport")
        let srcWorker = "/tmp/srcRoot/InferenceWorker"
        let srcPython = "/tmp/srcRoot/InferenceWorker/.venv/bin/python3"
        let valid: Set<String> = [srcWorker, srcPython]
        let (fileExists, isExecutable) = makeTracker(validPaths: valid, box: box)

        let config = try WorkerLaunchConfiguration.resolved(
            workerDirectoryOverride: nil,
            srcRoot: "/tmp/srcRoot",
            isDebug: true,
            bundlePath: "/Users/test/Library/Developer/Xcode/DerivedData/Strata-abc/Build/Products/Debug/Strata.app",
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: fileExists,
            isExecutable: isExecutable,
            sourceFilePath: "/tmp/dev/Project/Strata/Inference/WorkerLaunchConfiguration.swift",
            currentDirectoryPath: "/tmp/dev/Project"
        )
        XCTAssertEqual(config.workerDirectory.path, srcWorker)
    }

    func testDevPrefersAppOwnedOverSourceTree() throws {
        let box = ProbeBox()
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/bundleSup")
        let supportWorker = "/tmp/bundleSup/Strata/InferenceWorker"
        let supportPython = "/tmp/bundleSup/Strata/InferenceWorker/.venv/bin/python3"
        let bundleWorker = "/tmp/bundleRes/InferenceWorker"
        let bundlePython = "/tmp/bundleRes/InferenceWorker/.venv/bin/python3"
        let srcWorker = "/tmp/srcRoot/InferenceWorker"
        let srcPython = "/tmp/srcRoot/InferenceWorker/.venv/bin/python3"
        let devWorker = "/tmp/dev/Project/InferenceWorker"
        let devPython = "/tmp/dev/Project/InferenceWorker/.venv/bin/python3"
        let valid: Set<String> = [bundleWorker, bundlePython, supportWorker, supportPython, srcWorker, srcPython, devWorker, devPython]
        let (fileExists, isExecutable) = makeTracker(validPaths: valid, box: box)

        let config = try WorkerLaunchConfiguration.resolved(
            workerDirectoryOverride: nil,
            srcRoot: "/tmp/srcRoot",
            isDebug: true,
            bundlePath: "/Users/test/Library/Developer/Xcode/DerivedData/Strata-abc/Build/Products/Debug/Strata.app",
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: fileExists,
            isExecutable: isExecutable,
            sourceFilePath: "/tmp/dev/Project/Strata/Inference/WorkerLaunchConfiguration.swift",
            currentDirectoryPath: "/tmp/dev/Project"
        )
        // Dev prefers app-owned candidate first: Application Support wins over bundle, both win over SRCROOT/filePath
        XCTAssertEqual(config.workerDirectory.path, supportWorker)
        XCTAssertTrue(box.paths.contains(supportWorker))
    }

    func testDevPrefersBundleOverSourceTreeWhenSupportAbsent() throws {
        let box = ProbeBox()
        let resourceURL = URL(fileURLWithPath: "/tmp/bundleRes")
        let supportURL = URL(fileURLWithPath: "/tmp/bundleSup")
        let bundleWorker = "/tmp/bundleRes/InferenceWorker"
        let bundlePython = "/tmp/bundleRes/InferenceWorker/.venv/bin/python3"
        let srcWorker = "/tmp/srcRoot/InferenceWorker"
        let srcPython = "/tmp/srcRoot/InferenceWorker/.venv/bin/python3"
        let valid: Set<String> = [bundleWorker, bundlePython, srcWorker, srcPython]
        let (fileExists, isExecutable) = makeTracker(validPaths: valid, box: box)

        let config = try WorkerLaunchConfiguration.resolved(
            workerDirectoryOverride: nil,
            srcRoot: "/tmp/srcRoot",
            isDebug: true,
            bundlePath: "/Users/test/Library/Developer/Xcode/DerivedData/Strata-abc/Build/Products/Debug/Strata.app",
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: fileExists,
            isExecutable: isExecutable,
            sourceFilePath: "/tmp/dev/Project/Strata/Inference/WorkerLaunchConfiguration.swift",
            currentDirectoryPath: "/tmp/dev/Project"
        )
        XCTAssertEqual(config.workerDirectory.path, bundleWorker)
        XCTAssertTrue(box.paths.contains(bundleWorker))
    }

    func testOverrideWorksEvenWhenInstalled() throws {
        let box = ProbeBox()
        let resourceURL = URL(fileURLWithPath: "/tmp/fakeBundle/Resources")
        let supportURL = URL(fileURLWithPath: "/tmp/fakeSupport")
        let override = "/tmp/override/InferenceWorker"
        let overridePython = "/tmp/override/InferenceWorker/.venv/bin/python3"
        let valid: Set<String> = [override, overridePython]
        let (fileExists, isExecutable) = makeTracker(validPaths: valid, box: box)

        let config = try WorkerLaunchConfiguration.resolved(
            workerDirectoryOverride: override,
            srcRoot: nil,
            isDebug: true,
            bundlePath: "/Applications/Strata.app",
            resourceURL: resourceURL,
            applicationSupportURL: supportURL,
            fileExists: fileExists,
            isExecutable: isExecutable,
            sourceFilePath: "/Users/michaelbuckingham/Documents/my-apps/strata/Strata/Inference/WorkerLaunchConfiguration.swift",
            currentDirectoryPath: "/Users/michaelbuckingham/Documents/my-apps/strata"
        )
        XCTAssertEqual(config.workerDirectory.path, override)
    }

    func testReadinessSurfacesInstalledLaunchConfigurationError() {
        let checker = RuntimeReadinessChecker(
            isExecutable: { path in
                if path == RuntimeReadiness.ffmpegPath { return true }
                if path == RuntimeReadiness.ytDlpPath { return true }
                if path == RuntimeReadiness.nodePath { return true }
                return false
            },
            resolveWorker: {
                throw InferenceError.launchConfiguration("Worker not found. Checked /tmp/fakeSupport/Strata/InferenceWorker and /Applications/Strata.app/Contents/Resources/InferenceWorker. Run scripts/install-inference-worker.sh from the repository to create the worker at ~/Library/Application Support/Strata/InferenceWorker, or set DEMUX_WORKER_DIRECTORY to an absolute InferenceWorker directory.")
            }
        )
        let readiness = checker.check()
        XCTAssertFalse(readiness.workerAvailable)
        XCTAssertNotNil(readiness.workerError)
        XCTAssertTrue(readiness.workerError!.contains("Worker not found"))
        XCTAssertTrue(readiness.workerError!.contains("scripts/install-inference-worker.sh"))
        XCTAssertTrue(readiness.workerError!.contains("DEMUX_WORKER_DIRECTORY"))
        XCTAssertFalse(readiness.workerError!.contains("reinstall"))
        XCTAssertTrue(readiness.sidebarStatus.hasPrefix("Setup needed"))
        XCTAssertTrue(readiness.sidebarStatus.contains("Worker not found") || readiness.sidebarStatus.contains("DEMUX_WORKER_DIRECTORY"))
        XCTAssertTrue(readiness.sidebarStatus.contains("scripts/install-inference-worker.sh"))
        XCTAssertFalse(readiness.isWorkerReady)
        XCTAssertFalse(readiness.isSeparationReady)
    }

    func testReadinessInstalledErrorContainsPathWithSlash() {
        let checker = RuntimeReadinessChecker(
            isExecutable: { _ in true },
            resolveWorker: {
                throw InferenceError.launchConfiguration("Worker not found. Checked /tmp/fakeSupport/Strata/InferenceWorker and /tmp/bundle/Resources/InferenceWorker. Run scripts/install-inference-worker.sh from the repository to create the worker at ~/Library/Application Support/Strata/InferenceWorker, or set DEMUX_WORKER_DIRECTORY to an absolute InferenceWorker directory.")
            }
        )
        let r = checker.check()
        XCTAssertFalse(r.workerAvailable)
        XCTAssertTrue(r.sidebarStatus.contains("/tmp/fakeSupport/Strata/InferenceWorker"))
        XCTAssertTrue(r.sidebarStatus.contains("Setup needed"))
        XCTAssertTrue(r.workerError?.contains("scripts/install-inference-worker.sh") == true)
        XCTAssertFalse(r.workerError?.contains("reinstall") == true)
    }

    func testIsInstalledBundleDetection() {
        XCTAssertTrue(WorkerLaunchConfiguration.isInstalledBundle(bundlePath: "/Applications/Strata.app"))
        XCTAssertTrue(WorkerLaunchConfiguration.isInstalledBundle(bundlePath: "/Users/mb/Applications/Strata.app"))
        XCTAssertTrue(WorkerLaunchConfiguration.isInstalledBundle(bundlePath: "/Users/mb/Library/Containers/Strata/Data/Applications/Strata.app"))
        XCTAssertFalse(WorkerLaunchConfiguration.isInstalledBundle(bundlePath: "/Users/mb/Library/Developer/Xcode/DerivedData/Strata-abc/Build/Products/Debug/Strata.app"))
        XCTAssertFalse(WorkerLaunchConfiguration.isInstalledBundle(bundlePath: "/tmp/Strata.app"))
        XCTAssertFalse(WorkerLaunchConfiguration.isInstalledBundle(bundlePath: ""))
    }
}
