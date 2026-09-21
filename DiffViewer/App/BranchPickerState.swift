import Foundation

/// How the paired HEAD + branch-list read went. The two are read on one ticket, so one
/// status covers both.
enum BranchReadStatus: Equatable, Sendable {
    case unread
    case loaded
    case failed
}

/// What the window hands the branch picker on every change.
struct BranchPickerSnapshot: Equatable, Sendable {
    var headState: HeadState?
    var branches: [LocalBranch]
    var readStatus: BranchReadStatus
    var isSwitchingBranch: Bool
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

    static func make(snapshot: BranchPickerSnapshot) -> BranchPickerHeaderText {
        guard let headState = snapshot.headState else {
            let title = snapshot.readStatus == .failed ? "Couldn't read branches" : "Loading…"
            return BranchPickerHeaderText(title: title, showsCurrentPill: false, detail: "")
        }
        switch headState {
        case let .detached(sha):
            return BranchPickerHeaderText(
                title: "Detached " + sha.prefix(7), showsCurrentPill: false, detail: "")
        case let .named(name):
            // A branch missing from the list says nothing: the counts are what the list holds.
            let detail = snapshot.branches.first { $0.name == name }.map { branch in
                guard let upstream = branch.upstream else { return "no upstream" }
                return upstream.tracking.summary ?? "up to date"
            }
            return BranchPickerHeaderText(title: name, showsCurrentPill: true, detail: detail ?? "")
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

    /// A failed read keeps the last list up; the footer says the counts may be stale.
    var footer: BranchPickerFooter {
        guard !rows.isEmpty, snapshot.readStatus == .failed else { return .none }
        return .text("Couldn't refresh branches; counts may be stale", tooltip: nil)
    }

    var headerText: BranchPickerHeaderText {
        BranchPickerHeaderText.make(snapshot: snapshot)
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
        // A read status or a switch flag moves no row. A switch flag does change whether a
        // row can activate, which its cell holds, so every row is refreshed in place.
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
