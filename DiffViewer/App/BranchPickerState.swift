import Foundation

/// How the paired HEAD + branch-list read went. The two are read on one ticket, so one
/// status covers both.
enum BranchReadStatus: Equatable, Sendable {
    case unread
    case loaded
    case failed
}

/// How the picker's automatic fetch went. The remote is unknown until it is resolved,
/// which is why `.fetching` and `.failed` both allow a nil one.
enum FetchStatus: Equatable, Sendable {
    case idle
    /// Nil while the remote is still being resolved.
    case fetching(remote: String?)
    case fetched(remote: String, at: Date)
    /// A nil remote means remote discovery itself failed.
    case failed(remote: String?, message: String)
    /// No eligible remote could be resolved.
    case noFetchTarget
}

/// What the window hands the branch picker on every change.
struct BranchPickerSnapshot: Equatable, Sendable {
    var headState: HeadState?
    var branches: [LocalBranch]
    var readStatus: BranchReadStatus
    var isSwitchingBranch: Bool
    var fetchStatus: FetchStatus = .idle
    /// The pull or push in flight, or nil when neither is running.
    var activeSyncOperation: SyncOperation?
    /// Every remote being fetched, the current branch's included.
    var fetchingRemotes: Set<String> = []
    var remotes: [String] = []
    /// Branch name to its configured upstream remote, including upstreams git can't map.
    var configuredUpstreamRemotes: [String: String] = [:]
    /// Remote to git's message, for each remote other than the current branch's whose
    /// fetch failed.
    var secondaryFetchFailures: [String: String] = [:]
}

struct BranchPickerRow: Equatable {
    let branch: LocalBranch
    /// Set on the first row of each consecutive same-day run.
    let dayLabel: CommitDayGrouping.DayLabel?
    let isCurrent: Bool
    /// What follows the name: the upstream's state, or empty when there is nothing to say.
    let trailingText: String

    static func trailingText(for branch: LocalBranch) -> String {
        guard let upstream = branch.upstream else { return "no upstream" }
        return upstream.tracking.summary ?? ""
    }
}

/// What stands in for an empty table.
enum BranchPickerEmptyState: Equatable {
    case loading
    case noBranches
    case failed
}

/// What follows the rows: a note, with an optional tooltip.
enum BranchPickerFooter: Equatable {
    case none
    case text(String, tooltip: String?)
}

/// The header's face: where HEAD is, and how far it is from its upstream.
struct BranchPickerHeaderText: Equatable {
    let title: String
    let showsCurrentPill: Bool
    let detail: String
    /// True while a fetch runs, whether or not its remote is known yet.
    var showsSpinner = false

    static func make(snapshot: BranchPickerSnapshot) -> BranchPickerHeaderText {
        let spinner = if case .fetching = snapshot.fetchStatus { true } else { false }
        guard let headState = snapshot.headState else {
            let title = snapshot.readStatus == .failed ? "Couldn't read branches" : "Loading…"
            return BranchPickerHeaderText(
                title: title, showsCurrentPill: false, detail: "", showsSpinner: spinner)
        }
        switch headState {
        case let .detached(sha):
            return BranchPickerHeaderText(
                title: "Detached " + sha.prefix(7), showsCurrentPill: false, detail: "", showsSpinner: spinner)
        case let .named(name):
            // A branch missing from the list says nothing: the counts are what the list holds.
            let detail = snapshot.branches.first { $0.name == name }.map { branch in
                guard let upstream = branch.upstream else { return "no upstream" }
                return upstream.tracking.summary ?? "up to date"
            }
            return BranchPickerHeaderText(
                title: name, showsCurrentPill: true, detail: detail ?? "", showsSpinner: spinner)
        }
    }
}

/// The branch picker's model: the rows, the highlight, and what the table must do after
/// each snapshot. Picker behavior independent of AppKit.
///
/// Positions for keyboard movement are row indexes: there is no pinned row.
struct BranchPickerState {
    private(set) var snapshot: BranchPickerSnapshot
    private(set) var rows: [BranchPickerRow]
    /// The branch the keyboard is on, or nil when there are no rows.
    private(set) var highlightedBranch: String?
    private let grouping: CommitDayGrouping

    init(snapshot: BranchPickerSnapshot, grouping: CommitDayGrouping) {
        self.snapshot = snapshot
        self.grouping = grouping
        rows = Self.makeRows(snapshot: snapshot, grouping: grouping)
        highlightedBranch = Self.initialHighlight(rows: rows)
    }

    /// Newest tip first, so the branches in play come before the ones left behind; names
    /// break a tie so the order never depends on how git listed them.
    private static func makeRows(snapshot: BranchPickerSnapshot, grouping: CommitDayGrouping) -> [BranchPickerRow] {
        let sorted = snapshot.branches.sorted {
            $0.tipCommittedAt == $1.tipCommittedAt ? $0.name < $1.name : $0.tipCommittedAt > $1.tipCommittedAt
        }
        let labels = grouping.gutterLabels(for: sorted.map(\.tipCommittedAt))
        return zip(sorted, labels).map { branch, label in
            BranchPickerRow(
                branch: branch, dayLabel: label, isCurrent: snapshot.headState == .named(branch.name),
                trailingText: BranchPickerRow.trailingText(for: branch))
        }
    }

    private static func initialHighlight(rows: [BranchPickerRow]) -> String? {
        rows.first { $0.isCurrent }?.branch.name ?? rows.first?.branch.name
    }

    // MARK: Derived

    var highlightedTableRow: Int? {
        guard let highlightedBranch else { return nil }
        return rows.firstIndex { $0.branch.name == highlightedBranch }
    }

    /// Nil when there are rows.
    var emptyState: BranchPickerEmptyState? {
        guard rows.isEmpty else { return nil }
        switch snapshot.readStatus {
        case .unread: return .loading
        case .failed: return .failed
        case .loaded: return .noBranches
        }
    }

    /// A failed read keeps the last list up, and saying the counts may be stale outranks
    /// any fetch news: the numbers on screen are what the reader is judging. Failures
    /// come before success, the header's remote before the others.
    var footer: BranchPickerFooter {
        if !rows.isEmpty, snapshot.readStatus == .failed {
            return .text("Couldn't refresh branches; counts may be stale", tooltip: nil)
        }
        if case let .failed(remote, message) = snapshot.fetchStatus {
            let text = remote.map { "Couldn't fetch \($0)" } ?? "Couldn't load remotes"
            return .text(text, tooltip: message)
        }
        let failures = snapshot.secondaryFetchFailures.sorted { $0.key < $1.key }
        if let only = failures.first, failures.count == 1 {
            return .text("Couldn't fetch \(only.key)", tooltip: only.value)
        }
        if !failures.isEmpty {
            let names = failures.map(\.key).joined(separator: ", ")
            let messages = failures.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            return .text("Couldn't fetch \(names)", tooltip: messages)
        }
        if case let .fetched(remote, at) = snapshot.fetchStatus {
            return .text("Fetched \(remote) \(Self.fetchedTime(at))", tooltip: nil)
        }
        return .none
    }

    /// Wall-clock time rather than "just now", which would go stale while the popover
    /// stays open.
    static func fetchedTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    var headerText: BranchPickerHeaderText {
        BranchPickerHeaderText.make(snapshot: snapshot)
    }

    /// Both buttons at once, so a view configures them from one reading of the snapshot.
    /// Uses the same fetch check as `WindowState.sync`, so an enabled button always runs.
    var syncButtons: (pull: PickerButtonState, push: PickerButtonState) {
        let target = SyncPolicy.target(
            readStatus: snapshot.readStatus, headState: snapshot.headState, branches: snapshot.branches)
        let isFetching = SyncPolicy.isFetching(
            target: target, fetchStatus: snapshot.fetchStatus, fetchingRemotes: snapshot.fetchingRemotes)
        return SyncPolicy.buttons(
            target: target, active: snapshot.activeSyncOperation, isSwitching: snapshot.isSwitchingBranch,
            isFetching: isFetching)
    }

    func branchName(forTableRow row: Int) -> String? {
        rows.indices.contains(row) ? rows[row].branch.name : nil
    }

    /// The current branch is already checked out; activating it would be a no-op switch.
    /// A switch in flight locks every row until it settles.
    func canActivate(tableRow row: Int) -> Bool {
        guard !snapshot.isSwitchingBranch else { return false }
        return rows.indices.contains(row) && !rows[row].isCurrent
    }

    // MARK: Snapshots

    /// Takes a new snapshot and reports what the table must do. Header, footer and the
    /// empty state are re-read after every call; only the rows are reported.
    mutating func apply(_ new: BranchPickerSnapshot) -> PickerTableChange {
        guard new != snapshot else { return .none }
        let old = snapshot
        snapshot = new
        // A read status, fetch news, the remotes or a sync in flight moves no row. A switch
        // flag does change whether a row can activate, which its cell holds, so every row
        // is refreshed in place.
        guard new.branches != old.branches || new.headState != old.headState else {
            return new.isSwitchingBranch != old.isSwitchingBranch
                ? .incremental(inserted: nil, refreshed: IndexSet(rows.indices))
                : .none
        }

        let oldRows = rows
        rows = Self.makeRows(snapshot: new, grouping: grouping)
        let change: PickerTableChange
        if oldRows.map(\.branch.name) == rows.map(\.branch.name) {
            var refreshed = IndexSet()
            for (index, pair) in zip(oldRows, rows).enumerated() where pair.0 != pair.1 {
                refreshed.insert(index)
            }
            change = .incremental(inserted: nil, refreshed: refreshed)
        } else {
            change = .reloadAll
        }

        // Keep the highlight by name across list reloads.
        if !rows.contains(where: { $0.branch.name == highlightedBranch }) {
            highlightedBranch = Self.initialHighlight(rows: rows)
        }
        return change
    }

    // MARK: Navigation

    private mutating func highlight(position: Int) {
        guard !rows.isEmpty else { return }
        highlightedBranch = rows[min(max(position, 0), rows.count - 1)].branch.name
    }

    mutating func moveUp() {
        highlight(position: (highlightedTableRow ?? 0) - 1)
    }

    mutating func moveDown() {
        highlight(position: (highlightedTableRow ?? 0) + 1)
    }

    mutating func moveToFirst() {
        highlight(position: 0)
    }

    mutating func moveToLast() {
        highlight(position: rows.count - 1)
    }

    /// Out-of-range rows are ignored.
    mutating func highlight(tableRow row: Int) {
        guard rows.indices.contains(row) else { return }
        highlightedBranch = rows[row].branch.name
    }
}
