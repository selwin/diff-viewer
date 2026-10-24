import Foundation
import Synchronization
import Testing

@testable import DiffViewer

/// Drives the cache with a resolver, sleep and fallback the test controls. Every step waits
/// on a signal from them or an event from the cache, never on timing.
@Suite final class RepositoryShellEnvironmentCacheTests: Sendable {
    typealias Event = RepositoryShellEnvironmentCache.Event

    struct TimedOut: Error {}
    struct SignalEnded: Error {}

    /// Values sent before anyone waits stay buffered, so a wait never misses one.
    final class Signal<Value: Sendable>: Sendable {
        private let stream: AsyncStream<Value>
        private let continuation: AsyncStream<Value>.Continuation

        init() {
            (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        }

        func send(_ value: Value) {
            continuation.yield(value)
        }

        /// The first buffered or later value matching `predicate`; earlier ones are dropped.
        /// A timeout ends the stream, so the abandoned wait can't compete with the next one.
        @discardableResult
        func next(where predicate: @escaping @Sendable (Value) -> Bool = { _ in true }) async throws -> Value {
            try await withTimeLimit(
                onTimeout: { [continuation] in continuation.finish() },
                operation: { [stream] in
                    for await value in stream where predicate(value) { return value }
                    throw SignalEnded()
                })
        }
    }

    /// Each resolve call waits until the test finishes it, oldest first.
    final class HeldResolver: Sendable {
        let started = Signal<Void>()
        private let pending = Mutex<[CheckedContinuation<[String: String]?, Never>]>([])
        private let callCount = Mutex(0)

        var calls: Int { callCount.withLock { $0 } }

        func resolve() async -> [String: String]? {
            await withCheckedContinuation { continuation in
                pending.withLock { $0.append(continuation) }
                callCount.withLock { $0 += 1 }
                started.send(())
            }
        }

        func finishOldest(_ result: [String: String]?) {
            pending.withLock { $0.removeFirst() }.resume(returning: result)
        }

        func releaseAll() {
            let all = pending.withLock { pending in
                defer { pending = [] }
                return pending
            }
            for continuation in all { continuation.resume(returning: nil) }
        }
    }

    /// A sleep that ends when the test releases it, or throws when its task is cancelled.
    final class HeldSleep: Sendable {
        let started = Signal<Void>()
        private let pending = Mutex<[UUID: CheckedContinuation<Void, any Error>]>([:])

        func sleep() async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    // Under the lock, a cancellation either is already visible here or finds the entry.
                    let stored = pending.withLock { pending in
                        guard !Task.isCancelled else { return false }
                        pending[id] = continuation
                        return true
                    }
                    if stored { started.send(()) } else { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                pending.withLock { $0.removeValue(forKey: id) }?.resume(throwing: CancellationError())
            }
        }

        func releaseAll() {
            let all = pending.withLock { pending in
                defer { pending = [:] }
                return Array(pending.values)
            }
            for continuation in all { continuation.resume() }
        }
    }

    /// Counts fallback runs; when held, each run waits until the test releases it.
    final class Fallback: Sendable {
        static let variables = ["PATH": "/fallback"]

        let started = Signal<Void>()
        private let held = Mutex(false)
        private let pending = Mutex<[CheckedContinuation<Void, Never>]>([])
        private let callCount = Mutex(0)

        var calls: Int { callCount.withLock { $0 } }

        func hold() {
            held.withLock { $0 = true }
        }

        func run() async -> ProcessEnvironment {
            callCount.withLock { $0 += 1 }
            if held.withLock({ $0 }) {
                await withCheckedContinuation { continuation in
                    pending.withLock { $0.append(continuation) }
                    started.send(())
                }
            } else {
                started.send(())
            }
            return ProcessEnvironment(variables: Self.variables, inheritance: .inherit)
        }

        func releaseAll() {
            let all = pending.withLock { pending in
                defer { pending = [] }
                return pending
            }
            for continuation in all { continuation.resume() }
        }
    }

    let root = URL(fileURLWithPath: "/repo", isDirectory: true)
    let resolver = HeldResolver()
    let sleeper = HeldSleep()
    let fallback = Fallback()
    let events = Signal<Event>()
    let cache: RepositoryShellEnvironmentCache

    init() {
        let (resolver, sleeper, fallback, events) = (resolver, sleeper, fallback, events)
        cache = RepositoryShellEnvironmentCache(
            resolve: { _ in await resolver.resolve() },
            sleep: { _ in try await sleeper.sleep() },
            fallback: { await fallback.run() },
            onEvent: { events.send($0) })
    }

    /// Releases anything a failing test left held, so no task outlives it waiting.
    deinit {
        resolver.releaseAll()
        sleeper.releaseAll()
        fallback.releaseAll()
    }

    // MARK: Helpers

    private func environmentTask(for root: URL? = nil) -> Task<ProcessEnvironment, any Error> {
        let (cache, root) = (cache, root ?? self.root)
        return Task { try await cache.environment(for: root) }
    }

    private func value(of task: Task<ProcessEnvironment, any Error>) async throws -> ProcessEnvironment {
        try await withTimeLimit(onTimeout: { task.cancel() }, operation: { try await task.value })
    }

    private func expect(_ event: Event) async throws {
        try await events.next { $0 == event }
    }

    /// Finishes the next resolve call once it has started.
    private func finishResolve(_ result: [String: String]?) async throws {
        try await resolver.started.next()
        resolver.finishOldest(result)
    }

    /// Runs one resolution to completion, acknowledged by a caller that waited on it.
    private func populate(_ result: [String: String]) async throws {
        await cache.refresh(root)
        let caller = environmentTask()
        try await expect(.waiterRegistered(root))
        try await finishResolve(result)
        _ = try await value(of: caller)
    }

    // MARK: First resolution

    @Test func concurrentFirstCallsShareOneResolveAndFallBackWhenItFails() async throws {
        let first = environmentTask()
        let second = environmentTask()
        try await expect(.waiterRegistered(root))
        try await expect(.waiterRegistered(root))
        try await finishResolve(nil)

        for environment in [try await value(of: first), try await value(of: second)] {
            #expect(environment.variables == Fallback.variables)
            #expect(environment.inheritance == .inherit)
        }
        #expect(resolver.calls == 1)
        #expect(fallback.calls == 2)
    }

    // MARK: Refresh

    @Test func refreshCoalescesAndReplacesTheValue() async throws {
        await cache.refresh(root)
        await cache.refresh(root)
        let first = environmentTask()
        try await expect(.waiterRegistered(root))
        try await finishResolve(["V": "1"])
        #expect(try await value(of: first).variables == ["V": "1"])
        #expect(resolver.calls == 1)

        await cache.refresh(root)
        let second = environmentTask()
        try await expect(.waiterRegistered(root))
        try await finishResolve(["V": "2"])
        #expect(try await value(of: second).variables == ["V": "2"])

        let cached = try await cache.environment(for: root)
        #expect(cached.variables == ["V": "2"])
        #expect(cached.inheritance == .replace)
        #expect(resolver.calls == 2)
    }

    @Test func slowRefreshReturnsTheOldValueThenCachesTheNewOne() async throws {
        try await populate(["V": "1"])
        await cache.refresh(root)
        let impatient = environmentTask()
        try await expect(.waiterRegistered(root))
        try await sleeper.started.next()
        sleeper.releaseAll()
        // The resolver is still held, so this is the old snapshot.
        #expect(try await value(of: impatient).variables == ["V": "1"])

        let patient = environmentTask()
        try await expect(.waiterRegistered(root))
        try await finishResolve(["V": "2"])
        #expect(try await value(of: patient).variables == ["V": "2"])
        #expect(try await cache.environment(for: root).variables == ["V": "2"])
    }

    @Test func failedRefreshKeepsThePreviousSnapshot() async throws {
        try await populate(["V": "1"])
        await cache.refresh(root)
        let caller = environmentTask()
        try await expect(.waiterRegistered(root))
        try await finishResolve(nil)

        let waited = try await value(of: caller)
        #expect(waited.variables == ["V": "1"])
        #expect(waited.inheritance == .replace)
        #expect(try await cache.environment(for: root).variables == ["V": "1"])
        #expect(fallback.calls == 0)
    }

    // MARK: Lifecycle

    @Test func aResolutionFromBeforeForgetIsIgnored() async throws {
        await cache.refresh(root)
        try await resolver.started.next()
        await cache.forget(root)
        await cache.refresh(root)
        try await resolver.started.next()

        resolver.finishOldest(["V": "A"])
        try await expect(.resolutionFinished(root, accepted: false))
        // Registering as a waiter shows B is still in flight; a cached A would return at once.
        let caller = environmentTask()
        try await expect(.waiterRegistered(root))
        resolver.finishOldest(["V": "B"])

        #expect(try await value(of: caller).variables == ["V": "B"])
        #expect(try await cache.environment(for: root).variables == ["V": "B"])
    }

    @Test func forgetResumesWaitersWithTheSnapshot() async throws {
        try await populate(["V": "1"])
        await cache.refresh(root)
        let caller = environmentTask()
        try await expect(.waiterRegistered(root))
        await cache.forget(root)

        let waited = try await value(of: caller)
        #expect(waited.variables == ["V": "1"])
        #expect(waited.inheritance == .replace)
        #expect(fallback.calls == 0)
    }

    // MARK: Cancellation

    @Test func anAlreadyCancelledCallerThrowsWithoutRegistering() async throws {
        let cancelled = alreadyCancelledTask()
        await #expect(throws: CancellationError.self) { try await self.value(of: cancelled) }
        #expect(resolver.calls == 0)
        #expect(fallback.calls == 0)

        // The actor orders events, so a probe's registration arriving first proves none came before it.
        let probeRoot = URL(fileURLWithPath: "/probe", isDirectory: true)
        let probe = environmentTask(for: probeRoot)
        #expect(try await events.next() == .waiterRegistered(probeRoot))
        probe.cancel()
    }

    @Test func anAlreadyCancelledCallerWithASnapshotThrows() async throws {
        try await populate(["V": "1"])
        let cancelled = alreadyCancelledTask()
        await #expect(throws: CancellationError.self) { try await self.value(of: cancelled) }
        #expect(resolver.calls == 1)
        #expect(fallback.calls == 0)
    }

    @Test func cancellingOneWaiterLeavesTheResolutionForOthers() async throws {
        let cancelled = environmentTask()
        let kept = environmentTask()
        try await expect(.waiterRegistered(root))
        try await expect(.waiterRegistered(root))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await self.value(of: cancelled) }

        try await finishResolve(["V": "1"])
        #expect(try await value(of: kept).variables == ["V": "1"])
        #expect(resolver.calls == 1)
    }

    @Test func cancellingDuringTheFallbackThrowsOnceItReturns() async throws {
        fallback.hold()
        let caller = environmentTask()
        try await expect(.waiterRegistered(root))
        try await finishResolve(nil)
        try await fallback.started.next()
        caller.cancel()
        fallback.releaseAll()

        await #expect(throws: CancellationError.self) { try await self.value(of: caller) }
        #expect(fallback.calls == 1)
    }

    private func alreadyCancelledTask() -> Task<ProcessEnvironment, any Error> {
        let (cache, root) = (cache, root)
        return Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.environment(for: root)
        }
    }
}

/// Awaits `operation`, throwing instead of hanging if it takes 5 s. A failure safeguard only:
/// signals, not this limit, order each test. The losing side is left to finish on its own.
private func withTimeLimit<T: Sendable>(
    onTimeout: @escaping @Sendable () -> Void = {},
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = FirstOutcome<T>()
    return try await withCheckedThrowingContinuation { continuation in
        outcome.set(continuation)
        let timer = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if outcome.resume(with: .failure(RepositoryShellEnvironmentCacheTests.TimedOut())) { onTimeout() }
        }
        Task {
            do {
                outcome.resume(with: .success(try await operation()))
            } catch {
                outcome.resume(with: .failure(error))
            }
            timer.cancel()
        }
    }
}

/// Resumes a continuation once, with whichever outcome arrives first.
private final class FirstOutcome<T: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<T, any Error>?>(nil)

    func set(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    @discardableResult
    func resume(with result: Result<T, any Error>) -> Bool {
        guard let continuation = continuation.withLock({ $0.take() }) else { return false }
        continuation.resume(with: result)
        return true
    }
}
