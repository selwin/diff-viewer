import Foundation
import Testing

@testable import DiffViewer

/// London, with "now" pinned to Saturday 19 September 2026 at 14:02.
struct StashPickerStateTests {
    private static let timeZone = TimeZone(identifier: "Europe/London")!
    private static let now = at(19, 14, 2)
    private let grouping = CommitDayGrouping(
        calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"),
        timeZone: StashPickerStateTests.timeZone, now: StashPickerStateTests.now)

    /// A London time in September 2026.
    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// A stash whose message is also its seed, so layouts read as messages. Equal messages
    /// make identical duplicates.
    private static func entry(_ message: String, _ index: Int, branch: String? = "main", day: Int = 19, hour: Int = 13)
        -> StashEntry
    {
        StashEntry(
            stashIndex: index, sha: "sha-\(message)", shortSha: "short", parents: ["p"], committedAt: at(day, hour),
            author: "Tester", message: message, sourceBranch: branch, hasDefaultMessage: false, churn: nil)
    }

    /// Today's stashes named in order, indexed by position.
    private static func today(_ messages: [String]) -> [StashEntry] {
        messages.enumerated().map { entry($1, $0) }
    }

    private func snapshot(
        _ stashes: [StashEntry], status: StashReadStatus = .loaded, displayed: String? = nil
    ) -> StashPickerSnapshot {
        StashPickerSnapshot(
            stashes: stashes, readStatus: status,
            displayedRef: displayed.map { CommitRef(sha: $0, shortSha: "short", firstParentSHA: "p") })
    }

    private func state(_ snapshot: StashPickerSnapshot) -> StashPickerState {
        StashPickerState(snapshot: snapshot, grouping: grouping)
    }

    /// Headers by title and stashes by message, in table order.
    private func layout(_ picker: StashPickerState) -> [String] {
        picker.items.map { item in
            switch item {
            case let .header(group): "# \(group.title)"
            case let .stash(row): row.entry.message
            }
        }
    }

    private func highlightedIndex(_ picker: StashPickerState) -> Int? {
        picker.highlightedActivation?.stashIndex
    }

    private var mixed: [StashEntry] {
        [
            Self.entry("login fix", 0, branch: "feature/auth", hour: 13),
            Self.entry("spike", 1, branch: "main", hour: 9),
            Self.entry("old work", 2, branch: "feature/auth", day: 18),
            Self.entry("ancient", 3, branch: nil, day: 1),
        ]
    }

    // MARK: Filtering and headers

    @Test func stashesKeepGitOrderUnderTheirGroupsWithShortTimes() {
        let picker = state(snapshot(mixed))
        #expect(
            layout(picker) == [
                "# Today", "login fix", "spike", "# Yesterday", "old work", "# Older", "ancient",
            ])
        #expect(picker.rows.map(\.timeText) == ["13:00", "09:00", "13:00", "1 Sep"])
    }

    /// A clock-skewed list repeats a header rather than reordering git's stashes.
    @Test func aClockSkewedListRepeatsHeaders() {
        let skewed = [Self.entry("a", 0), Self.entry("b", 1, day: 1), Self.entry("c", 2)]
        #expect(layout(state(snapshot(skewed))) == ["# Today", "a", "# Older", "b", "# Today", "c"])
    }

    @Test(arguments: [
        ("LOGIN", ["# Today", "login fix"]),
        ("lo gin", ["# Today", "login fix"]),
        ("feature/auth", ["# Today", "login fix", "# Yesterday", "old work"]),
        ("main", ["# Today", "spike"]),
        ("anc", ["# Older", "ancient"]),
    ])
    func aQueryMatchesMessageOrBranchAndDropsEmptyGroups(query: String, expected: [String]) {
        var picker = state(snapshot(mixed))
        let change = picker.setQuery(query)
        #expect(change == .reloadAll)
        #expect(layout(picker) == expected)
    }

    @Test func repeatingTheSameQueryChangesNothing() {
        var picker = state(snapshot(mixed))
        _ = picker.setQuery("login")
        #expect(picker.setQuery("login") == .none)
    }

    @Test func aQueryWithNoHitsListsNothing() {
        var picker = state(snapshot(mixed))
        _ = picker.setQuery("zzz")
        #expect(picker.items.isEmpty)
        #expect(picker.emptyText == "No matching stashes")
        #expect(picker.highlightedActivation == nil)
    }

    @Test func whitespaceOnlyQueryShowsAllStashes() {
        var picker = state(snapshot(mixed))
        _ = picker.setQuery("  ")
        #expect(picker.rows.count == 4)
    }

    // MARK: Highlight

    @Test func highlightStartsOnTheDisplayedStashElseTheFirst() {
        #expect(highlightedIndex(state(snapshot(mixed))) == 0)
        #expect(highlightedIndex(state(snapshot(mixed, displayed: "sha-old work"))) == 2)

        var picker = state(snapshot(mixed, displayed: "sha-old work"))
        _ = picker.setQuery("spike")
        #expect(highlightedIndex(picker) == 1, "a search starts on its first match")
    }

    @Test func movesSkipHeadersAndClampAtBothEnds() {
        var picker = state(snapshot(mixed))
        picker.moveUp()
        #expect(highlightedIndex(picker) == 0)
        picker.moveDown()
        picker.moveDown()
        #expect(highlightedIndex(picker) == 2, "skips the Yesterday header")
        picker.moveToLast()
        picker.moveDown()
        #expect(highlightedIndex(picker) == 3)
        picker.moveToFirst()
        #expect(highlightedIndex(picker) == 0)
    }

    @Test func hoverIgnoresHeadersAndLeavingClearsUntilTheNextHover() {
        var picker = state(snapshot(mixed))
        let onHeader = picker.highlight(item: 0)
        let onRow = picker.highlight(item: 2)
        #expect(!onHeader && onRow, "a header takes no hover")
        #expect(highlightedIndex(picker) == 1)
        picker.clearHighlight()
        #expect(picker.highlightedActivation == nil)
        _ = picker.apply(snapshot(Array(mixed.dropFirst())))
        #expect(picker.highlightedActivation == nil, "a snapshot does not undo the pointer leaving")
        picker.moveDown()
        #expect(highlightedIndex(picker) != nil)
    }

    struct Reconcile: CustomTestStringConvertible {
        let name: String
        let old: [String]
        let highlighted: Int
        let new: [String]
        /// The stash index highlighted afterwards.
        let expected: Int?
        var testDescription: String { name }
    }

    @Test(arguments: [
        Reconcile(
            name: "a new top stash", old: ["a", "b", "c"], highlighted: 1, new: ["x", "a", "b", "c"], expected: 2),
        Reconcile(name: "a drop before it", old: ["a", "b", "c"], highlighted: 2, new: ["b", "c"], expected: 1),
        Reconcile(name: "it is dropped", old: ["a", "b", "c"], highlighted: 1, new: ["a", "c"], expected: 1),
        Reconcile(name: "the last is dropped", old: ["a", "b", "c"], highlighted: 2, new: ["a", "b"], expected: 1),
        Reconcile(
            name: "it and the one before are dropped", old: ["a", "b", "c", "d"], highlighted: 1, new: ["c", "d"],
            expected: 0),
        Reconcile(
            name: "it and everything after are dropped", old: ["a", "b", "c", "d"], highlighted: 2, new: ["a", "b"],
            expected: 1),
        Reconcile(
            name: "identical duplicates", old: ["d", "a", "d"], highlighted: 2, new: ["d", "d", "a"], expected: 1),
        Reconcile(name: "all dropped", old: ["a", "b"], highlighted: 1, new: [], expected: nil),
    ])
    func theHighlightFollowsItsEntryAcrossReindexing(_ test: Reconcile) {
        var picker = state(snapshot(Self.today(test.old)))
        picker.highlight(item: test.highlighted + 1)
        let change = picker.apply(snapshot(Self.today(test.new)))
        #expect(change == .reloadAll)
        #expect(highlightedIndex(picker) == test.expected)
    }

    @Test func aSnapshotThatChangesNothingVisibleReloadsNothing() {
        var picker = state(snapshot(mixed))
        let same = picker.apply(snapshot(mixed))
        let statusOnly = picker.apply(snapshot(mixed, status: .failed))
        #expect(same == .none && statusOnly == .none, "only the header changes")
        #expect(picker.headerText.subtitle == "Couldn't refresh stashes")
    }

    // MARK: Text

    @Test(arguments: [
        (StashReadStatus.unread, 0, "Loading stashes…", nil as String?),
        (.failed, 0, "Couldn't read stashes", nil),
        (.failed, 2, "Couldn't refresh stashes", nil),
        (.loaded, 0, "No stashes", "Stashed changes will appear here."),
        (.loaded, 1, "1 stash · newest 1 h ago", nil),
        (.loaded, 2, "2 stashes · newest 1 h ago", nil),
    ])
    func subtitleAndEmptyTextFollowTheReadState(
        status: StashReadStatus, count: Int, subtitle: String, empty: String?
    ) {
        let picker = state(snapshot(Self.today((0..<count).map(String.init)), status: status))
        #expect(picker.headerText == StashPickerHeaderText(title: "Stashes", subtitle: subtitle))
        #expect(picker.emptyText == empty)
    }

    @Test(arguments: [
        (StashReadStatus.unread, 0, nil as String?),
        (.failed, 0, nil),
        (.loaded, 0, "Stashed changes will appear here."),
        (.loaded, 2, "No matching stashes"),
    ])
    func aQueryWithNoHitsOnlyClaimsNoMatchesOnceThereIsAList(status: StashReadStatus, count: Int, empty: String?) {
        var picker = state(snapshot(Self.today((0..<count).map(String.init)), status: status))
        _ = picker.setQuery("zzz")
        #expect(picker.emptyText == empty)
    }

    @Test func everyEntrySharingTheDisplayedShaIsMarkedDisplayed() {
        let picker = state(snapshot(Self.today(["a", "d", "b", "d"]), displayed: "sha-d"))
        #expect(picker.rows.map(\.isDisplayed) == [false, true, false, true])
    }

    // MARK: Buttons

    private struct Pair: Equatable {
        let pop: PickerButtonState
        let drop: PickerButtonState
    }

    private static let busy = PickerButtonState.disabled(reason: "Another stash action is running")

    /// Pop and Drop for each stash row, in table order.
    private func buttons(_ picker: StashPickerState) -> [Pair] {
        picker.items.indices.compactMap { index in
            picker.buttons(forItem: index).map { Pair(pop: $0.pop, drop: $0.drop) }
        }
    }

    private func running(_ stashes: [StashEntry], _ operation: ActiveStashOperation.Operation, index: Int, sha: String)
        -> StashPickerSnapshot
    {
        var running = snapshot(stashes)
        running.activeOperation = ActiveStashOperation(stashIndex: index, sha: sha, operation: operation)
        return running
    }

    @Test func buttonsAreEnabledWithNoOperationAndNoBlockedReason() {
        let picker = state(snapshot(Self.today(["a", "b"])))
        #expect(buttons(picker) == Array(repeating: Pair(pop: .enabled, drop: .enabled), count: 2))
    }

    @Test(arguments: [ActiveStashOperation.Operation.pop, .drop])
    func theRunningRowShowsRunningAndEveryOtherButtonIsDisabled(operation: ActiveStashOperation.Operation) {
        let stashes = Self.today(["a", "b"])
        let picker = state(running(stashes, operation, index: 0, sha: stashes[0].sha))
        let first =
            operation == .pop ? Pair(pop: .running, drop: Self.busy) : Pair(pop: Self.busy, drop: .running)
        #expect(buttons(picker) == [first, Pair(pop: Self.busy, drop: Self.busy)])
    }

    @Test func anotherShaOrAnotherIndexIsNotTheRunningRow() {
        // Two entries can share a sha; the index tells them apart.
        let stashes = Self.today(["a", "a"])
        let disabled = Array(repeating: Pair(pop: Self.busy, drop: Self.busy), count: 2)
        #expect(buttons(state(running(stashes, .pop, index: 0, sha: "other"))) == disabled)
        #expect(buttons(state(running(stashes, .pop, index: 5, sha: stashes[0].sha))) == disabled)
    }

    @Test func aBlockedReasonDisablesBothButtons() {
        var blocked = snapshot(Self.today(["a", "b"]))
        blocked.actionsBlockedReason = "A commit is running"
        let reason = PickerButtonState.disabled(reason: "A commit is running")
        #expect(buttons(state(blocked)) == Array(repeating: Pair(pop: reason, drop: reason), count: 2))
    }

    @Test func buttonsAreEnabledAgainOnceTheOperationClears() {
        let stashes = Self.today(["a", "b"])
        var picker = state(running(stashes, .pop, index: 0, sha: stashes[0].sha))
        _ = picker.apply(snapshot(stashes))
        #expect(buttons(picker) == Array(repeating: Pair(pop: .enabled, drop: .enabled), count: 2))
    }
}
