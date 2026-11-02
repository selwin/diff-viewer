import Foundation

/// Keeps a repository's command environment fresh while its window is open.
struct RepositoryEnvironmentLifecycle {
    var refresh: @MainActor (RepositoryRoot) -> Void
    var forget: @MainActor (RepositoryRoot) -> Void
    /// Like `refresh`, but returns once the cache has started re-resolving, so a read that
    /// follows waits on the new resolution under the cache's usual limits.
    var beginRefresh: @MainActor (RepositoryRoot) async -> Void

    /// For tests and previews that run no hooks.
    static let none = RepositoryEnvironmentLifecycle(refresh: { _ in }, forget: { _ in }, beginRefresh: { _ in })
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

    /// An event and, for `beginRefresh`, who to resume once it has been applied.
    private struct Item: Sendable {
        let event: Event
        let acknowledgement: CheckedContinuation<Void, Never>?
    }

    /// `nonisolated` so `deinit` can finish the stream.
    nonisolated private let continuation: AsyncStream<Item>.Continuation
    /// Exposed only so tests can await the drain.
    let consumer: Task<Void, Never>

    /// `apply` must not wait for a shell: the acknowledgement is resumed when it returns, and
    /// every other root's events queue behind it.
    init(apply: @escaping @Sendable (Event) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Item.self)
        self.continuation = continuation
        consumer = Task {
            for await item in stream {
                await apply(item.event)
                item.acknowledgement?.resume()
            }
        }
    }

    deinit {
        continuation.finish()
    }

    var lifecycle: RepositoryEnvironmentLifecycle {
        let continuation = continuation
        return RepositoryEnvironmentLifecycle(
            refresh: { continuation.yield(Item(event: .refresh($0.url), acknowledgement: nil)) },
            forget: { continuation.yield(Item(event: .forget($0.url), acknowledgement: nil)) },
            beginRefresh: { root in
                await withCheckedContinuation { acknowledgement in
                    let result = continuation.yield(Item(event: .refresh(root.url), acknowledgement: acknowledgement))
                    // A finished stream will never apply it.
                    if case .terminated = result { acknowledgement.resume() }
                }
            })
    }

    /// Ends the stream; the consumer applies what is already queued, then stops.
    func finish() {
        continuation.finish()
    }
}
