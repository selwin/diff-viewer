import Foundation

/// What the window coordinator drives: one queue for the whole app, always
/// (re)filled for the key window and cancelled when that window loses key.
@MainActor
protocol Prefetching: AnyObject {
    func prefetch(files: [ChangedFile], repository: RepositoryRoot, client: any RepoClient)
    func cancel()
}

/// Warms the difft cache for changed files so a later click finds its hints ready.
///
/// Decides *which* files to load and in what order; `DifftCache` decides when difft
/// processes run. A small pool of long-lived workers takes files from a pending list
/// that each `prefetch` call replaces, so the number of jobs in progress (loading
/// sources or waiting on difft) is bounded globally, not per call.
///
/// Files beyond `maxPrefetchFiles` are never scheduled. A file already warmed for the
/// same inputs is skipped, so a repository that refreshes constantly re-reads only what
/// changed instead of the whole list on every call.
@MainActor
final class DiffPrefetcher: Prefetching {
    typealias SourceLoader = @Sendable (ChangedFile, any RepoClient) async throws -> DiffEngine.Sources

    static let maxPrefetchFiles = 100
    static let maxConcurrentPrefetchJobs = 3

    /// A file's identity for warming: the repository, since ids like `unstaged:path`
    /// repeat across repositories, and the inputs the diff reads.
    private struct WarmKey: Hashable {
        let repository: RepositoryRoot
        let fileID: ChangedFile.ID
        let fingerprint: DiffInputFingerprint?

        /// Same rule as `DiffEngine.inputKey`: a commit's content never changes, any other
        /// file needs a known fingerprint. Nil means status cannot vouch for it, so read it.
        static func key(for file: ChangedFile, repository: RepositoryRoot) -> WarmKey? {
            if !file.area.isCommit {
                guard let fingerprint = file.fingerprint, fingerprint.isKnown else { return nil }
            }
            return WarmKey(repository: repository, fileID: file.id, fingerprint: file.fingerprint)
        }
    }

    /// The key is computed at call time: a later call may name another repository.
    private struct PendingFile {
        let file: ChangedFile
        let key: WarmKey?
    }

    /// What reading a file's sources led to.
    private enum Load {
        case failed
        /// Binary or identical: readable, but difft has nothing to do.
        case needsNoDifft
        case needsDifft(DiffEngine.Sources)
    }

    private let cache: DifftCache
    private let loadSources: SourceLoader
    private var pending: [PendingFile] = []
    /// Keys whose difft result reached the cache, pruned to the latest list on each call.
    /// Known limit: if `DifftCache` later evicts an entry, the file is not re-warmed until
    /// its inputs change.
    private var warmed: Set<WarmKey> = []
    private var client: (any RepoClient)?
    private var activeWorkers = 0 {
        didSet { peakActiveWorkers = max(peakActiveWorkers, activeWorkers) }
    }
    /// The most workers ever busy at once; at most `maxConcurrentPrefetchJobs`.
    private(set) var peakActiveWorkers = 0
    /// Files scheduled by the last `prefetch` call, in order (set synchronously): the
    /// first `maxPrefetchFiles`, minus those already warmed for the same inputs.
    private(set) var acceptedFileIDs: [ChangedFile.ID] = []
    /// Files dequeued since the last `prefetch` call, in dequeue order.
    private(set) var dequeuedFileIDs: [ChangedFile.ID] = []

    var isIdle: Bool { activeWorkers == 0 }

    init(cache: DifftCache, loadSources: @escaping SourceLoader = { try await DiffEngine.sources(for: $0, client: $1) })
    {
        self.cache = cache
        self.loadSources = loadSources
    }

    /// Replaces the pending list with the first `maxPrefetchFiles` of `files` that are not
    /// already warmed. Workers already busy finish their current file and then continue
    /// from the new list.
    func prefetch(files: [ChangedFile], repository: RepositoryRoot, client: any RepoClient) {
        let candidates = files.prefix(Self.maxPrefetchFiles).map {
            PendingFile(file: $0, key: WarmKey.key(for: $0, repository: repository))
        }
        warmed.formIntersection(candidates.compactMap(\.key))
        pending = []
        for candidate in candidates {
            if let key = candidate.key, warmed.contains(key) {
                PipelineMetrics.countPrefetchSkip()
            } else {
                pending.append(candidate)
            }
        }
        self.client = client
        acceptedFileIDs = pending.map(\.file.id)
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
            while let (job, client) = dequeue() {
                PipelineMetrics.countPrefetchRead()
                switch await Self.load(job.file, client: client, loader: loadSources) {
                case .failed:
                    continue
                case .needsNoDifft:
                    markWarmed(job.key)
                case let .needsDifft(sources):
                    // A difft failure returns nil: leave the file unwarmed so the next call retries.
                    let result = await cache.result(
                        old: sources.old, new: sources.new, fileName: sources.fileName, priority: .background)
                    if result != nil { markWarmed(job.key) }
                }
            }
        }
    }

    private func markWarmed(_ key: WarmKey?) {
        if let key { warmed.insert(key) }
    }

    /// Loads and classifies off the main actor: the identical-content check compares
    /// whole buffers, which must not stall the UI for a speculative read.
    nonisolated private static func load(_ file: ChangedFile, client: any RepoClient, loader: SourceLoader) async
        -> Load
    {
        guard let sources = try? await loader(file, client) else { return .failed }
        return DiffEngine.needsDifft(sources) ? .needsDifft(sources) : .needsNoDifft
    }

    private func dequeue() -> (PendingFile, any RepoClient)? {
        guard !pending.isEmpty, let client else { return nil }
        let job = pending.removeFirst()
        dequeuedFileIDs.append(job.file.id)
        return (job, client)
    }
}
