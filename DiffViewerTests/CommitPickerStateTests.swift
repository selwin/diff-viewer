import Foundation
import Testing

@testable import DiffViewer

/// London, with "now" pinned to Saturday 19 September 2026 at 14:02.
struct CommitPickerStateTests {
    private static let timeZone = TimeZone(identifier: "Europe/London")!
    private static let now = at(19, 14, 2)
    private static let budget = CommitPickerState.searchBudgetStep
    private let grouping = CommitDayGrouping(
        calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"),
        timeZone: CommitPickerStateTests.timeZone, now: CommitPickerStateTests.now)

    /// A London time in September 2026.
    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// A commit whose subject is also its seed, so layouts read as subjects.
    private static func commit(_ subject: String, _ day: Int, _ hour: Int, author: String = "Tester")
        -> CommitSummary
    {
        commitSummary(subject, subject: subject, committedAt: at(day, hour), author: author)
    }

    private let today1 = commit("today-1", 19, 13)
    private let today2 = commit("today-2", 19, 12)
    private let yesterday = commit("yesterday", 18, 9)
    private let older = commit("older", 1, 9)

    /// Old commits no test query matches.
    private func unrelated(_ count: Int) -> [CommitSummary] {
        (0..<count).map { Self.commit("old\($0)", 1, 9) }
    }

    private func snapshot(
        scope: DiffScope = .workingTree, displayedCommit: CommitSummary? = nil, commits: [CommitSummary],
        hasMore: Bool = false, isLoading: Bool = false, failed: Bool = false, count: Int? = 3,
        unpushed: Set<String> = []
    ) -> CommitPickerSnapshot {
        CommitPickerSnapshot(
            displayedScope: scope, displayedCommit: displayedCommit, commits: commits, hasMore: hasMore,
            isLoadingHistory: isLoading, historyLoadFailed: failed, workingTreeChangeCount: count,
            unpushedShas: unpushed)
    }

    private func state(_ snapshot: CommitPickerSnapshot) -> CommitPickerState {
        CommitPickerState(snapshot: snapshot, grouping: grouping)
    }

    /// Headers by title, commits by subject and messages by text, in table order.
    private func layout(_ picker: CommitPickerState) -> [String] {
        picker.items.map { item in
            switch item {
            case .workingTree: "Working Tree"
            case let .header(section, _): "# \(section.title)"
            case let .commit(row): row.subject
            case let .message(message): "! \(message.text)"
            }
        }
    }

    private func index(_ commit: CommitSummary, in picker: CommitPickerState) throws -> Int {
        try #require(picker.items.firstIndex { $0.key == .commit(.commit(commit.ref)) })
    }

    private func workingTree(_ picker: CommitPickerState) -> CommitPickerWorkingTreeRow? {
        if case let .workingTree(row)? = picker.items.first { row } else { nil }
    }

    // MARK: Order

    @Test func workingTreeLeadsThenCommitsInGitOrderUnderTheirGroups() {
        let picker = state(snapshot(commits: [today1, today2, yesterday, older]))
        #expect(
            layout(picker) == [
                "Working Tree", "# Today", "today-1", "today-2", "# Yesterday", "yesterday", "# Older", "older",
            ])
    }

    @Test func aSelectedCommitMissingFromThePageHasItsOwnSection() {
        let picked = Self.commit("picked", 19, 11)
        let picker = state(snapshot(scope: .commit(picked.ref), displayedCommit: picked, commits: [today1, older]))
        #expect(
            layout(picker) == ["Working Tree", "# Selected", "picked", "# Today", "today-1", "# Older", "older"])
        #expect(picker.rows.map(\.isSelectedScope) == [true, false, false])
        #expect(picker.highlightedItemIndex == 2)

        let inPage = state(snapshot(scope: .commit(today1.ref), displayedCommit: today1, commits: [today1, older]))
        #expect(layout(inPage) == ["Working Tree", "# Today", "today-1", "# Older", "older"])
    }

    /// Each commit sits under its own date's label, and git's order is never changed.
    @Test func aClockSkewedHistoryRepeatsHeaders() {
        let skewed = Self.commit("skewed", 19, 9)
        let picker = state(snapshot(commits: [today1, older, skewed]))
        #expect(layout(picker) == ["Working Tree", "# Today", "today-1", "# Older", "older", "# Today", "skewed"])
        let keys = picker.items.map(\.key)
        #expect(Set(keys).count == keys.count, "repeated headers stay distinct")
    }

    // MARK: Row and header text

    @Test func rowsCarryTheAuthorAndNotPushedStatus() {
        let mine = Self.commit("mine", 19, 9, author: "Ada")
        let picker = state(snapshot(commits: [mine, older], unpushed: [mine.ref.sha]))
        #expect(picker.rows.map(\.authorName) == ["Ada", "Tester"])
        #expect(picker.rows.map(\.status) == [.notPushed, .none])
        #expect(picker.rows.map(\.status.text) == ["Not pushed", ""])
    }

    /// A recency header names the day, so its rows show the short form; Selected doesn't,
    /// so its row shows the full date.
    @Test func rowTimesFollowTheirSection() {
        let picked = Self.commit("picked", 18, 9)
        let picker = state(snapshot(scope: .commit(picked.ref), displayedCommit: picked, commits: [today1, older]))
        #expect(picker.rows.map(\.timeText) == ["Yesterday 09:00", "13:00", "1 Sep"])
    }

    @Test func workingTreeShowsItsChangeCountOnceKnown() {
        #expect(workingTree(state(snapshot(commits: [], count: 3)))?.detail == "3 changes")
        #expect(workingTree(state(snapshot(commits: [], count: nil)))?.detail == nil)
    }

    @Test func theHeaderDescribesTheDisplayedScope() {
        #expect(
            state(snapshot(commits: [today1], count: 2)).headerText
                == CommitPickerHeaderText(title: "Working Tree", detailParts: ["2 changes"]))
        #expect(state(snapshot(commits: [today1], count: nil)).headerText.detailParts.isEmpty)

        let mine = Self.commit("mine", 18, 9, author: "Ada")
        #expect(
            state(snapshot(scope: .commit(mine.ref), displayedCommit: mine, commits: [])).headerText
                == CommitPickerHeaderText(
                    title: "mine", detailParts: ["Ada", "Yesterday 09:00"], shortSha: mine.ref.shortSha,
                    sha: mine.ref.sha))
    }

    // MARK: Search

    @Test func aQueryMatchesTheSubjectTheAuthorOrAShaPrefix() {
        let bySubject = Self.commit("Fix the parser", 19, 13)
        let byAuthor = Self.commit("Refactor", 19, 12, author: "Grace Hopper")
        let other = Self.commit("Unrelated", 19, 11)
        var picker = state(snapshot(commits: [bySubject, byAuthor, other]))

        _ = picker.setQuery("PARSER")
        #expect(layout(picker) == ["# Today", "Fix the parser"])
        _ = picker.setQuery("hopper")
        #expect(layout(picker) == ["# Today", "Refactor"])
        _ = picker.setQuery(String(other.ref.sha.prefix(8)))
        #expect(layout(picker) == ["# Today", "Unrelated"])
        let middle = String(other.ref.sha.dropFirst(2).prefix(6))
        _ = picker.setQuery(middle)
        #expect(layout(picker) == ["! No commits match \"\(middle)\""], "only a prefix of the SHA")
    }

    /// The field drops whitespace, so the subject is matched without it too.
    @Test func aQueryWithSpacesStillMatchesTheSubject() {
        var picker = state(snapshot(commits: [Self.commit("Fix bug in parser", 19, 13), older]))
        _ = picker.setQuery(" fix bug ")
        #expect(layout(picker) == ["# Today", "Fix bug in parser"])
    }

    @Test func workingTreeMatchesOnItsTitle() {
        var picker = state(snapshot(commits: [today1]))
        _ = picker.setQuery("work")
        #expect(layout(picker) == ["Working Tree", "! No commits match \"work\""])
    }

    @Test func aQueryHidesGroupsWithoutMatchesAndHighlightsTheFirstMatch() {
        let alpha = Self.commit("alpha", 19, 13)
        let beta = Self.commit("beta", 18, 9)
        let alphaTwo = Self.commit("alpha two", 1, 9)
        var picker = state(snapshot(commits: [alpha, beta, alphaTwo]))

        let change = picker.setQuery("alpha")
        #expect(change == .reloadAll)
        #expect(layout(picker) == ["# Today", "alpha", "# Older", "alpha two"])
        #expect(picker.highlightedItemIndex == 1)

        _ = picker.setQuery("")
        #expect(layout(picker).count == 7)
        #expect(picker.highlightedItemIndex == 0, "back on the displayed scope")
    }

    // MARK: Search paging

    @Test func aSearchWithNoLoadedMatchesReadsOnUntilItsBudget() {
        var picker = state(snapshot(commits: unrelated(50), hasMore: true))
        _ = picker.setQuery("needle")
        #expect(picker.message == .loading)
        #expect(picker.shouldRequestMore(lastVisibleRow: nil), "nothing matches, so read on unscrolled")

        _ = picker.apply(snapshot(commits: unrelated(50), hasMore: true, isLoading: true))
        #expect(!picker.shouldRequestMore(lastVisibleRow: nil), "one read at a time")

        _ = picker.apply(snapshot(commits: unrelated(Self.budget), hasMore: true))
        #expect(picker.message == .capped(searched: Self.budget, hasMatches: false))
        #expect(!picker.shouldRequestMore(lastVisibleRow: picker.items.count - 1), "not even scrolled to the end")
    }

    /// No read is due until the end shows, so no loading row claims one is.
    @Test func aSearchWithMatchesReadsOnlyOnceItsEndIsVisible() {
        var picker = state(snapshot(commits: [Self.commit("needle", 19, 13)] + unrelated(49), hasMore: true))
        _ = picker.setQuery("needle")
        #expect(layout(picker) == ["# Today", "needle"])
        #expect(!picker.shouldRequestMore(lastVisibleRow: 0))
        #expect(picker.shouldRequestMore(lastVisibleRow: 1))
    }

    @Test func withNoQueryOnlyTheLastRowReadsMore() {
        var picker = state(snapshot(commits: [today1, today2], hasMore: true))
        let last = picker.items.count - 1
        #expect(picker.message == nil)
        #expect(!picker.shouldRequestMore(lastVisibleRow: last - 1))
        #expect(picker.shouldRequestMore(lastVisibleRow: last))

        _ = picker.apply(snapshot(commits: [today1, today2], hasMore: false))
        #expect(!picker.shouldRequestMore(lastVisibleRow: picker.items.count - 1), "nothing more to read")
    }

    @Test func aFailureStopsSearchPaging() {
        var picker = state(snapshot(commits: unrelated(50), hasMore: true, failed: true))
        _ = picker.setQuery("needle")
        #expect(picker.message == .failed)
        #expect(!picker.shouldRequestMore(lastVisibleRow: nil))
    }

    @Test func searchingOlderCommitsRaisesTheBudgetAndReadsOn() {
        var picker = state(snapshot(commits: unrelated(Self.budget), hasMore: true))
        _ = picker.setQuery("needle")
        #expect(!picker.shouldRequestMore(lastVisibleRow: nil))

        let change = picker.raiseSearchBudget()
        #expect(change == .update(removed: [], inserted: [], refreshed: [0]))
        #expect(picker.searchBudget == Self.budget * 2)
        #expect(picker.message == .loading)
        #expect(picker.shouldRequestMore(lastVisibleRow: nil))
    }

    /// The link reads the next page wherever the list is scrolled; once that read starts,
    /// matches go back to reading as the list scrolls.
    @Test func searchingOlderWithMatchesReadsOnUnscrolled() {
        let needle = Self.commit("needle", 19, 13)
        var picker = state(snapshot(commits: [needle] + unrelated(Self.budget - 1), hasMore: true))
        _ = picker.setQuery("needle")
        #expect(picker.message == .capped(searched: Self.budget, hasMatches: true))

        _ = picker.raiseSearchBudget()
        #expect(picker.message == .loading)
        #expect(picker.shouldRequestMore(lastVisibleRow: nil))

        _ = picker.apply(snapshot(commits: [needle] + unrelated(Self.budget - 1), hasMore: true, isLoading: true))
        _ = picker.apply(snapshot(commits: [needle] + unrelated(Self.budget + 49), hasMore: true))
        #expect(picker.message == nil)
        #expect(!picker.shouldRequestMore(lastVisibleRow: nil))
    }

    /// Pages scrolled in before the search can pass the budget: raising it still reads on.
    @Test func raisingABudgetAlreadyPassedStillReadsOn() {
        let loaded = Self.budget + 50
        var picker = state(snapshot(commits: unrelated(loaded), hasMore: true))
        _ = picker.setQuery("needle")
        #expect(picker.message == .capped(searched: loaded, hasMatches: false))

        _ = picker.raiseSearchBudget()
        #expect(picker.searchBudget == loaded + Self.budget)
        #expect(picker.shouldRequestMore(lastVisibleRow: nil))
    }

    @Test func eachNewQueryStartsWithItsOwnBudget() {
        var picker = state(snapshot(commits: unrelated(Self.budget), hasMore: true))
        _ = picker.setQuery("needle")
        _ = picker.raiseSearchBudget()
        _ = picker.setQuery("needles")
        #expect(picker.searchBudget == Self.budget)
        #expect(picker.message == .capped(searched: Self.budget, hasMatches: false))
    }

    @Test func noMatchesIsSaidOnlyOnceTheWholeHistoryIsRead() {
        var picker = state(snapshot(commits: [today1], hasMore: true))
        _ = picker.setQuery("fix bug")
        #expect(picker.message == .loading)

        _ = picker.apply(snapshot(commits: [today1, older], hasMore: false))
        #expect(picker.message == .noMatches(query: "fix bug"))
        #expect(picker.message?.text == "No commits match \"fix bug\"", "quoted as typed")
    }

    // MARK: Message rows

    @Test func aRepositoryWithNoCommitsSaysSoBelowWorkingTree() {
        let picker = state(snapshot(commits: []))
        #expect(layout(picker) == ["Working Tree", "! No commits yet"])
        #expect(picker.highlightedItemIndex == 0)
    }

    @Test func aQueryMatchingOnlyWorkingTreeAtTheBudgetIsCapped() {
        var picker = state(snapshot(commits: unrelated(Self.budget), hasMore: true))
        _ = picker.setQuery("tree")
        #expect(layout(picker) == ["Working Tree", "! No matches in the last 500 commits"])
        #expect(picker.message == .capped(searched: Self.budget, hasMatches: false))
        #expect(picker.message?.linkTitle == "Search older commits")
    }

    @Test func aCappedSearchWithMatchesSaysHowFarItLooked() {
        var picker = state(
            snapshot(commits: [Self.commit("needle", 19, 13)] + unrelated(Self.budget - 1), hasMore: true))
        _ = picker.setQuery("needle")
        #expect(picker.message == .capped(searched: Self.budget, hasMatches: true))
        #expect(picker.message?.text == "Searched the last 500 commits")
    }

    @Test func aFailedPageKeepsTheLoadedRows() {
        let picker = state(snapshot(commits: [today1, today2], hasMore: true, failed: true))
        #expect(layout(picker) == ["Working Tree", "# Today", "today-1", "today-2", "! Couldn't load history"])
        #expect(picker.message?.linkTitle == "Retry")
    }

    @Test func messagesWithoutAnActionTakeNoHighlight() {
        var noMatches = state(snapshot(commits: [today1]))
        _ = noMatches.setQuery("needle")
        let pickers = [
            state(snapshot(commits: [today1], hasMore: true, isLoading: true)), state(snapshot(commits: [])), noMatches,
        ]
        #expect(pickers.map(\.message) == [.loading, .noCommits, .noMatches(query: "needle")])
        for var picker in pickers {
            let last = picker.items.count - 1
            #expect(!picker.canHighlight(item: last))
            #expect(picker.activation(forItem: last) == nil)
            let moved = picker.highlight(item: last)
            #expect(!moved)
            picker.moveToLast()
            #expect(picker.highlightedItemIndex != last)
        }
    }

    @Test func downThenReturnOnAFailedPageRetries() {
        var picker = state(snapshot(commits: [today1], hasMore: true, failed: true))
        picker.moveDown()
        picker.moveDown()
        #expect(picker.highlightedItemIndex == 3)
        #expect(picker.highlightedActivation == .retry)

        // The retry runs: the message turns to loading and hands the highlight up.
        _ = picker.apply(snapshot(commits: [today1], hasMore: true, isLoading: true))
        #expect(picker.message == .loading)
        #expect(picker.highlightedItemIndex == 2)
    }

    @Test func downThenReturnOnACappedSearchSearchesOlder() {
        var picker = state(
            snapshot(commits: [Self.commit("needle", 19, 13)] + unrelated(Self.budget - 1), hasMore: true))
        _ = picker.setQuery("needle")
        picker.moveDown()
        #expect(picker.highlightedActivation == .searchOlder)

        _ = picker.raiseSearchBudget()
        #expect(picker.message == .loading)
        #expect(picker.highlightedItemIndex == 1)
    }

    // MARK: Highlight

    @Test func theHighlightStartsOnTheDisplayedScope() throws {
        let onCommit = state(snapshot(scope: .commit(today2.ref), displayedCommit: today2, commits: [today1, today2]))
        let row = try index(today2, in: onCommit)
        #expect(onCommit.highlightedItemIndex == row)
        #expect(onCommit.highlightedActivation == .scope(.commit(today2.ref)))

        let onTree = state(snapshot(commits: [today1, today2]))
        #expect(onTree.highlightedActivation == .scope(.workingTree))
    }

    @Test func movesSkipHeadersAndClampAtBothEnds() {
        var picker = state(snapshot(commits: [today1, yesterday]))
        picker.moveUp()
        #expect(picker.highlightedItemIndex == 0, "nothing above Working Tree")
        picker.moveDown()
        #expect(picker.highlightedItemIndex == 2)
        picker.moveDown()
        #expect(picker.highlightedItemIndex == 4)
        picker.moveDown()
        #expect(picker.highlightedItemIndex == 4, "nothing below the last row")
        picker.moveToFirst()
        #expect(picker.highlightedItemIndex == 0)
        picker.moveToLast()
        #expect(picker.highlightedItemIndex == 4)
    }

    @Test func headersTakeNoHighlight() {
        var picker = state(snapshot(commits: [today1]))
        #expect(!picker.canHighlight(item: 1))
        let onHeader = picker.highlight(item: 1)
        let onRow = picker.highlight(item: 2)
        let again = picker.highlight(item: 2)
        let pastTheEnd = picker.highlight(item: 9)
        #expect(!onHeader)
        #expect(onRow)
        #expect(!again, "already there")
        #expect(!pastTheEnd)
    }

    @Test func arrowsFromAClearedHighlightLandOnTheDisplayedScope() {
        var picker = state(
            snapshot(scope: .commit(yesterday.ref), displayedCommit: yesterday, commits: [today1, yesterday]))
        picker.clearHighlight()
        #expect(picker.highlight == .cleared)
        #expect(picker.highlightedActivation == nil, "Return does nothing")

        picker.moveUp()
        #expect(picker.highlightedActivation == .scope(.commit(yesterday.ref)))
        picker.clearHighlight()
        picker.moveDown()
        #expect(picker.highlightedActivation == .scope(.commit(yesterday.ref)))
    }

    @Test func arrowsFromAClearedHighlightTakeTheFirstRowWhenAQueryHidesTheDisplayedScope() {
        var picker = state(snapshot(commits: [today1, today2]))
        _ = picker.setQuery("today-2")
        picker.clearHighlight()
        picker.moveDown()
        #expect(picker.highlightedActivation == .scope(.commit(today2.ref)))
    }

    @Test func snapshotsAndPagesLeaveAClearedHighlightCleared() {
        var picker = state(snapshot(commits: [today1], hasMore: true))
        picker.clearHighlight()
        _ = picker.apply(snapshot(commits: [today1], hasMore: true, count: 5))
        #expect(picker.highlight == .cleared)
        _ = picker.apply(snapshot(commits: [today1, older], unpushed: [today1.ref.sha]))
        #expect(picker.highlight == .cleared)

        _ = picker.setQuery("today")
        #expect(picker.highlightedActivation == .scope(.commit(today1.ref)), "a new query replaces it")
    }

    @Test func rowsArrivingAfterASearchFoundNothingTakeTheFirstMatch() {
        var picker = state(snapshot(commits: [older], hasMore: true))
        _ = picker.setQuery("needle")
        #expect(picker.highlight == .none)

        let hit = Self.commit("needle", 1, 8)
        _ = picker.apply(snapshot(commits: [older, hit], hasMore: true))
        #expect(picker.highlightedActivation == .scope(.commit(hit.ref)))
    }

    @Test func theHighlightFollowsItsCommitAcrossAReload() throws {
        var picker = state(snapshot(commits: [today1, today2, yesterday]))
        picker.highlight(item: try index(today2, in: picker))
        _ = picker.apply(snapshot(commits: [Self.commit("fresh", 19, 14), today1, today2, yesterday]))
        #expect(picker.highlightedActivation == .scope(.commit(today2.ref)))
    }

    @Test func aRemovedHighlightMovesToTheNextRowElseThePrevious() throws {
        var picker = state(snapshot(commits: [today1, today2, yesterday]))
        picker.highlight(item: try index(today2, in: picker))
        _ = picker.apply(snapshot(commits: [today1, yesterday]))
        #expect(picker.highlightedActivation == .scope(.commit(yesterday.ref)))

        _ = picker.apply(snapshot(commits: [today1]))
        #expect(picker.highlightedActivation == .scope(.commit(today1.ref)))
    }

    // MARK: Table changes

    @Test func anAppendedPageReplacesTheLoadingMessage() {
        var picker = state(snapshot(commits: [today1, today2], hasMore: true, isLoading: true))
        let change = picker.apply(snapshot(commits: [today1, today2, yesterday, older], hasMore: true))
        #expect(change == .update(removed: [4], inserted: [4, 5, 6, 7], refreshed: []))
    }

    @Test func aPageInTheSameGroupInsertsOnlyItsRows() {
        var picker = state(snapshot(commits: [today1], hasMore: true))
        let change = picker.apply(snapshot(commits: [today1, today2]))
        #expect(change == .update(removed: [], inserted: [3], refreshed: []))
    }

    @Test func statusChangesRefreshOnlyTheirRows() {
        var picker = state(snapshot(commits: [today1, today2], count: 3))
        let unpushed = snapshot(commits: [today1, today2], count: 3, unpushed: [today2.ref.sha])
        let statusChange = picker.apply(unpushed)
        #expect(statusChange == .update(removed: [], inserted: [], refreshed: [3]))
        let counted = snapshot(commits: [today1, today2], count: 4, unpushed: [today2.ref.sha])
        let countChange = picker.apply(counted)
        let repeated = picker.apply(counted)
        #expect(countChange == .update(removed: [], inserted: [], refreshed: [0]))
        #expect(repeated == .none)
    }

    @Test func aQueryChangeReloadsEverythingAndTheSameQueryNothing() {
        var picker = state(snapshot(commits: [today1]))
        let typed = picker.setQuery("today")
        let padded = picker.setQuery(" today ")
        let cleared = picker.setQuery("   ")
        #expect(typed == .reloadAll)
        #expect(padded == .none)
        #expect(cleared == .reloadAll)
    }
}
