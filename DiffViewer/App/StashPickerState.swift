import Foundation

/// The stash picker's model: the items, the highlight, the search and what the table must
/// do after each change. Picker behavior independent of AppKit.
///
/// Items are the stashes in git's order (newest first) under recency headers.
struct StashPickerState {
    private(set) var snapshot: StashPickerSnapshot
    private(set) var items: [StashPickerItem] = []
    private(set) var highlight = StashPickerHighlight.none
    /// The search text, normalized, so a spaces-only field reads as no query at all.
    private(set) var query = ""
    private let grouping: CommitDayGrouping

    init(snapshot: StashPickerSnapshot, grouping: CommitDayGrouping) {
        self.snapshot = snapshot
        self.grouping = grouping
        items = makeItems()
        highlight = initialHighlight()
    }

    // MARK: Items

    private func makeItems() -> [StashPickerItem] {
        var items: [StashPickerItem] = []
        // A header opens wherever the group differs from the row above, so a clock-skewed
        // list repeats one rather than reordering git's stashes.
        var group: RecencyGroup?
        for entry in snapshot.stashes where matches(entry) {
            let entryGroup = grouping.recencyGroup(for: entry.committedAt)
            if entryGroup != group { items.append(.header(entryGroup)) }
            group = entryGroup
            items.append(
                .stash(
                    StashPickerRow(
                        entry: entry, isDisplayed: entry.commitSummary.ref == snapshot.displayedRef,
                        timeText: grouping.rowTimeText(for: entry.committedAt))))
        }
        return items
    }

    private func matches(_ entry: StashEntry) -> Bool {
        guard !query.isEmpty else { return true }
        return Self.matches(entry.message, query: query)
            || entry.sourceBranch.map { Self.matches($0, query: query) } == true
    }

    /// A case-insensitive substring, with whitespace dropped from the text as it is from
    /// the query, so `fix bug` still finds "Fix bug".
    private static func matches(_ text: String, query: String) -> Bool {
        FuzzyMatch.normalized(text).range(of: query, options: .caseInsensitive) != nil
    }

    // MARK: Derived

    /// The stash rows, in table order.
    var rows: [StashPickerRow] {
        items.compactMap(\.stashRow)
    }

    var headerText: StashPickerHeaderText {
        StashPickerHeaderText.make(snapshot: snapshot, now: grouping.now)
    }

    /// For the empty-state label; nil when there is nothing to say. "No matching" needs a
    /// list to have been read, so an unread or failed first read leaves it to the header.
    var emptyText: String? {
        if !query.isEmpty, rows.isEmpty, !snapshot.stashes.isEmpty { return "No matching stashes" }
        if snapshot.readStatus == .loaded, snapshot.stashes.isEmpty { return "Stashed changes will appear here." }
        return nil
    }

    var highlightedItemIndex: Int? {
        guard case let .row(key) = highlight else { return nil }
        return items.firstIndex { $0.key == key && $0.stashRow != nil }
    }

    /// Headers take no highlight, hover or click.
    func canHighlight(item index: Int) -> Bool {
        activation(forItem: index) != nil
    }

    /// The stash activating the item opens; nil for a header or past the end.
    func activation(forItem index: Int) -> StashEntry? {
        items.indices.contains(index) ? items[index].stashRow?.entry : nil
    }

    /// What ↩ does: nothing unless a row is highlighted, so Return never picks a row the
    /// reader didn't see highlighted.
    var highlightedActivation: StashEntry? {
        highlightedItemIndex.flatMap(activation(forItem:))
    }

    /// A row's Pop and Drop. While an operation runs, only its own button is live, as a
    /// spinner; otherwise the window's blocked reason disables both. Nil for a header.
    func buttons(forItem index: Int) -> (pop: PickerButtonState, drop: PickerButtonState)? {
        guard let entry = activation(forItem: index) else { return nil }
        if let active = snapshot.activeOperation {
            let busy = PickerButtonState.disabled(reason: "Another stash action is running")
            guard active.acts(on: entry) else { return (busy, busy) }
            return active.operation == .pop ? (.running, busy) : (busy, .running)
        }
        if let reason = snapshot.actionsBlockedReason {
            return (.disabled(reason: reason), .disabled(reason: reason))
        }
        return (.enabled, .enabled)
    }

    // MARK: Snapshots

    /// Takes a new snapshot and reports what the table must do. The header is re-read
    /// after every call.
    mutating func apply(_ new: StashPickerSnapshot) -> StashPickerTableChange {
        guard new != snapshot else { return .none }
        let remembered = rememberedHighlight()
        snapshot = new
        let oldItems = items
        items = makeItems()
        switch highlight {
        case .cleared: break
        case .none: highlight = initialHighlight()
        case .row: highlight = reconciledHighlight(remembered)
        }
        return items == oldItems ? .none : .reloadAll
    }

    // MARK: Query

    /// Filters the stashes on every keystroke.
    mutating func setQuery(_ text: String) -> StashPickerTableChange {
        let normalized = FuzzyMatch.normalized(text)
        guard normalized != query else { return .none }
        query = normalized
        items = makeItems()
        highlight = initialHighlight()
        return .reloadAll
    }

    // MARK: Highlight

    /// A search starts on its first match; otherwise on the displayed stash, else the
    /// first. `.none` until a row to start on arrives.
    private func initialHighlight() -> StashPickerHighlight {
        let rows = self.rows
        let start = query.isEmpty ? rows.first(where: \.isDisplayed) ?? rows.first : rows.first
        return start.map { .row(.stash(index: $0.entry.stashIndex)) } ?? .none
    }

    /// Where ↑ or ↓ lands with nothing highlighted: the displayed stash, else the first
    /// row when a query hides it.
    private var entryHighlight: StashPickerHighlight {
        let rows = self.rows
        let start = rows.first(where: \.isDisplayed) ?? rows.first
        return start.map { .row(.stash(index: $0.entry.stashIndex)) } ?? highlight
    }

    /// The highlighted entry and the old row order around it, read before a new snapshot
    /// replaces the indexes the key means.
    private func rememberedHighlight() -> (entry: StashEntry, order: [StashEntry], position: Int)? {
        guard let index = highlightedItemIndex, let entry = activation(forItem: index) else { return nil }
        let order = rows.map(\.entry)
        return (entry, order, order.firstIndex { $0.stashIndex == entry.stashIndex } ?? 0)
    }

    /// The same entry (nearest by index among identical duplicates), else the first entry
    /// after it in the old order that survives, else the nearest one before it, else the
    /// first row.
    private func reconciledHighlight(
        _ remembered: (entry: StashEntry, order: [StashEntry], position: Int)?
    ) -> StashPickerHighlight {
        let rows = self.rows
        guard let remembered else { return initialHighlight() }
        guard !rows.isEmpty else { return .none }
        func nearest(to entry: StashEntry) -> StashPickerRow? {
            rows.lazy.filter { $0.entry.sha == entry.sha && $0.entry.message == entry.message }
                .min { abs($0.entry.stashIndex - entry.stashIndex) < abs($1.entry.stashIndex - entry.stashIndex) }
        }
        let before = remembered.order[..<remembered.position].reversed()
        let after = remembered.order[(remembered.position + 1)...]
        let target =
            ([remembered.entry] + after + before).lazy.compactMap(nearest(to:)).first ?? rows[0]
        return .row(.stash(index: target.entry.stashIndex))
    }

    // MARK: Navigation

    /// Moves `offset` stash rows, clamped at both ends. With nothing highlighted it lands
    /// on the entry row instead.
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
        if let first = rows.first { highlight = .row(.stash(index: first.entry.stashIndex)) }
    }

    mutating func moveToLast() {
        if let last = rows.last { highlight = .row(.stash(index: last.entry.stashIndex)) }
    }

    /// Hover. Headers and out-of-range rows are ignored. Returns whether the highlight
    /// moved.
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
