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
        activeSyncOperation: SyncOperation? = nil
    ) -> BranchPickerSnapshot {
        BranchPickerSnapshot(
            headState: headState, branches: branches, readStatus: readStatus, isSwitchingBranch: isSwitchingBranch,
            fetchStatus: fetchStatus, activeSyncOperation: activeSyncOperation)
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
        #expect(picker.apply(taken) == PickerTableChange.none)
    }

    @Test func aReadStatusChangeLeavesTheRowsAlone() {
        var picker = state(snapshot(branches: [main, feature]))
        let rows = picker.rows
        #expect(picker.apply(snapshot(branches: [main, feature], readStatus: .failed)) == PickerTableChange.none)
        #expect(picker.rows == rows)
    }

    /// The cells hold whether a row can activate, so a switch starting or ending has to
    /// reach every visible cell even though no row's content moved.
    @Test func aSwitchFlagChangeRefreshesEveryRowInPlace() {
        var picker = state(snapshot(branches: [main, feature], isSwitchingBranch: true))
        let rows = picker.rows
        #expect(
            picker.apply(snapshot(branches: [main, feature]))
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
            picker.apply(snapshot(branches: [main, tracked]))
                == .incremental(inserted: nil, refreshed: IndexSet(integer: 1)))
        #expect(picker.rows[1].trailingText == "3 behind")
        #expect(picker.highlightedBranch == "feature")
    }

    @Test func aReorderReloadsEverything() {
        var picker = state(snapshot(branches: [main, feature]))
        let movedMain = LocalBranch(name: "main", upstream: nil, tipCommittedAt: Self.now - 100_000)
        #expect(picker.apply(snapshot(branches: [movedMain, feature])) == PickerTableChange.reloadAll)
        #expect(picker.rows.map(\.branch.name) == ["feature", "main"])
    }

    @Test func aVanishedHighlightFallsBackToCurrentThenFirst() {
        var picker = state(snapshot(branches: [main, feature, old]))
        picker.moveToLast()
        #expect(picker.highlightedBranch == "old")

        #expect(picker.apply(snapshot(branches: [main, feature])) == PickerTableChange.reloadAll)
        #expect(picker.highlightedBranch == "main", "the current branch")

        #expect(picker.apply(snapshot(headState: .named("gone"), branches: [feature, old])) == .reloadAll)
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

    /// The counts on screen are what the reader is judging, so their staleness outranks
    /// news about the fetch.
    @Test func aStaleReadOutranksTheFetch() {
        let taken = snapshot(
            branches: [main], readStatus: .failed, fetchStatus: .fetched(remote: "origin", at: Self.now))
        #expect(state(taken).footer == .text("Couldn't refresh branches; counts may be stale", tooltip: nil))
    }

    @Test func aFetchStatusChangeLeavesTheRowsAlone() {
        var picker = state(snapshot(branches: [main, feature]))
        let rows = picker.rows
        #expect(
            picker.apply(snapshot(branches: [main, feature], fetchStatus: .fetching(remote: nil)))
                == PickerTableChange.none)
        #expect(picker.rows == rows)
    }

    // MARK: Sync buttons

    @Test func theButtonsFollowTheSnapshot() {
        let behind = localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 0, behind: 2)))
        #expect(state(snapshot(branches: [behind])).syncButtons == (.enabled, .hidden))
        // The fetch behind the picker holds the same counts the buttons would move.
        let fetching = snapshot(branches: [behind], fetchStatus: .fetching(remote: "origin"))
        #expect(state(fetching).syncButtons == (.disabled(reason: "Fetching…"), .hidden))
        let pulling = snapshot(branches: [behind], activeSyncOperation: .pull)
        #expect(state(pulling).syncButtons == (.running, .hidden), "nothing to push, so nothing greys out")
        #expect(state(snapshot(branches: [main])).syncButtons == (.hidden, .hidden), "no upstream")
    }

    @Test func aSyncOperationChangeLeavesTheRowsAlone() {
        var picker = state(snapshot(branches: [main, feature]))
        let rows = picker.rows
        #expect(
            picker.apply(snapshot(branches: [main, feature], activeSyncOperation: .push)) == PickerTableChange.none)
        #expect(picker.rows == rows)
        #expect(picker.syncButtons == (.hidden, .running), "the operation in flight outranks the missing target")
    }

    @Test func theEmptyStateFollowsTheReadStatus() {
        #expect(state(snapshot(branches: [main])).emptyState == nil)
        #expect(state(snapshot(headState: nil, branches: [], readStatus: .unread)).emptyState == .loading)
        #expect(state(snapshot(headState: nil, branches: [], readStatus: .failed)).emptyState == .failed)
        #expect(state(snapshot(branches: [])).emptyState == .noBranches)
    }
}
