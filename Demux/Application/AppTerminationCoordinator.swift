import AppKit
import Foundation

// MARK: - AppTerminationCoordinator
//
// Sol xHigh: owns exactly ONE retained top-level Task bridging synchronous AppKit
// termination delegation to async cleanup. No independent timeout that can reply true.
// Mapping: safeToTerminate -> reply(true), any unsafe -> reply(false).
// While cleanup pending: .terminateLater, no duplicate cleanup, no duplicate reply.
// After false: reset so later quit can start fresh sequence.
// After true: safety proven, reentrant query may return .terminateNow, no second async reply.

final class AppTerminationCoordinator: @unchecked Sendable {

    typealias ShutdownAction = @Sendable () async -> ApplicationExitCleanupResult
    typealias ReplyAction = @Sendable (Bool) async -> Void

    private enum CoordinatorState {
        case idle
        case terminating
        case succeeded
        case failed
    }

    private let shutdown: ShutdownAction
    private let reply: ReplyAction
    private let lock = NSLock()
    private var state: CoordinatorState = .idle
    private var hasReplied = false
    private var retainedTask: Task<Void, Never>?

    init(shutdown: @escaping ShutdownAction, reply: @escaping ReplyAction) {
        self.shutdown = shutdown
        self.reply = reply
    }

    // Legacy Void overloads removed; callers must return ApplicationExitCleanupResult explicitly

    @discardableResult
    func shouldTerminate() -> NSApplication.TerminateReply {
        lock.lock()
        switch state {
        case .idle:
            state = .terminating
            hasReplied = false
            retainedTask = makeTerminationTask(joining: nil)
            lock.unlock()
            return .terminateLater
        case .terminating:
            lock.unlock()
            return .terminateLater
        case .succeeded:
            lock.unlock()
            return .terminateNow
        case .failed:
            state = .terminating
            hasReplied = false
            // The new retained task transitively owns the prior reply task until
            // that task has completely returned.
            retainedTask = makeTerminationTask(joining: retainedTask)
            lock.unlock()
            return .terminateLater
        }
    }

    private func makeTerminationTask(joining previousTask: Task<Void, Never>?) -> Task<Void, Never> {
        let shutdown = self.shutdown
        let reply = self.reply
        return Task { [weak self, previousTask] in
            if let previousTask { await previousTask.value }
            let result = await shutdown()
            guard let self else { return }
            let replyValue: Bool? = self.lock.withLock {
                guard !self.hasReplied else { return nil }
                self.hasReplied = true
                switch result {
                case .safeToTerminate:
                    self.state = .succeeded
                    return true
                case .unsafeToTerminate:
                    // Keep the completed task handle. A later retry joins it
                    // before replacing the retained owner.
                    self.state = .failed
                    return false
                }
            }
            guard let replyValue else { return }
            await reply(replyValue)
        }
    }

    var hasAcceptedTermination: Bool {
        lock.withLock {
            switch state {
            case .idle: return false
            case .terminating: return true
            case .succeeded: return true
            case .failed: return false
            }
        }
    }

    var hasActiveCleanupTask: Bool {
        lock.withLock {
            if case .terminating = state { return true }
            return false
        }
    }
}
