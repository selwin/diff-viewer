import Foundation

/// The commit picker's model: the items, the highlight, the search and its budget, and
/// what the table must do after each change. Picker behavior independent of AppKit.
///
/// Items run Working Tree, the displayed commit when the page lacks it, the loaded
/// commits in git's order under recency headers, then at most one message row.
struct CommitPickerListState {
    /// Loaded commits a search may reach before it stops and asks: ten next-page reads.
    static let searchBudgetStep = 10 * WindowState.commitPageSize

    private(set) var snapshot: CommitPickerListSnapshot
    private(set) var items: [CommitPickerItem] = []
    private(set) var highlight = CommitPickerHighlight.none
    /// The search text, normalized, so a spaces-only field reads as no query at all.
    private(set) var query = ""
    /// Counts loaded commits, not reads, and starts over with each new query.
    private(set) var searchBudget = CommitPickerListState.searchBudgetStep
    /// The field's text as typed, which a no-match message quotes.
    private var queryText = ""
    /// Search older commits was asked for and its read has not started, so that read is
    /// due wherever the list is scrolled.
    private var isSearchingOlder = false
    private let grouping: CommitDayGrouping

    init(snapshot: CommitPickerListSnapshot, grouping: CommitDayGrouping) {
        self.snapshot = snapshot
        self.grouping = grouping
        items = makeItems()
        highlight = initialHighlight()
    }

    // MARK: Items

    private func makeItems() -> [CommitPickerItem] {
        var items: [CommitPickerItem] = []
        if Self.matches(CommitPickerWorkingTreeRow.title, query: query) {
            let detail = snapshot.workingTreeChangeCount.map(ChangeCountText.make)
            items.append(.workingTree(.init(detail: detail, isSelectedScope: snapshot.displayedScope == .workingTree)))
        }
        if let selected = selectedOutsidePage, matches(selected) {
            items += [.header(.selected, firstSha: selected.ref.sha), .commit(row(for: selected))]
        }
        // A header opens wherever the group differs from the row above, so a clock-skewed
        // history repeats one rather than reordering git's commits.
        var group: RecencyGroup?
        for commit in snapshot.commits where matches(commit) {
            let commitGroup = grouping.recencyGroup(for: commit.committedAt)
            if commitGroup != group { items.append(.header(.recency(commitGroup), firstSha: commit.ref.sha)) }
            group = commitGroup
            items.append(.commit(row(for: commit)))
        }
        let hasCommitMatches = items.contains { $0.commitRow != nil }
        if let message = Self.message(
            snapshot: snapshot, query: query.isEmpty ? "" : queryText, searchBudget: searchBudget,
            hasCommitMatches: hasCommitMatches, isSearchingOlder: isSearchingOlder)
        {
            items.append(.message(message))
        }
        return items
    }

    /// The displayed commit, when the loaded page does not carry it.
    private var selectedOutsidePage: CommitSummary? {
        guard let commit = snapshot.displayedCommit, !snapshot.commits.contains(where: { $0.ref == commit.ref })
        else { return nil }
        return commit
    }

    private func row(for commit: CommitSummary) -> CommitPickerListRow {
        let scope = DiffScope.commit(commit.ref)
        return CommitPickerListRow(
            scope: scope, sha: commit.ref.sha, shortSha: commit.ref.shortSha, subject: commit.subject,
            authorName: commit.author, dateText: grouping.commitDateText(for: commit.committedAt),
            status: snapshot.unpushedShas.contains(commit.ref.sha) ? .notPushed : .none,
            isSelectedScope: scope == snapshot.displayedScope)
    }

    private func matches(_ commit: CommitSummary) -> Bool {
        guard !query.isEmpty else { return true }
        return Self.matches(commit.subject, query: query) || Self.matches(commit.author, query: query)
            || commit.ref.sha.range(of: query, options: [.caseInsensitive, .anchored]) != nil
    }

    /// A case-insensitive substring, with whitespace dropped from the text as it is from
    /// the query, so `fix bug` still finds "Fix bug".
    private static func matches(_ text: String, query: String) -> Bool {
        query.isEmpty || FuzzyMatch.normalized(text).range(of: query, options: .caseInsensitive) != nil
    }

    /// The row that ends the list, or nil for none. `query` is empty when there is no
    /// search. Below its budget a search says loading only while a read is due, which is
    /// when nothing matches yet or older commits were asked for. With matches it reads on
    /// as the list scrolls, like the unfiltered list.
    static func message(
        snapshot: CommitPickerListSnapshot, query: String, searchBudget: Int, hasCommitMatches: Bool,
        isSearchingOlder: Bool
    ) -> CommitPickerMessage? {
        if snapshot.historyLoadFailed { return .failed }
        if snapshot.isLoadingHistory { return .loading }
        if snapshot.commits.isEmpty, !snapshot.hasMore { return .noCommits }
        guard !query.isEmpty else { return nil }
        if snapshot.hasMore {
            let searched = snapshot.commits.count
            if searched >= searchBudget { return .capped(searched: searched, hasMatches: hasCommitMatches) }
            return isSearchingOlder || !hasCommitMatches ? .loading : nil
        }
        return hasCommitMatches ? nil : .noMatches(query: query)
    }

    // MARK: Derived

    /// The commit rows, in table order.
    var rows: [CommitPickerListRow] {
        items.compactMap(\.commitRow)
    }

    var message: CommitPickerMessage? {
        if case let .message(message)? = items.last { message } else { nil }
    }

    var headerText: CommitPickerListHeaderText {
        CommitPickerListHeaderText.make(snapshot: snapshot, grouping: grouping)
    }

    var highlightedItemIndex: Int? {
        guard case let .row(key) = highlight else { return nil }
        return items.firstIndex { $0.key == key && $0.activation != nil }
    }

    /// Headers, and messages without an action, take no highlight, hover or click.
    func canHighlight(item index: Int) -> Bool {
        activation(forItem: index) != nil
    }

    /// What activating the item does; nil for a header, an inert message or past the end.
    func activation(forItem index: Int) -> CommitPickerActivation? {
        items.indices.contains(index) ? items[index].activation : nil
    }

    /// What ↩ does: nothing unless a row is highlighted, so Return never picks a row the
    /// reader didn't see highlighted.
    var highlightedActivation: CommitPickerActivation? {
        highlightedItemIndex.flatMap(activation(forItem:))
    }

    private var hasCommitMatches: Bool {
        items.contains { $0.commitRow != nil }
    }

    // MARK: Pagination

    /// Whether to read the next page after a scroll to `lastVisibleRow`, a snapshot or a
    /// query. Never over a load or a failure, which has its own Retry. A search also reads
    /// on while nothing matches, until its budget is spent.
    func shouldRequestMore(lastVisibleRow: Int?) -> Bool {
        guard snapshot.hasMore, !snapshot.isLoadingHistory, !snapshot.historyLoadFailed else { return false }
        if isSearchingOlder { return true }
        let lastIsVisible = lastVisibleRow == items.count - 1
        guard !query.isEmpty else { return lastIsVisible }
        return (lastIsVisible || !hasCommitMatches) && snapshot.commits.count < searchBudget
    }

    /// Search older commits: another budget's worth beyond what is loaded, so the next
    /// read is always wanted even when earlier pages overshot the budget, and wherever
    /// the list is scrolled.
    mutating func raiseSearchBudget() -> CommitPickerTableChange {
        isSearchingOlder = true
        searchBudget = max(searchBudget, snapshot.commits.count) + Self.searchBudgetStep
        return rebuildItems()
    }

    // MARK: Snapshots

    /// Takes a new snapshot and reports what the table must do. The header is re-read
    /// after every call.
    mutating func apply(_ new: CommitPickerListSnapshot) -> CommitPickerTableChange {
        guard new != snapshot else { return .none }
        snapshot = new
        // The asked-for read has started, or can no longer run.
        if new.isLoadingHistory || new.historyLoadFailed || !new.hasMore { isSearchingOlder = false }
        return rebuildItems()
    }

    private mutating func rebuildItems() -> CommitPickerTableChange {
        let oldItems = items
        items = makeItems()
        keepHighlight(oldItems: oldItems)
        return Self.change(from: oldItems, to: items)
    }

    /// A moved row is a removal and an insertion; the rows between slide.
    private static func change(from oldItems: [CommitPickerItem], to items: [CommitPickerItem])
        -> CommitPickerTableChange
    {
        let difference = items.map(\.key).difference(from: oldItems.map(\.key))
        let removed = IndexSet(difference.removals.map(offset))
        let inserted = IndexSet(difference.insertions.map(offset))
        let stayed = zip(
            oldItems.indices.filter { !removed.contains($0) }, items.indices.filter { !inserted.contains($0) })
        let refreshed = IndexSet(stayed.filter { oldItems[$0] != items[$1] }.map { $1 })
        guard !removed.isEmpty || !inserted.isEmpty || !refreshed.isEmpty else { return .none }
        return .update(removed: removed, inserted: inserted, refreshed: refreshed)
    }

    private static func offset(of change: CollectionDifference<CommitPickerItem.Key>.Change) -> Int {
        switch change {
        case let .insert(offset, _, _), let .remove(offset, _, _): offset
        }
    }

    // MARK: Query

    /// Filters the loaded commits on every keystroke. Whether older pages are read for the
    /// query is `shouldRequestMore`'s call.
    mutating func setQuery(_ text: String) -> CommitPickerTableChange {
        let normalized = FuzzyMatch.normalized(text)
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != query else {
            guard typed != queryText else { return .none }
            // Only the quoted text can change, so the diff touches the message at most.
            queryText = typed
            return rebuildItems()
        }
        query = normalized
        queryText = typed
        searchBudget = Self.searchBudgetStep
        isSearchingOlder = false
        items = makeItems()
        highlight = initialHighlight()
        return .reloadAll
    }

    // MARK: Highlight

    /// A search starts on its first match; otherwise on the displayed scope, else the first
    /// row. `.none` until a row to start on arrives.
    private func initialHighlight() -> CommitPickerHighlight {
        let scopeRows = items.filter(\.isScopeRow)
        let start = query.isEmpty ? scopeRows.first(where: \.isSelectedScope) ?? scopeRows.first : scopeRows.first
        return start.map { .row($0.key) } ?? .none
    }

    /// Where ↑ or ↓ lands with nothing highlighted: the displayed scope, else the first
    /// row when a query hides it.
    private var entryHighlight: CommitPickerHighlight {
        let start = items.first { $0.isScopeRow && $0.isSelectedScope } ?? items.first { $0.activation != nil }
        return start.map { .row($0.key) } ?? highlight
    }

    /// Keeps the highlight by key. When its row goes or stops taking the highlight, a
    /// neighbour takes it, so the highlight stays where the reader was looking. A cleared
    /// highlight stays cleared until hover, a key or a new query.
    private mutating func keepHighlight(oldItems: [CommitPickerItem]) {
        switch highlight {
        case .cleared:
            return
        case .none:
            highlight = initialHighlight()
        case let .row(key):
            guard highlightedItemIndex == nil else { return }
            let listed = Set(items.filter(\.isScopeRow).map(\.key))
            highlight = Self.neighbour(of: key, in: oldItems, listed: listed).map { .row($0) } ?? initialHighlight()
        }
    }

    /// The scope row after `key` in `oldItems` that is still listed, else the one before.
    /// Only scope rows take it over, so a handoff never lands on Retry.
    private static func neighbour(
        of key: CommitPickerItem.Key, in oldItems: [CommitPickerItem], listed: Set<CommitPickerItem.Key>
    ) -> CommitPickerItem.Key? {
        guard let index = oldItems.firstIndex(where: { $0.key == key }) else { return nil }
        let after = oldItems[(index + 1)...].lazy.map(\.key).first { listed.contains($0) }
        let before = oldItems[..<index].reversed().lazy.map(\.key).first { listed.contains($0) }
        return after ?? before
    }

    // MARK: Navigation

    /// Moves `offset` highlightable rows, clamped at both ends. With nothing highlighted
    /// it lands on the entry row instead.
    private mutating func move(by offset: Int) {
        let positions = items.indices.filter(canHighlight(item:))
        guard let current = highlightedItemIndex, let at = positions.firstIndex(of: current) else {
            highlight = entryHighlight
            return
        }
        highlight = .row(items[positions[min(max(at + offset, 0), positions.count - 1)]].key)
    }

    mutating func moveUp() {
        move(by: -1)
    }

    mutating func moveDown() {
        move(by: 1)
    }

    mutating func moveToFirst() {
        if let first = items.first(where: { $0.activation != nil }) { highlight = .row(first.key) }
    }

    mutating func moveToLast() {
        if let last = items.last(where: { $0.activation != nil }) { highlight = .row(last.key) }
    }

    /// Hover. Headers, inert messages and out-of-range rows are ignored. Returns whether
    /// the highlight moved.
    @discardableResult
    mutating func highlight(item index: Int) -> Bool {
        guard canHighlight(item: index), highlight != .row(items[index].key) else { return false }
        highlight = .row(items[index].key)
        return true
    }

    /// The pointer left the list.
    mutating func clearHighlight() {
        highlight = .cleared
    }
}

extension CommitPickerItem {
    /// Working Tree or a commit: the rows that select a scope.
    fileprivate var isScopeRow: Bool {
        if case .scope = activation { true } else { false }
    }

    fileprivate var isSelectedScope: Bool {
        switch self {
        case let .workingTree(row): row.isSelectedScope
        case let .commit(row): row.isSelectedScope
        case .header, .message: false
        }
    }
}
