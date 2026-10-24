import Foundation

/// Keeps a repository's command environment fresh while its window is open.
struct RepositoryEnvironmentLifecycle {
    var refresh: @MainActor (RepositoryRoot) -> Void
    var forget: @MainActor (RepositoryRoot) -> Void

    /// For tests and previews that run no hooks.
    static let none = RepositoryEnvironmentLifecycle(refresh: { _ in }, forget: { _ in })
}

/// Applies refresh and forget events one at a time, in the order the UI sent them.
///
/// The cache must see them in UI-event order: a forget from a closed window that lands
/// after the refresh of a reopen would drop the new entry, and independent `Task`s
/// give no such ordering.
@MainActor
final class OrderedEnvironmentLifecycle {
    enum Event: Sendable, Equatable {
        case refresh(URL)
        case forget(URL)
    }

    /// `nonisolated` so `deinit` can finish the stream.
    nonisolated private let continuation: AsyncStream<Event>.Continuation
    /// Exposed only so tests can await the drain.
    let consumer: Task<Void, Never>

    init(apply: @escaping @Sendable (Event) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        self.continuation = continuation
        consumer = Task {
            for await event in stream { await apply(event) }
        }
    }

    deinit {
        continuation.finish()
    }

    var lifecycle: RepositoryEnvironmentLifecycle {
        let continuation = continuation
        return RepositoryEnvironmentLifecycle(
            refresh: { continuation.yield(.refresh($0.url)) },
            forget: { continuation.yield(.forget($0.url)) })
    }

    /// Ends the stream; the consumer applies what is already queued, then stops.
    func finish() {
        continuation.finish()
    }
}
