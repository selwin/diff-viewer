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

    private func state(_ snapshot: BranchPickerSnapshot) -> BranchPickerState {
        BranchPickerState(snapshot: snapshot, grouping: grouping)
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
                "Not published", "upstream not fetched", "upstream gone", "", "2 ahead · 3 behind", "New", "",
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
        #expect(picker.row(forTableRow: colliding)?.blockedReason == "A local branch named main already exists")
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

    @Test func initialHighlightPrefersTheCurrentBranch() {
        let onCurrent = state(snapshot(headState: .named("feature"), branches: [feature, main]))
        #expect(onCurrent.highlightedRow == .local(name: "feature"))
        #expect(onCurrent.highlightedTableRow == 2)

        let detached = state(snapshot(headState: .detached(sha: objectID("x")), branches: [main, feature]))
        #expect(detached.highlightedRow == .local(name: "main"), "the first row when no branch is current")

        #expect(state(snapshot(branches: [])).highlightedRow == nil)
        #expect(state(snapshot(branches: [])).highlightedTableRow == nil)
    }

    @Test func movesSkipHeadersAndClampAtBothEnds() {
        let older = localBranch("older", tipCommittedAt: Self.at(12, 9))
        var picker = state(snapshot(branches: [main, feature, old, older]))
        #expect(layout(picker) == ["# Today", "main", "feature", "# Yesterday", "old", "# Older", "older"])
        picker.moveUp()
        #expect(picker.highlightedTableRow == 1, "nothing above the first row, and never the header")
        picker.moveDown()
        picker.moveDown()
        #expect(picker.highlightedRow == .local(name: "old"))
        picker.moveDown()
        picker.moveDown()
        #expect(picker.highlightedRow == .local(name: "older"), "nothing below the last row")
        picker.moveUp()
        #expect(picker.highlightedRow == .local(name: "old"))
        picker.moveUp()
        #expect(picker.highlightedRow == .local(name: "feature"))
        picker.moveToLast()
        #expect(picker.highlightedTableRow == 6)
        picker.moveToFirst()
        #expect(picker.highlightedTableRow == 1)
    }

    @Test func headersTakeNoHighlight() {
        var picker = state(snapshot(branches: [main, old]))
        #expect(!picker.canHighlight(tableRow: 0))
        #expect(picker.canHighlight(tableRow: 1))
        #expect(!picker.canHighlight(tableRow: 9))
        let movedToOld = picker.highlight(tableRow: 3)
        #expect(movedToOld)
        #expect(picker.highlightedRow == .local(name: "old"))
        let movedToHeader = picker.highlight(tableRow: 2)
        #expect(!movedToHeader)
        #expect(picker.highlightedRow == .local(name: "old"), "the Yesterday header is ignored")
    }

    /// The pointer resting on a row the keyboard left takes the highlight back when it
    /// moves, and a move within the highlighted row changes nothing.
    @Test func hoverTakesTheHighlightBackFromTheKeyboard() {
        var picker = state(snapshot(branches: [main, feature]))
        let movedWithinMain = picker.highlight(tableRow: 1)
        #expect(!movedWithinMain, "already on main")
        picker.moveDown()
        #expect(picker.highlightedRow == .local(name: "feature"))
        let movedBack = picker.highlight(tableRow: 1)
        #expect(movedBack)
        #expect(picker.highlightedRow == .local(name: "main"))
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
        var picker = state(snapshot(branches: [main, feature, old]))
        picker.moveDown()
        #expect(picker.highlightedRow == .local(name: "feature"))
        _ = picker.apply(snapshot(branches: [main, old]))
        #expect(picker.highlightedRow == .local(name: "old"), "the next branch, not the current one")

        _ = picker.apply(snapshot(branches: [main]))
        #expect(picker.highlightedRow == .local(name: "main"), "the previous branch when it was last")
    }

    @Test func aHighlightWithNoNeighbourLeftFallsBackToCurrentThenFirst() {
        var picker = state(snapshot(headState: .named("gone"), branches: [main]))
        #expect(picker.highlightedRow == .local(name: "main"))
        _ = picker.apply(snapshot(headState: .named("gone"), branches: [feature, old]))
        #expect(picker.highlightedRow == .local(name: "feature"), "the first row when nothing is current")

        _ = picker.apply(snapshot(headState: .named("gone"), branches: []))
        #expect(picker.highlightedRow == nil)
        _ = picker.apply(snapshot(headState: .named("old"), branches: [feature, old]))
        #expect(picker.highlightedRow == .local(name: "old"), "rows arriving start on the current branch")
    }

    // MARK: Snapshots

    @Test func anUnchangedSnapshotChangesNothing() {
        let taken = snapshot(branches: [main, feature])
        var picker = state(taken)
        #expect(picker.apply(taken).rows == BranchTableChange.none)
    }

    @Test func aReadStatusChangeLeavesTheRowsAlone() {
        var picker = state(snapshot(branches: [main, feature]))
        let items = picker.items
        #expect(picker.apply(snapshot(branches: [main, feature], readStatus: .failed)).rows == BranchTableChange.none)
        #expect(picker.items == items)
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
        var picker = state(snapshot(branches: [main, feature, old]))
        let before = layout(picker)
        let movedMain = localBranch("main", tipCommittedAt: Self.at(18, 10))
        let change = picker.apply(snapshot(branches: [movedMain, feature, old])).rows
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

    @Test func clearingTheQueryBringsTheSectionsBack() {
        var picker = state(snapshot(branches: [main, feature, old]))
        _ = picker.setQuery("a")
        #expect(layout(picker) == ["main", "feature"])
        _ = picker.setQuery("")
        #expect(layout(picker) == ["# Today", "main", "feature", "# Yesterday", "old"])
        #expect(picker.rows.map(\.matchedRanges) == [[], [], []])
    }

    @Test func aQueryHighlightsTheFirstRowAndClearingItTheCurrentBranch() {
        let aiTools = localBranch("ai-tools", tipCommittedAt: Self.at(19, 12))
        var picker = state(snapshot(branches: [main, aiTools]))
        _ = picker.setQuery("ai")
        #expect(layout(picker) == ["ai-tools", "main"])
        #expect(picker.highlightedRow == .local(name: "ai-tools"), "the best match, though main is current")
        _ = picker.setQuery("")
        #expect(picker.highlightedRow == .local(name: "main"))
    }

    /// Only a snapshot's changes animate: a narrowing query, all removals, still reloads.
    @Test func aQueryChangeReloadsEverything() {
        var picker = state(snapshot(branches: [main, feature, old]))
        #expect(picker.setQuery("a") == .reloadAll)
        #expect(layout(picker) == ["main", "feature"])
        #expect(picker.setQuery("fe") == .reloadAll)
        #expect(layout(picker) == ["feature"])
        #expect(picker.setQuery("") == .reloadAll)
    }

    @Test func theSameNormalizedQueryChangesNothing() {
        var picker = state(snapshot(branches: [main, feature]))
        #expect(picker.setQuery("fe") == .reloadAll)
        #expect(picker.setQuery(" fe ") == BranchTableChange.none)
        #expect(picker.query == "fe")
    }

    @Test func aSpacesOnlyQueryIsNoQuery() {
        var picker = state(snapshot(branches: [main, feature, old]))
        #expect(picker.setQuery("   ") == BranchTableChange.none)
        #expect(layout(picker) == ["# Today", "main", "feature", "# Yesterday", "old"])
        #expect(picker.highlightedRow == .local(name: "main"))
        #expect(picker.emptyState == nil)
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
                "main", ["upstream not fetched"]
            ),
            (
                named([localBranch("main", upstream: upstream("origin/main", tracking: .gone))]), "main",
                ["upstream gone"]
            ),
            (named([localBranch("main", upstream: upstream("origin/main"))]), "main", ["up to date"]),
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
                == RowSyncButtons(pull: .hidden, push: .enabled, pushTitle: "Publish", publish: .remote("origin")))

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
                    pushTitle: "Publish"))
    }

    @Test func theEmptyStateFollowsTheReadStatus() {
        #expect(state(snapshot(branches: [main])).emptyState == nil)
        #expect(state(snapshot(headState: nil, branches: [], readStatus: .unread)).emptyState == .loading)
        #expect(state(snapshot(headState: nil, branches: [], readStatus: .failed)).emptyState == .failed)
        #expect(state(snapshot(branches: [])).emptyState == .noBranches)
    }
}
