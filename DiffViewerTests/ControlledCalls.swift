import Foundation
import Synchronization

/// An async dependency whose calls each wait until the test settles them, in any order. A call
/// ignores cancellation, so a test decides when even a cancelled caller gets its answer.
final class ControlledCalls<Argument: Sendable, Value: Sendable>: Sendable {
    private struct State {
        var arguments: [Argument] = []
        /// By call index; nil once settled.
        var continuations: [CheckedContinuation<Value, any Error>?] = []
    }

    private let state = Mutex(State())

    /// Every call's argument, in the order the calls started.
    var arguments: [Argument] { state.withLock { $0.arguments } }
    var count: Int { state.withLock { $0.arguments.count } }

    func call(_ argument: Argument) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock {
                $0.arguments.append(argument)
                $0.continuations.append(continuation)
            }
        }
    }

    /// Settles the call at `index`, counted in start order.
    func succeed(_ index: Int, with value: Value) {
        take(index)?.resume(returning: value)
    }

    func fail(_ index: Int, with error: any Error) {
        take(index)?.resume(throwing: error)
    }

    /// Settles every call still waiting.
    func succeedAll(with value: Value) {
        for continuation in takeAll() { continuation.resume(returning: value) }
    }

    /// Fails every call still waiting, so nothing outlives a test.
    func cancelAll() {
        for continuation in takeAll() { continuation.resume(throwing: CancellationError()) }
    }

    private func take(_ index: Int) -> CheckedContinuation<Value, any Error>? {
        state.withLock { state in
            guard state.continuations.indices.contains(index) else { return nil }
            defer { state.continuations[index] = nil }
            return state.continuations[index]
        }
    }

    private func takeAll() -> [CheckedContinuation<Value, any Error>] {
        state.withLock { state in
            defer { state.continuations = state.continuations.map { _ in nil } }
            return state.continuations.compactMap { $0 }
        }
    }
}

extension ControlledCalls where Argument == Void {
    func call() async throws -> Value {
        try await call(())
    }
}
