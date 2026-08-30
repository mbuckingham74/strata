import AppKit
import SwiftUI

// MARK: - AppLifecycleDelegate

/// Deterministic worker cleanup on app termination.
/// Uses AppKit deferral: applicationShouldTerminate -> terminateLater -> bounded shutdown -> reply
/// Delegates separable bounded logic to AppTerminationCoordinator for testability.
/// Does not introduce a global worker singleton; holds weak reference to the single root-owned InferenceController.
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {

    weak var inferenceController: InferenceController?
    private var coordinator: AppTerminationCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
