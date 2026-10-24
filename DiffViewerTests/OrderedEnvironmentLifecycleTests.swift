import Foundation
import Synchronization
import Testing

@testable import DiffViewer

/// Records applied events. With `holdFirst`, the first `apply` blocks until `release()`.
/// Waiting uses stream signals, so cancelling a wait ends it.
private actor ApplyRecorder {
    private(set) var events: [OrderedEnvironmentLifecycle.Event] = []
    private let holdFirst: Bool
    private var calls = 0
    private let startedSignals: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let appliedSignals: AsyncStream<Void>
    private let appliedContinuation: AsyncStream<Void>.Continuation
    private let releaseSignals: AsyncStream<Void>
    nonisolated private let releaseContinuation: AsyncStream<Void>.Continuation

    init(holdFirst: Bool = false) {
        self.holdFirst = holdFirst
        (startedSignals, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        (appliedSignals, appliedContinuation) = AsyncStream.makeStream(of: Void.self)
        (releaseSignals, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func apply(_ event: OrderedEnvironmentLifecycle.Event) async {
        calls += 1
        if calls == 1 { startedContinuation.yield() }
        if holdFirst && calls == 1 {
            for await _ in releaseSignals { break }
        }
        events.append(event)
        appliedContinuation.yield()
    }

    /// Buffered, so releasing before the first `apply` is safe.
    nonisolated func release() { releaseContinuation.yield() }

    /// Returns once the first `apply` has begun, which is when a hold takes effect.
    func waitForFirstApplyToStart() async {
        var iterator = startedSignals.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitForApplied(_ count: Int) async {
        var iterator = appliedSignals.makeAsyncIterator()
        for _ in 0..<count { _ = await iterator.next() }
    }
}

/// Hands one value to a single waiter, whichever of the racers resumes first; later values
/// are ignored. Works in either order of `resume` and `wait`.
private final class FirstResult: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Bool, Never>?
        var result: Bool?
    }

    private let state = Mutex(State())

    func resume(_ value: Bool) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.result == nil else { return nil }
            state.result = value
            return state.continuation.take()
        }
        continuation?.resume(returning: value)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let early = state.withLock { state -> Bool? in
                if state.result == nil { state.continuation = continuation }
                return state.result
            }
            if let early { continuation.resume(returning: early) }
        }
    }
}

/// Runs `operation` and returns whether it finished before the failure safeguard. Cancelling
/// the waiter does not interrupt an `await task.value`, so on timeout `onTimeout` must end
/// whatever `operation` awaits.
private func finishes(
    within seconds: Int = 10,
    onTimeout: @escaping @Sendable () -> Void = {},
    operation: @escaping @Sendable () async -> Void
) async -> Bool {
    let race = FirstResult()
    let waiter = Task {
        await operation()
        race.resume(true)
    }
    let sleeper = Task {
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        race.resume(false)
    }
    let finished = await race.wait()
    sleeper.cancel()
    if !finished {
        waiter.cancel()
        onTimeout()
    }
    return finished
}

@MainActor
struct OrderedEnvironmentLifecycleTests {
    private let root = RepositoryRoot(path: "/tmp/OrderedA")

    @Test func eventsApplyInTheOrderSentEvenWhileTheFirstIsStillRunning() async {
        let recorder = ApplyRecorder(holdFirst: true)
        let ordered = OrderedEnvironmentLifecycle { await recorder.apply($0) }
        let consumer = ordered.consumer
        defer {
            recorder.release()
            ordered.finish()
        }

        ordered.lifecycle.forget(root)
        // The second event goes in only while the first `apply` is held.
        #expect(
            await finishes(onTimeout: { consumer.cancel() }, operation: { await recorder.waitForFirstApplyToStart() }))
        ordered.lifecycle.refresh(root)
        recorder.release()

        #expect(await finishes(onTimeout: { consumer.cancel() }, operation: { await recorder.waitForApplied(2) }))
        #expect(await recorder.events == [.forget(root.url), .refresh(root.url)])
    }

    @Test func finishDrainsQueuedEventsAndDropsLaterOnes() async {
        let recorder = ApplyRecorder()
        let ordered = OrderedEnvironmentLifecycle { await recorder.apply($0) }
        let consumer = ordered.consumer

        ordered.lifecycle.refresh(root)
        ordered.finish()
        #expect(await finishes(onTimeout: { consumer.cancel() }, operation: { await consumer.value }))
        #expect(await recorder.events == [.refresh(root.url)])

        ordered.lifecycle.forget(root)
        #expect(await recorder.events == [.refresh(root.url)])
    }
}
