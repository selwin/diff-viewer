/// Identifies the destination and source commits a preview is for.
struct MergePreviewKey: Hashable, Sendable {
    let headSha: String
    let sourceTipSha: String
}

/// Computes merge previews on demand for the branch picker and the merge sheet, which
/// share its cache. Each consumer says which keys it wants now; only those run, at most
/// `maximumConcurrent` at a time, and a finished key is reported only to consumers still
/// asking.
@MainActor
final class MergePreviewLoader {
    struct ConsumerToken: Hashable, Sendable {
        fileprivate let id: Int
    }

    private struct Consumer {
        let onFinish: @MainActor (MergePreviewKey) -> Void
        var requested: Set<MergePreviewKey> = []
        /// Keys that failed for this consumer, not asked for again until `retry`.
        var failed: Set<MergePreviewKey> = []

        var wanted: Set<MergePreviewKey> { requested.subtracting(failed) }
    }

    /// Each preview is a `rev-list` then a `merge-tree`; two keep a scroll responsive
    /// without crowding out the window's own git reads.
    static let maximumConcurrent = 2

    private let client: any RepoClient
    private let capacity: Int
    private var consumers: [ConsumerToken: Consumer] = [:]
    private var nextTokenID = 0
    /// Successful previews only; failures are per consumer.
    private var cache: [MergePreviewKey: MergePreview] = [:]
    /// The cached keys, least recently used first.
    private var recency: [MergePreviewKey] = []
    /// Wanted keys waiting for a slot, oldest first.
    private var queue: [MergePreviewKey] = []
    /// Keys whose call is running, which a new request joins.
    private var inFlight: Set<MergePreviewKey> = []
    /// Client calls running, each holding a slot until it returns: cancelling a task
    /// doesn't stop its subprocess. Includes calls from before an `invalidate()`.
    private(set) var runningCount = 0
    /// Set when the session closes; from then on the loader does nothing.
    private var isInvalidated = false

    init(client: any RepoClient, capacity: Int = 256) {
        self.client = client
        self.capacity = capacity
    }

    // MARK: Consumers

    /// `onFinish` gets each key it asked for once its call returns; the preview, when
    /// there is one, is then in `cachedPreview(for:)`. After `invalidate()` the token is
    /// never stored, so it asks for nothing.
    func registerConsumer(onFinish: @escaping @MainActor (MergePreviewKey) -> Void) -> ConsumerToken {
        nextTokenID += 1
        let token = ConsumerToken(id: nextTokenID)
        if !isInvalidated { consumers[token] = Consumer(onFinish: onFinish) }
        return token
    }

    /// Its queued requests go unless another consumer wants them; running ones finish
    /// and are cached.
    func unregisterConsumer(_ token: ConsumerToken) {
        consumers[token] = nil
        pruneQueue()
    }

    /// Replaces what `token` wants. Cached keys are answered by `cachedPreview(for:)`,
    /// not the callback; the rest are reported as they finish.
    func setRequestedKeys(_ keys: Set<MergePreviewKey>, for token: ConsumerToken) {
        guard consumers[token] != nil else { return }
        consumers[token]?.requested = keys
        pruneQueue()
        for key in keys { enqueueIfNeeded(key, for: token) }
        startQueued()
    }

    /// Clears `key`'s failure for `token` and asks for it again.
    func retry(_ key: MergePreviewKey, for token: ConsumerToken) {
        guard consumers[token] != nil else { return }
        consumers[token]?.failed.remove(key)
        consumers[token]?.requested.insert(key)
        enqueueIfNeeded(key, for: token)
        startQueued()
    }

    /// Marks the entry as recently used.
    func cachedPreview(for key: MergePreviewKey) -> MergePreview? {
        guard let preview = cache[key] else { return nil }
        touch(key)
        return preview
    }

    /// Called when the session's window closes; for good, so nothing runs, caches or
    /// reports afterwards. Calls still running keep their slots until they return.
    func invalidate() {
        isInvalidated = true
        consumers = [:]
        queue = []
        inFlight = []
        cache = [:]
        recency = []
    }

    // MARK: Scheduling

    private func enqueueIfNeeded(_ key: MergePreviewKey, for token: ConsumerToken) {
        guard consumers[token]?.wanted.contains(key) == true, cache[key] == nil, !inFlight.contains(key),
            !queue.contains(key)
        else { return }
        queue.append(key)
    }

    private func pruneQueue() {
        let wanted = consumers.values.reduce(into: Set<MergePreviewKey>()) { $0.formUnion($1.wanted) }
        queue.removeAll { !wanted.contains($0) }
    }

    private func startQueued() {
        guard !isInvalidated else { return }
        while runningCount < Self.maximumConcurrent, !queue.isEmpty {
            start(queue.removeFirst())
        }
    }

    private func start(_ key: MergePreviewKey) {
        runningCount += 1
        inFlight.insert(key)
        let client = client
        Task { [weak self] in
            let preview = try? await client.mergePreview(headSha: key.headSha, sourceTipSha: key.sourceTipSha)
            self?.finish(key, preview: preview)
        }
    }

    /// `preview` is nil when the call failed.
    private func finish(_ key: MergePreviewKey, preview: MergePreview?) {
        runningCount -= 1
        guard !isInvalidated else { return }
        defer { startQueued() }
        inFlight.remove(key)
        if let preview { store(preview, for: key) }
        // State first, callbacks after: a callback may ask for new keys.
        var callbacks: [@MainActor (MergePreviewKey) -> Void] = []
        for (token, consumer) in consumers where consumer.requested.contains(key) {
            if preview == nil {
                consumers[token]?.failed.insert(key)
            } else {
                consumers[token]?.failed.remove(key)
            }
            callbacks.append(consumer.onFinish)
        }
        for callback in callbacks { callback(key) }
    }

    // MARK: Cache

    private func store(_ preview: MergePreview, for key: MergePreviewKey) {
        cache[key] = preview
        touch(key)
        while recency.count > capacity {
            cache[recency.removeFirst()] = nil
        }
    }

    private func touch(_ key: MergePreviewKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
