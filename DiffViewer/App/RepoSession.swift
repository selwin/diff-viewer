import Foundation

/// Identifies one window for the lifetime of the app.
struct WindowID: Hashable, Sendable {
    private let uuid = UUID()
}

/// An opened repository: its root, client, and watcher. Refreshes are bound to the
/// session they started in, so a result for a repository that has since been replaced
/// is discarded.
@MainActor
final class RepoSession {
    let root: RepositoryRoot
    let client: any RepoClient
    /// Nil while the window is hidden: a hidden window watches nothing.
    var watcher: (any RepoWatching)?
    /// Bumped on every watcher start and stop. A callback from a watcher whose
    /// generation is no longer current is dropped.
    var watcherGeneration = 0
    /// Incremented per refresh; only the latest may publish.
    var refreshSerial = 0
    /// Which line-stats read is active and which finished last. A refresh asks it what to
    /// do; the read reports back with the token it was given.
    var lineStats = LineStatsState()
    /// The active line-stats read, so a superseded one can be cancelled.
    var statsTask: Task<Void, Never>?
    /// Incremented per scope change, so a fallback or a reselection that outlived its
    /// transition cannot act on a scope the user has since moved away from.
    var scopeSerial = 0
    /// Incremented per history read, and deliberately separate from `refreshSerial`: a
    /// tick that only reloads the commit list must not invalidate an in-flight scope
    /// change and leave the sidebar empty.
    var historySerial = 0
    /// Incremented per HEAD check, so the newest check wins whatever order the checks
    /// finish in. Separate from `historySerial` on purpose: a page load must not cancel
    /// a check, nor a check a page load.
    var headCheckSerial = 0
    /// Incremented per HEAD-state read, so the newest read wins whatever order the reads
    /// finish in. Separate from `headCheckSerial` because the two run independently: a
    /// HEAD-state read must not cancel a HEAD check, nor a HEAD check a HEAD-state read.
    var headStateCheckSerial = 0
    /// The commit-list read in flight, if any.
    var historyTask: Task<Void, Never>?
    /// The tail of the chain of repository writes: sidebar file actions, commits, and branch switches. Each
    /// new write waits for this task before touching the repository, so two quick clicks
    /// cannot run two `git` writes at once and collide on `index.lock`. A fetch is not on
    /// this chain: it runs independently, updating the refs the remote's configured
    /// mappings name rather than the worktree or the index.
    var repositoryWriteTask: Task<Void, Never>?
    /// When each remote was last fetched successfully, so reopening the branch picker
    /// does not fetch again straight away.
    var lastSuccessfulFetchAtByRemote: [String: Date] = [:]
    /// The fetch running for each remote, so a second caller joins it instead of starting
    /// another.
    var remoteFetches: [String: Task<Result<Date, any Error>, Never>] = [:]
    /// Bumped each time a branch-picker opening starts, so a fetch outcome from an earlier
    /// opening stays out of a later one's footer.
    var pickerOpeningGeneration = 0
    /// Set by an opening that found an earlier one still fetching. The earlier one reads the
    /// remotes again when it ends, since they may have changed while the picker was closed.
    var remoteRediscoveryRequested = false
    /// Bumped every time a HEAD + branch read publishes, loaded or failed. A caller that
    /// needs a published read can tell one that landed meanwhile from none at all.
    var branchReadGeneration = 0
    /// Who is waiting for the next published branch read, resumed by that publication and
    /// by `close()`, so nobody waits on a window that has stopped reading.
    var branchReadWaiters: [CheckedContinuation<Void, Never>] = []
    /// The commit-defaults read in flight, if any. Superseded by generation, not by the
    /// refresh serial: a `.settings` refresh does not start one and must not cancel one.
    var commitDefaultsTask: Task<Void, Never>?
    /// Bumped when a refresh that needs a defaults read is accepted, and on close. Only
    /// the read of the current generation publishes.
    var commitDefaultsGeneration = 0
    /// The commit-message generation in flight, if any. One at a time.
    var commitGenerationTask: Task<Void, Never>?
    /// One watcher refresh at a time.
    var watcherRefreshRunning = false
    /// Ticks received during a watcher refresh, merged into one follow-up. Carries the
    /// generation of the watcher that delivered them, so a follow-up for a stopped
    /// watcher is dropped.
    var watcherRefreshPending: (generation: Int, changes: Set<RepoChange>)?
    /// Bumped on `.configuration` and `.rescan`. Part of every line-stats request, so
    /// carried-over counts are invalidated: attributes can change the binary
    /// classification of an unchanged file.
    var configurationRevision = 0
    /// What the last defaults read said about `commit.template`. Unknown until then and
    /// after a failed read, which routing treats as configured.
    var templateDependency: CommitDefaults.TemplateDependency = .unknown

    init(root: RepositoryRoot, client: any RepoClient) {
        self.root = root
        self.client = client
    }
}

/// Why a refresh ran. Reported with every published file list.
enum RefreshCause: Sendable {
    /// The first status read after `adopt`.
    case initial
    /// Cmd+R or the toolbar button.
    case manual
    /// The repository watcher fired.
    case watcher
    /// A setting that changes diff content (Hide Whitespace) changed.
    case settings
    /// The commit picker changed what the sidebar is showing.
    case scope
    /// A sidebar action changed the index or the working tree.
    case fileAction
    /// A commit attempt finished, successfully or not, and the repository was re-read.
    case commit
    /// A branch switch finished, successfully or not, and the working tree was re-read.
    case branchSwitch
    /// A pull finished, successfully or not, and the working tree was re-read.
    case pull

    /// Whether a refresh for this cause starts a commit-defaults read. A settings change
    /// has no bearing on the suggestion, and the watcher decides from its routing.
    var readsCommitDefaults: Bool { self != .settings && self != .watcher }
}

/// One page of the branch's history: the commits, the revision they were read from,
/// and whether older commits exist beyond the page. Published as one value so the
/// three can never describe different moments.
struct CommitHistory: Sendable, Equatable {
    /// The revision these commits were read from, or nil when HEAD is unborn. Set only
    /// on a successful read, so a failed one leaves the last good revision in place and
    /// the next tick sees HEAD as still unvisited and retries.
    var revision: String?
    var commits: [CommitSummary] = []
    var hasMore = false
}

/// One history read: which revision, and how many commits of it.
struct HistoryRequest: Equatable, Sendable {
    /// Nil when HEAD is unborn.
    var revision: String?
    var limit: Int
}
