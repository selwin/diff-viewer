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
        let client = await h.adoptWithHistory(state, files: workingFiles, commits: [commit], commitFiles: commitFiles)
        #expect(await eventually { await !state.history.commits.isEmpty })
        return client
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
        #expect(await eventually { await state.files.map(\.path) == inPublishedFileOrder(workingFiles).map(\.path) })
        #expect(state.selectedCommit == nil)
    }

    /// The picker's binding hands over a ref, not a commit: a known one selects its
    /// commit and an unknown one does nothing, rather than showing a scope with no summary.
    @Test func selectingAnUnknownCommitRefIsIgnored() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [])
        let unknown = CommitRef(sha: objectID("nowhere"), shortSha: "nowhere", firstParentSHA: nil)

        state.select(scope: .commit(unknown))
        #expect(state.scope == .workingTree)
        #expect(!state.isLoadingScope)
        #expect(await client.commitFileCalls == 0)

        state.select(scope: .commit(commit.ref))
        #expect(state.scope == .commit(commit.ref))
        #expect(state.selectedCommit == commit)
        #expect(await eventually { await h.published.last?.cause == .scope })

        state.select(scope: .workingTree)
        #expect(state.scope == .workingTree)
        #expect(await eventually { await state.files.count == workingFiles.count })
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

    /// The race the separate history generation exists for: a watcher tick that only
    /// reloads the commit list must not cancel an in-flight scope change.
    @Test func aWatcherTickDuringAScopeLoadDoesNotDiscardItsFiles() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [commitFile("src/held.swift", commit)])

        await client.hold(.commitFiles)
        state.select(commit: commit)
        #expect(await eventually { await client.heldCount(.commitFiles) == 1 })

        // A ref moves while the commit's files are still being read.
        h.watcherChangeCallbacks.values.first?([.refs])
        try? await Task.sleep(for: .milliseconds(50))

        await client.hold(.commitFiles, false)
        await client.release(.commitFiles)
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

    @Test func aMovedHeadReloadsHistoryAndResetsThePage() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [])
        let later = commitSummary("c2", subject: "Newer")
        await client.set(head: later.ref.sha)
        await client.set(commits: [later, commit])

        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await state.history.commits.first?.ref == later.ref })
        #expect(state.history.revision == later.ref.sha)
        #expect(await client.lastHistorySkip == 0)
    }

    @Test func anUnreadableCommitFallsBackToTheWorkingTreeKeepingItsError() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [])
        await client.fail(commitFiles: true)

        state.select(commit: commit)
        #expect(await eventually { await state.scope == .workingTree })
        #expect(await eventually { await state.files.map(\.path) == inPublishedFileOrder(workingFiles).map(\.path) })
        #expect(state.selectedCommit == nil)
        // The refresh that restored the working tree clears `errorMessage`; the
        // explanation has to outlive it.
        #expect(state.errorMessage?.contains(commit.ref.shortSha) == true)
    }

    /// The fallback leaves the commit, so its line counts are work nobody will see: the
    /// read is cancelled, and whatever it returns late is not recorded.
    @Test func fallingBackCancelsTheCommitsLineStats() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [commitFile("one.swift", commit)])
        await h.settleStats(state)
        await client.hold(.numstat)
        state.select(commit: commit)
        #expect(await eventually { await client.heldCount(.numstat) >= 1 })
        let task = state.session?.statsTask

        // The working-tree read fails too, so no later refresh starts another stats read.
        await client.fail(commitFiles: true)
        await client.fail(true)
        await state.refresh()
        #expect(state.scope == .workingTree)
        #expect(state.errorMessage?.contains(commit.ref.shortSha) == true)
        #expect(task?.isCancelled == true)
        #expect(state.session?.statsTask == nil)
        #expect(state.session?.lineStats.activeRequest == nil)

        // Cancellation does not resume the held numstat; releasing it lets the read finish.
        await client.release(.numstat)
        await task?.value
        #expect(
            state.session?.lineStats.lastOutcome?.request.scope == .workingTree, "the commit's read recorded nothing")
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
        let snapshot = state.commitPickerSnapshot
        #expect(snapshot.commits.isEmpty && !snapshot.isLoadingHistory && !snapshot.historyLoadFailed)
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
        #expect(state.commitPickerSnapshot.historyLoadFailed)

        await repo.client.fail(history: false)
        // Only a ref change checks HEAD again; an edit in the tree does not.
        h.watcherChangeCallbacks.values.first?([.refs])
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

    // MARK: Branch display title

    /// The SHA deliberately differs from the loaded history's commit, so a title that
    /// read the history revision rather than HEAD would fail this.
    @Test func aDetachedHeadNamesItsOwnCommitNotTheLoadedHistory() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [])
        await client.set(headState: .detached(sha: String(repeating: "b", count: 40)))

        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await state.branchDisplayTitle == "Detached bbbbbbb" })
    }

    /// Blanking the title for one failed read would be worse than a stale name.
    @Test func aFailedHeadStateReadKeepsThePreviousTitle() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let client = await adopt(h, state, commit: commit, commitFiles: [])
        #expect(await eventually { await state.branchDisplayTitle == "main" })

        await client.fail(headState: true)
        // Waiting for the failing read to be counted, rather than for a duration, keeps
        // the assertion below about the title and not about timing.
        let before = await client.headStateCalls
        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await client.headStateCalls == before + 1 })
        #expect(state.branchDisplayTitle == "main")
    }

    // MARK: Ordering

    /// The generation guard around the HEAD read. Two overlapping checks resolve
    /// different revisions; the slower one holds the older answer and must not use it to
    /// reinstate a branch the repository has already left. Ticks queue behind one
    /// another, so the overlapping check comes from a branch switch, which runs on the
    /// write chain.
    @Test func aSlowHeadCheckCannotReinstateOlderHistory() async {
        let h = Harness()
        let state = h.makeState()
        let first = commitSummary("c1")
        let client = await adopt(h, state, commit: first, commitFiles: [])
        #expect(await eventually { await state.history.revision == first.ref.sha })

        // The tick reads HEAD and blocks, having seen the old revision.
        await client.hold(.head)
        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await client.heldCount(.head) == 1 })

        // The switch resolves the new revision and publishes it while the tick waits.
        let later = commitSummary("c2", subject: "Newer")
        await client.hold(.head, false)
        await client.set(headAfterSwitch: later.ref.sha)
        await client.set(commits: [later, first])
        await state.switchBranch(to: "feature")
        #expect(await eventually { await state.history.revision == later.ref.sha })

        await client.release(.head)
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
        await client.hold(.status)
        state.selectWorkingTree()
        #expect(await eventually { await client.heldCount(.status) == 1 })
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await client.heldCount(.status) == 2 })

        // The newer refresh finishes first and is the one that publishes.
        await client.releaseLast(.status)
        #expect(await eventually { await state.files.count == workingFiles.count })
        await client.hold(.status, false)
        await client.releaseFirst(.status)
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
        await client.hold(.status)
        state.select(commit: broken)
        #expect(await eventually { await client.heldCount(.status) == 1 })

        // Meanwhile the user picks a commit that reads cleanly.
        await client.fail(commitFiles: false)
        state.select(commit: good)
        #expect(await eventually { await state.files.map(\.path) == ["ok.swift"] })

        await client.hold(.status, false)
        await client.releaseFirst(.status)
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

        await client.hold(.commitFiles)
        state.select(commit: commit)
        #expect(await eventually { await client.heldCount(.commitFiles) == 1 })
        #expect(state.isLoadingScope, "still reading, not yet an answer")
        #expect(state.files.isEmpty)

        await client.hold(.commitFiles, false)
        await client.release(.commitFiles)
        #expect(await eventually { await !state.isLoadingScope })
        #expect(state.files.isEmpty, "and now it really is an empty commit")
    }

    /// Ticks queue behind the running refresh, and the one follow-up they collapse into
    /// finds the `git log` its predecessor started still running: it must not cancel and
    /// relaunch it, since a cancelled `ProcessRunner` subprocess keeps running.
    @Test func repeatedTicksDoNotRestartTheSameHistoryRead() async {
        let h = Harness()
        let state = h.makeState()
        let first = commitSummary("c1")
        let client = await adopt(h, state, commit: first, commitFiles: [])
        #expect(await eventually { await state.history.revision == first.ref.sha })

        let later = commitSummary("c2")
        await client.set(head: later.ref.sha)
        await client.set(commits: [later, first])
        await client.hold(.head)
        for _ in 0..<4 { h.watcherChangeCallbacks.values.first?([.refs]) }
        #expect(await eventually { await client.heldCount(.head) == 1 }, "ticks queue behind the running refresh")
        let headsBefore = await client.headCalls
        let readsBefore = await client.historyCalls

        await client.hold(.head, false)
        await client.hold(.history)
        await client.release(.head)
        #expect(await eventually { await client.heldCount(.history) == 1 })
        #expect(await eventually { await client.headCalls == headsBefore + 1 }, "one follow-up for the queued ticks")
        try? await Task.sleep(for: .milliseconds(80))
        let readsAfter = await client.historyCalls
        #expect(readsAfter - readsBefore == 1, "four ticks, one log read")

        await client.hold(.history, false)
        await client.release(.history)
        #expect(await eventually { await state.history.revision == later.ref.sha })
    }

    /// The mirror of `aSlowHeadCheckCannotReinstateOlderHistory`: the *older* check
    /// finishes first. Completion order must not decide — the newest HEAD read wins
    /// either way. The second check again comes from a branch switch.
    @Test func anEarlyFinishingOlderCheckDoesNotBeatTheNewerOne() async {
        let h = Harness()
        let state = h.makeState()
        let start = commitSummary("c0")
        let client = await adopt(h, state, commit: start, commitFiles: [])
        #expect(await eventually { await state.history.revision == start.ref.sha })

        let older = commitSummary("c1", subject: "Older")
        let newer = commitSummary("c2", subject: "Newer")
        await client.hold(.head)

        // Both checks resolve revisions that differ from what is displayed.
        await client.set(head: older.ref.sha)
        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await client.heldCount(.head) == 1 })
        await client.set(headAfterSwitch: newer.ref.sha)
        let switching = Task { await state.switchBranch(to: "feature") }
        #expect(await eventually { await client.heldCount(.head) == 2 })

        await client.set(commits: [newer, older, start])
        await client.hold(.head, false)
        // The older check completes first and must be ignored anyway.
        await client.releaseFirst(.head)
        try? await Task.sleep(for: .milliseconds(60))
        await client.release(.head)
        await switching.value

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
        await client.hold(.history)
        await client.set(head: onB.ref.sha)
        await client.set(commits: [onB])
        h.watcherChangeCallbacks.values.first?([.refs])
        #expect(await eventually { await client.heldCount(.history) == 1 })

        // Back to A before B's history arrives.
        await client.set(head: onA.ref.sha)
        await client.set(commits: [onA])
        h.watcherChangeCallbacks.values.first?([.refs])
        try? await Task.sleep(for: .milliseconds(60))

        await client.hold(.history, false)
        await client.release(.history)
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

        await client.hold(.commitFiles)
        state.select(commit: first)
        #expect(await eventually { await client.heldCount(.commitFiles) == 1 })
        state.select(commit: second)
        await client.hold(.commitFiles, false)
        await client.release(.commitFiles)

        #expect(await eventually { await state.files.map(\.path) == ["a1.swift"] })
        #expect(await eventually { await state.selection == [.allChanges] })
        #expect(state.scope == .commit(second.ref))
    }

    // MARK: All changes

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
}
