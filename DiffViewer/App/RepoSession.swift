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
    var watcher: (any RepoWatching)?
    /// Incremented per refresh; only the latest may publish.
    var refreshSerial = 0
    /// The line-stats work of the latest refresh; cancelled when a newer one starts.
    var statsTask: Task<Void, Never>?
    /// Incremented per scope change, so a fallback or a reselection that outlived its
    /// transition cannot act on a scope the user has since moved away from.
    var scopeSerial = 0
    /// Incremented per history read, and deliberately separate from `refreshSerial`: a
    /// tick that only reloads the commit list must not invalidate an in-flight scope
    /// change and leave the sidebar empty.
    var historySerial = 0
    /// The commit-list read in flight, if any.
    var historyTask: Task<Void, Never>?

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
