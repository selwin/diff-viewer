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

    /// The scope change no longer hunts for the same path in the new list: the whole
    /// point of a new scope is a new set of changes, and All changes shows all of them.
    @Test func everyScopeChangeLandsOnAllChanges() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        _ = await adopt(h, state, commit: commit, commitFiles: [commitFile("a1.swift", commit)])
        #expect(state.selection == [.allChanges], "the first list selects All changes")
        state.selection = [.file(workingFiles[0].id)]

        state.select(commit: commit)
        #expect(await eventually { await state.files.map(\.path) == ["a1.swift"] })
        #expect(await eventually { await state.selection == [.allChanges] })
        #expect(state.selectedFileID == nil)

        state.selection = state.files.first.map { [.file($0.id)] } ?? []
        state.selectWorkingTree()
        #expect(await eventually { await state.files.count == workingFiles.count })
        #expect(await eventually { await state.selection == [.allChanges] }, "and on the way back too")
    }

    /// All changes reads every file itself, so the prefetcher has nothing to warm.
    @Test func allChangesWarmsNothing() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        _ = await adopt(h, state, commit: commit, commitFiles: [])
        #expect(state.selection == [.allChanges])
        #expect(state.filesToWarm.isEmpty)

        state.selection = [.file(workingFiles[0].id)]
        #expect(state.filesToWarm.map(\.path) == ["a2.swift"])
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
        #expect(await eventually { await state.selection == [.allChanges] })
        // All changes warms nothing, so the list is checked with a file selected and with
        // nothing selected at all.
        state.selection = []
        #expect(state.filesToWarm.map(\.path) == ["one.swift", "two.swift"])
        state.selection = state.files.first.map { [.file($0.id)] } ?? []
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

    // MARK: Branch subtitle

    @Test func adoptingPublishesTheBranchAsTheSubtitle() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: workingFiles)
        await repo.client.set(headState: .named("sidebar-actions"))
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await state.subtitle == "sidebar-actions" })
    }

    /// The reason the branch is read on the HEAD tick rather than from the status
    /// header: in commit scope the watcher never calls `status()`, so a checkout while a
    /// commit is selected would otherwise leave the subtitle stale.
    @Test func aWatcherTickUpdatesTheBranchInCommitScope() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [commitFile("one.swift", commit)])
        #expect(await eventually { await state.subtitle == "main" })

        state.select(commit: commit)
        #expect(await eventually { await state.files.count == 1 })

        await client.set(headState: .named("other"))
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await state.subtitle == "other" })
    }

    /// The SHA deliberately differs from the loaded history's commit, so a subtitle that
    /// read the history revision rather than HEAD would fail this.
    @Test func aDetachedHeadNamesItsOwnCommitNotTheLoadedHistory() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [])
        await client.set(headState: .detached(sha: String(repeating: "b", count: 40)))

        h.watcherCallbacks.values.first?()
        #expect(await eventually { await state.subtitle == "detached at bbbbbbb" })
    }

    /// Blanking the subtitle for one failed read would be worse than a stale name.
    @Test func aFailedHeadStateReadKeepsThePreviousSubtitle() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [])
        #expect(await eventually { await state.subtitle == "main" })

        await client.fail(headState: true)
        // Waiting for the failing read to be counted, rather than for a duration, keeps
        // the assertion below about the subtitle and not about timing.
        let before = await client.headStateCalls
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await client.headStateCalls == before + 1 })
        #expect(state.subtitle == "main")
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

    /// A watcher refresh can overtake the one a scope change started. Whichever publishes
    /// the new list, the window lands on All changes and stays there.
    @Test func anOvertakingRefreshStillLandsOnAllChanges() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [commitFile("a1.swift", commit)])

        state.select(commit: commit)
        #expect(await eventually { await state.files.count == 1 })
        state.selection = state.files.first.map { [.file($0.id)] } ?? []
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

        #expect(state.selection == [.allChanges])
        #expect(state.selectedFileID == nil)
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

    /// Two scope changes back to back, the second while the first is still loading: the
    /// list that finally arrives is the second one's, and it lands on All changes.
    @Test func aSecondScopeChangeAlsoLandsOnAllChanges() async {
        let h = Harness()
        let state = h.makeState()
        let first = commitSummary("c1")
        let second = commitSummary("c2", subject: "Second")
        let client = await adopt(h, state, commit: first, commitFiles: [commitFile("a1.swift", first)])
        await client.set(files: [commitFile("a1.swift", second)], forCommit: second.ref.sha)
        await client.set(commits: [second, first])

        state.selection = state.files.first { $0.path == "a1.swift" }.map { [.file($0.id)] } ?? []
        #expect(state.selectedFile?.path == "a1.swift")

        await client.holdCommitFiles(true)
        state.select(commit: first)
        #expect(await eventually { await client.heldCommitFileCount == 1 })
        state.select(commit: second)
        await client.holdCommitFiles(false)
        await client.releaseCommitFiles()

        #expect(await eventually { await state.files.map(\.path) == ["a1.swift"] })
        #expect(await eventually { await state.selection == [.allChanges] })
        #expect(state.scope == .commit(second.ref))
    }

    // MARK: All changes

    /// A watcher tick in All-changes mode republishes the list and reloads the changeset;
    /// what it must not do is move the selection off All changes.
    @Test func aWatcherRefreshInAllChangesModeKeepsTheSelectionAndReloads() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: workingFiles)
        #expect(state.selection == [.allChanges])
        let reads = await repo.client.contentReads

        let updated = [changedFile("a1.swift"), changedFile("new.swift")]
        await repo.client.set(files: updated)
        h.watcherCallbacks[repo.root]!()
        #expect(await eventually { await state.files == updated })
        #expect(state.selection == [.allChanges])
        #expect(await eventually { await repo.client.contentReads > reads }, "the changeset is read again")
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
    }

    /// A settings refresh reloads the diff before it re-reads the list, so in All-changes
    /// mode the changeset it built can already be out of date by the time the new list
    /// lands. A single file's diff is unaffected, which is why the reload is conditional.
    @Test func aSettingsRefreshInAllChangesModeReloadsAChangedList() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: [changedFile("a.swift")])
        #expect(state.selection == [.allChanges])

        await repo.client.set(files: [changedFile("a.swift"), changedFile("b.swift")])
        state.diffSettingsChanged()

        #expect(
            await eventually {
                guard case let .changeset(document)? = await state.diffLoader.content else { return false }
                return document.sections.map(\.file.path) == ["a.swift", "b.swift"]
            })
    }

    @Test func aFileActionOnAnUnselectedRowKeepsAllChanges() async {
        let h = Harness()
        let state = h.makeState()
        let files = [changedFile("a.swift"), changedFile("b.swift")]
        let repo = await h.adopt(state, "A", files: files)
        await repo.client.set(filesAfterWrite: [changedFile("a.swift", area: .staged), files[1]])
        #expect(state.selection == [.allChanges])

        await state.perform(.stage, on: [files[0]])

        #expect(await eventually { await h.published.last?.cause == .fileAction })
        #expect(state.selection == [.allChanges], "no row was selected, so nothing is restored")
    }

    /// The reselection rule still applies to a file the reader was actually on.
    @Test func aFileActionOnTheSelectedFileStillReselectsByPath() async {
        let h = Harness()
        let state = h.makeState()
        let files = [changedFile("a.swift"), changedFile("b.swift")]
        let staged = changedFile("a.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: files)
        await repo.client.set(filesAfterWrite: [staged, files[1]])
        state.selection = [.file(files[0].id)]

        await state.perform(.stage, on: [files[0]])

        #expect(await eventually { await state.selection == [.file(staged.id)] })
    }

    /// The case a computed `selectedFileID` would get wrong: All changes and "nothing
    /// selected" both read as no file, but only the second one may be overwritten.
    @Test func allChangesChosenDuringAWriteIsNotOverridden() async {
        let h = Harness()
        let state = h.makeState()
        let files = [changedFile("a.swift"), changedFile("b.swift")]
        let staged = changedFile("a.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: files)
        let client = repo.client
        state.selection = [.file(files[0].id)]
        await client.holdActions(true)

        let write = Task { await state.perform(.stage, on: [files[0]]) }
        #expect(await eventually { await client.heldActionCount == 1 })
        // A watcher refresh lands while git runs and clears the selection, because the
        // row the reader was on has gone.
        let afterWatcher = [staged, files[1]]
        await client.set(files: afterWatcher)
        h.watcherCallbacks[repo.root]?()
        #expect(
            await eventually {
                guard await state.selection.isEmpty else { return false }
                return await state.files == afterWatcher
            })
        state.selection = [.allChanges]
        await client.releaseActions()
        await write.value

        #expect(await eventually { await h.published.last?.cause == .fileAction })
        #expect(state.selection == [.allChanges], "the reader's own choice outranks the write")
    }
}
