import Foundation
import Testing

@testable import DiffViewer

@MainActor
struct WindowStateScopeTests {
    let workingFiles = [changedFile("a1.swift"), changedFile("a2.swift", area: .staged)]

    /// Adopts a repository whose history holds `commit`, and waits for both the file
    /// list and the commit list to arrive.
    private func adopt(
        _ h: Harness, _ state: WindowState, commit: CommitSummary, commitFiles: [ChangedFile]
    ) async -> StubRepoClient {
        let repo = h.repo("A", files: workingFiles)
        await repo.client.set(head: commit.ref.sha)
        await repo.client.set(commits: [commit])
        await repo.client.set(files: commitFiles, forCommit: commit.ref.sha)
        let before = h.published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count > before })
        #expect(await eventually { !state.history.commits.isEmpty })
        return repo.client
    }

    private func commitFile(_ path: String, _ commit: CommitSummary, kind: ChangedFile.Kind = .modified)
        -> ChangedFile
    {
        ChangedFile(path: path, originalPath: nil, kind: kind, area: .commit(commit.ref))
    }

    @Test func selectingACommitReplacesTheFileList() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1", subject: "Add the picker")
        let files = [commitFile("src/picker.swift", commit)]
        _ = await adopt(h, state, commit: commit, commitFiles: files)

        state.select(commit: commit)
        #expect(await eventually { state.files.map(\.path) == ["src/picker.swift"] })
        #expect(state.scope == .commit(commit.ref))
        #expect(state.selectedCommit == commit)
        #expect(state.unstagedFiles.isEmpty)
        #expect(state.commitFiles.count == 1)

        state.selectWorkingTree()
        #expect(await eventually { state.files.map(\.path) == workingFiles.map(\.path) })
        #expect(state.selectedCommit == nil)
    }

    @Test func selectionFollowsThePathIntoTheNewScope() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        _ = await adopt(h, state, commit: commit, commitFiles: [commitFile("a1.swift", commit)])
        state.selectedFileID = workingFiles[0].id

        state.select(commit: commit)
        #expect(await eventually { state.selectedFileID != nil })
        #expect(state.selectedFile?.path == "a1.swift")
        #expect(state.selectedFile?.area == .commit(commit.ref))
    }

    @Test func selectionClearsWhenThePathIsNotInTheNewScope() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        _ = await adopt(h, state, commit: commit, commitFiles: [commitFile("other.swift", commit)])
        state.selectedFileID = workingFiles[0].id

        state.select(commit: commit)
        #expect(await eventually { state.files.map(\.path) == ["other.swift"] })
        #expect(state.selectedFileID == nil)
    }

    /// A path staged and unstaged at once has a defined winner on the way back.
    @Test func returningToTheWorkingTreePrefersTheUnstagedEntry() async {
        let h = Harness()
        let state = h.makeState()
        let both = [changedFile("dup.swift"), changedFile("dup.swift", area: .staged)]
        let commit = commitSummary("c1")
        let repo = h.repo("A", files: both)
        await repo.client.set(head: commit.ref.sha)
        await repo.client.set(commits: [commit])
        await repo.client.set(files: [commitFile("dup.swift", commit)], forCommit: commit.ref.sha)
        let before = h.published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count > before })
        #expect(await eventually { !state.history.commits.isEmpty })

        state.select(commit: commit)
        #expect(await eventually { state.files.count == 1 })
        state.selectedFileID = state.files.first?.id
        #expect(state.selectedFile?.area == .commit(commit.ref))

        state.selectWorkingTree()
        #expect(await eventually { state.files.count == 2 })
        #expect(await eventually { state.selectedFileID != nil })
        #expect(state.selectedFile?.area == .unstaged)
    }

    /// The race the separate history generation exists for: a watcher tick that only
    /// reloads the commit list must not cancel an in-flight scope change.
    @Test func aWatcherTickDuringAScopeLoadDoesNotDiscardItsFiles() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [commitFile("src/held.swift", commit)])

        await client.holdCommitFiles(true)
        state.select(commit: commit)
        #expect(await eventually { await client.heldCommitFileCount == 1 })

        // The watcher fires while the commit's files are still being read.
        h.watcherCallbacks.values.first?()
        try? await Task.sleep(for: .milliseconds(50))

        await client.holdCommitFiles(false)
        await client.releaseCommitFiles()
        #expect(await eventually { state.files.map(\.path) == ["src/held.swift"] })
    }

    @Test func rapidScopeSwitchingSettlesOnTheLastChoice() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        _ = await adopt(h, state, commit: commit, commitFiles: [commitFile("src/one.swift", commit)])

        state.select(commit: commit)
        state.selectWorkingTree()
        state.select(commit: commit)
        #expect(await eventually { state.files.map(\.path) == ["src/one.swift"] })
        #expect(state.scope == .commit(commit.ref))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(state.files.map(\.path) == ["src/one.swift"], "no stale working-tree publish arrives late")
    }

    /// A commit cannot change, so an edit elsewhere in the tree must not re-read it,
    /// republish the list, or reload the diff.
    @Test func aWatcherTickWithUnmovedHeadDoesNothingInCommitScope() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [commitFile("src/one.swift", commit)])

        state.select(commit: commit)
        #expect(await eventually { state.files.count == 1 })
        let publishes = h.published.count
        let reads = await client.commitFileCalls
        let historyReads = await client.historyCalls

        h.watcherCallbacks.values.first?()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(h.published.count == publishes, "no file-list publish")
        #expect(await client.commitFileCalls == reads, "the commit's files are not re-read")
        #expect(await client.historyCalls == historyReads, "an unmoved HEAD reloads no history")
    }

    @Test func aMovedHeadReloadsHistoryAndResetsThePage() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [])
        let later = commitSummary("c2", subject: "Newer")
        await client.set(head: later.ref.sha)
        await client.set(commits: [later, commit])

        h.watcherCallbacks.values.first?()
        #expect(await eventually { state.history.commits.first?.ref == later.ref })
        #expect(state.history.revision == later.ref.sha)
        #expect(state.commitLimit == WindowState.commitPageSize)
    }

    @Test func anUnreadableCommitFallsBackToTheWorkingTreeKeepingItsError() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [])
        await client.fail(commitFiles: true)

        state.select(commit: commit)
        #expect(await eventually { state.scope == .workingTree })
        #expect(await eventually { state.files.map(\.path) == workingFiles.map(\.path) })
        #expect(state.selectedCommit == nil)
        // The refresh that restored the working tree clears `errorMessage`; the
        // explanation has to outlive it.
        #expect(state.errorMessage?.contains(commit.ref.shortSha) == true)
    }

    @Test func historyPaginationAsksForOneExtraAndRaisesTheLimit() async {
        let h = Harness()
        let state = h.makeState()
        let first = commitSummary("c1")
        let client = await adopt(h, state, commit: first, commitFiles: [])
        // One more commit than a page holds, so `hasMore` is true.
        let page = (0...WindowState.commitPageSize).map { commitSummary("c\($0)") }
        await client.set(commits: page)
        await client.set(head: objectID("moved"))
        h.watcherCallbacks.values.first?()

        #expect(await eventually { state.history.hasMore })
        #expect(state.history.commits.count == WindowState.commitPageSize)
        #expect(await client.lastHistoryLimit == WindowState.commitPageSize + 1)

        state.loadMoreCommits()
        #expect(await eventually { await client.lastHistoryLimit == WindowState.commitPageSize * 2 + 1 })
        #expect(state.commitLimit == WindowState.commitPageSize * 2)
        #expect(await client.lastHistoryRevision == objectID("moved"), "paging stays on the loaded revision")
    }

    @Test func anUnbornHeadLeavesAnEmptyHistoryAndNoError() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: workingFiles)
        await repo.client.set(head: nil)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { !state.isLoadingHistory })
        #expect(state.history.commits.isEmpty)
        #expect(state.historyErrorMessage == nil)
        #expect(state.historyPlaceholder == .empty)
    }

    @Test func aFailedHistoryReadIsRetriedOnTheNextTick() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: workingFiles)
        let commit = commitSummary("c1")
        await repo.client.set(head: commit.ref.sha)
        await repo.client.set(commits: [commit])
        await repo.client.fail(history: true)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { state.historyErrorMessage != nil })
        #expect(state.historyPlaceholder == .failed)

        await repo.client.fail(history: false)
        h.watcherCallbacks.values.first?()
        #expect(await eventually { !state.history.commits.isEmpty }, "a failed read is not left standing")
        #expect(state.historyErrorMessage == nil)
    }

    @Test func closingDuringAHistoryLoadPublishesNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: workingFiles)
        let commit = commitSummary("c1")
        await repo.client.set(head: commit.ref.sha)
        await repo.client.set(commits: [commit])
        #expect(state.adopt(root: repo.root, client: repo.client))

        state.close()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(state.history.commits.isEmpty, "a history read that outlived the window publishes nothing")
        #expect(state.files.isEmpty)
    }

    @Test func filesToWarmCoversCommitFiles() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let files = [commitFile("one.swift", commit), commitFile("two.swift", commit)]
        _ = await adopt(h, state, commit: commit, commitFiles: files)

        state.select(commit: commit)
        #expect(await eventually { state.files.count == 2 })
        #expect(state.filesToWarm.map(\.path) == ["one.swift", "two.swift"])
        state.selectedFileID = state.files.first?.id
        #expect(state.filesToWarm.map(\.path) == ["two.swift"])
    }

    @Test func lineStatsForACommitAskForItsAreaOnly() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [commitFile("one.swift", commit)])
        await client.set(
            numstat: [NumstatEntry(path: "one.swift", stats: .counted(added: 4, deleted: 2))],
            area: .commit(commit.ref))

        state.select(commit: commit)
        #expect(await eventually { state.files.first?.lineStats == .counted(added: 4, deleted: 2) })
    }
}
