import Foundation
import Observation

/// Every repository's GitHub connection, for the repository picker: open repositories read
/// their window's live model, closed ones the last stored result. Also the only source of
/// check revisions, so a result from an older check can never replace a newer one, whichever
/// window or background check produced it.
@MainActor
@Observable
final class GitHubConnectionDirectory {
    /// Checks a closed repository from scratch. Throws when the repository or its remotes
    /// can't be read, which keeps the stored result.
    typealias ClosedLoader = @MainActor (RepositoryRoot, _ previous: GitHubConnection?) async throws -> GitHubConnection

    static let maxConcurrentChecks = 2

    /// The last result stored for each repository.
    private var snapshots: [RepositoryRoot: GitHubConnection] = [:]
    @ObservationIgnored private var latestRevisions: [RepositoryRoot: Int] = [:]
    /// Closed repositories waiting for a background check, oldest first.
    @ObservationIgnored private var queued: [RepositoryRoot] = []
    @ObservationIgnored private var running: Set<RepositoryRoot> = []
    /// Incremented when a background check has been handled, whether it stored a result or
    /// not. Lets tests wait for the handling rather than for the loader's answer.
    @ObservationIgnored private(set) var checksFinished = 0

    /// The open window's model for a repository, or nil when no window has it open. Set by
    /// the owner, which knows the windows.
    @ObservationIgnored var openModel: @MainActor (RepositoryRoot) -> GitHubConnectionModel? = { _ in nil }

    @ObservationIgnored private let lifecycle: RepositoryEnvironmentLifecycle
    @ObservationIgnored private let loadClosed: ClosedLoader

    init(lifecycle: RepositoryEnvironmentLifecycle, loadClosed: @escaping ClosedLoader) {
        self.lifecycle = lifecycle
        self.loadClosed = loadClosed
    }

    /// What the picker shows for `root`. Nil when it hasn't been checked.
    func connection(for root: RepositoryRoot) -> GitHubConnection? {
        if let model = openModel(root) { return model.connection }
        return snapshots[root]
    }

    /// A new revision for a check of `root` that is about to start, higher than any before it.
    func issueRevision(for root: RepositoryRoot) -> Int {
        let revision = (latestRevisions[root] ?? 0) + 1
        latestRevisions[root] = revision
        return revision
    }

    /// Stores `connection` only when no check of `root` started after the one that produced it.
    func publish(root: RepositoryRoot, revision: Int, connection: GitHubConnection) {
        guard revision == latestRevisions[root] else { return }
        snapshots[root] = connection
    }

    // MARK: Background checks

    /// Queues a check of every closed repository in `roots`, cached or not, so account switches
    /// and origin changes show up. One already queued or running isn't queued again.
    func revalidate(_ roots: [RepositoryRoot]) {
        for root in roots where openModel(root) == nil && !queued.contains(root) && !running.contains(root) {
            queued.append(root)
        }
        startQueuedChecks()
    }

    /// Drops the checks that haven't started; running ones finish and publish.
    func cancelQueuedRevalidation() {
        queued.removeAll()
    }

    private func startQueuedChecks() {
        while running.count < Self.maxConcurrentChecks, !queued.isEmpty {
            let root = queued.removeFirst()
            // Opened since it was queued: its window checks it.
            guard openModel(root) == nil else { continue }
            running.insert(root)
            let revision = issueRevision(for: root)
            let previous = snapshots[root]
            Task { [weak self, loadClosed] in
                let connection = try? await loadClosed(root, previous)
                self?.finishCheck(root, revision: revision, connection: connection)
            }
        }
    }

    /// The lifecycle's entry is dropped only while nothing has the repository open, so a
    /// window that opened meanwhile keeps its environment.
    private func finishCheck(_ root: RepositoryRoot, revision: Int, connection: GitHubConnection?) {
        defer { checksFinished += 1 }
        running.remove(root)
        if let connection { publish(root: root, revision: revision, connection: connection) }
        if openModel(root) == nil { lifecycle.forget(root) }
        startQueuedChecks()
    }
}

extension GitHubConnectionDirectory {
    /// The path no longer discovers the repository it was saved for, as when its `.git` is gone
    /// and discovery finds a parent repository instead.
    struct MovedRepositoryError: Error {}

    /// The real background check: starts an environment refresh, discovers the repository,
    /// reads origin, and checks it when it is on GitHub. Only a successful remote read can
    /// report `.notOnGitHub`.
    static func closedLoader(
        discover: @escaping WindowCoordinator.Discoverer, lifecycle: RepositoryEnvironmentLifecycle
    ) -> ClosedLoader {
        { root, previous in
            await lifecycle.beginRefresh(root)
            let discovered = try await discover(root.url)
            // Another repository's connection must not show under this one's name.
            guard discovered.root == root else { throw MovedRepositoryError() }
            let client = discovered.client
            let remotes = try await client.remoteURLs()
            guard let fetchURL = remotes["origin"]?.fetchURL, let origin = GitHubRepository.parse(remoteURL: fetchURL)
            else { return .notOnGitHub }
            let check = try await client.gitHubRepositoryCheck(origin)
            return GitHubCheckOutcome.make(origin: origin, check: check, previous: previous).connection
        }
    }
}
