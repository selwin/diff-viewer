import Foundation

/// How the paired HEAD + branch-list read went. The two are read on one ticket, so one
/// status covers both.
enum BranchReadStatus: Equatable, Sendable {
    case unread
    case loaded
    case failed
}

/// Where the running fetch round is.
enum FetchStatus: Equatable, Sendable {
    case idle
    /// Listing the remotes: any of them may yet be fetched.
    case discovering
    /// Fetching the remotes in `fetchingRemotes`, then re-reading the branches.
    case fetching
}

/// What the window hands the branch picker on every change.
struct BranchPickerSnapshot: Equatable, Sendable {
    var headState: HeadState?
    var branches: [LocalBranch]
    var readStatus: BranchReadStatus
    var isSwitchingBranch: Bool
    var fetchStatus: FetchStatus = .idle
    /// The pull, push, publish or delete in flight and its branch, or nil when none is running.
    var activeSync: ActiveSync?
    /// The remotes the running round fetches, held until its branch read publishes.
    var fetchingRemotes: Set<String> = []
    var remotes: [String] = []
    /// Branch name to its configured upstream remote, including upstreams git can't map.
    var configuredUpstreamRemotes: [String: String] = [:]
    /// How each remote fared in the last finished round, or nil before the first.
    var lastFetchRound: FetchRound?
    /// Every remote-tracking branch, read with `branches`.
    var remoteBranches: [RemoteBranch] = []
    /// The remote-tracking refs fetch rounds brought in, by full ref.
    var newRemoteBranches: Set<String> = []
}

/// Which branch a row stands for. The highlight, reloads and actions all go by it, never
/// by position, so a row keeps its identity as the list moves.
enum BranchRowID: Hashable, Sendable {
    case local(name: String)
    /// A remote-tracking branch no local branch tracks, by full ref: two remotes can carry
    /// the same name.
    case remote(ref: String)
}

/// The popover's two modes. Rows, highlight and query are shared; what a row offers
/// and says differs.
enum BranchPickerTab: Sendable {
    case switchBranch
    case merge
}

/// The sentence above the search field: the verb, the highlighted branch (nil when none
/// is) and, for a merge, the branch it merges into.
struct BranchPickerInstruction: Equatable {
    let verb: String
    let token: String?
    let target: String?
}

/// What a row shows on its right edge in the current tab, and in which colour.
struct BranchRowLabel: Equatable {
    enum Style: Equatable {
        case secondary
        case accent
        /// A predicted merge conflict.
        case warning
    }

    let text: String
    let style: Style
}

/// What activating a row asks the window to do.
enum BranchActivation: Equatable {
    case switchTo(name: String)
    /// Create a local branch tracking this remote one, then switch to it.
    case checkoutTracking(RemoteBranch)
}

/// The words on a row's right edge, and whether they are drawn in the accent colour.
enum BranchRowStatus: Equatable {
    /// In sync, or a remote-only branch that isn't new.
    case none
    case counts(ahead: Int, behind: Int)
    case notPublished
    /// Tracks a remote whose fetch settings don't cover the upstream.
    case upstreamNotFetched
    case upstreamGone
    /// A remote-only branch a fetch round brought in. Local rows never show it.
    case new

    var text: String {
        switch self {
        case .none: ""
        case let .counts(ahead, behind): UpstreamTracking.counts(ahead: ahead, behind: behind).summary ?? ""
        case .notPublished: "Not published"
        case .upstreamNotFetched: "upstream not fetched"
        case .upstreamGone: UpstreamTracking.gone.summary ?? ""
        case .new: "New"
        }
    }

    var isAccent: Bool { self == .new }

    /// `configuredRemote` tells a branch that tracks nothing from one whose upstream the
    /// fetch settings hide.
    static func local(_ branch: LocalBranch, configuredRemote: String?) -> BranchRowStatus {
        guard let upstream = branch.upstream else {
            return SyncPolicy.hiddenUpstreamRemote(of: branch, configuredRemote: configuredRemote) == nil
                ? .notPublished : .upstreamNotFetched
        }
        switch upstream.tracking {
        case .gone: return .upstreamGone
        case let .counts(ahead, behind):
            return ahead == 0 && behind == 0 ? .none : .counts(ahead: ahead, behind: behind)
        }
    }
}

struct BranchPickerRow: Equatable {
    enum Kind: Equatable {
        case current
        case local
        case remoteOnly
    }

    /// The branch as it was read, which the row's actions carry.
    enum Source: Equatable {
        case local(LocalBranch)
        case remote(RemoteBranch)
    }

    let id: BranchRowID
    let kind: Kind
    let source: Source
    /// What the row shows: a remote-only branch keeps its remote's prefix unless it is the
    /// publish remote's and no local branch shares the name.
    let name: String
    /// `author · time`.
    let subtitle: String
    let status: BranchRowStatus
    /// A remote-only branch whose name a local branch already has: checking it out would
    /// collide with that branch.
    let collidesWithLocalName: Bool
    /// The name's characters the query matched; empty when no query is active.
    var matchedRanges: [Range<String.Index>] = []

    var tipCommittedAt: Date {
        switch source {
        case let .local(branch): branch.tipCommittedAt
        case let .remote(branch): branch.tipCommittedAt
        }
    }
}

/// One table row: a recency section's title, or a branch.
enum BranchPickerItem: Equatable {
    case header(RecencyGroup)
    case branch(BranchPickerRow)

    /// What a reload matches rows by.
    enum Key: Hashable {
        case header(RecencyGroup)
        case branch(BranchRowID)
    }

    var key: Key {
        switch self {
        case let .header(group): .header(group)
        case let .branch(row): .branch(row.id)
        }
    }

    var row: BranchPickerRow? {
        if case let .branch(row) = self { row } else { nil }
    }
}

/// What stands in for an empty table.
enum BranchPickerEmptyState: Equatable {
    case loading
    case noBranches
    case failed
    /// Branches exist, but the query matches none of them.
    case noMatches
}

/// What the branch table must do after a snapshot or a query.
enum BranchTableChange: Equatable {
    case none
    /// `removed` indexes the old items; `inserted` and `refreshed` the new ones. Rows that
    /// stay keep their cells, so the table can slide them into place.
    case update(removed: IndexSet, inserted: IndexSet, refreshed: IndexSet)
    case reloadAll

    /// Rows whose content changed, with none coming or going.
    static func refresh(_ rows: IndexSet) -> BranchTableChange {
        .update(removed: [], inserted: [], refreshed: rows)
    }
}

/// What the table must do after a snapshot. Row buttons change apart from the rows, so a
/// busy state coming and going restyles buttons without reloading any row.
struct BranchPickerChange: Equatable {
    var rows: BranchTableChange
    var buttonsChanged: Bool
}
