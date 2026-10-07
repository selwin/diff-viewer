import Foundation
import Testing

@testable import DiffViewer

/// London, with "now" pinned to Saturday 19 September 2026 at 14:02.
struct BranchPickerStateTests {
    private static let timeZone = TimeZone(identifier: "Europe/London")!
    private static let now = at(19, 14, 2)
    private let grouping = CommitDayGrouping(
        calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"),
        timeZone: BranchPickerStateTests.timeZone, now: BranchPickerStateTests.now)

    /// A London time in September 2026.
    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private let main = localBranch("main", tipCommittedAt: at(19, 13))
    private let feature = localBranch("feature", tipCommittedAt: at(19, 12))
    private let old = localBranch("old", tipCommittedAt: at(18, 9))

    private func snapshot(
        headState: HeadState? = .named("main"), branches: [LocalBranch], readStatus: BranchReadStatus = .loaded,
        isSwitchingBranch: Bool = false, fetchStatus: FetchStatus = .idle,
        activeSync: ActiveSync? = nil, fetchingRemotes: Set<String> = [], remotes: [String] = [],
        configuredUpstreamRemotes: [String: String] = [:], lastFetchRound: FetchRound? = nil,
        remoteBranches: [RemoteBranch] = [], newRemoteBranches: Set<String> = []
    ) -> BranchPickerSnapshot {
        BranchPickerSnapshot(
            headState: headState, branches: branches, readStatus: readStatus, isSwitchingBranch: isSwitchingBranch,
            fetchStatus: fetchStatus, activeSync: activeSync, fetchingRemotes: fetchingRemotes, remotes: remotes,
            configuredUpstreamRemotes: configuredUpstreamRemotes, lastFetchRound: lastFetchRound,
            remoteBranches: remoteBranches, newRemoteBranches: newRemoteBranches)
    }

    private func state(_ snapshot: BranchPickerSnapshot, tab: BranchPickerTab = .switchBranch) -> BranchPickerState {
        BranchPickerState(snapshot: snapshot, grouping: grouping, tab: tab)
    }

    /// The table row of `id`.
    private func index(_ id: BranchRowID, in picker: BranchPickerState) throws -> Int {
        try #require(picker.items.firstIndex { $0.row?.id == id })
    }

    /// Headers by title and branches by name, in table order.
    private func layout(_ picker: BranchPickerState) -> [String] {
        picker.items.map { item in
            switch item {
            case let .header(group): "# \(group.title)"
            case let .branch(row): row.name
            }
        }
    }

    // MARK: Groups

    @Test func sectionsAreNewestFirstAndEmptyOnesAreLeftOut() {
        let thisWeek = localBranch("this-week", tipCommittedAt: Self.at(15, 9))
        let older = localBranch("older", tipCommittedAt: Self.at(12, 9))
        let picker = state(snapshot(branches: [older, thisWeek, feature, main]))
        #expect(layout(picker) == ["# Today", "main", "feature", "# This week", "this-week", "# Older", "older"])
    }

    /// The current branch keeps its date's place; only its kind marks it.
    @Test func rowsWithinASectionAreNewestFirstThenByName() {
        let sameTime = localBranch("aardvark", tipCommittedAt: Self.at(19, 12))
        let picker = state(snapshot(headState: .named("feature"), branches: [old, feature, main, sameTime]))
        #expect(layout(picker) == ["# Today", "main", "aardvark", "feature", "# Yesterday", "old"])
        #expect(picker.rows.map(\.kind) == [.local, .local, .current, .local])
    }

    @Test func remoteOnlyBranchesJoinTheSections() {
        let remote = remoteBranch("release", tipCommittedAt: Self.at(18, 12))
        let picker = state(snapshot(branches: [main, old], remotes: ["origin"], remoteBranches: [remote]))
        #expect(layout(picker) == ["# Today", "main", "# Yesterday", "release", "old"])
        #expect(picker.rows.map(\.kind) == [.current, .remoteOnly, .local])
    }

    /// A remote branch a local branch tracks is the local row.
    @Test func aTrackedRemoteBranchIsNotListedAgain() {
        let tracked = localBranch("feature", upstream: upstream("origin/feature"), tipCommittedAt: Self.at(19, 12))
        let picker = state(
            snapshot(branches: [main, tracked], remotes: ["origin"], remoteBranches: [remoteBranch("feature")]))
        #expect(layout(picker) == ["# Today", "main", "feature"])
    }

    // MARK: Row text

    @Test func subtitlesNameTheAuthorAndTheTime() {
        let today = localBranch("today", tipCommittedAt: Self.at(19, 9, 5), tipCommitAuthor: "Me")
        let thisWeek = localBranch("this-week", tipCommittedAt: Self.at(15, 9), tipCommitAuthor: "Alice")
        let remote = remoteBranch("remote", tipCommittedAt: Self.at(1, 9), tipCommitAuthor: "Bob")
        let taken = snapshot(branches: [today, thisWeek], remoteBranches: [remote])
        #expect(state(taken).rows.map(\.subtitle) == ["Me · 09:05", "Alice · Tue", "Bob · 1 Sep"])
    }

    @Test func eachBranchStateHasItsStatus() {
        let branches = [
            localBranch("none", tipCommittedAt: Self.now),
            localBranch("hidden", tipCommittedAt: Self.now - 1),
            localBranch("gone", upstream: upstream("origin/gone", tracking: .gone), tipCommittedAt: Self.now - 2),
            localBranch("synced", upstream: upstream("origin/synced"), tipCommittedAt: Self.now - 3),
            localBranch(
                "apart", upstream: upstream("origin/apart", tracking: .counts(ahead: 2, behind: 3)),
                tipCommittedAt: Self.now - 4),
        ]
        let remotes = [
            remoteBranch("fresh", tipCommittedAt: Self.now - 5), remoteBranch("known", tipCommittedAt: Self.now - 6),
        ]
        let picker = state(
            snapshot(
                headState: .named("elsewhere"), branches: branches, configuredUpstreamRemotes: ["hidden": "origin"],
                remoteBranches: remotes, newRemoteBranches: ["refs/remotes/origin/fresh"]))
        let statuses = picker.rows.map(\.status)
        #expect(
            statuses == [
                .notPublished, .upstreamNotFetched, .upstreamGone, .none, .counts(ahead: 2, behind: 3), .new, .none,
            ])
        #expect(
            statuses.map(\.text) == [
                "Not published", "Upstream not fetched", "Remote gone", "", "2 ahead · 3 behind", "New", "",
            ])
        #expect(statuses.map(\.isAccent) == [false, false, false, false, false, true, false])
    }

    /// A local branch never reads as new, even if its name was just fetched elsewhere.
    @Test func onlyRemoteOnlyRowsAreNew() {
        let picker = state(snapshot(branches: [main], newRemoteBranches: ["refs/remotes/origin/main"]))
        #expect(picker.rows.map(\.status) == [.notPublished])
    }

    // MARK: Remote-only names

    @Test func thePublishRemotesPrefixIsDroppedUnlessANameCollides() throws {
        let remotes = [
            remoteBranch("foo", tipCommittedAt: Self.now),
            remoteBranch("foo", remote: "upstream", tipCommittedAt: Self.now),
            remoteBranch("main", tipCommittedAt: Self.now - 1),
        ]
        let picker = state(snapshot(branches: [main], remotes: ["origin", "upstream"], remoteBranches: remotes))
        #expect(picker.rows.map(\.name) == ["foo", "upstream/foo", "origin/main", "main"])
        let colliding = try index(.remote(ref: "refs/remotes/origin/main"), in: picker)
        #expect(picker.blockedReason(forTableRow: colliding) == "A local branch named main already exists")
        #expect(!picker.canActivate(tableRow: colliding))
        #expect(picker.activation(forTableRow: colliding) == nil)
    }

    /// Before a round lists the remotes, the ones the remote branches name decide.
    @Test func remoteBranchesStandInForUnlistedRemotes() {
        let picker = state(snapshot(branches: [main], remoteBranches: [remoteBranch("foo", remote: "fork")]))
        #expect(picker.rows.map(\.name) == ["main", "foo"], "fork is the only remote")
    }

    // MARK: Activation

    @Test func activationFollowsTheRowKind() throws {
        let remote = remoteBranch("release", tipCommittedAt: Self.at(18, 12))
        let picker = state(snapshot(branches: [main, feature], remotes: ["origin"], remoteBranches: [remote]))
        #expect(try picker.activation(forTableRow: index(.local(name: "main"), in: picker)) == nil, "current")
        let featureRow = try index(.local(name: "feature"), in: picker)
        #expect(picker.activation(forTableRow: featureRow) == .switchTo(name: "feature"))
        let remoteRow = try index(.remote(ref: remote.ref), in: picker)
        #expect(picker.activation(forTableRow: remoteRow) == .checkoutTracking(remote))
        #expect(picker.activation(forTableRow: 0) == nil, "a header")
        #expect(picker.activation(forTableRow: 99) == nil)
    }

    @Test func noRowActivatesWhileASwitchIsInFlight() {
        let picker = state(
            snapshot(branches: [main, feature], isSwitchingBranch: true, remoteBranches: [remoteBranch("r")]))
        #expect(picker.items.indices.allSatisfy { !picker.canActivate(tableRow: $0) })
    }

    @Test func theBranchBeingDeletedCannotBeActivated() throws {
        let deleting = ActiveSync(branch: "feature", operation: .delete)
        let picker = state(snapshot(branches: [main, feature, old], activeSync: deleting))
        #expect(try !picker.canActivate(tableRow: index(.local(name: "feature"), in: picker)))
        #expect(try picker.canActivate(tableRow: index(.local(name: "old"), in: picker)))
        let pushing = state(
            snapshot(branches: [main, feature], activeSync: ActiveSync(branch: "feature", operation: .push)))
        #expect(try pushing.canActivate(tableRow: index(.local(name: "feature"), in: pushing)))
    }

    // MARK: Highlight

    // MARK: Initial selection

    /// The first branch that isn't current, past the current one and its header.
    @Test func theFirstRowIsSelectedOnOpen() {
        let picker = state(snapshot(branches: [main, feature]))
        #expect(picker.highlightedRow == .local(name: "feature"))
        let detached = state(snapshot(headState: .detached(sha: objectID("x")), branches: [main]))
        #expect(detached.highlightedRow == .local(name: "main"))
    }

    /// A picker opened before the read lands selects the first row once it arrives, and a
    /// later refresh keeps it.
    @Test func theFirstRowIsSelectedWhenBranchesArriveAfterOpen() {
        var picker = state(snapshot(headState: nil, branches: [], readStatus: .unread))
        #expect(picker.highlightedRow == nil)
        _ = picker.apply(snapshot(branches: [main, feature]))
        #expect(picker.highlightedRow == .local(name: "feature"))
        #expect(picker.isSelectionResting)
        let newer = localBranch("newer", tipCommittedAt: Self.at(19, 14))
        _ = picker.apply(snapshot(branches: [main, feature, newer]))
        #expect(picker.highlightedRow == .local(name: "feature"))
    }

    // MARK: Highlight

    /// Every move steps over headers and the current branch.
    @Test func movesSkipHeadersAndTheCurrentBranch() {
        let older = localBranch("older", tipCommittedAt: Self.at(12, 9))
        let branches = [main, feature, old, older]
        var picker = state(snapshot(headState: .named("feature"), branches: branches))
        #expect(layout(picker) == ["# Today", "main", "feature", "# Yesterday", "old", "# Older", "older"])
        #expect(picker.highlightedRow == .local(name: "main"))
        picker.moveUp()
        #expect(picker.highlightedRow == .local(name: "main"), "nothing above the first row, and never the header")
        picker.moveDown()
        #expect(picker.highlightedRow == .local(name: "old"), "past the current branch")
        picker.moveUp()
        #expect(picker.highlightedRow == .local(name: "main"))
        picker.moveToLast()
        picker.moveDown()
        #expect(picker.highlightedTableRow == 6, "nothing below the last row")

        var onMain = state(snapshot(branches: branches))
        onMain.moveToFirst()
        #expect(onMain.highlightedRow == .local(name: "feature"))
        onMain.moveToLast()
        onMain.moveToFirst()
        #expect(onMain.highlightedRow == .local(name: "feature"))
    }

    /// Switch lists the current branch but doesn't act on it, so it takes no highlight.
    @Test func theCurrentRowIsNeverHighlightedOrActivated() throws {
        var picker = state(snapshot(branches: [main, old]))
        let current = try index(.local(name: "main"), in: picker)
        #expect(!picker.canHighlight(tableRow: current))
        #expect(!picker.canActivate(tableRow: current))
        let moved = picker.highlight(tableRow: current)
        #expect(!moved)
        #expect(picker.highlightedRow == .local(name: "old"))
    }

    @Test func headersTakeNoHighlight() {
        var picker = state(snapshot(branches: [main, feature, old]))
        #expect(!picker.canHighlight(tableRow: 0))
        #expect(picker.canHighlight(tableRow: 4))
        #expect(!picker.canHighlight(tableRow: 9))
        let movedToOld = picker.highlight(tableRow: 4)
        #expect(movedToOld)
        #expect(picker.highlightedRow == .local(name: "old"))
        let movedToHeader = picker.highlight(tableRow: 3)
        #expect(!movedToHeader)
        #expect(picker.highlightedRow == .local(name: "old"), "the Yesterday header is ignored")
    }

    /// The pointer resting on a row the keyboard left takes the highlight back when it
    /// moves, and a move within the highlighted row changes nothing.
    @Test func hoverTakesTheHighlightBackFromTheKeyboard() {
        var picker = state(snapshot(branches: [main, feature, old]))
        let movedToFeature = picker.highlight(tableRow: 2)
        #expect(movedToFeature)
        let movedWithinFeature = picker.highlight(tableRow: 2)
        #expect(!movedWithinFeature, "already on feature")
        picker.moveDown()
        #expect(picker.highlightedRow == .local(name: "old"))
        let movedBack = picker.highlight(tableRow: 2)
        #expect(movedBack)
        #expect(picker.highlightedRow == .local(name: "feature"))
    }

    /// The same branch name on two remotes is two rows, each with its own highlight.
    @Test func eachRemotesRowKeepsItsHighlightAcrossAReload() throws {
        let origin = remoteBranch("foo", tipCommittedAt: Self.at(19, 10))
        let fork = remoteBranch("foo", remote: "upstream", tipCommittedAt: Self.at(19, 10))
        let before = snapshot(branches: [main], remotes: ["origin", "upstream"], remoteBranches: [origin, fork])
        let newer = localBranch("newer", tipCommittedAt: Self.at(19, 14))
        let after = snapshot(
            branches: [main, newer], remotes: ["origin", "upstream"], remoteBranches: [origin, fork])
        for branch in [origin, fork] {
            var picker = state(before)
            picker.highlight(tableRow: try index(.remote(ref: branch.ref), in: picker))
            #expect(picker.apply(after).rows == .update(removed: [], inserted: [1], refreshed: []))
            #expect(picker.highlightedRow == .remote(ref: branch.ref))
        }
    }

    /// The highlight stays where the reader was looking: on the branch that followed the
    /// removed one, even across a header, or on the one before when it was last.
    @Test func aRemovedHighlightMovesToTheNextBranchElseThePrevious() {
        let older = localBranch("older", tipCommittedAt: Self.at(12, 9))
        var picker = state(snapshot(branches: [main, feature, old, older]))
        #expect(picker.highlightedRow == .local(name: "feature"))
        _ = picker.apply(snapshot(branches: [main, old, older]))
        #expect(picker.highlightedRow == .local(name: "old"), "the next branch, across a header")

        picker.moveToLast()
        _ = picker.apply(snapshot(branches: [main, old]))
        #expect(picker.highlightedRow == .local(name: "old"), "the previous branch when it was last")
    }

    /// A highlighted branch that becomes current gives way to its neighbour; with none
    /// left nothing is highlighted until rows return, when the first one takes it.
    @Test func aHighlightWithNoNeighbourLeftWaitsForTheFirstRow() {
        var picker = state(snapshot(branches: [main, feature, old]))
        _ = picker.apply(snapshot(headState: .named("feature"), branches: [main, feature, old]))
        #expect(picker.highlightedRow == .local(name: "old"), "feature is current now")

        _ = picker.apply(snapshot(branches: [main]))
        #expect(picker.highlightedRow == nil, "only the current branch is left")
        _ = picker.apply(snapshot(branches: [main, feature, old]))
        #expect(picker.highlightedRow == .local(name: "feature"))
    }

    // MARK: New Branch highlight

    @Test func highlightingNewBranchTakesTheHighlightOffTheRows() {
        var picker = state(snapshot(branches: [main, feature]))
        let moved = picker.highlightNewBranch()
        #expect(moved)
        #expect(picker.isNewBranchHighlighted)
        #expect(picker.highlightedRow == nil)
        #expect(picker.highlightedTableRow == nil)
        let movedAgain = picker.highlightNewBranch()
        #expect(!movedAgain, "already highlighted")
    }

    @Test func aBranchTakesTheHighlightBackFromNewBranch() {
        var picker = state(snapshot(branches: [main, old]))
        picker.highlightNewBranch()
        let movedToHeader = picker.highlight(tableRow: 0)
        let movedPastEnd = picker.highlight(tableRow: 9)
        #expect(!movedToHeader && !movedPastEnd)
        #expect(picker.isNewBranchHighlighted, "headers and bad indexes change nothing")

        let movedToOld = picker.highlight(tableRow: 3)
        #expect(movedToOld)
        #expect(!picker.isNewBranchHighlighted)
        #expect(picker.highlightedRow == .local(name: "old"))
    }

    @Test func upLeavesNewBranchForTheLastBranchAndDownStays() {
        var picker = state(snapshot(branches: [main, old]))
        picker.highlightNewBranch()
        picker.moveDown()
        #expect(picker.isNewBranchHighlighted)
        #expect(picker.highlightedRow == nil)
        picker.moveUp()
        #expect(!picker.isNewBranchHighlighted)
        #expect(picker.highlightedRow == .local(name: "old"))

        var empty = state(snapshot(branches: []))
        empty.highlightNewBranch()
        empty.moveUp()
        #expect(empty.isNewBranchHighlighted)
    }

    @Test func jumpingToAnEndLeavesNewBranchOnlyWhenABranchTakesIt() {
        let jumps: [(jump: (inout BranchPickerState) -> Void, lands: BranchRowID)] = [
            ({ $0.moveToFirst() }, .local(name: "feature")), ({ $0.moveToLast() }, .local(name: "old")),
        ]
        for (jump, lands) in jumps {
            var picker = state(snapshot(branches: [main, feature, old]))
            picker.highlightNewBranch()
            jump(&picker)
            #expect(!picker.isNewBranchHighlighted)
            #expect(picker.highlightedRow == lands)

            var empty = state(snapshot(branches: []))
            empty.highlightNewBranch()
            jump(&empty)
            #expect(empty.isNewBranchHighlighted)
        }
    }

    /// A fetch or FSEvents refresh must not pull the highlight back onto the list.
    @Test func snapshotsKeepTheNewBranchHighlight() {
        var picker = state(snapshot(branches: [main, feature]))
        picker.highlightNewBranch()
        let newer = localBranch("newer", tipCommittedAt: Self.at(19, 14))
        for branches in [[main, feature, newer], [main], [newer, feature, main]] {
            _ = picker.apply(snapshot(branches: branches))
            #expect(picker.isNewBranchHighlighted)
            #expect(picker.highlightedRow == nil)
        }
    }

    @Test func aChangedQueryTakesTheHighlightBackToTheBestMatch() {
        var picker = state(snapshot(branches: [main, feature]))
        picker.highlightNewBranch()
        #expect(picker.setQuery("fe") == .reloadAll)
        #expect(!picker.isNewBranchHighlighted)
        #expect(picker.highlightedRow == .local(name: "feature"))
    }

    /// A search matching only the current branch selects nothing; a match arriving later
    /// takes the highlight.
    @Test func aSearchHighlightsAMatchThatArrivesLater() {
        let map = localBranch("map", tipCommittedAt: Self.at(19, 12))
        var picker = state(snapshot(branches: [main]))
        _ = picker.setQuery("ma")
        #expect(picker.highlightedRow == nil)
        _ = picker.apply(snapshot(branches: [main, map]))
        #expect(picker.highlightedRow == .local(name: "map"))
    }

    // MARK: Return with no matches

    @Test func aQueryMatchingNoBranchSelectsNewBranch() {
        var picker = state(snapshot(branches: [main, feature]))
        #expect(picker.setQuery("zzz") == .reloadAll)
        #expect(picker.isNewBranchHighlighted)
        #expect(picker.highlightedRow == nil)
        #expect(picker.isNewBranchEnabled)
    }

    /// Return on New Branch… does nothing while a switch runs, though the search still
    /// selects it.
    @Test func newBranchIsOffWhileASwitchRuns() {
        var picker = state(snapshot(branches: [main, feature], isSwitchingBranch: true))
        _ = picker.setQuery("zzz")
        #expect(picker.isNewBranchHighlighted)
        #expect(!picker.isNewBranchEnabled)
    }

    /// New Branch… stays selected when the matches come back, as for any refresh.
    @Test func aRefreshRemovingTheLastMatchSelectsNewBranch() {
        var picker = state(snapshot(branches: [main, feature]))
        _ = picker.setQuery("fe")
        _ = picker.apply(snapshot(branches: [main]))
        #expect(picker.isNewBranchHighlighted)
        _ = picker.apply(snapshot(branches: [main, feature]))
        #expect(picker.isNewBranchHighlighted)
        #expect(picker.highlightedRow == nil)
    }

    /// Switch lists the current branch, which can't be created again, so nothing is
    /// selected; Merge leaves it out, so New Branch… is.
    @Test func aSearchMatchingOnlyTheCurrentBranchSelectsCreateOnlyInMerge() {
        var switching = state(snapshot(branches: [main, feature, old]))
        _ = switching.setQuery("mai")
        #expect(layout(switching) == ["main"])
        #expect(switching.highlightedRow == nil)
        #expect(!switching.isNewBranchHighlighted)

        var merging = state(snapshot(branches: [main, feature, old]), tab: .merge)
        _ = merging.setQuery("mai")
        #expect(merging.items.isEmpty)
        #expect(merging.isNewBranchHighlighted)
    }

    @Test func anUnchangedQueryKeepsTheNewBranchHighlight() {
        var picker = state(snapshot(branches: [main, feature]))
        _ = picker.setQuery("fe")
        picker.highlightNewBranch()
        #expect(picker.setQuery(" fe ") == BranchTableChange.none)
        #expect(picker.isNewBranchHighlighted)
    }

    // MARK: Snapshots

    @Test func anUnchangedSnapshotChangesNothing() {
        let taken = snapshot(branches: [main, feature])
        var picker = state(taken)
        #expect(picker.apply(taken).rows == BranchTableChange.none)
    }

    /// The cells hold whether a row can activate, so a switch starting or ending has to
    /// reach every visible cell even though no row's content moved.
    @Test func aSwitchFlagChangeRefreshesEveryRowInPlace() throws {
        var picker = state(snapshot(branches: [main, feature], isSwitchingBranch: true))
        #expect(
            picker.apply(snapshot(branches: [main, feature])).rows
                == .refresh(IndexSet(integersIn: 0..<3)))
        #expect(try picker.canActivate(tableRow: index(.local(name: "feature"), in: picker)))
    }

    /// The cells hold whether a row can activate, so a delete starting has to reach them.
    @Test func aDeleteStartingOrEndingRefreshesOnlyItsRow() throws {
        var picker = state(snapshot(branches: [main, feature]))
        let row = try index(.local(name: "feature"), in: picker)
        let deleting = ActiveSync(branch: "feature", operation: .delete)
        #expect(
            picker.apply(snapshot(branches: [main, feature], activeSync: deleting)).rows
                == .refresh(IndexSet(integer: row)))
        #expect(
            picker.apply(snapshot(branches: [main, feature])).rows
                == .refresh(IndexSet(integer: row)))
    }

    @Test func changedCountsRefreshThatRowAndKeepTheHighlight() throws {
        var picker = state(snapshot(branches: [main, feature]))
        picker.moveDown()
        #expect(picker.highlightedRow == .local(name: "feature"))
        let row = try index(.local(name: "feature"), in: picker)

        let tracked = localBranch(
            "feature", upstream: upstream("origin/feature", tracking: .counts(ahead: 0, behind: 3)),
            tipCommittedAt: feature.tipCommittedAt)
        #expect(
            picker.apply(snapshot(branches: [main, tracked])).rows
                == .refresh(IndexSet(integer: row)))
        #expect(picker.row(forTableRow: row)?.status == .counts(ahead: 0, behind: 3))
        #expect(picker.highlightedRow == .local(name: "feature"))
    }

    /// Removed rows index the old items, so a header whose group empties goes with its row.
    @Test func aRemovedBranchIsRemovedWithItsEmptiedHeader() {
        var picker = state(snapshot(branches: [main, feature, old]))
        #expect(layout(picker) == ["# Today", "main", "feature", "# Yesterday", "old"])
        #expect(
            picker.apply(snapshot(branches: [main, old])).rows
                == .update(removed: [2], inserted: [], refreshed: []))
        #expect(
            picker.apply(snapshot(branches: [main])).rows == .update(removed: [2, 3], inserted: [], refreshed: []),
            "Yesterday's header and old")
        #expect(layout(picker) == ["# Today", "main"])
    }

    /// Inserted rows index the new items, a new group's header included.
    @Test func anAddedBranchIsInserted() {
        var picker = state(snapshot(branches: [main]))
        let remote = remoteBranch("release", tipCommittedAt: Self.at(18, 12))
        #expect(
            picker.apply(snapshot(branches: [main], remoteBranches: [remote])).rows
                == .update(removed: [], inserted: [2, 3], refreshed: []))
        #expect(layout(picker) == ["# Today", "main", "# Yesterday", "release"])
    }

    /// A row whose tip moved leaves one place and arrives at another; the change replays
    /// on the old rows to give the new ones.
    @Test func aMovedBranchIsARemovalAndAnInsertion() throws {
        var picker = state(snapshot(headState: .named("old"), branches: [main, feature, old]))
        let before = layout(picker)
        let movedMain = localBranch("main", tipCommittedAt: Self.at(18, 10))
        let change = picker.apply(snapshot(headState: .named("old"), branches: [movedMain, feature, old])).rows
        #expect(layout(picker) == ["# Today", "feature", "# Yesterday", "main", "old"])
        guard case let .update(removed, inserted, refreshed) = change else {
            Issue.record("expected an update, got \(change)")
            return
        }
        var replayed = before.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        for index in inserted { replayed.insert(layout(picker)[index], at: index) }
        #expect(replayed == layout(picker))
        #expect(refreshed.isEmpty)
        #expect(picker.highlightedRow == .local(name: "main"), "a moved row keeps the highlight")
    }

    /// Rows coming or going as a whole swap with the empty state, which has nothing to slide.
    @Test func aListAppearingOrEmptyingReloadsEverything() {
        var picker = state(snapshot(headState: nil, branches: [], readStatus: .unread))
        #expect(picker.apply(snapshot(branches: [main, feature])).rows == .reloadAll)
        #expect(picker.apply(snapshot(headState: nil, branches: [])).rows == .reloadAll)
    }

    // MARK: Query

    @Test func aQueryFiltersAndRanksTheRowsWithoutSections() {
        let safe = localBranch("safe", tipCommittedAt: Self.at(19, 14))
        let fern = localBranch("fern", tipCommittedAt: Self.at(19, 13, 59))
        let feed = localBranch("feed", tipCommittedAt: Self.at(19, 13))
        var picker = state(
            snapshot(branches: [main, feed, feature, old, safe, fern], remoteBranches: [remoteBranch("fetch")]))
        #expect(picker.setQuery("fe") == .reloadAll)
        // A word-start match beats a mid-word one; an equal score falls back to newest first,
        // then to the name when the tips are the same age.
        #expect(layout(picker) == ["fern", "feed", "feature", "fetch", "safe"])
        let matched = picker.rows.map { row in row.matchedRanges.map { String(row.name[$0]) } }
        #expect(matched == [["fe"], ["fe"], ["fe"], ["fe"], ["fe"]])
    }

    /// Only a snapshot's changes animate: a narrowing query, all removals, still reloads.
    @Test func clearingTheQueryBringsTheSectionsBack() {
        let aiTools = localBranch("ai-tools", tipCommittedAt: Self.at(19, 12))
        var picker = state(snapshot(branches: [main, aiTools, old]))
        let sections = ["# Today", "main", "ai-tools", "# Yesterday", "old"]

        #expect(picker.setQuery("ai") == .reloadAll)
        #expect(layout(picker) == ["ai-tools", "main"])
        #expect(picker.highlightedRow == .local(name: "ai-tools"), "the best match, though main is current")
        #expect(picker.setQuery("ai-t") == .reloadAll)
        #expect(layout(picker) == ["ai-tools"])
        #expect(picker.setQuery("") == .reloadAll)
        #expect(layout(picker) == sections)
        #expect(picker.rows.map(\.matchedRanges) == [[], [], []])
        #expect(picker.highlightedRow == .local(name: "ai-tools"), "clearing the query selects the first row")
    }

    @Test func theSameNormalizedQueryChangesNothing() {
        var picker = state(snapshot(branches: [main, feature, old]))
        #expect(picker.setQuery("   ") == BranchTableChange.none, "spaces alone are no query")
        #expect(layout(picker) == ["# Today", "main", "feature", "# Yesterday", "old"])
        #expect(picker.highlightedRow == .local(name: "feature"))
        #expect(picker.emptyState == nil)

        #expect(picker.setQuery("fe") == .reloadAll)
        #expect(picker.setQuery(" fe ") == BranchTableChange.none)
        #expect(picker.query == "fe")
    }

    @Test func aSnapshotDuringASearchKeepsTheFilter() {
        var picker = state(snapshot(branches: [main, feature]))
        _ = picker.setQuery("fe")
        let fetchFix = localBranch("fetch-fix", tipCommittedAt: Self.at(19, 13, 30))
        #expect(
            picker.apply(snapshot(branches: [main, feature, fetchFix, old])).rows
                == .update(removed: [], inserted: [0], refreshed: []))
        #expect(layout(picker) == ["fetch-fix", "feature"])
    }

    @Test func aQueryMatchingNothingSaysSo() {
        var picker = state(snapshot(branches: [main, feature]))
        _ = picker.setQuery("zzz")
        #expect(picker.items.isEmpty)
        #expect(picker.emptyState == .noMatches)

        var remoteOnly = state(snapshot(branches: [], remoteBranches: [remoteBranch("r")]))
        _ = remoteOnly.setQuery("zzz")
        #expect(remoteOnly.emptyState == .noMatches)
        var noBranches = state(snapshot(branches: []))
        _ = noBranches.setQuery("zzz")
        #expect(noBranches.emptyState == .noBranches)
        var unread = state(snapshot(headState: nil, branches: [], readStatus: .unread))
        _ = unread.setQuery("zzz")
        #expect(unread.emptyState == .loading)
        var failed = state(snapshot(headState: nil, branches: [], readStatus: .failed))
        _ = failed.setQuery("zzz")
        #expect(failed.emptyState == .failed)
    }

    /// Merge with only the current branch has nothing to offer, whatever the query; a
    /// search for the current branch among others matches nothing.
    @Test func mergeSaysWhenThereIsNothingToMerge() {
        var alone = state(snapshot(branches: [main]), tab: .merge)
        #expect(alone.emptyState == .noBranchesToMerge)
        _ = alone.setQuery("zzz")
        #expect(alone.emptyState == .noBranchesToMerge)

        var others = state(snapshot(branches: [main, feature]), tab: .merge)
        _ = others.setQuery("mai")
        #expect(others.emptyState == .noMatches)
    }

    // MARK: Tabs

    /// A name collision only stops a checkout; a merge from the same remote branch is fine.
    @Test func blockedReasonsFollowTheTab() throws {
        let colliding = remoteBranch("main", tipCommittedAt: Self.at(19, 12))
        let taken = snapshot(branches: [main, feature], remotes: ["origin"], remoteBranches: [colliding])
        let switching = state(taken)
        let remoteRow = try index(.remote(ref: colliding.ref), in: switching)
        #expect(switching.blockedReason(forTableRow: remoteRow) == "A local branch named main already exists")
        #expect(switching.activation(forTableRow: remoteRow) == nil)
        let merging = state(taken, tab: .merge)
        #expect(try merging.blockedReason(forTableRow: index(.remote(ref: colliding.ref), in: merging)) == nil)
    }

    /// A Merge row carries everything the sheet needs, pinned to the tips as read.
    @Test func mergeRowsActivateWithTheirTargets() throws {
        let head = localBranch("main", tipSha: objectID("head"), tipCommittedAt: Self.at(19, 13))
        let local = localBranch("feature", tipSha: objectID("tip"), tipCommittedAt: Self.at(19, 12))
        let remote = remoteBranch("main", tipSha: objectID("remote"), tipCommittedAt: Self.at(19, 11))
        let taken = snapshot(branches: [head, local], remotes: ["origin"], remoteBranches: [remote])
        let merging = state(taken, tab: .merge)

        let localRow = try index(.local(name: "feature"), in: merging)
        #expect(
            merging.activation(forTableRow: localRow)
                == .merge(
                    MergeTarget(
                        sourceName: "feature", sourceRef: "refs/heads/feature", sourceTipSha: objectID("tip"),
                        destinationBranch: "main", destinationTipSha: objectID("head"))))
        let remoteRow = try index(.remote(ref: remote.ref), in: merging)
        #expect(
            merging.activation(forTableRow: remoteRow)
                == .merge(
                    MergeTarget(
                        sourceName: "origin/main", sourceRef: remote.ref, sourceTipSha: objectID("remote"),
                        destinationBranch: "main", destinationTipSha: objectID("head"))),
            "a name taken locally doesn't block a merge")
        #expect(merging.activation(forTableRow: 0) == nil, "a header")
        #expect(merging.canActivate(tableRow: localRow))

        let switching = state(
            snapshot(branches: [head, local], isSwitchingBranch: true), tab: .merge)
        #expect(switching.items.indices.allSatisfy { switching.activation(forTableRow: $0) == nil })
    }

    /// The current row says its status like any other; its kind marks it as current.
    @Test func trailingLabelsAreStatusesInSwitchAndPreviewsInMerge() throws {
        let gone = localBranch("gone", upstream: upstream("origin/gone", tracking: .gone))
        var picker = state(snapshot(branches: [main, feature, gone]))
        let current = try index(.local(name: "main"), in: picker)
        #expect(picker.trailingLabel(forTableRow: current) == BranchRowLabel(text: "Not published", style: .secondary))
        #expect(
            try picker.trailingLabel(forTableRow: index(.local(name: "gone"), in: picker))
                == BranchRowLabel(text: "Remote gone", style: .upstreamGone))
        picker.setTab(.merge)
        #expect(try picker.trailingLabel(forTableRow: index(.local(name: "feature"), in: picker)) == nil)
    }

    // MARK: Tab filtering

    /// Merge leaves out the current branch before grouping, so its section goes too.
    @Test func mergeLeavesOutTheCurrentBranchAndItsEmptiedSection() {
        let picker = state(snapshot(branches: [main, old]), tab: .merge)
        #expect(layout(picker) == ["# Yesterday", "old"])
        #expect(picker.highlightedRow == .local(name: "old"))
    }

    /// Every path that rebuilds the rows keeps Merge's filter, and Switch brings it back.
    @Test func everyRebuildFollowsTheTab() {
        var picker = state(snapshot(branches: [main, feature, old]))
        picker.setTab(.merge)
        #expect(layout(picker) == ["# Today", "feature", "# Yesterday", "old"])
        _ = picker.apply(snapshot(branches: [main, old]))
        #expect(layout(picker) == ["# Yesterday", "old"])
        _ = picker.setQuery("m")
        #expect(picker.rows.isEmpty, "main matches but isn't listed")
        _ = picker.setQuery("")
        picker.setTab(.switchBranch)
        #expect(layout(picker) == ["# Today", "main", "# Yesterday", "old"])
    }

    /// A tab change starts the selection over at the first row, as a fresh open would.
    @Test func aTabChangeSelectsTheFirstRow() {
        var picker = state(snapshot(branches: [main, feature, old]))
        picker.moveToLast()
        picker.highlightNewBranch()
        picker.setTab(.merge)
        #expect(!picker.isNewBranchHighlighted)
        #expect(picker.highlightedRow == .local(name: "feature"))
        #expect(picker.isSelectionResting)
    }

    /// Merge falling back to Switch reloads every row and selects the first.
    @Test func losingMergeFallsBackToSwitchOnTheFirstRow() {
        var picker = state(snapshot(branches: [main, feature, old]), tab: .merge)
        picker.moveToLast()
        let change = picker.apply(snapshot(headState: .detached(sha: objectID("x")), branches: [main, feature, old]))
        #expect(change.rows == .reloadAll)
        #expect(picker.tab == .switchBranch)
        #expect(layout(picker) == ["# Today", "main", "feature", "# Yesterday", "old"])
        #expect(picker.highlightedRow == .local(name: "main"))
        #expect(picker.isSelectionResting)
    }

    @Test func aMergeRowShowsThePreviewItIsGiven() throws {
        let picker = state(snapshot(branches: [main, feature]), tab: .merge)
        let other = try index(.local(name: "feature"), in: picker)
        #expect(
            picker.trailingLabel(forTableRow: other, preview: .conflicts(commits: 1, paths: ["a"]))
                == BranchRowLabel(text: "Conflict in 1 file", style: .warning))
    }

    // MARK: Merge preview keys

    /// Two branches at one tip share a key, and a lookup finds both of their rows.
    @Test func branchesAtTheSameTipShareAKey() throws {
        let head = localBranch("main", tipSha: objectID("head"), tipCommittedAt: Self.at(19, 13))
        let local = localBranch("feature", tipSha: objectID("tip"), tipCommittedAt: Self.at(19, 12))
        let remote = remoteBranch("release", tipSha: objectID("tip"), tipCommittedAt: Self.at(19, 11))
        let picker = state(
            snapshot(branches: [head, local], remotes: ["origin"], remoteBranches: [remote]), tab: .merge)
        let key = MergePreviewKey(headSha: objectID("head"), sourceTipSha: objectID("tip"))
        let rows = try [index(.local(name: "feature"), in: picker), index(.remote(ref: remote.ref), in: picker)]
        #expect(rows.map { picker.mergePreviewKey(forTableRow: $0) } == [key, key])
        #expect(picker.tableRows(matching: key) == rows)
        #expect(picker.requestedKeys(visibleRows: 0..<picker.items.count) == [key])
    }

    @Test func aNewHeadGivesTheRowsNewKeys() {
        let feature = localBranch("feature", tipSha: objectID("tip"), tipCommittedAt: Self.at(19, 12))
        let oldHead = localBranch("main", tipSha: objectID("old"), tipCommittedAt: Self.at(19, 13))
        let newHead = localBranch("main", tipSha: objectID("new"), tipCommittedAt: Self.at(19, 13))
        var picker = state(snapshot(branches: [oldHead, feature]), tab: .merge)
        _ = picker.apply(snapshot(branches: [newHead, feature]))
        #expect(
            picker.requestedKeys(visibleRows: 0..<picker.items.count)
                == [MergePreviewKey(headSha: objectID("new"), sourceTipSha: objectID("tip"))])
    }

    /// Past the end is clamped, and only Merge's rows have keys.
    @Test func theSwitchTabHasNoKeys() throws {
        var picker = state(snapshot(branches: [main, feature]), tab: .merge)
        #expect(picker.requestedKeys(visibleRows: 0..<50).count == 1)
        picker.setTab(.switchBranch)
        #expect(picker.requestedKeys(visibleRows: 0..<picker.items.count).isEmpty)
    }

    /// Merging needs a checked-out branch: a detached or unborn HEAD, or a read that
    /// hasn't loaded, leaves Switch the only tab.
    @Test func mergeNeedsACheckedOutBranch() {
        let unavailable = [
            snapshot(headState: .detached(sha: objectID("x")), branches: [main]),
            snapshot(headState: .named("unborn"), branches: [main]),
            snapshot(branches: [main], readStatus: .failed),
            snapshot(headState: nil, branches: [], readStatus: .unread),
        ]
        for taken in unavailable {
            var picker = state(taken)
            #expect(!picker.isMergeAvailable)
            let changed = picker.setTab(.merge)
            #expect(!changed)
            #expect(state(taken, tab: .merge).tab == .switchBranch)
        }

        var picker = state(snapshot(branches: [main]))
        let changed = picker.setTab(.merge)
        let changedAgain = picker.setTab(.merge)
        #expect(changed)
        #expect(!changedAgain, "already on Merge")
        _ = picker.apply(snapshot(headState: .detached(sha: objectID("x")), branches: [main]))
        #expect(picker.tab == .switchBranch)
    }

    // MARK: Header

    @Test(
        arguments: [(BranchPickerSnapshot, String, [String])]([
            (
                BranchPickerSnapshot(headState: nil, branches: [], readStatus: .unread, isSwitchingBranch: false),
                "Loading…", []
            ),
            (
                BranchPickerSnapshot(headState: nil, branches: [], readStatus: .failed, isSwitchingBranch: false),
                "Couldn't read branches", []
            ),
            (
                BranchPickerSnapshot(
                    headState: .detached(sha: String(repeating: "a", count: 40)), branches: [], readStatus: .loaded,
                    isSwitchingBranch: false),
                "Detached aaaaaaa", []
            ),
            (named([localBranch("main")]), "main", ["Not published"]),
            (
                BranchPickerSnapshot(
                    headState: .named("main"), branches: [localBranch("main")], readStatus: .loaded,
                    isSwitchingBranch: false, configuredUpstreamRemotes: ["main": "origin"]),
                "main", ["Upstream not fetched"]
            ),
            (
                named([localBranch("main", upstream: upstream("origin/main", tracking: .gone))]), "main",
                ["Remote gone"]
            ),
            (named([localBranch("main", upstream: upstream("origin/main"))]), "main", ["Up to date"]),
            (
                named([localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 1, behind: 2)))]),
                "main", ["1 ahead · 2 behind"]
            ),
            // HEAD on a branch the list does not carry: nothing is known about its upstream.
            (named([localBranch("other")]), "main", []),
        ]))
    func headerTextFollowsHeadAndTheList(taken: BranchPickerSnapshot, title: String, detail: [String]) {
        let header = state(taken).headerText
        #expect(header.title == title)
        #expect(header.detailParts == detail)
    }

    /// A loaded read with HEAD on `main`.
    private static func named(_ branches: [LocalBranch]) -> BranchPickerSnapshot {
        BranchPickerSnapshot(
            headState: .named("main"), branches: branches, readStatus: .loaded, isSwitchingBranch: false)
    }

    @Test func theHeaderDetailHidesZeroCountsAndEndsWithTheFetch() {
        let ahead = localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 2, behind: 0)))
        let header = state(snapshot(branches: [ahead])).headerText
        #expect(header.detail(fetch: nil) == "2 ahead")
        #expect(header.detail(fetch: BranchPickerFetchText(text: "Fetched just now")) == "2 ahead · Fetched just now")
        let synced = state(snapshot(branches: [localBranch("main", upstream: upstream("origin/main"))])).headerText
        #expect(
            synced.detail(fetch: BranchPickerFetchText(text: "Fetched just now")) == "Up to date · Fetched just now")
        let detached = state(snapshot(headState: .detached(sha: objectID("x")), branches: [])).headerText
        #expect(detached.detail(fetch: BranchPickerFetchText(text: "Fetching…")) == "Fetching…")
    }

    @Test func theHeaderOffersTheCurrentBranchsPullAndPush() {
        let ahead = localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 2, behind: 0)))
        let header = state(snapshot(branches: [ahead, feature])).headerText
        #expect(header.branch == "main")
        #expect(header.buttons == RowSyncButtons(pull: .hidden, push: .enabled))
        let detached = state(snapshot(headState: .detached(sha: objectID("x")), branches: [ahead])).headerText
        #expect(detached.branch == nil)
        #expect(detached.buttons == .hidden)
    }

    /// The name is copyable before the list carries it, though no sync buttons act on it yet.
    @Test func theHeaderCopiesANamedHeadListedOrNot() {
        #expect(state(snapshot(branches: [main])).headerText.copyableName == "main")
        let unlisted = state(snapshot(branches: [feature])).headerText
        #expect(unlisted.copyableName == "main")
        #expect(unlisted.branch == nil)
        let detached = state(snapshot(headState: .detached(sha: objectID("x")), branches: [main])).headerText
        #expect(detached.copyableName == nil)
    }

    /// Tab skips header buttons that are hidden or can't act.
    @Test func theHeaderFocusOrderHoldsOnlyButtonsThatCanAct() {
        let ahead = localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 2, behind: 0)))
        #expect(state(snapshot(branches: [ahead])).headerText.focusOrder == [.copy, .fetch, .push])
        let diverged = localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 1, behind: 1)))
        #expect(
            state(snapshot(branches: [diverged])).headerText.focusOrder == [.copy, .fetch, .pull],
            "Push says pull first")
        let fetching = state(snapshot(branches: [diverged], fetchStatus: .fetching)).headerText
        #expect(fetching.focusOrder == [.copy, .pull], "Fetch is disabled while a round runs")
        let detached = state(snapshot(headState: .detached(sha: objectID("x")), branches: [ahead])).headerText
        #expect(detached.focusOrder == [.fetch], "A detached HEAD has no name to copy")
    }

    // MARK: Fetching

    @Test func fetchIsWithheldWhileARoundOrASyncRuns() {
        for status in [FetchStatus.discovering, .fetching] {
            let header = state(snapshot(branches: [main], fetchStatus: status)).headerText
            #expect(header.showsSpinner)
            #expect(!header.canFetch)
        }
        let idle = state(snapshot(branches: [main])).headerText
        #expect(!idle.showsSpinner)
        #expect(idle.canFetch)
        // A header with no HEAD yet still reports the fetch.
        #expect(
            state(snapshot(headState: nil, branches: [], readStatus: .unread, fetchStatus: .discovering))
                .headerText.showsSpinner)
        // A round would not start beside a pull or push.
        let pulling = snapshot(branches: [main], activeSync: ActiveSync(branch: "main", operation: .pull))
        #expect(!state(pulling).headerText.canFetch)
    }

    @Test func theFetchTextFollowsTheSnapshot() {
        let round = FetchRound(outcomes: ["origin": .fetched(at: Self.now - 120)])
        let fetched = state(snapshot(branches: [main], lastFetchRound: round))
        #expect(fetched.fetchText(now: Self.now) == BranchPickerFetchText(text: "Fetched 2 min ago"))
        #expect(
            state(snapshot(branches: [main], fetchStatus: .fetching, lastFetchRound: round)).fetchText(now: Self.now)
                == BranchPickerFetchText(text: "Fetching…"))
        #expect(
            state(snapshot(branches: [main], readStatus: .failed, lastFetchRound: round)).fetchText(now: Self.now)
                == BranchPickerFetchText(text: "Couldn't refresh branches", tooltip: "Counts may be stale"))
    }

    @Test func fetchNewsLeavesTheRowsAlone() {
        var picker = state(snapshot(branches: [main, feature]))
        let items = picker.items
        #expect(picker.apply(snapshot(branches: [main, feature], readStatus: .failed)).rows == BranchTableChange.none)
        #expect(
            picker.apply(snapshot(branches: [main, feature], fetchStatus: .discovering)).rows
                == BranchTableChange.none)
        let failed = FetchRound(outcomes: ["fork": .failed(message: "down")])
        #expect(
            picker.apply(snapshot(branches: [main, feature], fetchingRemotes: ["fork"], lastFetchRound: failed)).rows
                == BranchTableChange.none)
        #expect(picker.items == items)
        let expected = BranchPickerFetchText(text: "Fetch failed — retry", tooltip: "fork: down")
        #expect(picker.fetchText(now: Self.now) == expected, "the header still follows")
    }

    // MARK: Sync buttons

    @Test func eachRowsButtonsFollowTheSnapshot() throws {
        let behind = localBranch(
            "main", upstream: upstream("origin/main", tracking: .counts(ahead: 0, behind: 2)), tipCommittedAt: Self.now)
        let ahead = localBranch(
            "feature", upstream: upstream("fork/feature", remote: "fork", tracking: .counts(ahead: 1, behind: 0)),
            tipCommittedAt: Self.at(19, 12))
        let remote = remoteBranch("r", tipCommittedAt: Self.at(19, 11))
        let picker = state(snapshot(branches: [behind, ahead, old], remoteBranches: [remote]))
        let mainRow = try index(.local(name: "main"), in: picker)
        let featureRow = try index(.local(name: "feature"), in: picker)
        #expect(picker.syncButtons(forTableRow: mainRow) == RowSyncButtons(pull: .enabled, push: .hidden))
        #expect(picker.syncButtons(forTableRow: featureRow) == RowSyncButtons(pull: .hidden, push: .enabled))
        #expect(try picker.syncButtons(forTableRow: index(.local(name: "old"), in: picker)) == .hidden, "no upstream")
        #expect(try picker.syncButtons(forTableRow: index(.remote(ref: remote.ref), in: picker)) == .hidden)
        #expect(picker.syncButtons(forTableRow: 0) == nil, "a header")
        #expect(picker.syncButtons(forTableRow: 99) == nil)
        // A fetch of a row's remote holds a Pull, not a Push; another remote's fetch holds
        // neither.
        let fetchingFork = state(snapshot(branches: [behind, ahead], fetchingRemotes: ["fork"]))
        #expect(fetchingFork.syncButtons(forTableRow: mainRow) == RowSyncButtons(pull: .enabled, push: .hidden))
        #expect(fetchingFork.syncButtons(forTableRow: featureRow) == RowSyncButtons(pull: .hidden, push: .enabled))
        let discovering = state(snapshot(branches: [behind, ahead], fetchStatus: .discovering))
        #expect(
            discovering.syncButtons(forTableRow: mainRow)
                == RowSyncButtons(pull: .disabled(reason: "Fetching…"), push: .hidden))
    }

    @Test func aSyncChangeReportsButtonsWithoutARowChange() throws {
        let behind = localBranch(
            "main", upstream: upstream("origin/main", tracking: .counts(ahead: 0, behind: 2)), tipCommittedAt: Self.now)
        var picker = state(snapshot(branches: [behind, feature]))
        let items = picker.items
        let row = try index(.local(name: "main"), in: picker)
        let pulling = snapshot(branches: [behind, feature], activeSync: ActiveSync(branch: "main", operation: .pull))
        #expect(picker.apply(pulling) == BranchPickerChange(rows: .none, buttonsChanged: true))
        #expect(picker.items == items)
        #expect(picker.syncButtons(forTableRow: row) == RowSyncButtons(pull: .running, push: .hidden))
        #expect(
            picker.apply(snapshot(branches: [behind, feature]))
                == BranchPickerChange(rows: .none, buttonsChanged: true), "the pull finished")
        #expect(
            picker.apply(snapshot(branches: [behind, feature], fetchingRemotes: ["fork"]))
                == BranchPickerChange(rows: .none, buttonsChanged: false), "no row tracks fork")
    }

    /// A branch whose upstream the fetch settings hide reads as tracking nothing, and
    /// config read on a later opening restyles its row in place.
    @Test func hiddenUpstreamConfigChangesTheRowAndDisablesPublish() throws {
        var picker = state(snapshot(branches: [main, feature], remotes: ["origin"]))
        let row = try index(.local(name: "feature"), in: picker)
        #expect(picker.rows.map(\.status) == [.notPublished, .notPublished])
        #expect(
            picker.syncButtons(forTableRow: row)
                == RowSyncButtons(pull: .hidden, push: .enabled, pushOperation: .publish, publish: .remote("origin")))

        let hidden = snapshot(
            branches: [main, feature], remotes: ["origin"], configuredUpstreamRemotes: ["feature": "origin"])
        #expect(
            picker.apply(hidden)
                == BranchPickerChange(rows: .refresh([row]), buttonsChanged: true))
        #expect(picker.rows.map(\.status) == [.notPublished, .upstreamNotFetched])
        #expect(
            picker.syncButtons(forTableRow: row)
                == RowSyncButtons(
                    pull: .hidden, push: .disabled(reason: "Tracks origin, but fetch settings don't fetch it"),
                    pushOperation: .publish))
    }

    // MARK: Sync shortcuts

    private static func tracked(_ name: String, ahead: Int, behind: Int) -> LocalBranch {
        localBranch(name, upstream: upstream("origin/\(name)", tracking: .counts(ahead: ahead, behind: behind)))
    }

    /// Where a case's highlight sits.
    enum ShortcutHighlight {
        case none
        case branch(BranchRowID)
        case newBranch
    }

    /// A row by identity, since its table index depends on the layout.
    enum ExpectedShortcutTarget {
        case row(BranchRowID)
        case header
    }

    struct ShortcutCase: CustomTestStringConvertible {
        let name: String
        var headState: HeadState? = .named("main")
        let branches: [LocalBranch]
        var activeSync: ActiveSync?
        var remoteBranches: [RemoteBranch] = []
        var remotes: [String] = []
        var tab = BranchPickerTab.switchBranch
        var highlight = ShortcutHighlight.none
        let pull: ExpectedShortcutTarget?
        let push: ExpectedShortcutTarget?

        var testDescription: String { name }
    }

    static let shortcutCases: [ShortcutCase] = [
        ShortcutCase(
            name: "no other branch goes to the header", branches: [tracked("main", ahead: 0, behind: 1)],
            pull: .header, push: nil),
        ShortcutCase(
            name: "a highlighted row wins for its enabled action",
            branches: [tracked("main", ahead: 0, behind: 1), tracked("feature", ahead: 0, behind: 1)],
            highlight: .branch(.local(name: "feature")), pull: .row(.local(name: "feature")), push: nil),
        ShortcutCase(
            name: "a disabled row slot falls to the header",
            branches: [tracked("main", ahead: 0, behind: 1), tracked("feature", ahead: 1, behind: 1)],
            highlight: .branch(.local(name: "feature")), pull: .header, push: nil),
        ShortcutCase(
            name: "a hidden row slot falls to the header, so Pull and Push part ways",
            branches: [tracked("main", ahead: 0, behind: 1), tracked("feature", ahead: 1, behind: 0)],
            highlight: .branch(.local(name: "feature")), pull: .header, push: .row(.local(name: "feature"))),
        ShortcutCase(
            name: "the Merge tab goes to the header",
            branches: [tracked("main", ahead: 1, behind: 0), tracked("feature", ahead: 1, behind: 0)], tab: .merge,
            highlight: .branch(.local(name: "feature")), pull: nil, push: .header),
        ShortcutCase(
            name: "a remote-only row goes to the header", branches: [tracked("main", ahead: 1, behind: 0)],
            remoteBranches: [remoteBranch("release")], highlight: .branch(.remote(ref: "refs/remotes/origin/release")),
            pull: nil, push: .header),
        ShortcutCase(
            name: "New Branch… goes to the header", branches: [tracked("main", ahead: 1, behind: 0)],
            highlight: .newBranch, pull: nil, push: .header),
        ShortcutCase(
            name: "a detached HEAD with no row target has none", headState: .detached(sha: objectID("x")),
            branches: [tracked("main", ahead: 1, behind: 1)], pull: nil, push: nil),
        ShortcutCase(
            name: "an unlisted current branch with no row target has none",
            branches: [tracked("feature", ahead: 1, behind: 1)], pull: nil, push: nil),
        ShortcutCase(
            name: "neither the current nor the highlighted branch can act",
            branches: [tracked("main", ahead: 0, behind: 0), tracked("feature", ahead: 1, behind: 1)],
            highlight: .branch(.local(name: "feature")), pull: nil, push: nil),
        ShortcutCase(
            name: "a running row slot with no header fallback has none",
            branches: [tracked("main", ahead: 0, behind: 0), tracked("feature", ahead: 0, behind: 1)],
            activeSync: ActiveSync(branch: "feature", operation: .pull), highlight: .branch(.local(name: "feature")),
            pull: nil, push: nil),
        ShortcutCase(
            name: "a highlighted untracked row publishes",
            branches: [tracked("main", ahead: 0, behind: 0), localBranch("feature")], remotes: ["origin"],
            highlight: .branch(.local(name: "feature")), pull: nil, push: .row(.local(name: "feature"))),
        ShortcutCase(
            name: "an untracked current branch publishes from the header", branches: [localBranch("main")],
            remotes: ["origin"], pull: nil, push: .header),
    ]

    @Test(arguments: shortcutCases)
    func syncShortcutsPressTheHighlightedRowElseTheHeader(_ testCase: ShortcutCase) throws {
        var picker = state(
            snapshot(
                headState: testCase.headState, branches: testCase.branches, activeSync: testCase.activeSync,
                remotes: testCase.remotes, remoteBranches: testCase.remoteBranches),
            tab: testCase.tab)
        switch testCase.highlight {
        case .none: break
        case let .branch(id): try picker.highlight(tableRow: index(id, in: picker))
        case .newBranch: picker.highlightNewBranch()
        }
        func resolved(_ expected: ExpectedShortcutTarget?) throws -> SyncShortcutTarget? {
            switch expected {
            case nil: nil
            case .header?: .header
            case let .row(id)?: try .row(tableRow: index(id, in: picker))
            }
        }
        let pull = try resolved(testCase.pull)
        let push = try resolved(testCase.push)
        #expect(picker.shortcutTarget(for: .pull) == pull)
        #expect(picker.shortcutTarget(for: .push) == push)
    }

    @Test func theEmptyStateFollowsTheReadStatus() {
        #expect(state(snapshot(branches: [main])).emptyState == nil)
        #expect(state(snapshot(headState: nil, branches: [], readStatus: .unread)).emptyState == .loading)
        #expect(state(snapshot(headState: nil, branches: [], readStatus: .failed)).emptyState == .failed)
        #expect(state(snapshot(branches: [])).emptyState == .noBranches)
    }
}

extension BranchPickerStateTests {
    /// ⌘P presses Push. The current branch and the others are all ahead, so the header's
    /// Push and any Switch row's can act. The list is feature, main (current), release.
    @Suite("Resting selection")
    struct RestingSelection {
        private static let ahead = ["feature", "main", "release"].map { name in
            localBranch(name, upstream: upstream("origin/\(name)", tracking: .counts(ahead: 1, behind: 0)))
        }

        private func makePicker(tab: BranchPickerTab = .switchBranch) -> BranchPickerState {
            let grouping = CommitDayGrouping(
                calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"),
                timeZone: BranchPickerStateTests.timeZone, now: BranchPickerStateTests.now)
            let snapshot = BranchPickerSnapshot(
                headState: .named("main"), branches: Self.ahead, readStatus: .loaded, isSwitchingBranch: false)
            return BranchPickerState(snapshot: snapshot, grouping: grouping, tab: tab)
        }

        private func featureRow(in picker: BranchPickerState) throws -> Int {
            try #require(picker.items.firstIndex { $0.row?.id == .local(name: "feature") })
        }

        @Test func onOpenTheShortcutsGoToTheHeader() {
            let picker = makePicker()
            #expect(picker.highlightedRow == .local(name: "feature"))
            #expect(picker.shortcutTarget(for: .push) == .header)
            #expect(picker.copyableRow == nil)
        }

        @Test func hoveringTheSelectedRowMakesItTheTarget() throws {
            var picker = makePicker()
            let row = try featureRow(in: picker)
            let changed = picker.highlight(tableRow: row)
            #expect(changed, "the selection stopped resting, so the caller redraws")
            #expect(picker.shortcutTarget(for: .push) == .row(tableRow: row))
        }

        @Test func aClampedMoveMakesTheRowTheTarget() throws {
            var picker = makePicker()
            picker.moveUp()
            #expect(picker.shortcutTarget(for: .push) == .row(tableRow: try featureRow(in: picker)))
        }

        /// Row sync buttons belong to Switch, but ⌘C copies in either tab.
        @Test func inMergeAnExplicitSelectionCopiesButSyncsTheHeader() throws {
            var picker = makePicker(tab: .merge)
            picker.highlight(tableRow: try featureRow(in: picker))
            #expect(picker.shortcutTarget(for: .push) == .header)
            #expect(picker.copyableRow?.name == "feature")
        }

        @Test func backInSwitchASearchSelectionIsTheTarget() throws {
            var picker = makePicker(tab: .merge)
            _ = picker.setQuery("fe")
            picker.setTab(.switchBranch)
            #expect(picker.shortcutTarget(for: .push) == .row(tableRow: try featureRow(in: picker)))
        }

        @Test func clearingTheQueryRestsTheSelectionAgain() throws {
            var picker = makePicker()
            _ = picker.setQuery("fe")
            #expect(picker.shortcutTarget(for: .push) == .row(tableRow: try featureRow(in: picker)))
            _ = picker.setQuery("")
            #expect(picker.shortcutTarget(for: .push) == .header)
            #expect(picker.copyableRow == nil)
        }

        /// A branch the reader never chose must not become the shortcuts' target.
        @Test func replacingTheChosenBranchRestsTheSelection() throws {
            let grouping = CommitDayGrouping(
                calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"),
                timeZone: BranchPickerStateTests.timeZone, now: BranchPickerStateTests.now)
            func snapshot(_ names: [String]) -> BranchPickerSnapshot {
                let branches = names.map { name in
                    localBranch(name, upstream: upstream("origin/\(name)", tracking: .counts(ahead: 1, behind: 0)))
                }
                return BranchPickerSnapshot(
                    headState: .named("main"), branches: branches, readStatus: .loaded, isSwitchingBranch: false)
            }
            var picker = BranchPickerState(snapshot: snapshot(["feature", "main"]), grouping: grouping)
            picker.highlight(tableRow: try featureRow(in: picker))

            _ = picker.apply(snapshot(["hotfix", "main"]))

            #expect(picker.highlightedRow == .local(name: "hotfix"))
            #expect(picker.shortcutTarget(for: .push) == .header)
        }
    }
}
