import Foundation
import Testing

@testable import DiffViewer

/// One staged file, so a commit is possible, and one unstaged file to stage in the
/// tests that queue a write ahead of the commit.
private let filesStaged = [changedFile("a.swift", area: .staged), changedFile("b.swift")]
/// What the reader types, never what git suggests.
private let message = "Add the picker"
/// What git suggests while a merge is in progress.
private let mergeText = "Merge branch 'feature'"

private func merging(_ text: String) -> CommitDefaults {
    CommitDefaults(suggestion: CommitDefaults.Suggestion(text: text, source: .merge), isMerging: true)
}

private func template(_ text: String) -> CommitDefaults {
    CommitDefaults(suggestion: CommitDefaults.Suggestion(text: text, source: .template), isMerging: false)
}

/// A window and the repository behind it.
private typealias Window = (h: Harness, state: WindowState, client: StubRepoClient, root: RepositoryRoot)

@MainActor
struct WindowStateCommitTests {
    // MARK: Fixtures

    /// A window over a repository whose `commitDefaults` are what git would suggest,
    /// adopted and waited on as far as the first file list. `holdingDefaults` keeps that
    /// list's defaults read suspended, for the tests that watch a read still in flight.
    private func adopted(
        files: [ChangedFile] = filesStaged, defaults: CommitDefaults = .none, holdingDefaults: Bool = false
    ) async -> Window {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: files)
        await repo.client.set(commitDefaults: defaults)
        await repo.client.holdCommitDefaults(holdingDefaults)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count == 1 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        return (h, state, repo.client, repo.root)
    }

    /// The same, plus the reads that follow the publish: the defaults, the commit list
    /// and HEAD. After it the draft holds whatever the defaults imply and every baseline
    /// is stable, so a later "unchanged" assertion means something.
    private func settled(files: [ChangedFile] = filesStaged, defaults: CommitDefaults = .none) async throws -> Window {
        let window = await adopted(files: files, defaults: defaults)
        try await settleDefaults(window.state)
        let historyTask = try #require(window.state.session?.historyTask)
        await historyTask.value
        #expect(await eventually { await window.state.headState != nil })
        return window
    }

    /// Waits for the defaults read of whichever refresh is newest right now, so an
    /// assertion about the draft is about the rule rather than about timing.
    private func settleDefaults(_ state: WindowState) async throws {
        let defaultsTask = try #require(state.session?.commitDefaultsTask)
        await defaultsTask.value
    }

    /// Refreshes and waits for that refresh's own defaults read.
    private func refreshSettled(_ state: WindowState) async throws {
        await state.refresh()
        try await settleDefaults(state)
    }

    /// Holds every git write, starts a commit and waits until git has it: the shape of
    /// every test that drives something while the commit is in flight.
    private func startHeldCommit(_ state: WindowState, _ client: StubRepoClient) async -> Task<Void, Never> {
        await client.holdActions(true)
        let task = Task { await state.commit() }
        #expect(await eventually { await client.heldActionCount == 1 })
        return task
    }

    /// Lets the held writes through and waits for the commit to finish.
    private func release(_ task: Task<Void, Never>, _ client: StubRepoClient) async {
        await client.holdActions(false)
        await client.releaseActions()
        await task.value
    }

    /// The same, and then the defaults read started by the commit's own refresh.
    private func finish(_ task: Task<Void, Never>, _ client: StubRepoClient, _ state: WindowState) async throws {
        await release(task, client)
        try await settleDefaults(state)
    }

    // MARK: Committing

    /// The whole successful path in one: git gets the draft, the box is emptied for the
    /// next message, and the list, the history and HEAD are all re-read, because the
    /// watcher ignores this process's own writes.
    @Test func commitSendsDraftClearsItAndReloadsHistory() async throws {
        let (h, state, client, _) = try await settled()
        state.commitMessage = message
        await state.commit()

        #expect(await client.commitMessages == [message])
        #expect(state.commitMessage == "")
        #expect(h.published.last?.cause == .commit)
        #expect(await client.headStateCalls == 2)
        // `refreshHistory` is fire-and-forget, so its read lands after `commit` returns.
        #expect(await eventually { await client.historyCalls == 2 })
        #expect(!state.isCommitting)
    }

    /// A rejected commit is news the reader has not seen, so it outlives the refresh
    /// that follows it — and the message they wrote is theirs to try again with.
    @Test func failingCommitKeepsDraftAndReportsAfterRefresh() async throws {
        let (h, state, client, _) = try await settled()
        await client.fail(commit: true)
        state.commitMessage = message
        await state.commit()

        #expect(state.commitMessage == message)
        #expect(state.errorMessage?.contains("pre-commit hook failed") == true)
        #expect(h.published.last?.cause == .commit)

        await client.set(commitDefaults: merging(mergeText))
        try await refreshSettled(state)
        #expect(state.commitMessage == message, "a failed message counts as the reader's own")
    }

    /// The gap the restore exists for: a refresh landed while git ran and emptied the
    /// untouched draft, so without it a rejected commit would lose the message.
    @Test func defaultsChangeDuringFailingCommitDoesNotLoseTheMessage() async throws {
        let (h, state, client, root) = try await settled(defaults: merging(mergeText))
        #expect(state.commitMessage == mergeText)
        let commitTask = await startHeldCommit(state, client)

        await client.set(commitDefaults: .none)
        let before = h.published.count
        // A merge abort removes MERGE_HEAD: the change that re-reads the defaults.
        h.tick(root, [.commitState])
        #expect(await eventually { await h.published.count == before + 1 })
        try await settleDefaults(state)
        #expect(state.commitMessage == "", "the untouched draft was emptied while git ran")

        await client.fail(commit: true)
        try await finish(commitTask, client, state)

        #expect(state.commitMessage == mergeText)
        #expect(state.errorMessage != nil)
    }

    /// Typed while git ran: the reader's own text outranks both the submitted message
    /// and the suggestion.
    @Test func typedDuringFailingCommit() async throws {
        let (_, state, client, _) = try await settled()
        state.commitMessage = message
        let commitTask = await startHeldCommit(state, client)
        state.commitMessage = "next"
        await client.fail(commit: true)
        try await finish(commitTask, client, state)

        #expect(state.commitMessage == "next")
        #expect(state.errorMessage != nil)
    }

    /// A box the reader emptied is an edit like any other: the failure does not put the
    /// submitted message back into it.
    @Test func clearedDuringFailingCommit() async throws {
        let (_, state, client, _) = try await settled()
        state.commitMessage = message
        let commitTask = await startHeldCommit(state, client)
        state.commitMessage = ""
        await client.fail(commit: true)
        try await finish(commitTask, client, state)

        #expect(state.commitMessage == "", "an emptied box is the reader's, not a draft to restore")
        #expect(state.errorMessage != nil)
    }

    /// Typing the suggestion back is an edit for the commit — the failure leaves it
    /// alone — and not for a refresh, which may still replace a draft equal to it.
    @Test func editedBackToDefaultDuringFailingCommit() async throws {
        let (_, state, client, _) = try await settled(defaults: merging(mergeText))
        state.commitMessage = message
        let commitTask = await startHeldCommit(state, client)
        state.commitMessage = mergeText
        await client.fail(commit: true)
        try await finish(commitTask, client, state)
        #expect(state.commitMessage == mergeText)

        await client.set(commitDefaults: .none)
        try await refreshSettled(state)
        #expect(state.commitMessage == "", "a draft equal to the default is the refresh's to replace")
    }

    // MARK: The write queue

    /// A commit rides the same serialized chain as the sidebar's writes, so it can never
    /// meet a stage on `index.lock`.
    @Test func commitWaitsBehindHeldStage() async throws {
        let (_, state, client, _) = try await settled()
        state.commitMessage = message
        await client.holdActions(true)
        let stage = Task { await state.perform(.stage, on: [filesStaged[1]]) }
        #expect(await eventually { await client.heldActionCount == 1 })

        let commitTask = Task { await state.commit() }
        #expect(await eventually { await state.isCommitting })
        #expect(await client.commitMessages.isEmpty, "queued, not started")

        await release(commitTask, client)
        await stage.value

        #expect(await client.commitMessages == [message])
        #expect(!state.isCommitting)
    }

    /// A burst of ⌘↩ records one commit: the admission guard is set before the first
    /// suspension, so the second call finds one already queued and returns.
    @Test func secondCommitWhileFirstIsHeldIsRejected() async throws {
        let (_, state, client, _) = try await settled()
        state.commitMessage = message
        let commitTask = await startHeldCommit(state, client)

        await state.commit()
        #expect(await client.commitMessages.count == 1)

        await release(commitTask, client)
        #expect(await client.commitMessages.count == 1)
    }

    /// The next message, started while the last one was still being recorded, is not
    /// swept away by the success that clears an untouched box.
    @Test func textTypedDuringCommitSurvivesItsSuccess() async throws {
        let (_, state, client, _) = try await settled()
        state.commitMessage = message
        let commitTask = await startHeldCommit(state, client)
        state.commitMessage = "next"
        try await finish(commitTask, client, state)

        #expect(state.commitMessage == "next")
        #expect(await client.commitMessages == [message])
    }

    // MARK: Closing

    /// git was already running when the window closed, so the commit itself stands; what
    /// a closed window must not do is publish a list or raise an alert nobody can see.
    @Test func commitInFlightAtCloseNeitherPublishesNorErrors() async throws {
        let (h, state, client, _) = try await settled()
        state.commitMessage = message
        let commitTask = await startHeldCommit(state, client)

        let publishes = h.published.count
        state.close()
        await release(commitTask, client)

        #expect(h.published.count == publishes)
        #expect(state.errorMessage == nil)
        #expect(!state.isCommitting)
    }

    /// Still behind another write when the window closed: the guard at the top of the
    /// queued body means git is never asked to commit at all.
    @Test func commitQueuedAtCloseNeverRunsGit() async throws {
        let (h, state, client, _) = try await settled()
        state.commitMessage = message
        await client.holdActions(true)
        let stage = Task { await state.perform(.stage, on: [filesStaged[1]]) }
        #expect(await eventually { await client.heldActionCount == 1 })
        let commitTask = Task { await state.commit() }
        #expect(await eventually { await state.isCommitting })

        let publishes = h.published.count
        state.close()
        await release(commitTask, client)
        await stage.value

        #expect(await client.commitMessages.isEmpty)
        #expect(h.published.count == publishes)
        #expect(state.errorMessage == nil)
    }

    /// `refresh` returns quietly for a closed window, so the history load after it needs
    /// a guard of its own: without one the picker would be left spinning for good.
    @Test func closeDuringPostCommitRefreshStartsNoHistoryLoad() async throws {
        let (h, state, client, _) = try await settled()
        state.commitMessage = message
        let commitTask = await startHeldCommit(state, client)
        // Every status read from here on is held, so the commit's own refresh waits.
        await client.hold(true)
        await client.holdActions(false)
        await client.releaseActions()
        #expect(await eventually { await client.heldCount == 1 })

        let historyReads = await client.historyCalls
        let headStateReads = await client.headStateCalls
        let publishes = h.published.count
        state.close()
        await client.hold(false)
        await client.releaseFirst()
        await commitTask.value

        #expect(h.published.count == publishes)
        #expect(await client.historyCalls == historyReads, "no commit-list read was even started")
        #expect(await client.headStateCalls == headStateReads)
        #expect(!state.isLoadingHistory)
        #expect(state.errorMessage == nil)
    }

    // MARK: Reading the defaults

    /// The defaults read runs after the publish, so a slow `commit.template` never holds
    /// up the sidebar.
    @Test func fileListPublishesWhileDefaultsReadIsHeld() async throws {
        let (h, state, client, _) = await adopted(holdingDefaults: true)

        #expect(h.published.count == 1)
        #expect(await eventually { await client.heldCommitDefaultsCount == 1 })
        #expect(state.commitDefaults == .none)

        await client.holdCommitDefaults(false)
        await client.releaseCommitDefaults()
        try await settleDefaults(state)
    }

    /// Two reads in flight at once: the older one finishes first and must apply nothing,
    /// or a watcher tick would put a stale suggestion back into the box.
    @Test func staleDefaultsReadIsIgnoredAfterNewerRefresh() async throws {
        let newer = merging("Merge branch 'newer'")
        // The stub snapshots the older value before it suspends.
        let (_, state, client, _) = await adopted(defaults: merging("Merge branch 'older'"), holdingDefaults: true)
        #expect(await eventually { await client.heldCommitDefaultsCount == 1 })
        let old = try #require(state.session?.commitDefaultsTask)

        await client.set(commitDefaults: newer)
        await state.refresh()
        #expect(await eventually { await client.heldCommitDefaultsCount == 2 })

        await client.releaseFirstCommitDefaults()
        await old.value
        #expect(state.commitDefaults == .none, "the older read finished and applied nothing")
        #expect(state.commitMessage == "")

        await client.holdCommitDefaults(false)
        await client.releaseCommitDefaults()
        try await settleDefaults(state)
        #expect(state.commitDefaults == newer)
        #expect(state.commitMessage == "Merge branch 'newer'")
    }

    // MARK: The draft rule

    /// An untouched box is git's to fill and git's to empty, and neither write is the
    /// reader's edit: `commitDraftRevision` is what a commit reads to tell the two apart.
    @Test func anUntouchedDraftFollowsTheSuggestion() async throws {
        let (_, state, client, _) = try await settled()
        #expect(state.commitMessage == "")
        let revision = state.commitDraftRevision

        await client.set(commitDefaults: merging(mergeText))
        try await refreshSettled(state)
        #expect(state.commitMessage == mergeText, "a new suggestion fills the empty box")
        #expect(state.commitDefaults.isMerging)

        await client.set(commitDefaults: .none)
        try await refreshSettled(state)
        #expect(state.commitMessage == "", "aborting a merge takes its message away with it")
        #expect(state.commitDefaults == .none)
        #expect(state.commitDraftRevision == revision, "neither write was an edit")

        state.commitMessage = message
        #expect(state.commitDraftRevision == revision + 1, "the reader's own write is")
    }

    /// Every watcher tick re-reads the defaults, so what the reader did to the box — a
    /// half-written message, or emptying it — has to survive all of them.
    @Test func anEditedDraftSurvivesEveryRefresh() async throws {
        let (_, state, client, _) = try await settled(defaults: merging(mergeText))
        state.commitMessage = message

        try await refreshSettled(state)
        #expect(state.commitMessage == message, "the same suggestion does not overwrite it")

        await client.set(commitDefaults: .none)
        try await refreshSettled(state)
        #expect(state.commitMessage == message, "and neither does the suggestion going away")

        await client.set(commitDefaults: merging(mergeText))
        state.commitMessage = ""
        try await refreshSettled(state)
        #expect(state.commitMessage == "", "clearing the box is a choice the next tick must not undo")
    }

    /// A read that threw knows nothing, so the box keeps its last good state rather than
    /// being emptied by a transient failure.
    @Test func aFailedDefaultsReadChangesNothing() async throws {
        let suggested = merging(mergeText)
        let (_, state, client, _) = try await settled(defaults: suggested)

        await client.fail(commitDefaults: true)
        await client.set(commitDefaults: .none)
        try await refreshSettled(state)

        #expect(state.commitMessage == mergeText)
        #expect(state.commitDefaults == suggested)
    }

    // MARK: canCommit

    /// Something has to be recorded: staged files, or a merge whose tree already equals
    /// HEAD and so stages nothing yet still has to be committed.
    @Test func commitNeedsSomethingToCommit() async throws {
        let (_, state, client, _) = try await settled(files: [changedFile("b.swift")], defaults: merging(mergeText))
        #expect(state.commitMessage == mergeText)
        #expect(state.canCommit, "an empty index is no reason to refuse a merge")

        await client.set(commitDefaults: .none)
        try await refreshSettled(state)
        state.commitMessage = message
        #expect(!state.canCommit, "with the merge over, nothing is staged")
    }

    /// A blank box commits nothing, and a `commit.template` left exactly as git wrote it
    /// is boilerplate rather than a message.
    @Test func commitNeedsARealMessage() async throws {
        let boilerplate = "# Write a message"
        let (_, state, _, _) = try await settled(defaults: template(boilerplate))
        #expect(state.commitMessage == boilerplate, "the template fills the empty box")
        #expect(state.commitNeedsTemplateEdit)
        #expect(!state.canCommit, "an unedited template is not a message")

        state.commitMessage = ""
        #expect(!state.canCommit, "an empty box commits nothing")
        state.commitMessage = "  \n\t "
        #expect(!state.canCommit, "and neither does whitespace")

        state.commitMessage = message
        #expect(!state.commitNeedsTemplateEdit, "the template was edited")
        #expect(state.canCommit)
    }

    /// A conflicted row means the merge is not finished; committing here would record
    /// the conflict markers.
    @Test func commitNeedsATreeWithoutConflicts() async throws {
        let (_, state, _, _) = try await settled(files: filesStaged + [changedFile("c.swift", kind: .unmerged)])
        state.commitMessage = message

        #expect(!state.canCommit)
    }

    /// The box belongs to an open window on the working tree: a commit on show is
    /// history, and the staged list behind it is not what the sidebar is describing.
    @Test func commitNeedsAnOpenWorkingTreeWindow() async throws {
        let (h, state, _, _) = try await settled()
        state.commitMessage = message
        #expect(state.canCommit)
        #expect(!state.commitNeedsTemplateEdit, "there is no template to edit")

        state.select(commit: commitSummary("c1"))
        #expect(!state.canCommit, "a commit on show is history")
        #expect(await eventually { await h.published.last?.cause == .scope })

        let publishes = h.published.count
        state.selectWorkingTree()
        #expect(await eventually { await h.published.count > publishes })
        #expect(state.canCommit, "back on the working tree")

        state.close()
        #expect(!state.canCommit)
    }

    // MARK: canOpenCommitSheet

    /// The sheet is where the message gets written, so a blank draft is no reason to
    /// keep it shut; only the commit itself waits for one.
    @Test func canOpenCommitSheetWithoutADraft() async throws {
        let (_, state, _, _) = try await settled()
        #expect(state.commitMessage == "")
        #expect(state.canOpenCommitSheet)
        #expect(!state.canCommit)
    }

    /// The same for an unedited template: the sheet opens so it can be edited there.
    @Test func canOpenCommitSheetWithAnUneditedTemplate() async throws {
        let boilerplate = "# Write a message"
        let (_, state, _, _) = try await settled(defaults: template(boilerplate))
        #expect(state.commitNeedsTemplateEdit)
        #expect(state.canOpenCommitSheet)
        #expect(!state.canCommit)
    }

    /// A merge whose tree equals HEAD stages nothing yet still has to be committed.
    @Test func canOpenCommitSheetForAMergeWithoutStagedFiles() async throws {
        let (_, state, _, _) = try await settled(files: [changedFile("b.swift")], defaults: merging(mergeText))
        #expect(state.commitDefaults.isMerging)
        #expect(state.canOpenCommitSheet)
    }

    /// Unstaged changes alone do not allow committing.
    @Test func cannotOpenCommitSheetWithoutStagedFilesOrMerge() async throws {
        let (_, state, _, _) = try await settled(files: [changedFile("b.swift")])
        #expect(!state.canOpenCommitSheet)
    }

    /// A conflicted row means the merge is not finished.
    @Test func cannotOpenCommitSheetWithConflicts() async throws {
        let (_, state, _, _) = try await settled(files: filesStaged + [changedFile("c.swift", kind: .unmerged)])
        #expect(!state.canOpenCommitSheet)
    }

    // MARK: Confirming the sheet's message

    /// The sheet hands over the text the reader saw; while the draft still says the same,
    /// the commit goes ahead as a plain `commit()` would.
    @Test func aConfirmedMessageThatStillMatchesTheDraftCommits() async throws {
        let (_, state, client, _) = try await settled()
        state.commitMessage = message
        #expect(await state.commit(confirming: message))
        #expect(await client.commitMessages == [message])
    }

    /// An untouched merge suggestion confirmed just before the merge was aborted: the
    /// draft is empty by the time the sheet is gone, and nothing is committed.
    @Test func aDraftChangedSinceConfirmationIsNotCommitted() async throws {
        let (_, state, client, _) = try await settled(defaults: merging(mergeText))
        #expect(state.commitMessage == mergeText)
        await client.set(commitDefaults: .none)
        try await refreshSettled(state)
        #expect(state.commitMessage == "")

        #expect(await !state.commit(confirming: mergeText))
        #expect(await client.commitMessages.isEmpty)
    }
}
