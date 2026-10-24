import Foundation

/// The environment an interactive login shell exports in each repository root: the command
/// environment for the commands that run hooks or talk to a remote. Shares one resolution
/// per live cache entry. Results from forgotten entries are ignored. A failed refresh keeps
/// the last snapshot; with none, callers fall back to login-shell PATH resolution.
///
/// Keyed by the root's file URL; callers pass the canonical `RepositoryRoot.url`.
///
/// Cancelling a caller ends its wait at once. During a fallback, cancellation is delayed,
/// not ignored: the caller throws once the fallback returns. The worst case is a 5 s
/// interactive timeout plus a 5 s login fallback, and a shell that never succeeds pays the
/// interactive timeout on each command.
actor RepositoryShellEnvironmentCache {
    /// What a test waits on instead of reading the cache's state.
    enum Event: Sendable, Equatable {
        case waiterRegistered(URL)
        case resolutionFinished(URL, accepted: Bool)
    }

    /// A caller waiting on a resolution. Resumed with nil when it should use the fallback.
    private struct Waiter {
        let continuation: CheckedContinuation<[String: String]?, any Error>
        /// Set only when a snapshot exists to return if the refresh is slow.
        let timer: Task<Void, Never>?
    }

    private struct Entry {
        var lastSuccessfulEnvironment: [String: String]?
        /// The running resolution, nil when idle. A stale run outlives a `forget` and is
        /// dropped by this id; cancelling its task would not stop the shell anyway.
        var resolutionID: UUID?
        var waiters: [UUID: Waiter] = [:]
    }

    private let resolve: @Sendable (URL) async -> [String: String]?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let fallback: @Sendable () async -> ProcessEnvironment
    /// How long a caller with a snapshot in hand waits for a refresh before using it.
    private let refreshWait: Duration
    /// Called synchronously on the cache actor after registration or completion processing.
    /// Must not block.
    private let onEvent: @Sendable (Event) -> Void
    private var entries: [URL: Entry] = [:]

    init(
        resolve: @escaping @Sendable (URL) async -> [String: String]? = {
            await ShellEnvironment.resolve(
                shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", directory: $0,
                timeout: .seconds(5))
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        fallback: @escaping @Sendable () async -> ProcessEnvironment = {
            ProcessEnvironment(variables: await LoginShellPath.environment(), inheritance: .inherit)
        },
        refreshWait: Duration = .seconds(2),
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.resolve = resolve
        self.sleep = sleep
        self.fallback = fallback
        self.refreshWait = refreshWait
        self.onEvent = onEvent
    }

    /// The shell's environment for `root`, or the fallback when no shell has succeeded there.
    /// Throws only `CancellationError`.
    nonisolated func environment(for root: URL) async throws -> ProcessEnvironment {
        // A cancelled caller must not take a cached snapshot or start a fallback.
        try Task.checkCancellation()
        if let snapshot = try await snapshot(for: root) {
            try Task.checkCancellation()
            return ProcessEnvironment(variables: snapshot, inheritance: .replace)
        }
        // Off the actor, so a slow login shell never holds up other roots or completions.
        let environment = await fallback()
        try Task.checkCancellation()
        return environment
    }

    /// Starts a resolution for `root` unless one is already running.
    func refresh(_ root: URL) {
        startResolutionIfIdle(root)
    }

    /// Drops `root`'s entry. Its waiters get the last snapshot, or nil and fall back in their
    /// own tasks; a run still in flight finds the entry gone and is ignored.
    func forget(_ root: URL) {
        guard let entry = entries.removeValue(forKey: root) else { return }
        for waiter in entry.waiters.values {
            waiter.timer?.cancel()
            waiter.continuation.resume(returning: entry.lastSuccessfulEnvironment)
        }
    }

    // MARK: Waiting

    /// The snapshot to use, or nil for the fallback. Returns a settled snapshot at once;
    /// otherwise waits on the running resolution, at most `refreshWait` when a snapshot exists.
    private func snapshot(for root: URL) async throws -> [String: String]? {
        if let entry = entries[root], entry.resolutionID == nil, let snapshot = entry.lastSuccessfulEnvironment {
            return snapshot
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(root, id, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(root, id) }
        }
    }

    /// Suspension-free, so a cancellation handler that ran first is caught by the
    /// `isCancelled` check and one that runs later finds the waiter stored.
    private func register(
        _ root: URL, _ id: UUID, _ continuation: CheckedContinuation<[String: String]?, any Error>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        startResolutionIfIdle(root)
        let timer: Task<Void, Never>? =
            entries[root]?.lastSuccessfulEnvironment == nil
            ? nil
            : Task { [sleep, refreshWait] in
                do { try await sleep(refreshWait) } catch { return }
                self.timeOut(root, id)
            }
        entries[root, default: Entry()].waiters[id] = Waiter(continuation: continuation, timer: timer)
        onEvent(.waiterRegistered(root))
    }

    private func timeOut(_ root: URL, _ id: UUID) {
        takeWaiter(root, id)?.continuation.resume(returning: entries[root]?.lastSuccessfulEnvironment)
    }

    private func cancelWaiter(_ root: URL, _ id: UUID) {
        takeWaiter(root, id)?.continuation.resume(throwing: CancellationError())
    }

    /// Removes a waiter so only the path that takes it resumes it.
    private func takeWaiter(_ root: URL, _ id: UUID) -> Waiter? {
        guard let waiter = entries[root]?.waiters.removeValue(forKey: id) else { return nil }
        waiter.timer?.cancel()
        return waiter
    }

    // MARK: Resolution

    /// Records the resolution in the same step that starts it, so no caller can start a second.
    private func startResolutionIfIdle(_ root: URL) {
        guard entries[root]?.resolutionID == nil else { return }
        let id = UUID()
        entries[root, default: Entry()].resolutionID = id
        Task { [resolve] in
            let result = await resolve(root)
            self.complete(root, id, result)
        }
    }

    /// Ignores a run that is no longer the entry's, so one from before a `forget` and reopen
    /// can't overwrite or clear its successor. A failure keeps the previous snapshot.
    private func complete(_ root: URL, _ id: UUID, _ result: [String: String]?) {
        guard var entry = entries[root], entry.resolutionID == id else {
            onEvent(.resolutionFinished(root, accepted: false))
            return
        }
        if let result { entry.lastSuccessfulEnvironment = result }
        entry.resolutionID = nil
        let waiters = entry.waiters.values
        entry.waiters = [:]
        entries[root] = entry
        for waiter in waiters {
            waiter.timer?.cancel()
            waiter.continuation.resume(returning: entry.lastSuccessfulEnvironment)
        }
        onEvent(.resolutionFinished(root, accepted: true))
    }
}
