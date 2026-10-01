import Foundation
import Testing

@testable import DiffViewer

@MainActor
struct WindowStateTests {
    let filesA = [changedFile("a1.swift"), changedFile("a2.swift", area: .staged)]
    let filesB = [changedFile("b1.swift")]

    // MARK: Adoption

    @Test func adoptInstallsSessionWatcherAndRefreshes() async {
        let h = Harness()
        let state = h.makeState()
        #expect(state.isEmpty)
        let repo = await h.adopt(state, "A", files: filesA)
        #expect(state.repositoryRoot == repo.root)
        #expect(!state.isEmpty)
        #expect(state.files == filesA)
        #expect(h.watchers[repo.root] != nil)
        #expect(h.published.last?.cause == .initial)
        #expect(await eventually { await !state.isLoading })
    }

    @Test func secondAdoptIsRejected() async {
        let h = Harness()
        let state = h.makeState()
        let a = await h.adopt(state, "A", files: filesA)
        let b = h.repo("B", files: filesB)
        #expect(!state.adopt(root: b.root, client: b.client))
        #expect(state.repositoryRoot == a.root)
        #expect(state.files == filesA)
        #expect(h.watchers[b.root] == nil)
        #expect(await b.client.statusCalls == 0)
    }

    // MARK: Refreshing

    @Test func olderRefreshCannotOverwriteNewerOne() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let client = repo.client
        await client.hold(.status)

        let second = [changedFile("second.swift")]
        let third = [changedFile("third.swift")]
        await client.set(files: second)
        let refresh1 = Task { await state.refresh() }
        #expect(await eventually { await client.heldCount(.status) == 1 })
        await client.set(files: third)
        let refresh2 = Task { await state.refresh() }
        #expect(await eventually { await client.heldCount(.status) == 2 })

        await client.releaseLast(.status)
        await refresh2.value
        #expect(state.files == third)
        await client.releaseFirst(.status)
        await refresh1.value
        #expect(state.files == third, "the older status response must not win")
    }

    @Test func refreshReportsItsCauseEvenWhenUnchanged() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await state.refresh()
        #expect(h.published.count == 2)
        #expect(h.published.last?.cause == .manual)
        #expect(h.published.last?.files == filesA)

        let updated = [changedFile("changed.swift")]
        await repo.client.set(files: updated)
        h.watcherCallbacks[repo.root]!()
        #expect(await eventually { await h.published.count == 3 })
        #expect(h.published.last?.cause == .watcher)
        #expect(state.files == updated)
    }

    @Test func refreshErrorIsPublishedAndKeepsFiles() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await repo.client.fail(true)
        await state.refresh()
        #expect(state.errorMessage != nil)
        #expect(state.files == filesA)
        #expect(h.published.count == 1)
    }

    @Test func filesToWarmExcludesSelection() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: filesA)
        // All changes is reading every file itself, so there is nothing to warm.
        #expect(state.filesToWarm.isEmpty)
        state.selection = [.file(filesA[0].id)]
        #expect(state.filesToWarm == [filesA[1]])
        state.selection = []
        #expect(state.filesToWarm == filesA)
    }

    // MARK: Closing

    @Test func closeStopsWatcherAndIsIdempotent() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        state.close()
        #expect(state.isClosed)
        #expect(h.watchers[repo.root]?.stopped == true)
        state.close()
        #expect(state.isClosed)
    }

    @Test func refreshCompletingAfterCloseIsDiscarded() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let client = repo.client
        await client.hold(.status)
        await client.set(files: filesB)
        let stale = Task { await state.refresh() }
        #expect(await eventually { await client.heldCount(.status) == 1 })

        state.close()
        await client.releaseFirst(.status)
        await stale.value
        #expect(state.files == filesA)
        #expect(h.published.count == 1, "a closed window must not publish")
        #expect(state.errorMessage == nil)
    }

    @Test func watcherCallbackAfterCloseReadsNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let before = await repo.client.statusCalls
        state.close()
        h.watcherCallbacks[repo.root]!()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == before)
    }

    @Test func adoptAfterCloseIsRejected() async {
        let h = Harness()
        let state = h.makeState()
        state.close()
        let repo = h.repo("A", files: filesA)
        #expect(!state.adopt(root: repo.root, client: repo.client))
        #expect(state.isEmpty)
        #expect(h.watchers[repo.root] == nil)
    }

    // MARK: Visibility

    private func hasContent(_ state: WindowState, for file: ChangedFile? = nil) -> Bool {
        guard state.diffLoader.content != nil else { return false }
        return file.map { state.diffLoader.contentFileID == $0.id } ?? true
    }

    /// Selects `file` and waits for its diff to be published.
    private func select(_ file: ChangedFile, in state: WindowState) async {
        state.selection = [.file(file.id)]
        #expect(await eventually { await self.hasContent(state, for: file) })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
    }

    private func documentID(_ state: WindowState) -> UUID? {
        if case let .text(document)? = state.diffLoader.content { return document.id }
        return nil
    }

    @Test func hidingCancelsReplacementLoadAndKeepsPublishedDiff() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let published = documentID(state)
        #expect(published != nil)

        // A reload of the same file, held at the worktree read.
        await repo.client.hold(.reads)
        state.diffSettingsChanged()
        #expect(await eventually { await repo.client.heldCount(.reads) == 1 })
        #expect(state.diffLoader.isLoading)

        state.isVisible = false
        #expect(state.diffStale)
        #expect(!state.diffLoader.hasActiveWork)
        await repo.client.release(.reads)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(documentID(state) == published, "the cancelled replacement must not publish")
        #expect(hasContent(state), "the published diff stays for the switch back")
    }

    @Test func hiddenSelectionChangeAndRefreshStartNoLoad() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        state.isVisible = false
        let reads = await repo.client.contentReads

        state.selection = [.file(filesA[0].id)]
        #expect(state.diffStale)
        await state.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == reads)
        // The changeset from adoption is still on show; what did not happen is the load
        // for the file just selected.
        #expect(!hasContent(state, for: filesA[0]))
        #expect(h.published.count == 2, "hidden refreshes still publish their file list")

        // The owed load rides on the rescan refresh that showing delivers.
        state.isVisible = true
        #expect(await eventually { await h.published.count == 3 })
        #expect(h.published.last?.cause == .watcher)
        #expect(await eventually { await !state.diffStale })
        #expect(await eventually { await self.hasContent(state, for: self.filesA[0]) })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        #expect(await repo.client.contentReads == reads + 2, "one load: index plus worktree")
    }

    @Test func diffSettingsChangeReloadsWhenVisibleAndMarksStaleWhenHidden() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads
        let visiblePublishes = h.published.count

        h.preferences.hideWhitespace.toggle()
        state.diffSettingsChanged()
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        // The reload does not wait for status, so its refresh can still be publishing.
        #expect(await eventually { await h.published.count > visiblePublishes })
        #expect(h.published.last?.cause == .settings)

        let before = h.published.count
        state.isVisible = false
        state.diffSettingsChanged()
        #expect(await eventually { await h.published.count > before })
        #expect(h.published.last?.cause == .settings)
        // The reload now rides on a settings refresh, so staleness lands asynchronously.
        #expect(await eventually { await state.diffStale })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == reads + 2, "a hidden window loads no diff")
    }

    // MARK: Changeset reloads

    /// Waits for a changeset load other than `previous` to finish publishing, and returns it.
    private func replacementChangeset(_ state: WindowState, after previous: UUID?) async -> ChangesetDocument? {
        #expect(await eventually { await changesetDocument(state.diffLoader.content)?.loadID != previous })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        return changesetDocument(state.diffLoader.content)
    }

    /// What reloads the All-changes document on screen.
    enum ReloadTrigger: CaseIterable {
        case edit
        case whitespaceToggle
        /// The rescan that showing a window delivers, after an edit made while it was hidden.
        case showingAfterAnEdit
    }

    /// A reload of the same view keeps its document on screen until the replacement is whole.
    @Test(arguments: ReloadTrigger.allCases)
    func aReloadOfAllChangesKeepsTheDocumentOnScreen(_ trigger: ReloadTrigger) async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let shown = changesetDocument(state.diffLoader.content)?.loadID
        #expect(shown != nil)

        await repo.client.hold(worktree: ["a1.swift"])
        switch trigger {
        case .edit:
            await repo.client.set(files: [filesA[0].edited(), filesA[1]])
            h.watcherCallbacks[repo.root]!()
        case .whitespaceToggle:
            h.preferences.hideWhitespace.toggle()
            state.diffSettingsChanged()
        case .showingAfterAnEdit:
            await repo.client.set(files: [filesA[0].edited(), filesA[1]])
            state.isVisible = false
            state.isVisible = true
        }
        #expect(await eventually { await repo.client.waitingWorktreePaths.contains("a1.swift") })
        #expect(
            changesetDocument(state.diffLoader.content)?.loadID == shown,
            "the document on screen stays while the replacement loads")
        #expect(state.diffLoader.isLoading)

        await repo.client.release(worktree: "a1.swift")
        let replacement = await replacementChangeset(state, after: shown)
        #expect(replacement?.sections.map(\.file.path) == ["a1.swift", "a2.swift"])
    }

    /// A new selection is a new view and starts from empty; once it is on screen, a
    /// reload of the same files keeps it, like All changes.
    @Test func selectingFilesAfterAllChangesStartsFromEmpty() async {
        let h = Harness()
        let state = h.makeState()
        // Both in Changes: a selection holds one list's rows.
        let unstaged = [filesA[0], changedFile("a2.swift")]
        let repo = await h.adopt(state, "A", files: unstaged)
        #expect(changesetDocument(state.diffLoader.content) != nil)

        await repo.client.hold(worktree: ["a1.swift"])
        state.selection = [.file(unstaged[0].id), .file(unstaged[1].id)]
        #expect(state.diffLoader.content == nil, "the All-changes document is not kept for another selection")

        await repo.client.release(worktree: "a1.swift")
        let selected = await replacementChangeset(state, after: nil)
        #expect(selected?.sections.map(\.file.path) == ["a1.swift", "a2.swift"])

        await repo.client.hold(worktree: ["a1.swift"])
        await repo.client.set(files: [unstaged[0].edited(), unstaged[1]])
        h.watcherCallbacks[repo.root]!()
        #expect(await eventually { await repo.client.waitingWorktreePaths.contains("a1.swift") })
        #expect(
            changesetDocument(state.diffLoader.content)?.loadID == selected?.loadID, "the same files reload in place")
        #expect(state.diffLoader.isLoading)

        await repo.client.release(worktree: "a1.swift")
        let replacement = await replacementChangeset(state, after: selected?.loadID)
        #expect(replacement?.sections.map(\.file.path) == ["a1.swift", "a2.swift"])
    }

    // MARK: Line stats

    @Test func publishedFilesCarryLineStats() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: filesA) { client in
            await client.set(numstat: [counted("a1.swift", 12, 4)], area: .unstaged)
            await client.set(numstat: [NumstatEntry(path: "a2.swift", stats: .binary(nil))], area: .staged)
        }
        #expect(h.published.last?.files.map(\.id) == filesA.map(\.id))

        // Stats follow the publish; the list itself does not change again.
        #expect(
            await eventually {
                await state.files.first { $0.path == "a1.swift" }?.lineStats == .counted(added: 12, deleted: 4)
            })
        #expect(state.files.first { $0.path == "a2.swift" }?.lineStats == .binary(nil))
        #expect(state.files.map(\.id) == filesA.map(\.id))
        #expect(h.published.count == 1)
    }

    @Test func whitespaceChangeReloadsDiffEvenWhenStatusFails() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads

        await repo.client.fail(true)
        h.preferences.hideWhitespace.toggle()
        state.diffSettingsChanged()
        #expect(
            await eventually { await repo.client.contentReads == reads + 2 },
            "the diff reloads without waiting for status")
        #expect(await eventually { await state.errorMessage != nil })
        #expect(state.files.map(\.id) == filesA.map(\.id))
    }

    @Test func closingDuringUntrackedReadsAttachesNothing() async {
        let h = Harness()
        let state = h.makeState()
        let fresh = changedFile("fresh.txt", kind: .untracked)
        let repo = h.repo("A", files: [fresh])
        await repo.client.hold(.reads)
        let before = h.published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count > before })
        #expect(
            await eventually { await repo.client.heldCount(.reads) >= 1 },
            "the untracked count starts after the publish")

        state.close()
        await repo.client.release(.reads)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(state.files.first?.lineStats == nil)
    }

    // MARK: Quiet refreshes

    /// Flips when the observed property is assigned. `withObservationTracking` fires its
    /// closure on the assigning thread, which for `files` is the main actor.
    private final class ChangeFlag: @unchecked Sendable {
        var raised = false
    }

    /// Adopts `files` with counts for both areas and waits for them to land.
    private func adoptCounted(
        _ h: Harness, _ state: WindowState, files: [ChangedFile], defaults: CommitDefaults = .none
    ) async -> (root: RepositoryRoot, client: StubRepoClient) {
        let repo = await h.adopt(state, "A", files: files) { client in
            await client.set(
                numstat: files.filter { $0.area == .unstaged }.map { counted($0.path, 3, 1) }, area: .unstaged)
            await client.set(numstat: files.filter { $0.area == .staged }.map { counted($0.path, 5, 2) }, area: .staged)
            await client.set(commitDefaults: defaults)
        }
        await h.settleStats(state)
        #expect(state.files.allSatisfy { $0.lineStats != nil })
        return repo
    }

    private func stats(of path: String, in state: WindowState) -> LineStats? {
        state.files.first { $0.path == path }?.lineStats
    }

    /// Sends `changes` and waits for the status read and publish it must produce. The
    /// default is a plain tick, the one `Harness.watcherCallbacks` delivers.
    private func tick(
        _ h: Harness, _ repo: RepositoryRoot, _ changes: Set<RepoChange> = [.worktree, .index],
        waitingFor client: StubRepoClient
    ) async {
        let status = await client.statusCalls
        let before = h.published.count
        h.tick(repo, changes)
        #expect(await eventually { await client.statusCalls == status + 1 })
        #expect(await eventually { await h.published.count > before })
    }

    @Test func equalTickPublishesWithoutReloadingRecountingOrReassigning() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptCounted(h, state, files: filesA)
        let reads = await repo.client.contentReads
        let numstats = await repo.client.numstatCalls
        let flag = ChangeFlag()
        withObservationTracking {
            _ = state.files
        } onChange: {
            flag.raised = true
        }

        await tick(h, repo.root, waitingFor: repo.client)
        #expect(h.published.last?.cause == .watcher)
        #expect(h.published.last?.inputsChanged == false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == reads, "nothing shown changed, so nothing is re-read")
        #expect(await repo.client.numstatCalls == numstats, "the last counts still answer the same inputs")
        #expect(!flag.raised, "an equal list is not reassigned")
        #expect(state.files.allSatisfy { $0.lineStats != nil })
    }

    @Test func changedSelectedFileReloadsTheDiff() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads

        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(h.published.last?.inputsChanged == true)
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
    }

    @Test func anyChangedFileReloadsAllChanges() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        #expect(state.detailSelection == .allChanges)
        let reads = await repo.client.contentReads

        await repo.client.set(files: [filesA[0], filesA[1].restaged()])
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(await eventually { await repo.client.contentReads > reads })
    }

    @Test func changedUnselectedFileRecountsWithoutReloading() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptCounted(h, state, files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads
        await repo.client.hold(.numstat)

        await repo.client.set(files: [filesA[0], filesA[1].restaged()])
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(stats(of: "a2.swift", in: state) == nil, "moved inputs drop the old counts until new ones arrive")
        #expect(stats(of: "a1.swift", in: state) == .counted(added: 3, deleted: 1), "unmoved inputs keep theirs")
        #expect(await eventually { await repo.client.heldCount(.numstat) == 2 })
        #expect(await repo.client.contentReads == reads, "the shown file did not change")

        await repo.client.release(.numstat)
        #expect(await eventually { await self.stats(of: "a2.swift", in: state) == .counted(added: 5, deleted: 2) })
    }

    @Test func failedLoadRetriesOnAnEqualTick() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        await repo.client.fail(worktree: ["a1.swift"])
        await state.refresh()
        #expect(await eventually { await state.diffLoader.errorMessage != nil })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })

        await repo.client.fail(worktree: [])
        let reads = await repo.client.contentReads
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
        #expect(await eventually { await state.diffLoader.errorMessage == nil })
    }

    @Test func interruptedCountsPublishNilAndRunOnce() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptCounted(h, state, files: filesA)
        await repo.client.hold(.numstat)

        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(stats(of: "a1.swift", in: state) == nil)
        #expect(await eventually { await repo.client.heldCount(.numstat) == 2 })
        let numstats = await repo.client.numstatCalls

        await tick(h, repo.root, waitingFor: repo.client)
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(await repo.client.numstatCalls == numstats, "an equal request keeps the read already running")
        #expect(stats(of: "a1.swift", in: state) == nil)

        await repo.client.release(.numstat)
        #expect(await eventually { await self.stats(of: "a1.swift", in: state) == .counted(added: 3, deleted: 1) })
    }

    @Test func revertedEditKeepsTheEarlierCountsWhenTheSupersededReadFinishes() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptCounted(h, state, files: filesA)
        // A: the counts on screen. B: the edit, whose read would report something else.
        await repo.client.set(numstat: [counted(filesA[0].path, 99, 0)], area: .unstaged)
        await repo.client.hold(.numstat)
        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(stats(of: "a1.swift", in: state) == nil)
        #expect(await eventually { await repo.client.heldCount(.numstat) == 2 })

        // Back to A: the last finished read answers again, and B's is superseded.
        await repo.client.set(files: filesA)
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(stats(of: "a1.swift", in: state) == .counted(added: 3, deleted: 1))
        await repo.client.release(.numstat)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(stats(of: "a1.swift", in: state) == .counted(added: 3, deleted: 1), "B's counts never land on A")
    }

    @Test func failedCountsAreReusedByTicksAndRetriedByManualRefresh() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA) { await $0.fail(numstat: true) }
        await h.settleStats(state)
        #expect(state.files.map(\.id) == filesA.map(\.id))
        #expect(state.files.allSatisfy { $0.lineStats == nil })
        #expect(state.errorMessage == nil, "stats are decoration and must not fail the refresh")
        let numstats = await repo.client.numstatCalls

        await tick(h, repo.root, waitingFor: repo.client)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.numstatCalls == numstats, "a tick does not retry a failure")

        await repo.client.fail(numstat: false)
        await repo.client.set(numstat: [counted(filesA[0].path, 3, 1)], area: .unstaged)
        await repo.client.set(numstat: [counted(filesA[1].path, 5, 2)], area: .staged)
        await state.refresh()
        #expect(await eventually { await self.stats(of: "a1.swift", in: state) == .counted(added: 3, deleted: 1) })
        #expect(await eventually { await self.stats(of: "a2.swift", in: state) == .counted(added: 5, deleted: 2) })
    }

    @Test func whitespaceToggleStartsANewCount() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptCounted(h, state, files: filesA)
        let numstats = await repo.client.numstatCalls

        let toggled = !h.preferences.hideWhitespace
        h.preferences.hideWhitespace = toggled
        state.diffSettingsChanged()
        #expect(await eventually { await repo.client.numstatCalls == numstats + 2 })
        #expect(await eventually { await repo.client.lastIgnoreWhitespace == toggled })
    }

    private func hasFailedSection(_ state: WindowState) -> Bool {
        guard case let .changeset(document)? = state.diffLoader.content else { return false }
        return document.sections.contains { if case .failed = $0.outcome { return true } else { return false } }
    }

    @Test func failedSectionRetriesOnceAcrossEqualTicks() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA) { await $0.fail(worktree: ["a1.swift"]) }
        #expect(hasFailedSection(state))

        await repo.client.fail(worktree: [])
        await repo.client.hold(.reads)
        let reads = await repo.client.contentReads
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(await eventually { await repo.client.heldCount(.reads) == 1 }, "the replacement starts")
        #expect(await eventually { await repo.client.contentReads == reads + 4 })

        await tick(h, repo.root, waitingFor: repo.client)
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(await repo.client.contentReads == reads + 4, "a replacement in flight is not restarted")

        await repo.client.release(.reads)
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        #expect(!hasFailedSection(state))
        #expect(await repo.client.contentReads == reads + 4)
    }

    @Test func settingsRefreshLeavesTheDefaultsReadAlone() async throws {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: filesA)
        let expected = merging("Merge branch 'feature'")
        await repo.client.set(commitDefaults: expected)
        await repo.client.hold(.commitDefaults)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await repo.client.heldCount(.commitDefaults) == 1 })
        let task = try #require(state.session?.commitDefaultsTask)
        let generation = state.session?.commitDefaultsGeneration
        let before = h.published.count

        state.diffSettingsChanged()
        #expect(await eventually { await h.published.count > before })
        #expect(h.published.last?.cause == .settings)
        #expect(await repo.client.commitDefaultsCalls == 1, "a settings change has no bearing on the suggestion")
        #expect(state.session?.commitDefaultsGeneration == generation)

        await repo.client.release(.commitDefaults)
        await task.value
        #expect(state.commitDefaults == expected)
    }

    @Test func olderDefaultsReadIsDiscardedWhileTheNewerRefreshIsStillReading() async throws {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: filesA)
        let older = merging("Merge branch 'older'")
        let newer = merging("Merge branch 'newer'")
        await repo.client.set(commitDefaults: older)
        await repo.client.hold(.commitDefaults)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await repo.client.heldCount(.commitDefaults) == 1 })
        let old = try #require(state.session?.commitDefaultsTask)

        // The newer refresh is accepted, and its defaults read starts, before its status returns.
        await repo.client.set(commitDefaults: newer)
        await repo.client.hold(.status)
        let refresh = Task { await state.refresh() }
        #expect(await eventually { await repo.client.heldCount(.status) == 1 })
        #expect(await eventually { await repo.client.heldCount(.commitDefaults) == 2 })

        await repo.client.releaseFirst(.commitDefaults)
        await old.value
        #expect(state.commitDefaults == .none, "the older read finished and applied nothing")

        await repo.client.releaseFirst(.status)
        await refresh.value
        await repo.client.release(.commitDefaults)
        let current = try #require(state.session?.commitDefaultsTask)
        await current.value
        #expect(state.commitDefaults == newer)
    }

    @Test func manualRefreshReloadsEqualFiles() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads

        await state.refresh()
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
    }

    /// An edit that lands between the settings load's read and its status would leave
    /// the old content behind a fingerprint every later tick judges unchanged.
    @Test func settingsRefreshReloadsAShownFileThatChangedUnderTheLoad() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads

        // The stub snapshots its list when status is called, so the edit is in place before
        // the refresh starts; the held status still returns after the load's reads.
        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        await repo.client.hold(.status)
        state.diffSettingsChanged()
        #expect(await eventually { await repo.client.contentReads == reads + 2 }, "the settings load read the file")
        #expect(await eventually { await repo.client.heldCount(.status) == 1 })
        await repo.client.hold(.status, false)
        await repo.client.releaseFirst(.status)
        #expect(await eventually { await h.published.last?.cause == .settings })
        #expect(await eventually { await repo.client.contentReads == reads + 4 }, "the edit is read again")

        let after = await repo.client.contentReads
        await tick(h, repo.root, waitingFor: repo.client)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == after, "the tick has nothing new to load")
    }

    // MARK: Hiding and showing

    @Test func hidingStopsTheWatcherAndShowingStartsANewOne() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        #expect(h.watcherStarts[repo.root] == 1)
        let first = h.watchers[repo.root]
        let status = await repo.client.statusCalls
        let reads = await repo.client.contentReads
        let before = h.published.count

        state.isVisible = false
        #expect(!state.diffStale, "nothing was loading, so nothing is owed")
        #expect(first?.stopped == true)
        #expect(h.watcherStarts[repo.root] == 2, "hidden, a watcher keeps the churn")
        let hidden = h.watchers[repo.root]
        #expect(hidden !== first)
        #expect(hidden?.stopped == false)

        state.isVisible = true
        #expect(hidden?.stopped == true)
        #expect(h.watcherStarts[repo.root] == 3)
        #expect(h.watchers[repo.root] !== hidden)
        #expect(h.watchers[repo.root]?.stopped == false)
        #expect(await eventually { await h.published.count > before })
        #expect(h.published.last?.cause == .watcher)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == status + 1, "one rescan")
        #expect(await repo.client.contentReads == reads, "nothing changed: the diff on show is kept")
        #expect(!state.diffLoader.hasActiveWork)
    }

    /// Hiding replaces the watcher: a running refresh and the tick queued behind it go
    /// with the old one, and the rescan on showing finds the edit they carried.
    @Test func staleStatusAcrossHideAndShow() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads
        let status = await repo.client.statusCalls
        let before = h.published.count
        let tick = h.watcherCallbacks[repo.root]!

        await repo.client.hold(.status)
        tick()
        #expect(await eventually { await repo.client.heldCount(.status) == 1 })
        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        tick()
        state.isVisible = false
        await repo.client.hold(.status, false)
        await repo.client.releaseFirst(.status)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.published.count == before, "the outlived read publishes nothing")
        #expect(await repo.client.statusCalls == status + 1, "the queued follow-up is dropped")
        #expect(state.files.first?.fingerprint == filesA[0].fingerprint)
        #expect(!state.diffStale, "nothing was published, so no reload is owed")
        #expect(await repo.client.contentReads == reads)

        // The stopped watcher's callback reads nothing.
        tick()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == status + 1)

        state.isVisible = true
        #expect(await eventually { await repo.client.statusCalls == status + 2 })
        #expect(await eventually { await state.files.first?.fingerprint == self.filesA[0].edited().fingerprint })
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        #expect(!state.diffStale)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == status + 2)
        #expect(await repo.client.contentReads == reads + 2, "exactly one load")

        // Once a new watcher runs, the replaced one's ticks are still dropped.
        tick()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == status + 2)
        h.watcherCallbacks[repo.root]!()
        #expect(
            await eventually { await repo.client.statusCalls == status + 3 }, "the new watcher's ticks are processed")
    }

    @Test func showingInCommitScopeReadsMetadataAndReloadsTheStaleDiff() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptInCommitScope(h, state)
        let file = state.files[0]

        state.isVisible = false
        state.selection = [.file(file.id)]
        #expect(state.diffStale)
        let before = await Reads(repo.client)

        state.isVisible = true
        // A commit's files cannot change; the status and numstat reads are the working
        // tree's churn. The owed load runs and reuses the result the changeset registered,
        // so it reads nothing.
        #expect(await eventually { await self.hasContent(state, for: file) })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        let expected = before.plus(Reads(status: 1, head: 1, headState: 1, numstat: 2))
        #expect(await eventually { await Reads(repo.client) == expected })
        #expect(!state.diffStale)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await Reads(repo.client) == expected)
    }

    @Test func adoptingHiddenStartsAWatcherAtOnce() async {
        let h = Harness()
        let state = h.makeState()
        state.isVisible = false
        let repo = await h.adopt(state, "A", files: filesA)
        #expect(h.watcherStarts[repo.root] == 1)
        #expect(state.session?.watcher != nil)

        state.isVisible = true
        #expect(h.watcherStarts[repo.root] == 2)
        #expect(state.session?.watcher != nil)
    }

    /// A hidden tick refreshes the list and its line counts for the tab bar's churn, and
    /// nothing else: no diff, no repository metadata, no commit defaults.
    @Test func aHiddenTickRefreshesOnlyTheListAndItsChurn() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        #expect(state.workingTreeChurn == RepositoryChurn(changedFileCount: 2, added: 8, deleted: 3))
        state.isVisible = false
        let before = await Reads(repo.client)
        let published = h.published.count

        let updated = filesA + [changedFile("new.swift")]
        await repo.client.set(files: updated)
        await repo.client.set(
            numstat: [counted(filesA[0].path, 3, 1), counted(updated[2].path, 4, 0)], area: .unstaged)
        h.tick(repo.root, [.worktree, .index, .refs])
        #expect(
            await eventually {
                await state.workingTreeChurn == RepositoryChurn(changedFileCount: 3, added: 12, deleted: 3)
            })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await Reads(repo.client) == before.plus(Reads(status: 1, numstat: 2)))
        #expect(state.files.map(\.id) == updated.map(\.id))
        #expect(h.published.count == published + 1)
        #expect(state.diffStale, "the new row's diff waits for the window to show")
    }

    /// A `.gitattributes` edit can change line counts without moving any fingerprint, so a
    /// hidden tab must re-count rather than reuse the counts it has.
    @Test func aHiddenConfigurationChangeRecountsUnchangedFiles() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        state.isVisible = false
        let before = await Reads(repo.client)

        await repo.client.set(numstat: [counted(filesA[0].path, 1, 0)], area: .unstaged)
        await repo.client.set(numstat: [counted(filesA[1].path, 1, 0)], area: .staged)
        h.tick(repo.root, [.configuration])
        let recounted = RepositoryChurn(changedFileCount: 2, added: 2, deleted: 0)
        #expect(await eventually { await state.workingTreeChurn == recounted })
        #expect(await Reads(repo.client) == before.plus(Reads(status: 1, numstat: 2)))
    }

    /// Showing while a hidden refresh is in flight queues the rescan behind it.
    @Test func aHiddenRefreshInFlightDoesNotLoseTheRescan() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        state.isVisible = false
        let status = await repo.client.statusCalls
        let before = h.published.count

        await repo.client.hold(.status)
        h.tick(repo.root, [.worktree])
        #expect(await eventually { await repo.client.heldCount(.status) == 1 })
        state.isVisible = true
        #expect(await eventually { await state.session?.watcherRefreshPending != nil })

        let updated = [changedFile("new.swift")]
        await repo.client.set(files: updated)
        await repo.client.hold(.status, false)
        await repo.client.releaseFirst(.status)
        #expect(await eventually { await repo.client.statusCalls == status + 2 }, "the rescan runs as the follow-up")
        #expect(await eventually { await h.published.count == before + 1 })
        #expect(state.files == updated)
        #expect(await eventually { await state.workingTreeChurn?.changedFileCount == 1 })
    }

    /// A status read that outlives its watcher publishes nothing: its snapshot predates
    /// the hide, and the rescan queued behind it reads again rather than being lost.
    @Test func aStatusReadOutlivedByItsWatcherPublishesNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads
        let status = await repo.client.statusCalls
        let before = h.published.count

        // The selected file is gone in the snapshot the held read will return.
        await repo.client.set(files: [filesA[1]])
        await repo.client.hold(.status)
        h.watcherCallbacks[repo.root]!()
        #expect(await eventually { await repo.client.heldCount(.status) == 1 })
        state.isVisible = false
        state.isVisible = true
        #expect(await eventually { await state.session?.watcherRefreshPending != nil })
        // It is back by the time the rescan reads.
        await repo.client.set(files: filesA)
        // The stale read returns; the rescan's read is held next.
        await repo.client.releaseFirst(.status)
        #expect(await eventually { await repo.client.heldCount(.status) == 1 })
        await repo.client.releaseFirst(.status)

        #expect(await eventually { await repo.client.statusCalls == status + 2 })
        #expect(await eventually { await h.published.count == before + 1 }, "the stale response published nothing")
        #expect(state.selection == [.file(filesA[0].id)], "the selection survives the file's brief absence")
        #expect(state.files == filesA)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.published.count == before + 1)
        #expect(await repo.client.statusCalls == status + 2, "the rescan runs once, as the follow-up")
        #expect(await repo.client.contentReads == reads, "the shown file's fingerprint is unchanged: no reload")
    }

    /// The load owed from hiding does not depend on the status read on show succeeding.
    @Test func aFailedStatusOnShowStillLoadsTheOwedDiff() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads

        // A reload of the same file, held at the worktree read.
        await repo.client.hold(.reads)
        state.diffSettingsChanged()
        #expect(await eventually { await repo.client.heldCount(.reads) == 1 })
        state.isVisible = false
        #expect(state.diffStale)
        await repo.client.hold(.reads, false)
        await repo.client.release(.reads)

        await repo.client.fail(true)
        state.isVisible = true
        #expect(await eventually { await state.errorMessage != nil }, "the status failure is kept")
        // The cancelled reload's two reads were counted before the hold; the owed load adds two.
        #expect(await eventually { await repo.client.contentReads == reads + 4 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        #expect(!state.diffStale)
        #expect(hasContent(state, for: filesA[0]))
        #expect(state.files == filesA, "the old list is retained")
    }

    /// Status cannot say what HEAD holds for a conflict, so the fingerprint is unknown and
    /// every tick reloads: the price of never showing a stale conflict.
    @Test func unmergedFileRevalidatesOnEveryTick() async {
        let h = Harness()
        let state = h.makeState()
        let conflict = changedFile("c.swift", kind: .unmerged)
        let repo = await h.adopt(state, "A", files: [conflict])
        await select(conflict, in: state)
        let reads = await repo.client.contentReads

        await tick(h, repo.root, waitingFor: repo.client)
        #expect(h.published.last?.inputsChanged == true)
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
    }

    // MARK: Routed ticks

    /// Adopts `files` with counts and waits for every read the adoption starts, so the
    /// counters below move only for the tick under test.
    private func adoptSettled(
        _ h: Harness, _ state: WindowState, files: [ChangedFile], defaults: CommitDefaults = .none
    ) async -> (root: RepositoryRoot, client: StubRepoClient) {
        let repo = await adoptCounted(h, state, files: files, defaults: defaults)
        await state.session?.historyTask?.value
        await state.session?.commitDefaultsTask?.value
        #expect(await eventually { await state.localBranches == ["main"] })
        return repo
    }

    /// Every read a tick can route to, taken at one moment, or the reads a tick adds.
    struct Reads: Equatable {
        var status, head, headState, defaults, numstat, content, commitFiles, history: Int

        /// The reads a tick adds; the commit's files and its history are never among them.
        init(status: Int = 0, head: Int = 0, headState: Int = 0, defaults: Int = 0, numstat: Int = 0) {
            self.status = status
            self.head = head
            self.headState = headState
            self.defaults = defaults
            self.numstat = numstat
            content = 0
            commitFiles = 0
            history = 0
        }

        init(_ client: StubRepoClient) async {
            status = await client.statusCalls
            head = await client.headCalls
            headState = await client.headStateCalls
            defaults = await client.commitDefaultsCalls
            numstat = await client.numstatCalls
            content = await client.contentReads
            commitFiles = await client.commitFileCalls
            history = await client.historyCalls
        }

        /// The same counters after `added`.
        func plus(_ added: Reads) -> Reads {
            var reads = self
            reads.status += added.status
            reads.head += added.head
            reads.headState += added.headState
            reads.defaults += added.defaults
            reads.numstat += added.numstat
            reads.content += added.content
            reads.commitFiles += added.commitFiles
            reads.history += added.history
            return reads
        }
    }

    /// A tick, where it lands, and what it may cost.
    struct RoutedTick: CustomTestStringConvertible {
        enum Setup {
            case workingTree
            /// With a commit template configured, which may live in the worktree.
            case workingTreeWithTemplate
            case commit
            case hiddenCommit
        }

        let name: String
        let setup: Setup
        let changes: Set<RepoChange>
        let reads: Reads
        /// Only a working-tree status read publishes a file list.
        let publishes: Int

        var testDescription: String { name }
    }

    /// A tick reads only what its changes can have moved. In commit scope that is the
    /// working tree's churn for the tab bar, plus HEAD and the branch for the title bar
    /// on a ref change; a commit's files and an unmoved HEAD's history are never re-read.
    @Test(arguments: [
        RoutedTick(
            name: "an index change costs one status read", setup: .workingTree, changes: [.index],
            reads: Reads(status: 1), publishes: 1),
        RoutedTick(
            name: "a ref change reads metadata and defaults without reloading", setup: .workingTree,
            changes: [.refs], reads: Reads(status: 1, head: 1, headState: 1, defaults: 1), publishes: 1),
        RoutedTick(
            name: "a worktree change rereads the defaults while a template is configured",
            setup: .workingTreeWithTemplate, changes: [.worktree], reads: Reads(status: 1, defaults: 1),
            publishes: 1),
        RoutedTick(
            name: "a worktree change in commit scope reads only the churn", setup: .commit, changes: [.worktree],
            reads: Reads(status: 1, numstat: 2), publishes: 0),
        RoutedTick(
            name: "a ref change in commit scope checks HEAD and reads the churn", setup: .commit, changes: [.refs],
            reads: Reads(status: 1, head: 1, headState: 1, numstat: 2), publishes: 0),
        RoutedTick(
            name: "a worktree change while hidden in commit scope reads only the churn", setup: .hiddenCommit,
            changes: [.worktree], reads: Reads(status: 1, numstat: 2), publishes: 0),
        RoutedTick(
            name: "an index change while hidden in commit scope reads only the churn", setup: .hiddenCommit,
            changes: [.index], reads: Reads(status: 1, numstat: 2), publishes: 0),
        RoutedTick(
            name: "a ref change while hidden in commit scope reads only the churn", setup: .hiddenCommit,
            changes: [.refs], reads: Reads(status: 1, numstat: 2), publishes: 0),
    ])
    func aTickReadsOnlyWhatItsChangesCanMove(_ tick: RoutedTick) async {
        let h = Harness()
        let state = h.makeState()
        let repo: (root: RepositoryRoot, client: StubRepoClient)
        switch tick.setup {
        case .workingTree:
            repo = await adoptSettled(h, state, files: filesA)
        case .workingTreeWithTemplate:
            let defaults = CommitDefaults(suggestion: nil, isMerging: false, templateDependency: configured)
            repo = await adoptSettled(h, state, files: filesA, defaults: defaults)
            #expect(state.session?.templateDependency == configured)
        case .commit:
            repo = await adoptInCommitScope(h, state)
        case .hiddenCommit:
            repo = await adoptInCommitScope(h, state)
            state.isVisible = false
        }
        let before = await Reads(repo.client)
        let published = h.published.count

        h.tick(repo.root, tick.changes)
        let expected = before.plus(tick.reads)
        #expect(await eventually { await Reads(repo.client) == expected })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await Reads(repo.client) == expected, "and nothing else follows")
        #expect(h.published.count == published + tick.publishes)
    }

    /// Attributes can reclassify an unchanged file as binary, so a configuration change
    /// recounts everything and shows nothing stale meanwhile.
    @Test func aConfigurationTickDropsCarriedOverCountsAndRecounts() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        let revision = state.session?.configurationRevision
        await repo.client.hold(.numstat)

        await tick(h, repo.root, [.configuration], waitingFor: repo.client)
        #expect(state.session?.configurationRevision == revision.map { $0 + 1 })
        #expect(state.files.allSatisfy { $0.lineStats == nil }, "the old counts answer another configuration")
        #expect(await eventually { await repo.client.heldCount(.numstat) == 2 })

        await repo.client.release(.numstat)
        #expect(await eventually { await state.files.allSatisfy { $0.lineStats != nil } })
    }

    @Test func aWorktreeTickLeavesAHeldDefaultsReadAloneWhenNoTemplateIsConfigured() async throws {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        // Spelled out: `.none` against an optional would mean nil.
        #expect(state.session?.templateDependency == CommitDefaults.TemplateDependency.none)
        let expected = merging("Merge branch 'feature'")
        await repo.client.set(commitDefaults: expected)
        await repo.client.hold(.commitDefaults)
        await state.refresh()
        #expect(await eventually { await repo.client.heldCount(.commitDefaults) == 1 })
        let task = try #require(state.session?.commitDefaultsTask)
        let defaults = await repo.client.commitDefaultsCalls

        await tick(h, repo.root, [.worktree], waitingFor: repo.client)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.commitDefaultsCalls == defaults, "no template: the worktree cannot change it")

        await repo.client.release(.commitDefaults)
        await task.value
        #expect(state.commitDefaults == expected, "the held read was not superseded")
    }

    /// A configuration change may have enabled a template. Until the read it starts says
    /// so, a worktree tick must not trust the old "none": a template edit made while that
    /// read is pending would otherwise publish a suggestion that is already stale.
    @Test func aConfigurationTickForgetsTheTemplateDependencyUntilItsReadLands() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        #expect(state.session?.templateDependency == CommitDefaults.TemplateDependency.none)

        let templateA = templated("A")
        let templateB = templated("B")
        // The read the configuration tick starts sees template A and is held there.
        await repo.client.set(commitDefaults: templateA)
        await repo.client.hold(.commitDefaults)
        await tick(h, repo.root, [.configuration], waitingFor: repo.client)
        #expect(await eventually { await repo.client.heldCount(.commitDefaults) == 1 })
        #expect(state.session?.templateDependency == .unknown)

        // The template is edited to B while A's read is pending; the worktree tick must read again.
        await repo.client.set(commitDefaults: templateB)
        await tick(h, repo.root, [.worktree], waitingFor: repo.client)
        #expect(await eventually { await repo.client.heldCount(.commitDefaults) == 2 })

        await repo.client.releaseFirst(.commitDefaults)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(state.commitDefaults == .none, "A's read is stale and applies nothing")
        await repo.client.hold(.commitDefaults, false)
        await repo.client.release(.commitDefaults)
        #expect(await eventually { await state.commitDefaults == templateB })
        #expect(state.session?.templateDependency == configured)
    }

    /// A template in the worktree, as the routed-tick tests configure it.
    private let configured = CommitDefaults.TemplateDependency.configured(path: "/tmp/A/.gitmessage")

    private func templated(_ text: String) -> CommitDefaults {
        CommitDefaults(
            suggestion: .init(text: text, source: .template), isMerging: false, templateDependency: configured)
    }

    /// The watcher learns the template's path from each read, so an edit to a template kept
    /// under `.git` is not dropped with that directory's noise.
    @Test func aDefaultsReadHandsTheTemplatePathToTheWatcher() async {
        let h = Harness()
        let state = h.makeState()
        let path = "/tmp/A/.git/commit-template"
        let repo = await h.adopt(state, "A", files: filesA) { client in
            await client.set(
                commitDefaults: CommitDefaults(
                    suggestion: nil, isMerging: false, templateDependency: .configured(path: path)))
        }
        await state.session?.commitDefaultsTask?.value
        #expect(h.watchers[repo.root]?.dependencies.last == [path])

        await repo.client.set(commitDefaults: .none)
        await state.refresh()
        await state.session?.commitDefaultsTask?.value
        #expect(h.watchers[repo.root]?.dependencies.last == [], "unset: nothing left to depend on")
    }

    /// A read that threw cannot say whether a template is configured, so the next
    /// worktree tick reads again rather than assuming there is none.
    @Test func aFailedDefaultsReadIsRetriedByAWorktreeTick() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA) { await $0.fail(commitDefaults: true) }
        await state.session?.commitDefaultsTask?.value
        #expect(state.session?.templateDependency == .unknown)

        let expected = merging("Merge branch 'feature'")
        await repo.client.fail(commitDefaults: false)
        await repo.client.set(commitDefaults: expected)
        await tick(h, repo.root, [.worktree], waitingFor: repo.client)
        #expect(await eventually { await state.commitDefaults == expected })
    }

    @Test func ticksWithDifferentChangesMergeIntoOneFollowUp() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        let before = await Reads(repo.client)
        await repo.client.hold(.status)
        h.tick(repo.root, [.index])
        #expect(await eventually { await repo.client.heldCount(.status) == 1 })
        h.tick(repo.root, [.index])
        h.tick(repo.root, [.refs])
        await repo.client.hold(.status, false)
        await repo.client.releaseFirst(.status)

        #expect(await eventually { await repo.client.statusCalls == before.status + 2 }, "one follow-up")
        #expect(await eventually { await repo.client.headStateCalls == before.headState + 1 }, "carrying `.refs`")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == before.status + 2)
        #expect(await repo.client.headStateCalls == before.headState + 1)
    }

    /// Selects `commit` and waits for its files, its line counts and the working tree's
    /// churn, so a tick arrives in commit scope with no read still running.
    private func adoptInCommitScope(_ h: Harness, _ state: WindowState) async -> (
        root: RepositoryRoot, client: StubRepoClient
    ) {
        let commit = commitSummary("c1")
        let repo = h.repo("A", files: filesA)
        await repo.client.set(head: commit.ref.sha)
        await repo.client.set(commits: [commit])
        await repo.client.set(
            files: [ChangedFile(path: "one.swift", originalPath: nil, kind: .modified, area: .commit(commit.ref))],
            forCommit: commit.ref.sha)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await !state.history.commits.isEmpty })
        state.select(commit: commit)
        #expect(await eventually { await state.files.count == 1 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        #expect(await eventually { await state.localBranches == ["main"] })
        #expect(await eventually { await state.workingTreeChurn != nil })
        await h.settleStats(state)
        return repo
    }
}
