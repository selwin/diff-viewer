import Foundation
import Testing

@testable import DiffViewer

/// What the commit picker reads from a window, and its Retry.
@MainActor
struct WindowStateCommitPickerTests {
    private let workingFiles = [changedFile("a.swift"), changedFile("a.swift", area: .staged), changedFile("b.swift")]

    /// Adopts a repository whose HEAD is the first of `commits`, and waits for both the
    /// file list and the commit list to arrive.
    private func adopt(_ h: Harness, _ state: WindowState, commits: [CommitSummary]) async -> StubRepoClient {
        let client = await h.adoptWithHistory(state, files: workingFiles, commits: commits)
        #expect(await eventually { await !state.isLoadingHistory })
        return client
    }

    /// A page and one more, so `hasMore` holds after the first page.
    private var twoPages: [CommitSummary] {
        (0...WindowState.commitPageSize * 2).map { commitSummary("c\($0)") }
    }

    // MARK: Snapshot

    /// The picker has to tick what is on screen even after the page stops listing it, so
    /// the selected commit is kept in the rows until it is deselected.
    @Test func snapshotKeepsTheDisplayedCommitWhenThePageDropsIt() async {
        let h = Harness()
        let state = h.makeState()
        let first = commitSummary("c1")
        let second = commitSummary("c2")
        let client = await adopt(h, state, commits: [first])
        #expect(state.selectableCommits == [first])

        state.select(commit: first)
        #expect(await eventually { await h.published.last?.cause == .scope })
        await client.set(commits: [second])
        await client.set(head: second.ref.sha)
        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await state.history.commits == [second] })
        #expect(state.selectableCommits == [first, second])

        let snapshot = state.commitPickerSnapshot
        #expect(snapshot.displayedScope == .commit(first.ref))
        #expect(snapshot.displayedCommit == first)
        #expect(snapshot.commits == [second], "the page alone; the list gives the selection its own section")
        #expect(!snapshot.historyLoadFailed)

        state.selectWorkingTree()
        #expect(state.selectableCommits == [second])
        #expect(await eventually { await state.files.count == workingFiles.count })
    }

    @Test func snapshotReportsAFailedLoadMoreOverALoadedPage() async {
        let h = Harness()
        let state = h.makeState()
        let client = await adopt(h, state, commits: twoPages)
        #expect(state.history.hasMore)

        await client.fail(history: true)
        state.loadMoreCommits()
        #expect(await eventually { await state.historyErrorMessage != nil })

        let snapshot = state.commitPickerSnapshot
        #expect(snapshot.historyLoadFailed)
        #expect(snapshot.hasMore)
        #expect(snapshot.commits.count == WindowState.commitPageSize)
    }

    // MARK: Retry

    /// Retry asks again for the page the failed Load More asked for; a second failure and
    /// a second Retry stay on it too, so repeated failures never skip or repeat commits.
    @Test func retryAfterAFailedLoadMoreRepeatsThatPage() async {
        let h = Harness()
        let state = h.makeState()
        let client = await adopt(h, state, commits: twoPages)
        let page = WindowState.commitPageSize

        await client.fail(history: true)
        state.loadMoreCommits()
        #expect(await eventually { await state.historyErrorMessage != nil })
        #expect(await client.lastHistorySkip == page)
        #expect(await client.lastHistoryLimit == page + 1)

        // First retry, held so it can be failed again after it asked.
        await client.fail(history: false)
        await client.hold(.history)
        let heads = await client.headCalls
        state.retryHistoryLoad()
        #expect(await eventually { await client.heldCount(.history) == 1 })
        #expect(await client.headCalls == heads + 1, "HEAD is read again")
        #expect(await client.lastHistorySkip == page)
        #expect(state.isLoadingHistory)

        state.retryHistoryLoad()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await client.headCalls == heads + 1, "no retry while one is running")
        #expect(await client.heldCount(.history) == 1)

        await client.fail(history: true)
        await client.hold(.history, false)
        await client.release(.history)
        #expect(await eventually { await state.historyErrorMessage != nil })

        // Second retry succeeds at the same limit.
        await client.fail(history: false)
        state.retryHistoryLoad()
        #expect(await eventually { await !state.isLoadingHistory })
        #expect(state.historyErrorMessage == nil)
        #expect(await client.headCalls == heads + 2)
        #expect(await client.lastHistorySkip == page, "never moved by a retry")
        #expect(state.history.commits == Array(twoPages.prefix(page * 2)), "the page is appended once")

        state.retryHistoryLoad()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await client.headCalls == heads + 2, "nothing to retry")
    }

    /// A checkout whose history reload failed, then Retry and a watcher tick for the same
    /// HEAD at once: both want the new revision, and the picker must end up on it with
    /// the page size reset, whichever read lands.
    @Test func retryInterleavedWithAWatcherTickAfterAFailedReload() async {
        let h = Harness()
        let state = h.makeState()
        let first = commitSummary("c1")
        let client = await adopt(h, state, commits: [first])
        #expect(state.history.revision == first.ref.sha)
        let newHead = objectID("moved")
        let commits = (0...WindowState.commitPageSize).map { commitSummary("m\($0)") }
        await client.set(commits: commits)
        await client.set(head: newHead)

        // The reload the checkout triggers reaches `git log`, which fails.
        await client.hold(.history)
        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await client.heldCount(.history) == 1 })
        await client.fail(history: true)
        await client.hold(.history, false)
        await client.release(.history)
        #expect(await eventually { await state.historyErrorMessage != nil })
        #expect(state.history.revision == first.ref.sha, "the last good page stays")

        await client.fail(history: false)
        state.retryHistoryLoad()
        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await state.history.revision == newHead })
        #expect(await eventually { await !state.isLoadingHistory })
        #expect(state.historyErrorMessage == nil)
        #expect(await client.lastHistorySkip == 0)
        #expect(state.history.commits.count == WindowState.commitPageSize)
        #expect(state.history.hasMore)
    }

    // MARK: Paging

    /// Each page asks for one commit more than it shows, which is how `hasMore` is known,
    /// and pages the revision on show.
    @Test func loadMoreAppendsOnlyTheNextPage() async {
        let h = Harness()
        let state = h.makeState()
        let client = await adopt(h, state, commits: twoPages)
        let revision = state.history.revision
        #expect(state.history.commits.count == WindowState.commitPageSize)
        #expect(state.history.hasMore)
        #expect(await client.lastHistoryLimit == WindowState.commitPageSize + 1)

        state.loadMoreCommits()
        #expect(await eventually { await state.history.commits.count == WindowState.commitPageSize * 2 })
        #expect(state.history.commits == Array(twoPages.prefix(WindowState.commitPageSize * 2)))
        #expect(state.history.hasMore)
        #expect(state.history.revision == revision)
        #expect(await client.lastHistorySkip == WindowState.commitPageSize)
        #expect(await client.lastHistoryLimit == WindowState.commitPageSize + 1)
        #expect(await client.lastHistoryRevision == revision, "paging stays on the loaded revision")

        state.loadMoreCommits()
        #expect(await eventually { await state.history.commits.count == WindowState.commitPageSize * 2 + 1 })
        #expect(state.history.commits == twoPages)
        #expect(!state.history.hasMore, "the last page has no extra commit")
    }

    /// A Retry after HEAD moved must not append the old revision's next page to a list
    /// that now belongs elsewhere: it starts again at page one.
    @Test func retryAfterHeadMovedRestartsAtPageOne() async {
        let h = Harness()
        let state = h.makeState()
        let client = await adopt(h, state, commits: twoPages)
        await client.fail(history: true)
        state.loadMoreCommits()
        #expect(await eventually { await state.historyErrorMessage != nil })

        let moved = (0...WindowState.commitPageSize).map { commitSummary("m\($0)") }
        await client.set(head: objectID("moved"))
        await client.set(commits: moved)
        await client.fail(history: false)
        state.retryHistoryLoad()
        #expect(await eventually { await state.history.revision == objectID("moved") })
        #expect(state.history.commits == Array(moved.prefix(WindowState.commitPageSize)))
        #expect(await client.lastHistorySkip == 0)
        #expect(state.historyErrorMessage == nil)
    }

    @Test func aHeadMoveDuringANextPageDropsThatPage() async {
        let h = Harness()
        let state = h.makeState()
        let client = await adopt(h, state, commits: twoPages)
        await client.hold(.history)
        state.loadMoreCommits()
        #expect(await eventually { await client.heldCount(.history) == 1 })

        let moved = (0...WindowState.commitPageSize).map { commitSummary("m\($0)") }
        await client.set(head: objectID("moved"))
        await client.set(commits: moved)
        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await client.heldCount(.history) == 2 })
        #expect(await client.lastHistorySkip == 0)

        await client.hold(.history, false)
        await client.release(.history)
        #expect(await eventually { await !state.isLoadingHistory })
        #expect(state.history.revision == objectID("moved"))
        #expect(state.history.commits == Array(moved.prefix(WindowState.commitPageSize)))
    }

    // MARK: Presentation guards

    @Test func closingClearsTheCommitPicker() async {
        let h = Harness()
        let state = h.makeState()
        _ = await adopt(h, state, commits: [commitSummary("c1")])
        state.isCommitPickerPresented = true

        state.close()
        #expect(!state.isCommitPickerPresented)
        #expect(!state.canOpenCommitPicker)
    }
}
