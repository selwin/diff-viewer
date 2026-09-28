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
    /// Why the row can't be checked out, shown as its tooltip.
    let blockedReason: String?
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

/// The header's face: where HEAD is, how far it is from its upstream, and the current
/// branch's Pull and Push.
struct BranchPickerHeaderText: Equatable {
    let title: String
    /// What the detail line says about HEAD's upstream; the fetch news follows.
    var detailParts: [String] = []
    /// True while a fetch round runs, whether or not its remotes are known yet.
    var showsSpinner = false
    /// Fetch is offered unless a round is running or a pull or push is about to move the
    /// same counts, which a round would not start beside.
    var canFetch = true
    /// HEAD's branch, which `buttons` act on; nil when HEAD is on no listed branch.
    var branch: String?
    var buttons = RowSyncButtons.hidden

    /// A header button Tab can reach.
    enum Control: Equatable {
        case fetch
        case pull
        case push
    }

    /// The header buttons Tab visits after the search field, in order: only those shown
    /// and enabled, so focus never lands on a button that can't act.
    var focusOrder: [Control] {
        var order: [Control] = canFetch ? [.fetch] : []
        guard branch != nil else { return order }
        if buttons.pull == .enabled { order.append(.pull) }
        if buttons.push == .enabled { order.append(.push) }
        return order
    }

    /// The detail line, with the fetch news last.
    func detail(fetch: BranchPickerFetchText?) -> String {
        (detailParts + [fetch?.text ?? ""]).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func make(snapshot: BranchPickerSnapshot) -> BranchPickerHeaderText {
        let spinner = snapshot.fetchStatus != .idle
        let canFetch = !spinner && snapshot.activeSync == nil
        guard let headState = snapshot.headState else {
            let title = snapshot.readStatus == .failed ? "Couldn't read branches" : "Loading…"
            return BranchPickerHeaderText(title: title, showsSpinner: spinner, canFetch: canFetch)
        }
        switch headState {
        case let .detached(sha):
            return BranchPickerHeaderText(title: "Detached " + sha.prefix(7), showsSpinner: spinner, canFetch: canFetch)
        case let .named(name):
            // A branch missing from the list says nothing: the counts are what the list holds.
            guard let branch = snapshot.branches.first(where: { $0.name == name }) else {
                return BranchPickerHeaderText(title: name, showsSpinner: spinner, canFetch: canFetch)
            }
            // Worded as the row is, so a hidden upstream reads the same in both places.
            let status = BranchRowStatus.local(branch, configuredRemote: snapshot.configuredUpstreamRemotes[name])
            return BranchPickerHeaderText(
                title: name, detailParts: [status == .none ? "up to date" : status.text], showsSpinner: spinner,
                canFetch: canFetch, branch: name,
                buttons: BranchPickerState.syncButtons(for: branch, isCurrent: true, snapshot: snapshot))
        }
    }
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

/// The branch picker's model: the items, the highlight, and what the table must do after
/// each snapshot. Picker behavior independent of AppKit.
///
/// Items are table rows: section headers and branches. Only branches can be highlighted
/// or activated, so movement steps over headers.
struct BranchPickerState {
    private(set) var snapshot: BranchPickerSnapshot
    private(set) var items: [BranchPickerItem]
    /// The row the keyboard or pointer is on, or nil when there are no rows.
    private(set) var highlightedRow: BranchRowID?
    /// The search text, normalized, so a spaces-only field reads as no query at all.
    private(set) var query = ""
    private let grouping: CommitDayGrouping

    init(snapshot: BranchPickerSnapshot, grouping: CommitDayGrouping) {
        self.snapshot = snapshot
        self.grouping = grouping
        items = Self.makeItems(snapshot: snapshot, grouping: grouping, query: "")
        highlightedRow = Self.initialHighlight(items: items, query: "")
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
                blockedReason: nil)
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
                blockedReason: collides ? "A local branch named \(branch.name) already exists" : nil)
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

    /// A search starts on its best match; otherwise the current branch, else the first row.
    private static func initialHighlight(items: [BranchPickerItem], query: String) -> BranchRowID? {
        let rows = items.compactMap(\.row)
        guard query.isEmpty else { return rows.first?.id }
        return (rows.first { $0.kind == .current } ?? rows.first)?.id
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

    /// Section headers take no highlight, hover or click.
    func canHighlight(tableRow index: Int) -> Bool {
        row(forTableRow: index) != nil
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
    /// remote-only row has none. Uses the same immediate fetch checks as `WindowState`'s
    /// admission: Pull and Delete are admitted exactly as shown, while Push may still wait
    /// for its remote's fetch and be re-checked afterwards.
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
            isSwitching: snapshot.isSwitchingBranch, isDiscovering: snapshot.fetchStatus == .discovering,
            fetchingRemotes: snapshot.fetchingRemotes, remotes: snapshot.remotes,
            configuredRemote: snapshot.configuredUpstreamRemotes[branch.name])
    }

    /// The local branch as the row shows it, which a delete checks against before it runs.
    func branch(forTableRow index: Int) -> LocalBranch? {
        guard case let .local(branch)? = row(forTableRow: index)?.source else { return nil }
        return branch
    }

    /// What activating the row does, or nil when it can't be activated: the current
    /// branch is already checked out, a switch in flight locks every row until it settles,
    /// a branch being deleted can't be checked out, and a remote branch whose name a local
    /// branch has would collide with it.
    func activation(forTableRow index: Int) -> BranchActivation? {
        guard !snapshot.isSwitchingBranch, let row = row(forTableRow: index), row.blockedReason == nil else {
            return nil
        }
        switch row.source {
        case let .local(branch):
            guard row.kind != .current, branch.name != Self.deleting(snapshot) else { return nil }
            return .switchTo(name: branch.name)
        case let .remote(branch):
            return .checkoutTracking(branch)
        }
    }

    func canActivate(tableRow index: Int) -> Bool {
        activation(forTableRow: index) != nil
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

    /// Keeps the highlight by identity. When its row goes, a neighbour takes it, so the
    /// highlight stays where the reader was looking rather than jumping to the top.
    private mutating func keepHighlight(oldItems: [BranchPickerItem]) {
        let listed = Set(rows.map(\.id))
        if let highlightedRow, listed.contains(highlightedRow) { return }
        highlightedRow =
            highlightedRow.flatMap { Self.neighbour(of: $0, in: oldItems, listed: listed) }
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
        items = Self.makeItems(snapshot: snapshot, grouping: grouping, query: query)
        highlightedRow = Self.initialHighlight(items: items, query: query)
        return .reloadAll
    }

    // MARK: Navigation

    /// Moves `offset` branch rows from the highlight, clamped at both ends.
    private mutating func move(by offset: Int) {
        let positions = items.indices.filter { items[$0].row != nil }
        guard !positions.isEmpty else { return }
        let current = highlightedTableRow.flatMap { positions.firstIndex(of: $0) } ?? 0
        let target = positions[min(max(current + offset, 0), positions.count - 1)]
        highlightedRow = items[target].row?.id
    }

    mutating func moveUp() {
        move(by: -1)
    }

    mutating func moveDown() {
        move(by: 1)
    }

    mutating func moveToFirst() {
        highlightedRow = rows.first?.id
    }

    mutating func moveToLast() {
        highlightedRow = rows.last?.id
    }

    /// Headers and out-of-range rows are ignored. Returns whether the highlight moved.
    @discardableResult
    mutating func highlight(tableRow index: Int) -> Bool {
        guard let row = row(forTableRow: index), row.id != highlightedRow else { return false }
        highlightedRow = row.id
        return true
    }
}
