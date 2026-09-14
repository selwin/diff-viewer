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
        #expect(await eventually { await !state.history.commits.isEmpty })
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
        #expect(await eventually { await state.files.map(\.path) == ["src/picker.swift"] })
        #expect(state.scope == .commit(commit.ref))
        #expect(state.selectedCommit == commit)
        #expect(state.unstagedFiles.isEmpty)
        #expect(state.commitFiles.count == 1)

        state.selectWorkingTree()
        #expect(await eventually { await state.files.map(\.path) == workingFiles.map(\.path) })
        #expect(state.selectedCommit == nil)
    }

    @Test func selectionFollowsThePathIntoTheNewScope() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        _ = await adopt(h, state, commit: commit, commitFiles: [commitFile("a1.swift", commit)])
        state.selectedFileID = workingFiles[0].id

        state.select(commit: commit)
        #expect(await eventually { await state.selectedFileID != nil })
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
        #expect(await eventually { await state.files.map(\.path) == ["other.swift"] })
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
        #expect(await eventually { await !state.history.commits.isEmpty })

        state.select(commit: commit)
        #expect(await eventually { await state.files.count == 1 })
        state.selectedFileID = state.files.first?.id
        #expect(state.selectedFile?.area == .commit(commit.ref))

        state.selectWorkingTree()
        #expect(await eventually { await state.files.count == 2 })
        #expect(await eventually { await state.selectedFileID != nil })
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
        #expect(await eventually { await state.files.map(\.path) == ["src/held.swift"] })
    }

    @Test func rapidScopeSwitchingSettlesOnTheLastChoice() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        _ = await adopt(h, state, commit: commit, commitFiles: [commitFile("src/one.swift", commit)])

        state.select(commit: commit)
        state.selectWorkingTree()
        state.select(commit: commit)
        #expect(await eventually { await state.files.map(\.path) == ["src/one.swift"] })
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
        #expect(await eventually { await state.files.count == 1 })
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
        #expect(await eventually { await state.history.commits.first?.ref == later.ref })
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
        #expect(await eventually { await state.scope == .workingTree })
        #expect(await eventually { await state.files.map(\.path) == workingFiles.map(\.path) })
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

        #expect(await eventually { await state.history.hasMore })
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
        #expect(await eventually { await !state.isLoadingHistory })
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
        #expect(await eventually { await state.historyErrorMessage != nil })
        #expect(state.historyPlaceholder == .failed)

        await repo.client.fail(history: false)
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await !state.history.commits.isEmpty }, "a failed read is not left standing")
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
        #expect(await eventually { await state.files.count == 2 })
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
        #expect(await eventually { await state.files.first?.lineStats == .counted(added: 4, deleted: 2) })
    }

    // MARK: Ordering

    /// The generation guard around the HEAD read. Two overlapping checks resolve
    /// different revisions; the slower one holds the older answer and must not use it to
    /// reinstate a branch the repository has already left.
    @Test func aSlowHeadCheckCannotReinstateOlderHistory() async {
        let h = Harness()
        let state = h.makeState()
        let first = commitSummary("c1")
        let client = await adopt(h, state, commit: first, commitFiles: [])
        #expect(await eventually { await state.history.revision == first.ref.sha })

        // Tick one reads HEAD and blocks, having seen the old revision.
        await client.holdHead(true)
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await client.heldHeadCount == 1 })

        // Tick two resolves the new revision and publishes it while tick one waits.
        let later = commitSummary("c2", subject: "Newer")
        await client.holdHead(false)
        await client.set(head: later.ref.sha)
        await client.set(commits: [later, first])
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await state.history.revision == later.ref.sha })

        await client.releaseHead()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(state.history.revision == later.ref.sha, "the older check does not start a load")
        #expect(state.history.commits.first?.ref == later.ref)
    }

    /// The scope change records what to re-select, but the refresh it starts is not
    /// always the one that publishes: a watcher refresh can overtake it, and then the
    /// restoration has to happen there instead.
    @Test func selectionIsRestoredByWhicheverRefreshPublishes() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [commitFile("a1.swift", commit)])

        state.select(commit: commit)
        #expect(await eventually { await state.files.count == 1 })
        state.selectedFileID = state.files.first?.id
        #expect(state.selectedFile?.path == "a1.swift")

        // Both working-tree reads block, so their completion order can be chosen.
        await client.hold(true)
        state.selectWorkingTree()
        #expect(await eventually { await client.heldCount == 1 })
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await client.heldCount == 2 })

        // The newer refresh finishes first and is the one that publishes.
        await client.releaseLast()
        #expect(await eventually { await state.files.count == workingFiles.count })
        await client.hold(false)
        await client.releaseFirst()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(state.selectedFile?.path == "a1.swift", "the overtaking refresh restores the selection")
        #expect(state.selectedFile?.area == .unstaged)
    }

    /// An alert about a commit the user has already moved on from is both wrong and in
    /// the way, so the fallback checks that its transition is still the current one.
    @Test func aStaleFallbackDoesNotRaiseAnErrorOverANewerCommit() async {
        let h = Harness()
        let state = h.makeState()
        let broken = commitSummary("c1")
        let good = commitSummary("c2", subject: "Readable")
        let client = await adopt(h, state, commit: broken, commitFiles: [])
        await client.set(commits: [good, broken])
        await client.set(files: [commitFile("ok.swift", good)], forCommit: good.ref.sha)

        // The failing commit starts a fallback whose working-tree read blocks.
        await client.fail(commitFiles: true)
        await client.hold(true)
        state.select(commit: broken)
        #expect(await eventually { await client.heldCount == 1 })

        // Meanwhile the user picks a commit that reads cleanly.
        await client.fail(commitFiles: false)
        state.select(commit: good)
        #expect(await eventually { await state.files.map(\.path) == ["ok.swift"] })

        await client.hold(false)
        await client.releaseFirst()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(state.scope == .commit(good.ref))
        #expect(state.errorMessage == nil, "the abandoned fallback stays quiet")
    }

    /// An unfinished read must not be drawn as a commit that changed nothing.
    @Test func scopeLoadingIsDistinctFromAnEmptyCommit() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [])
        #expect(!state.isLoadingScope)

        await client.holdCommitFiles(true)
        state.select(commit: commit)
        #expect(await eventually { await client.heldCommitFileCount == 1 })
        #expect(state.isLoadingScope, "still reading, not yet an answer")
        #expect(state.files.isEmpty)

        await client.holdCommitFiles(false)
        await client.releaseCommitFiles()
        #expect(await eventually { await !state.isLoadingScope })
        #expect(state.files.isEmpty, "and now it really is an empty commit")
    }

    /// Repeated ticks while one `git log` is running would otherwise cancel and relaunch
    /// it each time, and a cancelled `ProcessRunner` subprocess keeps running.
    @Test func repeatedTicksDoNotRestartTheSameHistoryRead() async {
        let h = Harness()
        let state = h.makeState()
        let first = commitSummary("c1")
        let client = await adopt(h, state, commit: first, commitFiles: [])
        #expect(await eventually { await state.history.revision == first.ref.sha })

        let later = commitSummary("c2")
        await client.set(head: later.ref.sha)
        await client.set(commits: [later, first])
        await client.holdHead(true)
        for _ in 0..<4 { h.watcherCallbacks.values.first?() }
        #expect(await eventually { await client.heldHeadCount == 4 })

        let readsBefore = await client.historyCalls
        await client.holdHead(false)
        await client.releaseHead()
        #expect(await eventually { await state.history.revision == later.ref.sha })
        try? await Task.sleep(for: .milliseconds(80))
        let readsAfter = await client.historyCalls
        #expect(readsAfter - readsBefore == 1, "four ticks, one log read")
    }

    /// The mirror of the test above: the *older* check finishes first. Completion order
    /// must not decide — the newest HEAD read wins either way.
    @Test func anEarlyFinishingOlderCheckDoesNotBeatTheNewerOne() async {
        let h = Harness()
        let state = h.makeState()
        let start = commitSummary("c0")
        let client = await adopt(h, state, commit: start, commitFiles: [])
        #expect(await eventually { await state.history.revision == start.ref.sha })

        let older = commitSummary("c1", subject: "Older")
        let newer = commitSummary("c2", subject: "Newer")
        await client.holdHead(true)

        // Both checks resolve revisions that differ from what is displayed.
        await client.set(head: older.ref.sha)
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await client.heldHeadCount == 1 })
        await client.set(head: newer.ref.sha)
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await client.heldHeadCount == 2 })

        await client.set(commits: [newer, older, start])
        await client.holdHead(false)
        // The older check completes first and must be ignored anyway.
        await client.releaseFirstHead()
        try? await Task.sleep(for: .milliseconds(60))
        await client.releaseHead()

        #expect(await eventually { await state.history.revision == newer.ref.sha })
        #expect(state.history.revision != older.ref.sha, "the first to finish does not win")
    }

    /// Checked out elsewhere and back again while the load for "elsewhere" is running.
    /// Comparing only against the displayed revision finds nothing to do, and that load
    /// then publishes the wrong branch's commits.
    @Test func returningToTheDisplayedHeadDropsTheObsoleteLoad() async {
        let h = Harness()
        let state = h.makeState()
        let onA = commitSummary("a1", subject: "On A")
        let client = await adopt(h, state, commit: onA, commitFiles: [])
        #expect(await eventually { await state.history.revision == onA.ref.sha })

        // Check out B; its history read blocks part-way.
        let onB = commitSummary("b1", subject: "On B")
        await client.holdHistory(true)
        await client.set(head: onB.ref.sha)
        await client.set(commits: [onB])
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await client.heldHistoryCount == 1 })

        // Back to A before B's history arrives.
        await client.set(head: onA.ref.sha)
        await client.set(commits: [onA])
        h.watcherCallbacks.values.first?()
        try? await Task.sleep(for: .milliseconds(60))

        await client.holdHistory(false)
        await client.releaseHistory()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(state.history.revision == onA.ref.sha, "B's load does not land on A")
        #expect(state.history.commits.first?.ref == onA.ref)
        #expect(!state.isLoadingHistory, "and the picker is not left spinning")
    }

    /// A second scope change has no selection left to read, because the first cleared
    /// the list; the path the user was on must survive both hops.
    @Test func aPendingSelectionSurvivesASecondScopeChange() async {
        let h = Harness()
        let state = h.makeState()
        let first = commitSummary("c1")
        let second = commitSummary("c2", subject: "Second")
        let client = await adopt(h, state, commit: first, commitFiles: [commitFile("a1.swift", first)])
        await client.set(files: [commitFile("a1.swift", second)], forCommit: second.ref.sha)
        await client.set(commits: [second, first])

        state.selectedFileID = state.files.first { $0.path == "a1.swift" }?.id
        #expect(state.selectedFile?.path == "a1.swift")

        // Two scope changes back to back, the second while the first is still loading.
        await client.holdCommitFiles(true)
        state.select(commit: first)
        #expect(await eventually { await client.heldCommitFileCount == 1 })
        state.select(commit: second)
        await client.holdCommitFiles(false)
        await client.releaseCommitFiles()

        #expect(await eventually { await state.files.map(\.path) == ["a1.swift"] })
        #expect(await eventually { await state.selectedFileID != nil }, "the path survives both hops")
        #expect(state.selectedFile?.area == .commit(second.ref))
    }
}
