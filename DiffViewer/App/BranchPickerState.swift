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
    /// The pull, push, publish or delete in flight and its branch, or nil when none is running.
    var activeSync: ActiveSync?
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

    /// `configuredRemote` tells a branch that tracks nothing from one whose upstream the
    /// fetch settings hide.
    static func trailingText(for branch: LocalBranch, configuredRemote: String?) -> String {
        guard let upstream = branch.upstream else {
            return SyncPolicy.hiddenUpstreamRemote(of: branch, configuredRemote: configuredRemote) == nil
                ? "no upstream" : "upstream not fetched"
        }
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
                // Worded as the row is, so a hidden upstream reads the same in both places.
                guard let upstream = branch.upstream else {
                    return BranchPickerRow.trailingText(
                        for: branch, configuredRemote: snapshot.configuredUpstreamRemotes[name])
                }
                return upstream.tracking.summary ?? "up to date"
            }
            return BranchPickerHeaderText(
                title: name, showsCurrentPill: true, detail: detail ?? "", showsSpinner: spinner)
        }
    }
}

/// What the table must do after a snapshot. Row buttons change apart from the rows, so a
/// busy state coming and going restyles buttons without reloading any row.
struct BranchPickerChange: Equatable {
    var rows: PickerTableChange
    var buttonsChanged: Bool
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
                trailingText: BranchPickerRow.trailingText(
                    for: branch, configuredRemote: snapshot.configuredUpstreamRemotes[branch.name]))
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

    /// A row's Pull and Push, Publish, or Delete, or nil past the end. Uses the same
    /// immediate fetch checks as `WindowState`'s admission: Pull and Delete are admitted
    /// exactly as shown, while Push may still wait for its remote's fetch and be re-checked
    /// afterwards.
    func syncButtons(forTableRow row: Int) -> RowSyncButtons? {
        guard rows.indices.contains(row) else { return nil }
        return Self.syncButtons(for: rows[row], snapshot: snapshot)
    }

    private static func syncButtons(for row: BranchPickerRow, snapshot: BranchPickerSnapshot) -> RowSyncButtons {
        SyncPolicy.rowButtons(
            branch: row.branch, isCurrent: row.isCurrent, readStatus: snapshot.readStatus,
            active: snapshot.activeSync, isSwitching: snapshot.isSwitchingBranch,
            isDiscovering: snapshot.fetchStatus == .fetching(remote: nil), fetchingRemotes: snapshot.fetchingRemotes,
            remotes: snapshot.remotes, configuredRemote: snapshot.configuredUpstreamRemotes[row.branch.name])
    }

    func branchName(forTableRow row: Int) -> String? {
        branch(forTableRow: row)?.name
    }

    /// The branch as the row shows it, which a delete checks against before it runs.
    func branch(forTableRow row: Int) -> LocalBranch? {
        rows.indices.contains(row) ? rows[row].branch : nil
    }

    /// The current branch is already checked out; activating it would be a no-op switch.
    /// A switch in flight locks every row until it settles, and a branch being deleted
    /// can't be checked out.
    func canActivate(tableRow row: Int) -> Bool {
        guard !snapshot.isSwitchingBranch, rows.indices.contains(row) else { return false }
        return !rows[row].isCurrent && rows[row].branch.name != Self.deleting(snapshot)
    }

    // MARK: Snapshots

    /// Takes a new snapshot and reports what the table must do. Header, footer and the
    /// empty state are re-read after every call; only the rows and buttons are reported.
    mutating func apply(_ new: BranchPickerSnapshot) -> BranchPickerChange {
        guard new != snapshot else { return BranchPickerChange(rows: .none, buttonsChanged: false) }
        let old = snapshot
        let oldButtons = rows.map { Self.syncButtons(for: $0, snapshot: old) }
        snapshot = new
        let rowChange = applyRows(new, old: old)
        let buttonsChanged = rows.map { Self.syncButtons(for: $0, snapshot: new) } != oldButtons
        return BranchPickerChange(rows: rowChange, buttonsChanged: buttonsChanged)
    }

    private mutating func applyRows(_ new: BranchPickerSnapshot, old: BranchPickerSnapshot) -> PickerTableChange {
        // A read status, fetch news, the remotes or a sync in flight moves no row. A switch
        // flag changes whether any row can activate, which its cell holds, so every row is
        // refreshed in place; a delete starting or ending changes only its own row.
        // Configured upstreams change a row's trailing text.
        guard
            new.branches != old.branches || new.headState != old.headState
                || new.configuredUpstreamRemotes != old.configuredUpstreamRemotes
        else {
            if new.isSwitchingBranch != old.isSwitchingBranch {
                return .incremental(inserted: nil, refreshed: IndexSet(rows.indices))
            }
            let refreshed = deleteChangedRows(new, old: old)
            return refreshed.isEmpty ? .none : .incremental(inserted: nil, refreshed: refreshed)
        }

        let oldRows = rows
        rows = Self.makeRows(snapshot: new, grouping: grouping)
        let change: PickerTableChange
        if oldRows.map(\.branch.name) == rows.map(\.branch.name) {
            var refreshed = IndexSet()
            for (index, pair) in zip(oldRows, rows).enumerated() where pair.0 != pair.1 {
                refreshed.insert(index)
            }
            change = .incremental(inserted: nil, refreshed: refreshed.union(deleteChangedRows(new, old: old)))
        } else {
            change = .reloadAll
        }

        // Keep the highlight by name across list reloads.
        if !rows.contains(where: { $0.branch.name == highlightedBranch }) {
            highlightedBranch = Self.initialHighlight(rows: rows)
        }
        return change
    }

    /// The rows of the branches whose delete started or ended between `old` and `new`.
    private func deleteChangedRows(_ new: BranchPickerSnapshot, old: BranchPickerSnapshot) -> IndexSet {
        guard Self.deleting(new) != Self.deleting(old) else { return [] }
        let names = [Self.deleting(new), Self.deleting(old)].compactMap { $0 }
        return IndexSet(names.compactMap { name in rows.firstIndex { $0.branch.name == name } })
    }

    /// The branch being deleted, which no row may activate.
    private static func deleting(_ snapshot: BranchPickerSnapshot) -> String? {
        snapshot.activeSync.flatMap { $0.operation == .delete ? $0.branch : nil }
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
