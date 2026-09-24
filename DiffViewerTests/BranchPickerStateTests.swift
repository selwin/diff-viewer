import Foundation
import Testing

@testable import DiffViewer

struct BranchPickerStateTests {
    private static let now = Date(timeIntervalSince1970: 1_789_300_000)
    private let grouping = CommitDayGrouping(
        calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"),
        timeZone: TimeZone(identifier: "Europe/London")!, now: BranchPickerStateTests.now)

    private let main = localBranch("main", tipCommittedAt: BranchPickerStateTests.now)
    private let feature = localBranch("feature", tipCommittedAt: BranchPickerStateTests.now - 3600)
    private let old = localBranch("old", tipCommittedAt: BranchPickerStateTests.now - 100_000)

    private func snapshot(
        headState: HeadState? = .named("main"), branches: [LocalBranch], readStatus: BranchReadStatus = .loaded,
        isSwitchingBranch: Bool = false, fetchStatus: FetchStatus = .idle,
        activeSync: ActiveSync? = nil, fetchingRemotes: Set<String> = [], remotes: [String] = [],
        configuredUpstreamRemotes: [String: String] = [:], secondaryFetchFailures: [String: String] = [:]
    ) -> BranchPickerSnapshot {
        BranchPickerSnapshot(
            headState: headState, branches: branches, readStatus: readStatus, isSwitchingBranch: isSwitchingBranch,
            fetchStatus: fetchStatus, activeSync: activeSync, fetchingRemotes: fetchingRemotes, remotes: remotes,
            configuredUpstreamRemotes: configuredUpstreamRemotes, secondaryFetchFailures: secondaryFetchFailures)
    }

    private func state(_ snapshot: BranchPickerSnapshot) -> BranchPickerState {
        BranchPickerState(snapshot: snapshot, grouping: grouping)
    }

    // MARK: Rows

    @Test func rowsAreNewestFirstThenByName() {
        let sameDay = localBranch("aardvark", tipCommittedAt: BranchPickerStateTests.now - 3600)
        let picker = state(snapshot(branches: [old, feature, main, sameDay]))
        #expect(picker.rows.map(\.branch.name) == ["main", "aardvark", "feature", "old"])
    }

    @Test func gutterLabelsMarkTheFirstRowOfEachDay() {
        let picker = state(snapshot(branches: [main, feature, old]))
        #expect(picker.rows.map { $0.dayLabel?.title } == ["Today", nil, "Yesterday"])
        #expect(picker.rows.map(\.isCurrent) == [true, false, false])
    }

    @Test func trailingTextDescribesTheUpstream() {
        let branches = [
            localBranch("a", tipCommittedAt: BranchPickerStateTests.now),
            localBranch("b", upstream: upstream("origin/b"), tipCommittedAt: BranchPickerStateTests.now - 1),
            localBranch("c", upstream: upstream("origin/c", tracking: .gone), tipCommittedAt: Self.now - 2),
            localBranch(
                "d", upstream: upstream("origin/d", tracking: .counts(ahead: 1, behind: 2)),
                tipCommittedAt: Self.now - 3),
        ]
        let picker = state(snapshot(branches: branches))
        #expect(picker.rows.map(\.trailingText) == ["no upstream", "", "upstream gone", "2 behind, 1 ahead"])
    }

    // MARK: Highlight

    @Test func initialHighlightPrefersTheCurrentBranch() {
        let onCurrent = state(snapshot(branches: [feature, main]))
        #expect(onCurrent.highlightedBranch == "main")
        #expect(onCurrent.highlightedTableRow == 0)

        let detached = state(snapshot(headState: .detached(sha: objectID("x")), branches: [main, feature]))
        #expect(detached.highlightedBranch == "main", "the first row when no branch is current")

        #expect(state(snapshot(branches: [])).highlightedBranch == nil)
        #expect(state(snapshot(branches: [])).highlightedTableRow == nil)
    }

    @Test func movesClampAtBothEnds() {
        var picker = state(snapshot(branches: [main, feature, old]))
        picker.moveUp()
        #expect(picker.highlightedTableRow == 0, "nothing above the first row")
        picker.moveDown()
        picker.moveDown()
        #expect(picker.highlightedBranch == "old")
        picker.moveDown()
        #expect(picker.highlightedBranch == "old", "nothing below the last row")
        picker.moveToFirst()
        #expect(picker.highlightedTableRow == 0)
        picker.moveToLast()
        #expect(picker.highlightedTableRow == 2)
    }

    @Test func theCurrentRowCannotBeActivated() {
        let picker = state(snapshot(branches: [main, feature]))
        #expect(!picker.canActivate(tableRow: 0))
        #expect(picker.canActivate(tableRow: 1))
        #expect(!picker.canActivate(tableRow: 5))
        #expect(picker.branchName(forTableRow: 1) == "feature")
        #expect(picker.branchName(forTableRow: 5) == nil)
    }

    @Test func noRowActivatesWhileASwitchIsInFlight() {
        let picker = state(snapshot(branches: [main, feature], isSwitchingBranch: true))
        #expect(!picker.canActivate(tableRow: 0))
        #expect(!picker.canActivate(tableRow: 1))
    }

    // MARK: Snapshots

    @Test func anUnchangedSnapshotChangesNothing() {
        let taken = snapshot(branches: [main, feature])
        var picker = state(taken)
        #expect(picker.apply(taken).rows == PickerTableChange.none)
    }

    @Test func aReadStatusChangeLeavesTheRowsAlone() {
        var picker = state(snapshot(branches: [main, feature]))
        let rows = picker.rows
        #expect(picker.apply(snapshot(branches: [main, feature], readStatus: .failed)).rows == PickerTableChange.none)
        #expect(picker.rows == rows)
    }

    /// The cells hold whether a row can activate, so a switch starting or ending has to
    /// reach every visible cell even though no row's content moved.
    @Test func aSwitchFlagChangeRefreshesEveryRowInPlace() {
        var picker = state(snapshot(branches: [main, feature], isSwitchingBranch: true))
        let rows = picker.rows
        #expect(
            picker.apply(snapshot(branches: [main, feature])).rows
                == .incremental(inserted: nil, refreshed: IndexSet(integersIn: 0..<2)))
        #expect(picker.rows == rows)
        #expect(!picker.snapshot.isSwitchingBranch)
        #expect(picker.canActivate(tableRow: 1))
    }

    @Test func changedCountsRefreshThatRowAndKeepTheHighlight() {
        var picker = state(snapshot(branches: [main, feature]))
        picker.moveDown()
        #expect(picker.highlightedBranch == "feature")

        let tracked = LocalBranch(
            name: "feature", upstream: upstream("origin/feature", tracking: .counts(ahead: 0, behind: 3)),
            tipCommittedAt: feature.tipCommittedAt)
        #expect(
            picker.apply(snapshot(branches: [main, tracked])).rows
                == .incremental(inserted: nil, refreshed: IndexSet(integer: 1)))
        #expect(picker.rows[1].trailingText == "3 behind")
        #expect(picker.highlightedBranch == "feature")
    }

    @Test func aReorderReloadsEverything() {
        var picker = state(snapshot(branches: [main, feature]))
        let movedMain = LocalBranch(name: "main", upstream: nil, tipCommittedAt: Self.now - 100_000)
        #expect(picker.apply(snapshot(branches: [movedMain, feature])).rows == PickerTableChange.reloadAll)
        #expect(picker.rows.map(\.branch.name) == ["feature", "main"])
    }

    @Test func aVanishedHighlightFallsBackToCurrentThenFirst() {
        var picker = state(snapshot(branches: [main, feature, old]))
        picker.moveToLast()
        #expect(picker.highlightedBranch == "old")

        #expect(picker.apply(snapshot(branches: [main, feature])).rows == PickerTableChange.reloadAll)
        #expect(picker.highlightedBranch == "main", "the current branch")

        #expect(picker.apply(snapshot(headState: .named("gone"), branches: [feature, old])).rows == .reloadAll)
        #expect(picker.highlightedBranch == "feature", "the first row when nothing is current")
    }

    // MARK: Chrome

    private static func header(_ title: String, pill: Bool = false, detail: String = "") -> BranchPickerHeaderText {
        BranchPickerHeaderText(title: title, showsCurrentPill: pill, detail: detail)
    }

    @Test(
        arguments: [(BranchPickerSnapshot, BranchPickerHeaderText)]([
            (
                BranchPickerSnapshot(headState: nil, branches: [], readStatus: .unread, isSwitchingBranch: false),
                header("Loading…")
            ),
            (
                BranchPickerSnapshot(headState: nil, branches: [], readStatus: .failed, isSwitchingBranch: false),
                header("Couldn't read branches")
            ),
            (
                BranchPickerSnapshot(
                    headState: .detached(sha: String(repeating: "a", count: 40)), branches: [], readStatus: .loaded,
                    isSwitchingBranch: false),
                header("Detached aaaaaaa")
            ),
            (named([localBranch("main")]), header("main", pill: true, detail: "no upstream")),
            (
                BranchPickerSnapshot(
                    headState: .named("main"), branches: [localBranch("main")], readStatus: .loaded,
                    isSwitchingBranch: false, configuredUpstreamRemotes: ["main": "origin"]),
                header("main", pill: true, detail: "upstream not fetched")
            ),
            (
                named([localBranch("main", upstream: upstream("origin/main", tracking: .gone))]),
                header("main", pill: true, detail: "upstream gone")
            ),
            (
                named([localBranch("main", upstream: upstream("origin/main"))]),
                header("main", pill: true, detail: "up to date")
            ),
            (
                named([localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 1, behind: 2)))]),
                header("main", pill: true, detail: "2 behind, 1 ahead")
            ),
            // HEAD on a branch the list does not carry: nothing is known about its upstream.
            (named([localBranch("other")]), header("main", pill: true)),
        ]))
    func headerTextFollowsHeadAndTheList(taken: BranchPickerSnapshot, expected: BranchPickerHeaderText) {
        #expect(state(taken).headerText == expected)
    }

    /// A loaded read with HEAD on `main`.
    private static func named(_ branches: [LocalBranch]) -> BranchPickerSnapshot {
        BranchPickerSnapshot(
            headState: .named("main"), branches: branches, readStatus: .loaded, isSwitchingBranch: false)
    }

    @Test func theFooterOnlySpeaksForAFailedReadWithRows() {
        #expect(state(snapshot(branches: [main])).footer == BranchPickerFooter.none)
        #expect(state(snapshot(branches: [], readStatus: .failed)).footer == BranchPickerFooter.none)
        #expect(
            state(snapshot(branches: [main], readStatus: .failed)).footer
                == .text("Couldn't refresh branches; counts may be stale", tooltip: nil))
    }

    // MARK: Fetching

    @Test func theSpinnerOnlyShowsWhileFetching() {
        #expect(state(snapshot(branches: [main], fetchStatus: .fetching(remote: nil))).headerText.showsSpinner)
        #expect(state(snapshot(branches: [main], fetchStatus: .fetching(remote: "origin"))).headerText.showsSpinner)
        #expect(!state(snapshot(branches: [main])).headerText.showsSpinner)
        #expect(
            !state(snapshot(branches: [main], fetchStatus: .fetched(remote: "origin", at: Self.now)))
                .headerText.showsSpinner)
        // A header with no HEAD yet still reports the fetch.
        #expect(
            state(snapshot(headState: nil, branches: [], readStatus: .unread, fetchStatus: .fetching(remote: nil)))
                .headerText.showsSpinner)
    }

    @Test func theFooterReportsTheFetch() {
        let time = BranchPickerState.fetchedTime(Self.now)
        #expect(
            state(snapshot(branches: [main], fetchStatus: .fetched(remote: "origin", at: Self.now))).footer
                == .text("Fetched origin \(time)", tooltip: nil))
        #expect(
            state(snapshot(branches: [main], fetchStatus: .failed(remote: nil, message: "no remotes"))).footer
                == .text("Couldn't load remotes", tooltip: "no remotes"))
        #expect(
            state(snapshot(branches: [main], fetchStatus: .failed(remote: "origin", message: "host down"))).footer
                == .text("Couldn't fetch origin", tooltip: "host down"))
        #expect(state(snapshot(branches: [main], fetchStatus: .noFetchTarget)).footer == BranchPickerFooter.none)
        #expect(
            state(snapshot(branches: [main], fetchStatus: .fetching(remote: "origin"))).footer
                == BranchPickerFooter.none)
    }

    @Test func theFooterReportsAnotherRemotesFailure() {
        let time = BranchPickerState.fetchedTime(Self.now)
        let fork = ["fork": "host down"]
        #expect(
            state(snapshot(branches: [main], fetchStatus: .noFetchTarget, secondaryFetchFailures: fork)).footer
                == .text("Couldn't fetch fork", tooltip: "host down"))
        let fetched = FetchStatus.fetched(remote: "origin", at: Self.now)
        #expect(
            state(snapshot(branches: [main], fetchStatus: fetched, secondaryFetchFailures: fork)).footer
                == .text("Couldn't fetch fork", tooltip: "host down"))
        #expect(
            state(snapshot(branches: [main], fetchStatus: fetched, secondaryFetchFailures: [:])).footer
                == .text("Fetched origin \(time)", tooltip: nil))
        let two = ["upstream": "timed out", "fork": "host down"]
        #expect(
            state(snapshot(branches: [main], fetchStatus: fetched, secondaryFetchFailures: two)).footer
                == .text("Couldn't fetch fork, upstream", tooltip: "fork: host down\nupstream: timed out"))
    }

    @Test func theHeadersRemoteFailureOutranksAnotherRemotes() {
        let taken = snapshot(
            branches: [main], fetchStatus: .failed(remote: "origin", message: "refused"),
            secondaryFetchFailures: ["fork": "host down"])
        #expect(state(taken).footer == .text("Couldn't fetch origin", tooltip: "refused"))
    }

    /// The counts on screen are what the reader is judging, so their staleness outranks
    /// news about the fetch.
    @Test func aStaleReadOutranksTheFetch() {
        let taken = snapshot(
            branches: [main], readStatus: .failed, fetchStatus: .fetched(remote: "origin", at: Self.now))
        #expect(state(taken).footer == .text("Couldn't refresh branches; counts may be stale", tooltip: nil))
    }

    @Test func fetchNewsLeavesTheRowsAlone() {
        var picker = state(snapshot(branches: [main, feature]))
        let rows = picker.rows
        #expect(
            picker.apply(snapshot(branches: [main, feature], fetchStatus: .fetching(remote: nil))).rows
                == PickerTableChange.none)
        #expect(
            picker.apply(
                snapshot(
                    branches: [main, feature], fetchingRemotes: ["fork"], secondaryFetchFailures: ["fork": "down"])
            ).rows == PickerTableChange.none)
        #expect(picker.rows == rows)
        #expect(picker.footer == .text("Couldn't fetch fork", tooltip: "down"), "the footer still follows")
    }

    // MARK: Sync buttons

    @Test func eachRowsButtonsFollowTheSnapshot() {
        let behind = localBranch(
            "main", upstream: upstream("origin/main", tracking: .counts(ahead: 0, behind: 2)),
            tipCommittedAt: Self.now)
        let ahead = localBranch(
            "feature", upstream: upstream("fork/feature", remote: "fork", tracking: .counts(ahead: 1, behind: 0)),
            tipCommittedAt: Self.now - 3600)
        let picker = state(snapshot(branches: [behind, ahead, old]))
        #expect(picker.syncButtons(forTableRow: 0) == RowSyncButtons(pull: .enabled, push: .hidden))
        #expect(picker.syncButtons(forTableRow: 1) == RowSyncButtons(pull: .hidden, push: .enabled))
        #expect(picker.syncButtons(forTableRow: 2) == .hidden, "no upstream")
        #expect(picker.syncButtons(forTableRow: 3) == nil)
        // A fetch of a row's remote holds a Pull, not a Push; another remote's fetch holds
        // neither.
        let fetchingFork = state(snapshot(branches: [behind, ahead], fetchingRemotes: ["fork"]))
        #expect(fetchingFork.syncButtons(forTableRow: 0) == RowSyncButtons(pull: .enabled, push: .hidden))
        #expect(fetchingFork.syncButtons(forTableRow: 1) == RowSyncButtons(pull: .hidden, push: .enabled))
        let fetchingOrigin = state(snapshot(branches: [behind, ahead], fetchingRemotes: ["origin"]))
        #expect(
            fetchingOrigin.syncButtons(forTableRow: 0)
                == RowSyncButtons(pull: .disabled(reason: "Fetching…"), push: .hidden))
        let discovering = state(snapshot(branches: [behind, ahead], fetchStatus: .fetching(remote: nil)))
        #expect(
            discovering.syncButtons(forTableRow: 0)
                == RowSyncButtons(pull: .disabled(reason: "Fetching…"), push: .hidden))
        #expect(discovering.syncButtons(forTableRow: 1) == RowSyncButtons(pull: .hidden, push: .enabled))
    }

    @Test func aSyncChangeReportsButtonsWithoutARowChange() {
        let behind = localBranch(
            "main", upstream: upstream("origin/main", tracking: .counts(ahead: 0, behind: 2)),
            tipCommittedAt: Self.now)
        var picker = state(snapshot(branches: [behind, feature]))
        let rows = picker.rows
        let pulling = snapshot(branches: [behind, feature], activeSync: ActiveSync(branch: "main", operation: .pull))
        #expect(picker.apply(pulling) == BranchPickerChange(rows: .none, buttonsChanged: true))
        #expect(picker.rows == rows)
        #expect(picker.syncButtons(forTableRow: 0) == RowSyncButtons(pull: .running, push: .hidden))
        #expect(
            picker.apply(snapshot(branches: [behind, feature], fetchStatus: .fetched(remote: "origin", at: Self.now)))
                == BranchPickerChange(rows: .none, buttonsChanged: true), "the pull finished")
        #expect(
            picker.apply(snapshot(branches: [behind, feature], fetchingRemotes: ["fork"]))
                == BranchPickerChange(rows: .none, buttonsChanged: false), "no row tracks fork")
    }

    /// A branch whose upstream the fetch settings hide reads as tracking nothing, and
    /// config read on a later opening restyles its row in place.
    @Test func hiddenUpstreamConfigChangesTheRowAndDisablesPublish() {
        var picker = state(snapshot(branches: [main, feature], remotes: ["origin"]))
        #expect(picker.rows.map(\.trailingText) == ["no upstream", "no upstream"])
        #expect(
            picker.syncButtons(forTableRow: 1)
                == RowSyncButtons(pull: .hidden, push: .enabled, pushTitle: "Publish", publish: .remote("origin")))

        let hidden = snapshot(
            branches: [main, feature], remotes: ["origin"], configuredUpstreamRemotes: ["feature": "origin"])
        #expect(
            picker.apply(hidden)
                == BranchPickerChange(rows: .incremental(inserted: nil, refreshed: [1]), buttonsChanged: true))
        #expect(picker.rows.map(\.trailingText) == ["no upstream", "upstream not fetched"])
        #expect(
            picker.syncButtons(forTableRow: 1)
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
