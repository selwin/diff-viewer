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
        let repo = h.repo("A", files: workingFiles)
        await repo.client.set(head: commits.first?.ref.sha)
        await repo.client.set(commits: commits)
        let before = h.published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count > before })
        #expect(await eventually { await !state.isLoadingHistory })
        return repo.client
    }

    /// A page and one more, so `hasMore` holds after the first page.
    private var twoPages: [CommitSummary] {
        (0...WindowState.commitPageSize * 2).map { commitSummary("c\($0)") }
    }

    // MARK: File count

    @Test func fileCountIsOfDistinctPaths() async {
        let h = Harness()
        let state = h.makeState()
        _ = await adopt(h, state, commits: [commitSummary("c1")])
        #expect(state.files.count == 3)
        #expect(state.displayedScopeFileCount == 2, "a file staged and unstaged counts once")
        #expect(state.commitPickerSnapshot.displayedScopeFileCount == 2)
    }

    @Test func fileCountIsUnknownWhileAScopeLoads() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commits: [commit])
        let file = ChangedFile(path: "one.swift", originalPath: nil, kind: .modified, area: .commit(commit.ref))
        await client.set(files: [file], forCommit: commit.ref.sha)

        await client.holdCommitFiles(true)
        state.select(commit: commit)
        #expect(await eventually { await client.heldCommitFileCount == 1 })
        #expect(state.isLoadingScope)
        #expect(state.displayedScopeFileCount == nil)

        await client.holdCommitFiles(false)
        await client.releaseCommitFiles()
        #expect(await eventually { await !state.isLoadingScope })
        #expect(state.displayedScopeFileCount == 1)
    }

    @Test func fileCountIsUnknownAfterAFailedListRead() async {
        let h = Harness()
        let state = h.makeState()
        let client = await adopt(h, state, commits: [commitSummary("c1")])
        await client.fail(true)
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await state.listReadFailed })
        #expect(state.displayedScopeFileCount == nil)

        await client.fail(false)
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await !state.listReadFailed })
        #expect(state.displayedScopeFileCount == 2)
    }

    // MARK: Snapshot

    @Test func snapshotKeepsTheDisplayedCommitWhenThePageDropsIt() async {
        let h = Harness()
        let state = h.makeState()
        let first = commitSummary("c1")
        let second = commitSummary("c2")
        let client = await adopt(h, state, commits: [first])

        state.select(commit: first)
        #expect(await eventually { await h.published.last?.cause == .scope })
        await client.set(commits: [second])
        await client.set(head: second.ref.sha)
        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await state.history.commits == [second] })

        let snapshot = state.commitPickerSnapshot
        #expect(snapshot.displayedScope == .commit(first.ref))
        #expect(snapshot.displayedCommit == first)
        #expect(snapshot.commits == [first, second])
        #expect(!snapshot.historyLoadFailed)

        let listSnapshot = state.commitPickerListSnapshot
        #expect(listSnapshot.displayedCommit == first)
        #expect(listSnapshot.commits == [second], "the page alone; the list gives the selection its own section")
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
        await client.holdHistory(true)
        let heads = await client.headCalls
        state.retryHistoryLoad()
        #expect(await eventually { await client.heldHistoryCount == 1 })
        #expect(await client.headCalls == heads + 1, "HEAD is read again")
        #expect(await client.lastHistorySkip == page)
        #expect(state.isLoadingHistory)

        state.retryHistoryLoad()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await client.headCalls == heads + 1, "no retry while one is running")
        #expect(await client.heldHistoryCount == 1)

        await client.fail(history: true)
        await client.holdHistory(false)
        await client.releaseHistory()
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
        await client.holdHistory(true)
        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await client.heldHistoryCount == 1 })
        await client.fail(history: true)
        await client.holdHistory(false)
        await client.releaseHistory()
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

    @Test func loadMoreAppendsOnlyTheNextPage() async {
        let h = Harness()
        let state = h.makeState()
        let client = await adopt(h, state, commits: twoPages)
        let revision = state.history.revision

        state.loadMoreCommits()
        #expect(await eventually { await state.history.commits.count == WindowState.commitPageSize * 2 })
        #expect(state.history.commits == Array(twoPages.prefix(WindowState.commitPageSize * 2)))
        #expect(state.history.hasMore)
        #expect(state.history.revision == revision)
        #expect(await client.lastHistorySkip == WindowState.commitPageSize)
        #expect(await client.lastHistoryLimit == WindowState.commitPageSize + 1)
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
        await client.holdHistory(true)
        state.loadMoreCommits()
        #expect(await eventually { await client.heldHistoryCount == 1 })

        let moved = (0...WindowState.commitPageSize).map { commitSummary("m\($0)") }
        await client.set(head: objectID("moved"))
        await client.set(commits: moved)
        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await client.heldHistoryCount == 2 })
        #expect(await client.lastHistorySkip == 0)

        await client.holdHistory(false)
        await client.releaseHistory()
        #expect(await eventually { await !state.isLoadingHistory })
        #expect(state.history.revision == objectID("moved"))
        #expect(state.history.commits == Array(moved.prefix(WindowState.commitPageSize)))
    }

    // MARK: Presentation guards

    @Test func thePickerAndTheCommitSheetNeverStack() async {
        let h = Harness()
        let state = h.makeState()
        _ = await adopt(h, state, commits: [commitSummary("c1")])
        #expect(await eventually { await state.canOpenCommitSheet })
        #expect(state.canOpenCommitPicker)

        state.isCommitSheetPresented = true
        #expect(!state.canOpenCommitPicker)
        state.isCommitSheetPresented = false
        #expect(state.canOpenCommitPicker)

        state.isCommitPickerPresented = true
        #expect(!state.canOpenCommitSheet)
        state.isCommitPickerPresented = false
        #expect(state.canOpenCommitSheet)

        state.isCommitPickerPresented = true
        state.close()
        #expect(!state.isCommitPickerPresented)
        #expect(!state.canOpenCommitPicker)
    }
}
