import Foundation

/// What the window hands the commit picker on every change. Two scopes appear: the
/// *displayed* one, which the diff shows, and the picker's own highlight, which lives
/// in `CommitPickerState` and moves independently.
struct CommitPickerSnapshot: Equatable, Sendable {
    var displayedScope: DiffScope
    /// The displayed commit's summary, when the scope is a commit and one is held.
    var displayedCommit: CommitSummary?
    /// The rows to list: the loaded page, with the displayed commit prepended when the
    /// page does not carry it.
    var commits: [CommitSummary]
    var hasMore: Bool
    var isLoadingHistory: Bool
    var historyLoadFailed: Bool
    /// Distinct paths in the displayed scope, or nil while the list is unread.
    var displayedScopeFileCount: Int?
}

struct CommitPickerRow: Equatable {
    let scope: DiffScope
    let commit: CommitSummary
    /// Set on the first row of each consecutive same-day run.
    let dayLabel: CommitDayGrouping.DayLabel?
    let isDisplayedScope: Bool
}

/// How the table must update after `CommitPickerState.apply`.
enum CommitPickerTableChange: Equatable {
    case none
    /// Appended rows and existing rows that need refreshing.
    case incremental(inserted: Range<Int>?, refreshed: IndexSet)
    case reloadAll
}

/// What stands in for an empty table.
enum CommitPickerEmptyState: Equatable {
    case loading
    case noCommits
    case failed
}

/// What follows the rows.
enum CommitPickerFooter: Equatable {
    case none
    case loading
    /// A refresh or a Load More failed; the rows that loaded stay up.
    case failed
}

/// The header's face: a title and a detail line whose segments the view sets in text
/// or monospace.
struct CommitPickerHeaderText: Equatable {
    enum Segment: Equatable {
        case text(String)
        case mono(String)
    }

    let title: String
    let detail: [Segment]

    static func make(snapshot: CommitPickerSnapshot, grouping: CommitDayGrouping) -> CommitPickerHeaderText {
        let count = snapshot.displayedScopeFileCount.map { Segment.text(CommitPickerState.fileCountText($0)) }
        switch snapshot.displayedScope {
        case .workingTree:
            return CommitPickerHeaderText(title: "Working Tree", detail: count.map { [$0] } ?? [])
        case let .commit(ref):
            let date = snapshot.displayedCommit.map { Segment.text(grouping.dateTimeText(for: $0.committedAt)) }
            let shortSha = snapshot.displayedCommit?.ref.shortSha ?? ref.shortSha
            let segments = [date, count, .mono(shortSha)].compactMap { $0 }
            return CommitPickerHeaderText(
                title: snapshot.displayedCommit?.subject ?? shortSha,
                detail: Array(segments.map { [$0] }.joined(separator: [.text(" · ")])))
        }
    }
}

/// The picker's model: the rows, the highlight, and what the table must do after each
/// snapshot. Picker behavior independent of AppKit.
///
/// Positions for keyboard movement count Working Tree as 0 and `rows[i]` as `i + 1`.
struct CommitPickerState {
    private(set) var snapshot: CommitPickerSnapshot
    private(set) var highlightedScope: DiffScope
    private(set) var rows: [CommitPickerRow]
    private let grouping: CommitDayGrouping

    init(snapshot: CommitPickerSnapshot, grouping: CommitDayGrouping) {
        self.snapshot = snapshot
        self.grouping = grouping
        rows = Self.makeRows(snapshot: snapshot, grouping: grouping)
        highlightedScope = snapshot.displayedScope
    }

    private static func makeRows(snapshot: CommitPickerSnapshot, grouping: CommitDayGrouping) -> [CommitPickerRow] {
        let labels = grouping.gutterLabels(for: snapshot.commits.map(\.committedAt))
        return zip(snapshot.commits, labels).map { commit, label in
            let scope = DiffScope.commit(commit.ref)
            return CommitPickerRow(
                scope: scope, commit: commit, dayLabel: label, isDisplayedScope: scope == snapshot.displayedScope)
        }
    }

    static func fileCountText(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    // MARK: Derived

    /// The highlighted row's index; nil when Working Tree is highlighted.
    var highlightedTableRow: Int? {
        guard case .commit = highlightedScope else { return nil }
        return rows.firstIndex { $0.scope == highlightedScope }
    }

    /// Nil when there are rows.
    var emptyState: CommitPickerEmptyState? {
        guard rows.isEmpty else { return nil }
        if snapshot.isLoadingHistory { return .loading }
        return snapshot.historyLoadFailed ? .failed : .noCommits
    }

    /// `.none` when there are no rows; the empty state speaks then.
    var footer: CommitPickerFooter {
        guard !rows.isEmpty else { return .none }
        if snapshot.isLoadingHistory { return .loading }
        return snapshot.historyLoadFailed ? .failed : .none
    }

    var headerText: CommitPickerHeaderText {
        CommitPickerHeaderText.make(snapshot: snapshot, grouping: grouping)
    }

    /// The file count beside the Working Tree row, only while it is what the diff shows.
    var workingTreeTrailingText: String {
        guard snapshot.displayedScope == .workingTree, let count = snapshot.displayedScopeFileCount else { return "" }
        return Self.fileCountText(count)
    }

    func scope(forTableRow row: Int) -> DiffScope? {
        rows.indices.contains(row) ? rows[row].scope : nil
    }

    // MARK: Snapshots

    /// Takes a new snapshot and reports what the table must do. Header, footer and the
    /// Working Tree text are re-read after every call; only the rows are reported.
    mutating func apply(_ new: CommitPickerSnapshot) -> CommitPickerTableChange {
        guard new != snapshot else { return .none }
        let old = snapshot
        snapshot = new
        guard new.commits != old.commits || new.displayedScope != old.displayedScope else { return .none }

        let oldRows = rows
        rows = Self.makeRows(snapshot: new, grouping: grouping)
        let change: CommitPickerTableChange
        if rows.count >= oldRows.count, zip(oldRows, rows).allSatisfy({ $0.commit.ref.sha == $1.commit.ref.sha }) {
            let inserted = rows.count > oldRows.count ? oldRows.count..<rows.count : nil
            var refreshed = IndexSet()
            for (index, pair) in zip(oldRows, rows).enumerated() where pair.0 != pair.1 {
                refreshed.insert(index)
            }
            change = .incremental(inserted: inserted, refreshed: refreshed)
        } else {
            change = .reloadAll
        }

        // Keep the highlight by SHA across history reloads.
        if case .commit = highlightedScope, !rows.contains(where: { $0.scope == highlightedScope }) {
            highlightedScope = rows.first?.scope ?? .workingTree
        }
        return change
    }

    // MARK: Navigation

    private var highlightedPosition: Int {
        highlightedTableRow.map { $0 + 1 } ?? 0
    }

    private mutating func highlight(position: Int) {
        highlightedScope = position == 0 ? .workingTree : rows[position - 1].scope
    }

    mutating func moveUp() {
        highlight(position: max(highlightedPosition - 1, 0))
    }

    mutating func moveDown() {
        highlight(position: min(highlightedPosition + 1, rows.count))
    }

    mutating func moveToFirst() {
        highlightWorkingTree()
    }

    mutating func moveToLast() {
        highlight(position: rows.count)
    }

    /// Out-of-range rows are ignored.
    mutating func highlight(tableRow row: Int) {
        guard rows.indices.contains(row) else { return }
        highlightedScope = rows[row].scope
    }

    mutating func highlightWorkingTree() {
        highlightedScope = .workingTree
    }

    // MARK: Pagination

    /// Whether scrolling to `lastVisibleRow` should ask for the next page: only at the
    /// last row, only when there is one, and never over a load or a failure, which has
    /// its own Retry.
    func shouldRequestMore(lastVisibleRow: Int?) -> Bool {
        guard !rows.isEmpty, lastVisibleRow == rows.count - 1 else { return false }
        return snapshot.hasMore && !snapshot.isLoadingHistory && !snapshot.historyLoadFailed
    }
}
