import Foundation
import Testing

@testable import DiffViewer

struct CommitPickerStateTests {
    private static let now = Date(timeIntervalSince1970: 1_789_300_000)
    private let grouping = CommitDayGrouping(
        calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"),
        timeZone: TimeZone(identifier: "Europe/London")!, now: CommitPickerStateTests.now)

    private let c1 = commitSummary("c1", subject: "First", committedAt: CommitPickerStateTests.now)
    private let c2 = commitSummary("c2", subject: "Second", committedAt: CommitPickerStateTests.now - 3600)
    private let c3 = commitSummary("c3", subject: "Third", committedAt: CommitPickerStateTests.now - 100_000)

    private func snapshot(
        displayedScope: DiffScope = .workingTree, displayedCommit: CommitSummary? = nil,
        commits: [CommitSummary], hasMore: Bool = false, isLoadingHistory: Bool = false,
        historyLoadFailed: Bool = false, fileCount: Int? = 3
    ) -> CommitPickerSnapshot {
        CommitPickerSnapshot(
            displayedScope: displayedScope, displayedCommit: displayedCommit, commits: commits, hasMore: hasMore,
            isLoadingHistory: isLoadingHistory, historyLoadFailed: historyLoadFailed,
            displayedScopeFileCount: fileCount)
    }

    private func state(_ snapshot: CommitPickerSnapshot) -> CommitPickerState {
        CommitPickerState(snapshot: snapshot, grouping: grouping)
    }

    // MARK: Rows and highlight

    @Test func rowsCarryDayLabelsAndTheDisplayedScope() {
        let picker = state(snapshot(displayedScope: .commit(c2.ref), displayedCommit: c2, commits: [c1, c2, c3]))
        #expect(picker.rows.map(\.scope) == [.commit(c1.ref), .commit(c2.ref), .commit(c3.ref)])
        #expect(picker.rows.map { $0.dayLabel?.title } == ["Today", nil, "Yesterday"])
        #expect(picker.rows.map(\.isDisplayedScope) == [false, true, false])
    }

    @Test func initialHighlightIsTheDisplayedScope() {
        let onCommit = state(snapshot(displayedScope: .commit(c2.ref), displayedCommit: c2, commits: [c1, c2]))
        #expect(onCommit.highlightedScope == .commit(c2.ref))
        #expect(onCommit.highlightedTableRow == 1)

        let onTree = state(snapshot(commits: [c1, c2]))
        #expect(onTree.highlightedScope == .workingTree)
        #expect(onTree.highlightedTableRow == nil)
    }

    // MARK: Navigation

    @Test func movesClampAtBothEndsAndCrossThePinnedRow() {
        var picker = state(snapshot(commits: [c1, c2]))
        picker.moveUp()
        #expect(picker.highlightedScope == .workingTree, "nothing above Working Tree")
        picker.moveDown()
        #expect(picker.highlightedTableRow == 0)
        picker.moveUp()
        #expect(picker.highlightedScope == .workingTree)
        picker.moveDown()
        picker.moveDown()
        #expect(picker.highlightedTableRow == 1)
        picker.moveDown()
        #expect(picker.highlightedTableRow == 1, "nothing below the last row")
        picker.moveToFirst()
        #expect(picker.highlightedScope == .workingTree)
        picker.moveToLast()
        #expect(picker.highlightedScope == .commit(c2.ref))
    }

    @Test func movesWithNoRowsStayOnWorkingTree() {
        var picker = state(snapshot(commits: []))
        picker.moveDown()
        picker.moveToLast()
        #expect(picker.highlightedScope == .workingTree)
    }

    @Test func highlightByTableRowThenActivate() {
        var picker = state(snapshot(commits: [c1, c2]))
        picker.highlight(tableRow: 1)
        #expect(picker.highlightedScope == .commit(c2.ref))
        picker.highlight(tableRow: 7)
        #expect(picker.highlightedScope == .commit(c2.ref), "out of range is ignored")
        picker.highlightWorkingTree()
        #expect(picker.highlightedScope == .workingTree)
        #expect(picker.scope(forTableRow: 0) == .commit(c1.ref))
        #expect(picker.scope(forTableRow: 2) == nil)
    }

    // MARK: Applying snapshots

    @Test func applyingAnEqualSnapshotChangesNothing() {
        let initial = snapshot(commits: [c1, c2])
        var picker = state(initial)
        #expect(picker.apply(initial) == .none)
    }

    @Test func aGrownListIsAnInsertionAndKeepsTheHighlightBySHA() {
        var picker = state(snapshot(commits: [c1, c2]))
        picker.highlight(tableRow: 1)
        let change = picker.apply(snapshot(commits: [c1, c2, c3]))
        #expect(change == .incremental(inserted: 2..<3, refreshed: []))
        #expect(picker.rows.count == 3)
        #expect(picker.highlightedScope == .commit(c2.ref))
    }

    /// A refresh that lengthens git's abbreviation changes a row's face, not its identity.
    @Test func aLengthenedShortShaRefreshesThatRow() {
        var picker = state(snapshot(commits: [c1, c2]))
        let longer = CommitSummary(
            sha: c2.ref.sha, shortSha: String(c2.ref.sha.prefix(9)), parents: c2.parents, subject: c2.subject,
            committedAt: c2.committedAt)
        let change = picker.apply(snapshot(commits: [c1, longer]))
        #expect(change == .incremental(inserted: nil, refreshed: [1]))
        #expect(picker.rows[1].commit.ref.shortSha == longer.ref.shortSha)
    }

    @Test func movingTheDisplayedScopeRefreshesBothRows() {
        var picker = state(snapshot(displayedScope: .commit(c1.ref), displayedCommit: c1, commits: [c1, c2, c3]))
        let change = picker.apply(
            snapshot(displayedScope: .commit(c3.ref), displayedCommit: c3, commits: [c1, c2, c3]))
        #expect(change == .incremental(inserted: nil, refreshed: [0, 2]))
        #expect(picker.rows.map(\.isDisplayedScope) == [false, false, true])
    }

    @Test func aHeaderOnlyChangeIsNoTableChangeButUpdatesTheHeader() {
        var picker = state(snapshot(commits: [c1], fileCount: 3))
        #expect(picker.headerText.detail == [.text("3 files")])
        #expect(picker.apply(snapshot(commits: [c1], fileCount: 5)) == .none)
        #expect(picker.headerText.detail == [.text("5 files")])
        #expect(picker.workingTreeTrailingText == "5 files")
    }

    @Test func aReorderedOrReplacedListReloadsEverything() {
        var reordered = state(snapshot(commits: [c1, c2]))
        #expect(reordered.apply(snapshot(commits: [c2, c1])) == .reloadAll)

        var replaced = state(snapshot(commits: [c1, c2]))
        #expect(replaced.apply(snapshot(commits: [c3])) == .reloadAll)

        var shrunk = state(snapshot(commits: [c1, c2]))
        #expect(shrunk.apply(snapshot(commits: [c1])) == .reloadAll)
    }

    @Test func aVanishedHighlightFallsToTheFirstRowThenToWorkingTree() {
        var picker = state(snapshot(commits: [c1, c2]))
        picker.highlight(tableRow: 1)
        _ = picker.apply(snapshot(commits: [c3, c1]))
        #expect(picker.highlightedScope == .commit(c3.ref))

        _ = picker.apply(snapshot(commits: []))
        #expect(picker.highlightedScope == .workingTree)
        #expect(picker.highlightedTableRow == nil)
    }

    @Test func aWorkingTreeHighlightSurvivesEveryReload() {
        var picker = state(snapshot(commits: [c1, c2]))
        _ = picker.apply(snapshot(commits: [c3]))
        #expect(picker.highlightedScope == .workingTree)
    }

    // MARK: Pagination

    @Test func shouldRequestMoreOnlyAtTheLastRowOfAPageThatHasMore() {
        let more = state(snapshot(commits: [c1, c2], hasMore: true))
        #expect(more.shouldRequestMore(lastVisibleRow: 1))
        #expect(!more.shouldRequestMore(lastVisibleRow: 0))
        #expect(!more.shouldRequestMore(lastVisibleRow: nil))

        #expect(!state(snapshot(commits: [c1, c2], hasMore: false)).shouldRequestMore(lastVisibleRow: 1))
        #expect(
            !state(snapshot(commits: [c1, c2], hasMore: true, isLoadingHistory: true)).shouldRequestMore(
                lastVisibleRow: 1))
        #expect(
            !state(snapshot(commits: [c1, c2], hasMore: true, historyLoadFailed: true)).shouldRequestMore(
                lastVisibleRow: 1))
        #expect(!state(snapshot(commits: [], hasMore: true)).shouldRequestMore(lastVisibleRow: nil))
    }

    // MARK: Empty states and footers

    @Test func emptyStatesWhenThereAreNoRows() {
        #expect(state(snapshot(commits: [], isLoadingHistory: true)).emptyState == .loading)
        #expect(state(snapshot(commits: [], historyLoadFailed: true)).emptyState == .failed)
        #expect(state(snapshot(commits: [])).emptyState == .noCommits)
        #expect(state(snapshot(commits: [])).footer == .none)
        #expect(state(snapshot(commits: [c1])).emptyState == nil)
    }

    /// The displayed commit is prepended when the page dropped it, so a loading, failed
    /// or empty history still has one row and speaks through the footer instead.
    @Test func anOffPageDisplayedCommitAloneUsesTheFooter() {
        let scope = DiffScope.commit(c1.ref)
        let loading = state(snapshot(displayedScope: scope, displayedCommit: c1, commits: [c1], isLoadingHistory: true))
        #expect(loading.rows.count == 1)
        #expect(loading.emptyState == nil)
        #expect(loading.footer == .loading)

        let failed = state(snapshot(displayedScope: scope, displayedCommit: c1, commits: [c1], historyLoadFailed: true))
        #expect(failed.emptyState == nil)
        #expect(failed.footer == .failed)

        let empty = state(snapshot(displayedScope: scope, displayedCommit: c1, commits: [c1]))
        #expect(empty.emptyState == nil)
        #expect(empty.footer == .none)
    }

    @Test func aFailedLoadMoreKeepsTheRowsAndSaysSo() {
        let picker = state(snapshot(commits: [c1, c2], hasMore: true, historyLoadFailed: true))
        #expect(picker.footer == .failed)
        #expect(state(snapshot(commits: [c1, c2], isLoadingHistory: true)).footer == .loading)
    }

    // MARK: Header and Working Tree text

    @Test func workingTreeTrailingTextOnlyInWorkingTreeScope() {
        #expect(state(snapshot(commits: [c1], fileCount: 4)).workingTreeTrailingText == "4 files")
        #expect(state(snapshot(commits: [c1], fileCount: 1)).workingTreeTrailingText == "1 file")
        #expect(state(snapshot(commits: [c1], fileCount: nil)).workingTreeTrailingText == "")
        let onCommit = state(snapshot(displayedScope: .commit(c1.ref), displayedCommit: c1, commits: [c1]))
        #expect(onCommit.workingTreeTrailingText == "")
    }

    @Test func headerTextForTheWorkingTree() {
        let header = CommitPickerHeaderText.make(snapshot: snapshot(commits: [c1], fileCount: 2), grouping: grouping)
        #expect(header.title == "Working Tree")
        #expect(header.detail == [.text("2 files")])

        let unread = CommitPickerHeaderText.make(snapshot: snapshot(commits: [c1], fileCount: nil), grouping: grouping)
        #expect(unread.detail.isEmpty)
    }

    @Test func headerTextForACommit() {
        let header = CommitPickerHeaderText.make(
            snapshot: snapshot(displayedScope: .commit(c1.ref), displayedCommit: c1, commits: [c1], fileCount: 2),
            grouping: grouping)
        #expect(header.title == "First")
        #expect(
            header.detail == [
                .text(grouping.dateTimeText(for: c1.committedAt)), .text(" · "), .text("2 files"), .text(" · "),
                .mono(c1.ref.shortSha),
            ])

        let unread = CommitPickerHeaderText.make(
            snapshot: snapshot(displayedScope: .commit(c1.ref), displayedCommit: c1, commits: [c1], fileCount: nil),
            grouping: grouping)
        #expect(
            unread.detail == [.text(grouping.dateTimeText(for: c1.committedAt)), .text(" · "), .mono(c1.ref.shortSha)]
        )
    }

    /// The summary's abbreviation wins: git can lengthen it after the scope was chosen.
    @Test func headerTextUsesTheDisplayedCommitsShortSha() {
        let longer = CommitSummary(
            sha: c1.ref.sha, shortSha: String(c1.ref.sha.prefix(8)), parents: c1.parents, subject: c1.subject,
            committedAt: c1.committedAt)
        let header = CommitPickerHeaderText.make(
            snapshot: snapshot(
                displayedScope: .commit(c1.ref), displayedCommit: longer, commits: [longer], fileCount: nil),
            grouping: grouping)
        #expect(longer.ref.shortSha != c1.ref.shortSha)
        #expect(header.detail.last == .mono(longer.ref.shortSha))
    }

    /// No summary to hand: the SHA titles the header and the date is left out.
    @Test func headerTextWithoutASummaryFallsBackToTheSha() {
        let header = CommitPickerHeaderText.make(
            snapshot: snapshot(displayedScope: .commit(c1.ref), displayedCommit: nil, commits: [], fileCount: 2),
            grouping: grouping)
        #expect(header.title == c1.ref.shortSha)
        #expect(header.detail == [.text("2 files"), .text(" · "), .mono(c1.ref.shortSha)])
    }
}
