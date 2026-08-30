import XCTest
@testable import Strata
import AppKit
import Foundation

// MARK: - Test helpers

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}

private final class ReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _values: [Bool] = []
    private var _times: [ContinuousClock.Instant] = []
    func record(_ v: Bool) {
        lock.lock()
        _count += 1
        _values.append(v)
        _times.append(ContinuousClock.now)
        lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return _values }
    var times: [ContinuousClock.Instant] { lock.lock(); defer { lock.unlock() }; return _times }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

// MARK: - AppTerminationCoordinatorTests

final class AppTerminationCoordinatorTests: XCTestCase {

    // 1. fast async worker shutdown causes exactly one termination reply (safe -> true)
    func testFastAsyncWorkerShutdownCausesExactlyOneReply() async throws {
        let replies = ReplyRecorder()
        let shutdowns = Counter()
        let replied = expectation(description: "termination reply")
        let coordinator = AppTerminationCoordinator(
            shutdown: {
                shutdowns.increment()
                return .safeToTerminate
            },
            reply: { replies.record($0); replied.fulfill() }
        )
        let result = coordinator.shouldTerminate()
        XCTAssertEqual(result, .terminateLater, "must defer termination")

        await fulfillment(of: [replied], timeout: 1)

        XCTAssertEqual(replies.count, 1, "fast shutdown must cause exactly one reply")
        XCTAssertEqual(shutdowns.value, 1, "fast shutdown must be requested once")
        XCTAssertEqual(replies.values.first, true)
    }

    // 2. duplicate/concurrent termination attempts cannot cause duplicate replies
    func testDuplicateConcurrentAttemptsCannotCauseDuplicateReplies() async throws {
        let replies = ReplyRecorder()
        let shutdowns = Counter()
        let gate = AsyncGate()
        let replied = expectation(description: "termination reply")
        let coordinator = AppTerminationCoordinator(
            shutdown: {
                shutdowns.increment()
                await gate.wait()
                return .safeToTerminate
            },
            reply: { replies.record($0); replied.fulfill() }
        )

        let concurrentCount = 20
        await withTaskGroup(of: NSApplication.TerminateReply.self) { group in
            for _ in 0..<concurrentCount {
                group.addTask { coordinator.shouldTerminate() }
            }
            for await r in group {
                XCTAssertEqual(r, .terminateLater)
            }
        }

        await gate.open()
        await fulfillment(of: [replied], timeout: 1)

        XCTAssertEqual(replies.count, 1, "concurrent duplicate attempts must not cause duplicate replies")
        XCTAssertEqual(shutdowns.value, 1, "concurrent duplicates must not request additional shutdowns")
    }

    func testDuplicateSequentialAttemptsCannotCauseDuplicateReplies() async throws {
        let replies = ReplyRecorder()
        let shutdowns = Counter()
        let gate = AsyncGate()
        let replied = expectation(description: "termination reply")
        let coordinator = AppTerminationCoordinator(
            shutdown: {
                shutdowns.increment()
                await gate.wait()
                return .safeToTerminate
            },
            reply: { replies.record($0); replied.fulfill() }
        )
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)

        await gate.open()
        await fulfillment(of: [replied], timeout: 1)

        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(shutdowns.value, 1)
    }

    // 3. worker shutdown is requested exactly once per accepted termination sequence
    func testWorkerShutdownRequestedExactlyOncePerAcceptedSequence() async throws {
        let shutdowns = Counter()
        let replies = ReplyRecorder()
        let gate = AsyncGate()
        let replied = expectation(description: "first termination reply")
        let coordinator = AppTerminationCoordinator(
            shutdown: {
                shutdowns.increment()
                await gate.wait()
                return .safeToTerminate
            },
            reply: { replies.record($0); replied.fulfill() }
        )
        // First accepted sequence
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        // Duplicates within same sequence
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)

        await gate.open()
        await fulfillment(of: [replied], timeout: 1)

        XCTAssertEqual(shutdowns.value, 1, "shutdown must be requested exactly once per accepted sequence")
        XCTAssertEqual(replies.count, 1)
        XCTAssertTrue(coordinator.hasAcceptedTermination)

        // New coordinator represents new accepted sequence (simulating new app lifecycle)
        let shutdowns2 = Counter()
        let replies2 = ReplyRecorder()
        let replied2 = expectation(description: "second termination reply")
        let coordinator2 = AppTerminationCoordinator(
            shutdown: {
                shutdowns2.increment()
                return .safeToTerminate
            },
            reply: { replies2.record($0); replied2.fulfill() }
        )
        XCTAssertEqual(coordinator2.shouldTerminate(), .terminateLater)
        await fulfillment(of: [replied2], timeout: 1)
        XCTAssertEqual(shutdowns2.value, 1)
        XCTAssertEqual(replies2.count, 1)
    }

    func testFastShutdownShutdownCountExactlyOneEvenWithTimeoutRace() async throws {
        // Ensures shutdown not invoked twice via race between fast path and timeout
        let shutdowns = Counter()
        let replies = ReplyRecorder()
        let replied = expectation(description: "termination reply")
        let coordinator = AppTerminationCoordinator(
            shutdown: {
                shutdowns.increment()
                return .safeToTerminate
            },
            reply: { replies.record($0); replied.fulfill() }
        )
        coordinator.shouldTerminate()
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(shutdowns.value, 1)
        XCTAssertEqual(replies.count, 1)
    }

    // MARK: - New Sol xHigh tests

    // Test 5 - bounded AppKit deferral: both safe and unsafe produce exactly one reply within target
    func testBoundedDeferralSafeProducesExactlyOneReplyWithinTarget() async throws {
        let replies = ReplyRecorder()
        let start = ContinuousClock.now
        let replied = expectation(description: "safe termination reply")
        let coordinator = AppTerminationCoordinator(
            shutdown: { .safeToTerminate },
            reply: { replies.record($0); replied.fulfill() }
        )
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replies.count, 1, "safe cleanup must produce exactly one reply")
        XCTAssertEqual(replies.values.first, true)
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(1), "safe path must be bounded within lifecycle target")
    }

    func testBoundedDeferralUnsafeProducesExactlyOneReplyFalseWithinTarget() async throws {
        let replies = ReplyRecorder()
        let start = ContinuousClock.now
        let replied = expectation(description: "unsafe termination reply")
        let coordinator = AppTerminationCoordinator(
            shutdown: { .unsafeToTerminate(reason: .workerStillRunning) },
            reply: { replies.record($0); replied.fulfill() }
        )
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replies.count, 1, "unsafe cleanup must produce exactly one reply")
        XCTAssertEqual(replies.values.first, false, "unsafe must reply false, never true")
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(1), "unsafe path must be bounded")
        // Must never have replied true
        XCTAssertFalse(replies.values.contains(true), "unsafe path must never reply true")
    }

    // Ensure old invalid assumption "timeout means permission to reply true" is removed
    // This test proves unsafe never maps to true
    func testUnsafeNeverMapsToTrue() async throws {
        let replies = ReplyRecorder()
        let replied = expectation(description: "unsafe termination reply")
        let coordinator = AppTerminationCoordinator(
            shutdown: { .unsafeToTerminate(reason: .deadlineExpired) },
            reply: { replies.record($0); replied.fulfill() }
        )
        coordinator.shouldTerminate()
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.values.first, false)
        XCTAssertNotEqual(replies.values.first, true, "timeout/unsafe must NOT be treated as permission to reply true")
    }

    // Test 6 - exactly once + retry
    func testConcurrentRepeatedWhilePendingOnlyOneCleanupOneReply() async throws {
        let replies = ReplyRecorder()
        let shutdowns = Counter()
        let gate = AsyncGate()
        let replied = expectation(description: "termination reply")
        let coordinator = AppTerminationCoordinator(
            shutdown: {
                shutdowns.increment()
                await gate.wait()
                return .safeToTerminate
            },
            reply: { replies.record($0); replied.fulfill() }
        )
        // First call starts cleanup
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        // Concurrent/repeated while pending
        for _ in 0..<5 {
            XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        }
        await withTaskGroup(of: NSApplication.TerminateReply.self) { group in
            for _ in 0..<10 {
                group.addTask { coordinator.shouldTerminate() }
            }
            for await r in group { XCTAssertEqual(r, .terminateLater) }
        }
        await gate.open()
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(shutdowns.value, 1, "one cleanup sequence while pending")
        XCTAssertEqual(replies.count, 1, "one eventual reply")
    }

    func testAfterFalseSubsequentStartsExactlyOneNewCleanup() async throws {
        let replies = ReplyRecorder()
        let shutdowns = Counter()
        final class Flag: @unchecked Sendable {
            let lock = NSLock()
            var value = false
            func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
            func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
        }
        let flag = Flag()
        let firstReply = expectation(description: "first false reply")
        let secondReply = expectation(description: "second true reply")
        let coordinator = AppTerminationCoordinator(
            shutdown: {
                shutdowns.increment()
                if flag.get() { return .safeToTerminate } else { return .unsafeToTerminate(reason: .workerStillRunning) }
            },
            reply: {
                replies.record($0)
                if $0 { secondReply.fulfill() } else { firstReply.fulfill() }
            }
        )
        // First attempt -> unsafe -> false
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        await fulfillment(of: [firstReply], timeout: 1)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.values.first, false)
        XCTAssertEqual(shutdowns.value, 1)
        // Coordinator should have reset to allow retry (hasAcceptedTermination false after false)
        XCTAssertFalse(coordinator.hasAcceptedTermination, "after false, coordinator must reset to allow fresh sequence")
        // Second attempt -> should start new cleanup
        flag.set(true)
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        await fulfillment(of: [secondReply], timeout: 1)
        XCTAssertEqual(shutdowns.value, 2, "subsequent request after false must start exactly one new cleanup")
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies.values.last, true)
    }

    func testAfterTrueNoDuplicateAsyncReplyAndReturnsTerminateNow() async throws {
        let replies = ReplyRecorder()
        let shutdowns = Counter()
        let replied = expectation(description: "successful termination reply")
        let coordinator = AppTerminationCoordinator(
            shutdown: {
                shutdowns.increment()
                return .safeToTerminate
            },
            reply: { replies.record($0); replied.fulfill() }
        )
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.values.first, true)
        XCTAssertTrue(coordinator.hasAcceptedTermination)
        // Subsequent call after true should return terminateNow and not start new cleanup
        let secondResult = coordinator.shouldTerminate()
        XCTAssertEqual(secondResult, .terminateNow, "after successful cleanup, reentrant query may return terminateNow")
        XCTAssertEqual(shutdowns.value, 1, "after true, no duplicate cleanup")
        XCTAssertEqual(replies.count, 1, "after true, no duplicate async reply")
    }

    func testCoordinatorInstancesMaintainIndependentTerminationState() async throws {
        let firstReplies = ReplyRecorder()
        let secondReplies = ReplyRecorder()
        let firstShutdowns = Counter()
        let secondShutdowns = Counter()
        let firstGate = AsyncGate()
        let firstStarted = expectation(description: "first coordinator cleanup started")
        let firstReplied = expectation(description: "first coordinator replied")
        let secondReplied = expectation(description: "second coordinator replied")

        let first = AppTerminationCoordinator(
            shutdown: {
                firstShutdowns.increment()
                firstStarted.fulfill()
                await firstGate.wait()
                return .safeToTerminate
            },
            reply: { firstReplies.record($0); firstReplied.fulfill() }
        )
        let second = AppTerminationCoordinator(
            shutdown: {
                secondShutdowns.increment()
                return .safeToTerminate
            },
            reply: { secondReplies.record($0); secondReplied.fulfill() }
        )

        XCTAssertEqual(first.shouldTerminate(), .terminateLater)
        XCTAssertEqual(second.shouldTerminate(), .terminateLater)
        await fulfillment(of: [firstStarted, secondReplied], timeout: 1)

        XCTAssertEqual(firstReplies.count, 0, "a pending first coordinator must not be completed by the second")
        XCTAssertEqual(secondReplies.count, 1)
        XCTAssertEqual(secondReplies.values, [true])
        XCTAssertEqual(firstShutdowns.value, 1)
        XCTAssertEqual(secondShutdowns.value, 1)
        XCTAssertTrue(first.hasActiveCleanupTask)
        XCTAssertTrue(second.hasAcceptedTermination)

        await firstGate.open()
        await fulfillment(of: [firstReplied], timeout: 1)
        XCTAssertEqual(firstReplies.count, 1)
        XCTAssertEqual(firstReplies.values, [true])
        XCTAssertEqual(secondReplies.count, 1, "completing the first coordinator must not reply through the second")
    }
}
