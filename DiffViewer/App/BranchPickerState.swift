import Foundation

/// Branch picker items, highlight, navigation, and snapshot changes, independent of AppKit.
///
/// Items are table rows: section headers and branches. Movement steps over headers and
/// the current branch, which no tab acts on. With no query nothing is highlighted until
/// the reader moves.
struct BranchPickerState {
    private(set) var snapshot: BranchPickerSnapshot
    private(set) var items: [BranchPickerItem]
    /// Never `.merge` while a merge is unavailable.
    private(set) var tab: BranchPickerTab
    /// The highlighted branch ID; nil when New Branch is highlighted or no branch is
    /// highlighted.
    private(set) var highlightedRow: BranchRowID?
    /// The New Branch… row below the list holds the highlight; never set with `highlightedRow`.
    private(set) var isNewBranchHighlighted = false
    /// The search text, normalized, so a spaces-only field reads as no query at all.
    private(set) var query = ""
    private let grouping: CommitDayGrouping
    /// The current branch's tip, which merge previews are keyed by; nil while a merge is
    /// unavailable. Stored so a row's key costs no scan of the branches.
    private var mergeHeadSha: String?

    init(snapshot: BranchPickerSnapshot, grouping: CommitDayGrouping, tab: BranchPickerTab = .switchBranch) {
        self.snapshot = snapshot
        self.grouping = grouping
        self.tab = tab
        mergeHeadSha = Self.mergeHeadSha(in: snapshot)
        items = Self.makeItems(snapshot: snapshot, grouping: grouping, query: "")
        leaveMergeIfUnavailable()
    }

    // MARK: Items

    private static func makeItems(
        snapshot: BranchPickerSnapshot, grouping: CommitDayGrouping, query: String
    ) -> [BranchPickerItem] {
        let rows =
            localRows(snapshot: snapshot, grouping: grouping) + remoteRows(snapshot: snapshot, grouping: grouping)
        guard !query.isEmpty else { return groupedItems(rows, grouping: grouping) }
        return rankedRows(rows, query: query).map(BranchPickerItem.branch)
    }

    /// Newest tip first within each section, so the branches in play come before the ones
    /// left behind. Empty sections are left out.
    private static func groupedItems(_ rows: [BranchPickerRow], grouping: CommitDayGrouping) -> [BranchPickerItem] {
        var byGroup: [RecencyGroup: [BranchPickerRow]] = [:]
        for row in rows.sorted(by: isNewer) {
            byGroup[grouping.recencyGroup(for: row.tipCommittedAt), default: []].append(row)
        }
        return RecencyGroup.allCases.flatMap { group -> [BranchPickerItem] in
            guard let rows = byGroup[group] else { return [] }
            return [.header(group)] + rows.map(BranchPickerItem.branch)
        }
    }

    /// Best match first. A ranked list has no sections.
    private static func rankedRows(_ rows: [BranchPickerRow], query: String) -> [BranchPickerRow] {
        let matched = rows.compactMap { row in FuzzyMatch.match(query, in: row.name).map { (row: row, match: $0) } }
        let sorted = matched.sorted { a, b in
            a.match.score == b.match.score ? isNewer(a.row, b.row) : a.match.score > b.match.score
        }
        return sorted.map { entry in
            var row = entry.row
            row.matchedRanges = entry.match.ranges
            return row
        }
    }

    /// Names, then local before remote, break a tie so the order never depends on how git
    /// listed the branches.
    private static func isNewer(_ a: BranchPickerRow, _ b: BranchPickerRow) -> Bool {
        if a.tipCommittedAt != b.tipCommittedAt { return a.tipCommittedAt > b.tipCommittedAt }
        if a.name != b.name { return a.name < b.name }
        return a.kind != .remoteOnly && b.kind == .remoteOnly
    }

    private static func localRows(snapshot: BranchPickerSnapshot, grouping: CommitDayGrouping) -> [BranchPickerRow] {
        snapshot.branches.map { branch in
            BranchPickerRow(
                id: .local(name: branch.name), kind: snapshot.headState == .named(branch.name) ? .current : .local,
                source: .local(branch), name: branch.name,
                subtitle: subtitle(author: branch.tipCommitAuthor, date: branch.tipCommittedAt, grouping: grouping),
                status: .local(branch, configuredRemote: snapshot.configuredUpstreamRemotes[branch.name]),
                collidesWithLocalName: false)
        }
    }

    /// The remote branches no local branch tracks.
    private static func remoteRows(snapshot: BranchPickerSnapshot, grouping: CommitDayGrouping) -> [BranchPickerRow] {
        let localNames = Set(snapshot.branches.map(\.name))
        let shortRemote = publishRemote(snapshot)
        return RemoteOnlyBranches.filter(remotes: snapshot.remoteBranches, locals: snapshot.branches).map { branch in
            let collides = localNames.contains(branch.name)
            // The prefix stays on a collision, so the reader can tell the two rows apart.
            let name = !collides && branch.remote == shortRemote ? branch.name : "\(branch.remote)/\(branch.name)"
            return BranchPickerRow(
                id: .remote(ref: branch.ref), kind: .remoteOnly, source: .remote(branch), name: name,
                subtitle: subtitle(author: branch.tipCommitAuthor, date: branch.tipCommittedAt, grouping: grouping),
                status: snapshot.newRemoteBranches.contains(branch.ref) ? .new : .none,
                collidesWithLocalName: collides)
        }
    }

    /// Where Publish would go. Until a fetch round has listed the remotes, the ones the
    /// remote branches name stand in, so names don't change as the first round starts.
    private static func publishRemote(_ snapshot: BranchPickerSnapshot) -> String? {
        var remotes = snapshot.remotes
        if remotes.isEmpty {
            for branch in snapshot.remoteBranches where !remotes.contains(branch.remote) {
                remotes.append(branch.remote)
            }
        }
        if case let .remote(remote) = SyncPolicy.publishRemote(remotes: remotes) { return remote }
        return nil
    }

    private static func subtitle(author: String, date: Date, grouping: CommitDayGrouping) -> String {
        "\(author) · \(grouping.branchTimeText(for: date))"
    }

    /// A search starts on its best highlightable match; with no query nothing is
    /// highlighted.
    private static func initialHighlight(items: [BranchPickerItem], query: String) -> BranchRowID? {
        guard !query.isEmpty else { return nil }
        return items.first(where: isHighlightable)?.row?.id
    }

    /// The one rule for the highlight, hover and keyboard moves: a branch that is not
    /// the current one. Headers and the current branch take none in either tab.
    private static func isHighlightable(_ item: BranchPickerItem) -> Bool {
        guard let row = item.row else { return false }
        return row.kind != .current
    }

    // MARK: Derived

    /// The branch rows, in table order.
    var rows: [BranchPickerRow] {
        items.compactMap(\.row)
    }

    var highlightedTableRow: Int? {
        guard let highlightedRow else { return nil }
        return items.firstIndex { $0.row?.id == highlightedRow }
    }

    /// Nil for a section header or past the end.
    func row(forTableRow index: Int) -> BranchPickerRow? {
        items.indices.contains(index) ? items[index].row : nil
    }

    /// Section headers and the current branch take no highlight, hover or click.
    func canHighlight(tableRow index: Int) -> Bool {
        items.indices.contains(index) && Self.isHighlightable(items[index])
    }

    /// Nil when there are rows.
    var emptyState: BranchPickerEmptyState? {
        guard items.isEmpty else { return nil }
        if !query.isEmpty, !snapshot.branches.isEmpty || !snapshot.remoteBranches.isEmpty { return .noMatches }
        switch snapshot.readStatus {
        case .unread: return .loading
        case .failed: return .failed
        case .loaded: return .noBranches
        }
    }

    /// The header's fetch news as of `now`; the caller re-asks as time passes.
    func fetchText(now: Date) -> BranchPickerFetchText? {
        BranchPickerFetchText.make(
            isFetching: snapshot.fetchStatus != .idle, readFailed: snapshot.readStatus == .failed,
            lastRound: snapshot.lastFetchRound, now: now)
    }

    var headerText: BranchPickerHeaderText {
        BranchPickerHeaderText.make(snapshot: snapshot)
    }

    /// A row's Pull and Push, Publish, or Delete, or nil for a header or past the end; a
    /// remote-only row has none. Pull, Publish and Delete wait on fetches through
    /// `SyncPolicy.isFetching`, as `WindowState`'s admission does, so the two agree. Push
    /// may still wait for its remote's fetch and be re-checked afterwards.
    func syncButtons(forTableRow index: Int) -> RowSyncButtons? {
        guard let row = row(forTableRow: index) else { return nil }
        return Self.syncButtons(for: row, snapshot: snapshot)
    }

    private static func syncButtons(for row: BranchPickerRow, snapshot: BranchPickerSnapshot) -> RowSyncButtons {
        guard case let .local(branch) = row.source else { return .hidden }
        return syncButtons(for: branch, isCurrent: row.kind == .current, snapshot: snapshot)
    }

    static func syncButtons(for branch: LocalBranch, isCurrent: Bool, snapshot: BranchPickerSnapshot)
        -> RowSyncButtons
    {
        SyncPolicy.rowButtons(
            branch: branch, isCurrent: isCurrent, readStatus: snapshot.readStatus, active: snapshot.activeSync,
            isSwitching: snapshot.isSwitchingBranch, fetchStatus: snapshot.fetchStatus,
            fetchingRemotes: snapshot.fetchingRemotes, remotes: snapshot.remotes,
            configuredRemote: snapshot.configuredUpstreamRemotes[branch.name])
    }

    /// The local branch as the row shows it, which a delete checks against before it runs.
    func branch(forTableRow index: Int) -> LocalBranch? {
        guard case let .local(branch)? = row(forTableRow: index)?.source else { return nil }
        return branch
    }

    /// What activating the row does, or nil when it can't be activated. A switch in flight
    /// locks every row until it settles. In Switch: the current branch is already checked
    /// out, a branch being deleted can't be checked out, and a blocked row explains why. In
    /// Merge: any other branch opens the merge sheet, while a merge is available.
    func activation(forTableRow index: Int) -> BranchActivation? {
        guard !snapshot.isSwitchingBranch, let row = row(forTableRow: index),
            blockedReason(forTableRow: index) == nil
        else { return nil }
        switch tab {
        case .switchBranch: return switchActivation(for: row)
        case .merge: return mergeTarget(for: row).map(BranchActivation.merge)
        }
    }

    private func switchActivation(for row: BranchPickerRow) -> BranchActivation? {
        switch row.source {
        case let .local(branch):
            guard row.kind != .current, branch.name != Self.deleting(snapshot) else { return nil }
            return .switchTo(name: branch.name)
        case let .remote(branch):
            return .checkoutTracking(branch)
        }
    }

    private func mergeTarget(for row: BranchPickerRow) -> MergeTarget? {
        guard row.kind != .current, let mergeHeadSha, let into = currentBranchName else { return nil }
        switch row.source {
        case let .local(branch): return .local(branch, destinationBranch: into, destinationTipSha: mergeHeadSha)
        case let .remote(branch): return .remote(branch, destinationBranch: into, destinationTipSha: mergeHeadSha)
        }
    }

    func canActivate(tableRow index: Int) -> Bool {
        activation(forTableRow: index) != nil
    }

    /// Why the row can't be activated, shown as its tooltip: in Switch, a remote branch
    /// whose name a local branch has. A merge from it has no such clash.
    func blockedReason(forTableRow index: Int) -> String? {
        guard tab == .switchBranch, let row = row(forTableRow: index), row.collidesWithLocalName,
            case let .remote(branch) = row.source
        else { return nil }
        return branch.localNameCollisionMessage
    }

    /// The row's right-edge words: the current branch's role in the tab, else its status
    /// in Switch, or in Merge the `preview` of its current key once one has arrived.
    func trailingLabel(forTableRow index: Int, preview: MergePreview? = nil) -> BranchRowLabel? {
        guard let row = row(forTableRow: index) else { return nil }
        if row.kind == .current {
            return BranchRowLabel(text: tab == .merge ? "Merge target" : "Current", style: .secondary)
        }
        switch tab {
        case .merge:
            return preview.map(MergePreviewText.label(for:))
        case .switchBranch:
            guard !row.status.text.isEmpty else { return nil }
            return BranchRowLabel(text: row.status.text, style: row.status.isAccent ? .accent : .secondary)
        }
    }

    // MARK: Merge previews

    /// What merging the row into the current branch would be previewed by: in Merge only,
    /// and never for the current branch itself. Keyed by tips, so a moved HEAD or branch
    /// gives the row a new key.
    func mergePreviewKey(forTableRow index: Int) -> MergePreviewKey? {
        guard tab == .merge, let row = row(forTableRow: index) else { return nil }
        return mergeTarget(for: row)?.previewKey
    }

    /// Every row whose current key is `key`: branches at the same tip share one.
    func tableRows(matching key: MergePreviewKey) -> [Int] {
        items.indices.filter { mergePreviewKey(forTableRow: $0) == key }
    }

    /// The keys of the rows in `visibleRows` that have one.
    func requestedKeys(visibleRows: Range<Int>) -> Set<MergePreviewKey> {
        Set(visibleRows.clamped(to: items.indices).compactMap { mergePreviewKey(forTableRow: $0) })
    }

    // MARK: Tabs

    /// A merge needs a checked-out branch to merge into: a loaded read with HEAD on a
    /// listed branch. Detached, unborn, unread and failed reads have none.
    var isMergeAvailable: Bool {
        mergeHeadSha != nil
    }

    private static func mergeHeadSha(in snapshot: BranchPickerSnapshot) -> String? {
        guard snapshot.readStatus == .loaded, case let .named(name)? = snapshot.headState else { return nil }
        return snapshot.branches.first { $0.name == name }?.tipSha
    }

    private var currentBranchName: String? {
        if case let .named(name)? = snapshot.headState { name } else { nil }
    }

    var instruction: BranchPickerInstruction {
        let token = highlightedTableRow.flatMap { row(forTableRow: $0)?.name }
        switch tab {
        case .switchBranch: return BranchPickerInstruction(verb: "Switch to", token: token, ending: nil)
        case .merge: return BranchPickerInstruction(verb: "Merge", token: token, ending: "into current branch")
        }
    }

    /// Returns whether the tab changed; Merge is refused while unavailable. The query and
    /// highlight stay: neither depends on the tab.
    @discardableResult
    mutating func setTab(_ new: BranchPickerTab) -> Bool {
        guard new != tab, new != .merge || isMergeAvailable else { return false }
        tab = new
        return true
    }

    private mutating func leaveMergeIfUnavailable() {
        if tab == .merge, !isMergeAvailable { tab = .switchBranch }
    }

    // MARK: Snapshots

    /// Takes a new snapshot and reports what the table must do. Header and the empty
    /// state are re-read after every call; only the rows and buttons are reported.
    mutating func apply(_ new: BranchPickerSnapshot) -> BranchPickerChange {
        guard new != snapshot else { return BranchPickerChange(rows: .none, buttonsChanged: false) }
        let old = snapshot
        // By branch, since rows can come and go: only rows that stay can have changed buttons.
        let oldButtons = Dictionary(
            rows.map { ($0.id, Self.syncButtons(for: $0, snapshot: old)) }, uniquingKeysWith: { first, _ in first })
        snapshot = new
        mergeHeadSha = Self.mergeHeadSha(in: new)
        leaveMergeIfUnavailable()
        let rowChange = applyItems(new, old: old)
        let buttonsChanged = rows.contains { row in
            oldButtons[row.id].map { $0 != Self.syncButtons(for: row, snapshot: new) } ?? false
        }
        return BranchPickerChange(rows: rowChange, buttonsChanged: buttonsChanged)
    }

    private mutating func applyItems(_ new: BranchPickerSnapshot, old: BranchPickerSnapshot) -> BranchTableChange {
        let oldItems = items
        items = Self.makeItems(snapshot: new, grouping: grouping, query: query)
        keepHighlight(oldItems: oldItems)
        // A list appearing or emptying swaps with the empty state: there is nothing to slide.
        guard oldItems.isEmpty == items.isEmpty else { return .reloadAll }
        // A moved row is a removal and an insertion; the rows between slide.
        let difference = items.map(\.key).difference(from: oldItems.map(\.key))
        let removed = IndexSet(difference.removals.map(Self.offset))
        let inserted = IndexSet(difference.insertions.map(Self.offset))
        let stayed = zip(
            oldItems.indices.filter { !removed.contains($0) }, items.indices.filter { !inserted.contains($0) })
        // The cells hold whether a row can activate: a switch flag changing reaches every
        // row, and a delete starting or ending reaches its own.
        let switchChanged = new.isSwitchingBranch != old.isSwitchingBranch
        var refreshed = IndexSet(stayed.filter { switchChanged || oldItems[$0] != items[$1] }.map { $1 })
        refreshed.formUnion(deleteChangedRows(new, old: old).subtracting(inserted))
        guard !removed.isEmpty || !inserted.isEmpty || !refreshed.isEmpty else { return .none }
        return .update(removed: removed, inserted: inserted, refreshed: refreshed)
    }

    private static func offset(of change: CollectionDifference<BranchPickerItem.Key>.Change) -> Int {
        switch change {
        case let .insert(offset, _, _), let .remove(offset, _, _): offset
        }
    }

    /// Keeps the highlight by identity. When its row goes, or becomes the current branch,
    /// a neighbour takes it, so the highlight stays where the reader was looking rather
    /// than jumping to the top.
    private mutating func keepHighlight(oldItems: [BranchPickerItem]) {
        // A refresh (fetch, FSEvents) must not pull the highlight off New Branch… or wake
        // an idle list. A search with nothing highlighted takes the first match that arrives.
        guard !isNewBranchHighlighted else { return }
        guard let highlightedRow else {
            if !query.isEmpty { highlightedRow = Self.initialHighlight(items: items, query: query) }
            return
        }
        let listed = Set(highlightableIDs)
        if listed.contains(highlightedRow) { return }
        self.highlightedRow =
            Self.neighbour(of: highlightedRow, in: oldItems, listed: listed)
            ?? Self.initialHighlight(items: items, query: query)
    }

    /// The branch after `id` in `oldItems` that is still listed, else the one before it.
    private static func neighbour(
        of id: BranchRowID, in oldItems: [BranchPickerItem], listed: Set<BranchRowID>
    ) -> BranchRowID? {
        guard let index = oldItems.firstIndex(where: { $0.row?.id == id }) else { return nil }
        let after = oldItems[(index + 1)...].lazy.compactMap(\.row?.id).first { listed.contains($0) }
        let before = oldItems[..<index].reversed().lazy.compactMap(\.row?.id).first { listed.contains($0) }
        return after ?? before
    }

    /// The rows of the branches whose delete started or ended between `old` and `new`.
    private func deleteChangedRows(_ new: BranchPickerSnapshot, old: BranchPickerSnapshot) -> IndexSet {
        guard Self.deleting(new) != Self.deleting(old) else { return [] }
        let names = [Self.deleting(new), Self.deleting(old)].compactMap { $0 }
        return IndexSet(names.compactMap { name in items.firstIndex { $0.row?.id == .local(name: name) } })
    }

    /// The branch being deleted, which no row may activate.
    private static func deleting(_ snapshot: BranchPickerSnapshot) -> String? {
        snapshot.activeSync.flatMap { $0.operation == .delete ? $0.branch : nil }
    }

    // MARK: Query

    /// Takes the search field's text. Lists are small, so any change reloads every row
    /// rather than diffing them.
    mutating func setQuery(_ text: String) -> BranchTableChange {
        let normalized = FuzzyMatch.normalized(text)
        guard normalized != query else { return .none }
        query = normalized
        isNewBranchHighlighted = false
        items = Self.makeItems(snapshot: snapshot, grouping: grouping, query: query)
        highlightedRow = Self.initialHighlight(items: items, query: query)
        return .reloadAll
    }

    // MARK: Navigation

    /// The highlightable rows' branch IDs, in table order.
    private var highlightableIDs: [BranchRowID] {
        items.compactMap { Self.isHighlightable($0) ? $0.row?.id : nil }
    }

    /// Moves `offset` highlightable rows from the highlight, clamped at both ends. From
    /// idle, down starts at the first row and up at the last.
    private mutating func move(by offset: Int) {
        let ids = highlightableIDs
        // New Branch… is below the last branch: only up leaves it.
        if isNewBranchHighlighted {
            guard offset < 0, let last = ids.last else { return }
            isNewBranchHighlighted = false
            highlightedRow = last
            return
        }
        guard !ids.isEmpty else { return }
        guard let current = highlightedRow.flatMap(ids.firstIndex(of:)) else {
            highlightedRow = offset > 0 ? ids.first : ids.last
            return
        }
        highlightedRow = ids[min(max(current + offset, 0), ids.count - 1)]
    }

    mutating func moveUp() {
        move(by: -1)
    }

    mutating func moveDown() {
        move(by: 1)
    }

    mutating func moveToFirst() {
        guard let first = highlightableIDs.first else { return }
        isNewBranchHighlighted = false
        highlightedRow = first
    }

    mutating func moveToLast() {
        guard let last = highlightableIDs.last else { return }
        isNewBranchHighlighted = false
        highlightedRow = last
    }

    /// Moves the highlight to New Branch… and takes it off the branches. Returns whether
    /// it moved.
    @discardableResult
    mutating func highlightNewBranch() -> Bool {
        guard !isNewBranchHighlighted else { return false }
        isNewBranchHighlighted = true
        highlightedRow = nil
        return true
    }

    /// Rows that take no highlight and out-of-range rows are ignored. Returns whether the
    /// highlight moved.
    @discardableResult
    mutating func highlight(tableRow index: Int) -> Bool {
        guard canHighlight(tableRow: index), let row = row(forTableRow: index), row.id != highlightedRow else {
            return false
        }
        isNewBranchHighlighted = false
        highlightedRow = row.id
        return true
    }
}
