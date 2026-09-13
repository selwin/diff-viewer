import Foundation

/// What the window coordinator drives: one queue for the whole app, always
/// (re)filled for the key window and cancelled when that window loses key.
@MainActor
protocol Prefetching: AnyObject {
    func prefetch(files: [ChangedFile], client: any RepoClient)
    func cancel()
}

/// Warms the difft cache for changed files so a later click finds its hints ready.
///
/// Decides *which* files to load and in what order; `DifftCache` decides when difft
/// processes run. A small pool of long-lived workers takes files from a pending list
/// that each `prefetch` call replaces, so the number of jobs in progress (loading
/// sources or waiting on difft) is bounded globally, not per call.
///
/// Files beyond `maxPrefetchFiles` are never scheduled. Files within the cap are
/// scheduled from the top of the list on every call, so on a repository that
/// refreshes constantly the early ones are re-read each time (cheap on a cache hit)
/// and the later ones may not be reached before the next replacement.
@MainActor
final class DiffPrefetcher: Prefetching {
    typealias SourceLoader = @Sendable (ChangedFile, any RepoClient) async throws -> DiffEngine.Sources

    static let maxPrefetchFiles = 100
    static let maxConcurrentPrefetchJobs = 3

    private let cache: DifftCache
    private let loadSources: SourceLoader
    private var pending: [ChangedFile] = []
    private var client: (any RepoClient)?
    private var activeWorkers = 0 {
        didSet { peakActiveWorkers = max(peakActiveWorkers, activeWorkers) }
    }
    /// The most workers ever busy at once; at most `maxConcurrentPrefetchJobs`.
    private(set) var peakActiveWorkers = 0
    /// Files accepted by the last `prefetch` call, in order (set synchronously).
    private(set) var acceptedFileIDs: [ChangedFile.ID] = []
    /// Files dequeued since the last `prefetch` call, in dequeue order.
    private(set) var dequeuedFileIDs: [ChangedFile.ID] = []

    var isIdle: Bool { activeWorkers == 0 }

    init(cache: DifftCache, loadSources: @escaping SourceLoader = { try await DiffEngine.sources(for: $0, client: $1) }) {
        self.cache = cache
        self.loadSources = loadSources
    }

    /// Replaces the pending list with the first `maxPrefetchFiles` of `files`.
    /// Workers already busy finish their current file and then continue from the new list.
    func prefetch(files: [ChangedFile], client: any RepoClient) {
        pending = Array(files.prefix(Self.maxPrefetchFiles))
        self.client = client
        acceptedFileIDs = pending.map(\.id)
        dequeuedFileIDs = []
        while activeWorkers < Self.maxConcurrentPrefetchJobs, activeWorkers < pending.count {
            startWorker()
        }
    }

    /// Stops dequeuing. Files already being loaded or diffed run to completion and
    /// their results stay in the cache.
    func cancel() {
        pending.removeAll()
    }

    private func startWorker() {
        activeWorkers += 1
        Task { [loadSources, cache] in
            // No suspension between a nil dequeue and this decrement, so `prefetch`
            // never sees a worker that is about to exit as available.
            defer { activeWorkers -= 1 }
            while let (file, client) = dequeue() {
                guard let sources = await Self.candidate(file, client: client, loader: loadSources) else { continue }
                _ = await cache.result(old: sources.old, new: sources.new, fileName: sources.fileName, priority: .background)
            }
        }
    }

    /// Loads and classifies off the main actor: the identical-content check compares
    /// whole buffers, which must not stall the UI for a speculative read.
    nonisolated private static func candidate(_ file: ChangedFile, client: any RepoClient, loader: SourceLoader) async -> DiffEngine.Sources? {
        guard let sources = try? await loader(file, client), DiffEngine.needsDifft(sources) else { return nil }
        return sources
    }

    private func dequeue() -> (ChangedFile, any RepoClient)? {
        guard !pending.isEmpty, let client else { return nil }
        let file = pending.removeFirst()
        dequeuedFileIDs.append(file.id)
        return (file, client)
    }
}
