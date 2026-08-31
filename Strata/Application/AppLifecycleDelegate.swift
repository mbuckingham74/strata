import AppKit
import SwiftUI

// MARK: - AppLifecycleDelegate

/// Deterministic worker cleanup on app termination.
/// Uses AppKit deferral: applicationShouldTerminate -> terminateLater -> bounded shutdown -> reply
/// Delegates separable bounded logic to AppTerminationCoordinator for testability.
/// Does not introduce a global worker singleton; holds weak reference to the single root-owned InferenceController.
// MARK: - HostedTestEnvironment

/// Minimal hosted-XCTest detection. The running Strata process is a test host
/// when Xcode injects XCTest configuration via environment or loads XCTest.
/// Production launches never set XCTestConfigurationFilePath, so this is false there.
enum HostedTestEnvironment {
    static func isHostedTest() -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        // Fallback when bundle already injected (e.g. parallelized hosted run).
        if NSClassFromString("XCTestCase") != nil { return true }
        return false
    }
}

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {

    weak var inferenceController: InferenceController?
    private var coordinator: AppTerminationCoordinator?
    /// Test seam: defaults to live hosted-test check, override in unit tests.
    var isHostedTestCheck: () -> Bool = HostedTestEnvironment.isHostedTest

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Hosted XCTest copies must terminate normally when the test runner
        // disposes of them. Never defer or refuse termination in that case.
        // Production/manual launches retain bounded deferral below.
        if isHostedTestCheck() {
            return .terminateNow
        }
        // Reuse the same owner after an unsafe reply as well. Its retry task
        // transitively joins the prior reply task before starting new cleanup,
        // closing the reentrancy window between state update and AppKit reply.
        if let existing = coordinator {
            return existing.shouldTerminate()
        }
        guard let controller = inferenceController else {
            return .terminateNow
        }
        let c = AppTerminationCoordinator(
            shutdown: { await controller.terminateForApplicationExit() },
            reply: { shouldTerminate in
                await MainActor.run {
                    NSApplication.shared.reply(toApplicationShouldTerminate: shouldTerminate)
                }
            }
        )
        coordinator = c
        return c.shouldTerminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // No async here; termination deferral already handled via applicationShouldTerminate.
    }
}
