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
/// What `git diff --cached --patch-with-stat` prints: a generation needs a patch to describe.
private let stagedPatch = """
     a.swift | 2 +-
    1 file changed, 1 insertion(+), 1 deletion(-)

    diff --git a/a.swift b/a.swift
    --- a/a.swift
    +++ b/a.swift
    @@ -1 +1 @@
    -old
    +new
    """

private func template(_ text: String) -> CommitDefaults {
    CommitDefaults(suggestion: CommitDefaults.Suggestion(text: text, source: .template), isMerging: false)
}

@MainActor
struct WindowStateCommitTests {
    // MARK: Fixtures

    /// A window over a repository whose `commitDefaults` are what git would suggest,
    /// adopted and waited on as far as the first file list. `holdingDefaults` keeps that
    /// list's defaults read suspended, for the tests that watch a read still in flight.
    private func adopted(
        files: [ChangedFile] = filesStaged, defaults: CommitDefaults = .none, holdingDefaults: Bool = false,
        generator: any CommitMessageGenerator = StubCommitMessageGenerator()
    ) async -> Window {
        let h = Harness()
        let state = h.makeState(commitMessageGenerator: generator)
        let repo = await h.adopt(state, "A", files: files) { client in
            await client.set(commitDefaults: defaults)
            await client.hold(.commitDefaults, holdingDefaults)
        }
        return (h, state, repo.client, repo.root)
    }

    /// The same, plus the reads that follow the publish: the defaults, the commit list
    /// and HEAD. After it the draft holds whatever the defaults imply and every baseline
    /// is stable, so a later "unchanged" assertion means something.
    private func settled(
        files: [ChangedFile] = filesStaged, defaults: CommitDefaults = .none,
        generator: any CommitMessageGenerator = StubCommitMessageGenerator()
    ) async throws -> Window {
        let window = await adopted(files: files, defaults: defaults, generator: generator)
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
        await client.hold(.actions)
        let task = Task { await state.commit() }
        #expect(await eventually { await client.heldCount(.actions) == 1 })
        return task
    }

    /// Lets the held writes through and waits for the commit to finish.
    private func release(_ task: Task<Void, Never>, _ client: StubRepoClient) async {
        await client.hold(.actions, false)
        await client.release(.actions)
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

    /// A rejected commit gets its own alert, and only for as long as its message is the
    /// one on show: a later error from anything else takes the generic one.
    @Test func failingCommitIsFlaggedUntilAnotherErrorReplacesIt() async throws {
        let (_, state, client, _) = try await settled()
        #expect(!state.errorIsCommitFailure)
        await client.fail(commit: true)
        state.commitMessage = message
        await state.commit()
        #expect(state.errorIsCommitFailure)

        await client.fail(actions: true)
        await state.perform(.stage, on: [filesStaged[1]])
        #expect(state.errorMessage?.contains("index.lock exists") == true)
        #expect(!state.errorIsCommitFailure)
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

    /// An edit made while git runs survives the failure; `""` guards a cleared draft.
    @Test(arguments: ["next", ""])
    func editedDuringFailingCommit(editedMessage: String) async throws {
        let (_, state, client, _) = try await settled()
        state.commitMessage = message
        let commitTask = await startHeldCommit(state, client)
        state.commitMessage = editedMessage
        await client.fail(commit: true)
        try await finish(commitTask, client, state)

        #expect(state.commitMessage == editedMessage, "the reader's edit, not a draft to restore")
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
        await client.hold(.actions)
        let stage = Task { await state.perform(.stage, on: [filesStaged[1]]) }
        #expect(await eventually { await client.heldCount(.actions) == 1 })

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
        await client.hold(.actions)
        let stage = Task { await state.perform(.stage, on: [filesStaged[1]]) }
        #expect(await eventually { await client.heldCount(.actions) == 1 })
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
        await client.hold(.status)
        await client.hold(.actions, false)
        await client.release(.actions)
        #expect(await eventually { await client.heldCount(.status) == 1 })

        let historyReads = await client.historyCalls
        let headStateReads = await client.headStateCalls
        let publishes = h.published.count
        state.close()
        await client.hold(.status, false)
        await client.releaseFirst(.status)
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
        #expect(await eventually { await client.heldCount(.commitDefaults) == 1 })
        #expect(state.commitDefaults == .none)

        await client.hold(.commitDefaults, false)
        await client.release(.commitDefaults)
        try await settleDefaults(state)
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

    // MARK: canCommit and canOpenCommitSheet

    /// Something has to be recorded: staged files, or a merge whose tree already equals
    /// HEAD and so stages nothing yet still has to be committed.
    @Test func commitNeedsSomethingToCommit() async throws {
        let (_, state, client, _) = try await settled(files: [changedFile("b.swift")], defaults: merging(mergeText))
        #expect(state.commitMessage == mergeText)
        #expect(state.canOpenCommitSheet)
        #expect(state.canCommit, "an empty index is no reason to refuse a merge")

        await client.set(commitDefaults: .none)
        try await refreshSettled(state)
        state.commitMessage = message
        #expect(!state.canOpenCommitSheet, "unstaged changes alone are nothing to commit")
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
        #expect(state.canOpenCommitSheet, "the sheet opens so the template can be edited there")

        state.commitMessage = ""
        #expect(!state.canCommit, "an empty box commits nothing")
        #expect(state.canOpenCommitSheet, "the sheet is where the message gets written")
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

        #expect(!state.canOpenCommitSheet)
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

    // MARK: Generating the message

    /// Each piece replaces the last, and the finished text is the reader's own from then
    /// on: the next defaults read may not swap it for git's suggestion.
    @Test func generationStreamsIntoTheDraftAndOutranksTheSuggestion() async throws {
        let generator = StubCommitMessageGenerator(texts: ["Add", "Add the picker"])
        let (_, state, client, _) = try await settled(generator: generator)
        await client.set(stagedPatch: stagedPatch)

        state.generateCommitMessage()
        #expect(await eventually { await !state.isGeneratingCommitMessage })
        #expect(state.commitMessage == "Add the picker")
        #expect(state.commitGenerationError == nil)
        #expect(await client.stagedPatchContextLines == [10])

        await client.set(commitDefaults: merging(mergeText))
        try await refreshSettled(state)
        #expect(state.commitMessage == "Add the picker")
    }

    /// A generated message that happens to read like git's own suggestion is the reader's
    /// all the same: the next defaults read may not swap it for a newer suggestion.
    @Test func generatedTextEqualToTheSuggestionStaysOwned() async throws {
        let (_, state, client, _) = try await settled(
            defaults: merging(mergeText), generator: StubCommitMessageGenerator(texts: [mergeText]))
        await client.set(stagedPatch: stagedPatch)

        state.generateCommitMessage()
        #expect(await eventually { await !state.isGeneratingCommitMessage })
        #expect(state.commitMessage == mergeText)

        await client.set(commitDefaults: merging("Merge branch 'other'"))
        try await refreshSettled(state)
        #expect(state.commitMessage == mergeText)
    }

    /// A model that gave up says so in the sheet, and what the reader had written stays.
    @Test func aFailedGenerationReportsAndKeepsTheDraft() async throws {
        let (_, state, client, _) = try await settled(
            generator: StubCommitMessageGenerator(failure: StubGenerationError()))
        await client.set(stagedPatch: stagedPatch)
        state.commitMessage = message

        state.generateCommitMessage()
        #expect(await eventually { await state.commitGenerationError != nil })
        #expect(state.commitGenerationError == "the model gave up")
        #expect(state.commitMessage == message)
        #expect(!state.isGeneratingCommitMessage)
    }

    /// No model, no button: the reason is what the button's help shows, and pressing it
    /// anyway reads nothing.
    @Test func anUnavailableModelGeneratesNothing() async throws {
        let unavailable = StubCommitMessageGenerator(unavailableReason: "Turn on Apple Intelligence")
        let (_, state, client, _) = try await settled(generator: unavailable)

        #expect(state.canOpenCommitSheet)
        #expect(!state.canGenerateCommitMessage)
        #expect(state.commitGenerationUnavailableReason == "Turn on Apple Intelligence")

        state.generateCommitMessage()
        #expect(!state.isGeneratingCommitMessage)
        #expect(state.commitMessage == "")
        #expect(await client.stagedPatchContextLines.isEmpty)
    }

    /// The reader typing over what the model is writing takes the draft back: the run
    /// stops there, and nothing it streams afterwards reaches the draft.
    @Test func aReaderEditDuringGenerationCancelsIt() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: StubCommitMessageGenerator(channel: channel))
        await client.set(stagedPatch: stagedPatch)

        state.generateCommitMessage()
        #expect(await eventually { channel.generateCalls == 1 })
        channel.yield("Add")
        #expect(await eventually { await state.commitMessage == "Add" })
        #expect(state.isGeneratingCommitMessage)

        // Taken before the edit, which clears the session's handle on it.
        let task = try #require(state.session?.commitGenerationTask)
        state.commitMessage = "Add the picker"
        #expect(!state.isGeneratingCommitMessage)

        channel.yield("Add the pic")
        await task.value
        #expect(state.commitMessage == "Add the picker", "a cancelled run writes nothing more")
    }

    /// Committing half a message would record whatever the model had reached, so Commit
    /// waits until the run is over.
    @Test func commitWaitsForGenerationToFinish() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: StubCommitMessageGenerator(channel: channel))
        await client.set(stagedPatch: stagedPatch)

        state.generateCommitMessage()
        #expect(await eventually { channel.generateCalls == 1 })
        channel.yield(message)
        #expect(await eventually { await state.commitMessage == message })
        #expect(!state.canCommit, "the message is still being written")

        channel.finish()
        #expect(await eventually { await state.canCommit })
    }

    /// A run that fails partway keeps the piece the reader has already seen, and says why
    /// the rest never came.
    @Test func aFailureAfterPartialOutputKeepsItAndReports() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: StubCommitMessageGenerator(channel: channel))
        await client.set(stagedPatch: stagedPatch)

        state.generateCommitMessage()
        #expect(await eventually { channel.generateCalls == 1 })
        channel.yield("Add")
        #expect(await eventually { await state.commitMessage == "Add" })

        channel.fail()
        #expect(await eventually { await state.commitGenerationError == "the model gave up" })
        #expect(state.commitMessage == "Add")
        #expect(!state.isGeneratingCommitMessage)
    }

    /// Cancelling settles the run without an error, and the button is ready again: a
    /// second press starts a fresh generation.
    @Test func aCancelledGenerationCanBeRestarted() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: StubCommitMessageGenerator(channel: channel))
        await client.set(stagedPatch: stagedPatch)

        state.generateCommitMessage()
        #expect(await eventually { channel.generateCalls == 1 })
        channel.yield("Add")
        #expect(await eventually { await state.commitMessage == "Add" })

        state.cancelCommitMessageGeneration()
        #expect(!state.isGeneratingCommitMessage)
        #expect(state.commitGenerationError == nil)
        #expect(state.commitMessage == "Add")

        state.generateCommitMessage()
        #expect(await eventually { channel.generateCalls == 2 })
        #expect(state.isGeneratingCommitMessage)
    }

    /// A merge whose tree already equals HEAD opens the sheet with nothing staged: there
    /// is no patch to summarize, so the model is never asked and the draft stands.
    @Test func aMergeWithNothingStagedGeneratesNothing() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(
            files: [], defaults: merging(mergeText), generator: StubCommitMessageGenerator(channel: channel))
        #expect(state.canOpenCommitSheet)
        #expect(state.commitMessage == mergeText)
        await client.set(stagedPatch: "")

        state.generateCommitMessage()
        #expect(await eventually { await state.commitGenerationError == "No staged changes to summarize" })
        #expect(state.commitMessage == mergeText)
        #expect(!state.isGeneratingCommitMessage)
        #expect(channel.generateCalls == 0)
    }

    // MARK: How much context the patch carries

    /// A patch whose header carries `name`, so a test can tell which context size it came
    /// from, padded by `extraLines` added lines to push it past a small budget.
    private func patch(_ name: String, extraLines: Int = 0) -> String {
        stagedPatch.replacingOccurrences(of: "a.swift", with: "\(name).swift")
            + (0..<extraLines).map { "\n+line \($0)" }.joined()
    }

    /// Budget small enough that a hundred added lines never fit and the bare fixture does.
    private func generatorWithSmallBudget(_ channel: StubGenerationChannel) -> StubCommitMessageGenerator {
        var generator = StubCommitMessageGenerator(channel: channel)
        generator.characterBudget = 1_000
        return generator
    }

    @Test func aPatchThatFitsAtTenLinesIsTheOnlyOneAskedFor() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: generatorWithSmallBudget(channel))
        await client.set(stagedPatch: patch("ten"), forContextLines: 10)

        await generate(state, channel, writing: message)
        #expect(await client.stagedPatchContextLines == [10])
        #expect(channel.lastRequest?.patchWithStat == patch("ten"))
    }

    @Test func aTooBigPatchFallsBackToSixLines() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: generatorWithSmallBudget(channel))
        await client.set(stagedPatch: patch("ten", extraLines: 100), forContextLines: 10)
        await client.set(stagedPatch: patch("six"), forContextLines: 6)

        await generate(state, channel, writing: message)
        #expect(await client.stagedPatchContextLines == [10, 6])
        #expect(channel.lastRequest?.patchWithStat == patch("six"))
    }

    /// Three lines is git's default and the last resort: it is used even when it is cut.
    @Test func theThreeLinePatchIsUsedEvenWhenItDoesNotFit() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: generatorWithSmallBudget(channel))
        await client.set(stagedPatch: patch("ten", extraLines: 100), forContextLines: 10)
        await client.set(stagedPatch: patch("six", extraLines: 100), forContextLines: 6)
        await client.set(stagedPatch: patch("three", extraLines: 100), forContextLines: 3)

        await generate(state, channel, writing: message)
        #expect(await client.stagedPatchContextLines == [10, 6, 3])
        #expect(channel.lastRequest?.patchWithStat == patch("three", extraLines: 100))
    }

    /// Less context cannot add a change, so an empty patch is not asked for again.
    @Test func anEmptyPatchIsAskedForOnce() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: generatorWithSmallBudget(channel))
        await client.set(stagedPatch: "")

        state.generateCommitMessage()
        #expect(await eventually { await state.commitGenerationError == "No staged changes to summarize" })
        #expect(await client.stagedPatchContextLines == [10])
        #expect(channel.generateCalls == 0)
    }

    /// Less context would not shrink the stat, so a cut stat alone never asks for another read.
    @Test func anOversizedStatDoesNotAskForLessContext() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: generatorWithSmallBudget(channel))
        let stat = (1...100).map { " file\($0).swift | 2 +-" }.joined(separator: "\n") + "\n\n"
        let text = stat + patch("ten")
        await client.set(stagedPatch: text, forContextLines: 10)

        await generate(state, channel, writing: message)
        #expect(await client.stagedPatchContextLines == [10])
        #expect(channel.lastRequest?.patchWithStat == text)
    }

    /// Starts a generation whose first patch is too big to keep and holds that read, so the
    /// walk would go on to the next step if nothing stopped it.
    private func generationHeldOnFirstRead(
        _ state: WindowState, _ client: StubRepoClient
    ) async throws -> Task<Void, Never> {
        await client.set(stagedPatch: patch("ten", extraLines: 100), forContextLines: 10)
        await client.hold(.stagedPatch)
        state.generateCommitMessage()
        #expect(await eventually { await client.heldCount(.stagedPatch) == 1 })
        let task = try #require(state.session?.commitGenerationTask)
        await client.hold(.stagedPatch, false)
        return task
    }

    @Test func cancellingDuringTheFirstReadStopsTheWalk() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: generatorWithSmallBudget(channel))
        let task = try await generationHeldOnFirstRead(state, client)

        state.cancelCommitMessageGeneration()
        await client.release(.stagedPatch)
        await task.value
        #expect(await client.stagedPatchContextLines == [10])
        #expect(channel.generateCalls == 0)
    }

    @Test func closingDuringTheFirstReadStopsTheWalk() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: generatorWithSmallBudget(channel))
        let task = try await generationHeldOnFirstRead(state, client)

        state.close()
        await client.release(.stagedPatch)
        await task.value
        #expect(await client.stagedPatchContextLines == [10])
        #expect(channel.generateCalls == 0)
    }

    // MARK: What the model is told

    /// Starts a generation through `channel`, streams `text`, finishes it and waits for
    /// the run to settle.
    private func generate(_ state: WindowState, _ channel: StubGenerationChannel, writing text: String) async {
        let calls = channel.generateCalls
        state.generateCommitMessage()
        #expect(await eventually { channel.generateCalls == calls + 1 })
        channel.yield(text)
        channel.finish()
        #expect(await eventually { await !state.isGeneratingCommitMessage })
    }

    /// What the reader typed before pressing Generate steers the message.
    @Test func aTypedDraftIsSentAsTheNote() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: StubCommitMessageGenerator(channel: channel))
        await client.set(stagedPatch: stagedPatch)
        state.commitMessage = "fix flicker"

        await generate(state, channel, writing: message)
        #expect(channel.lastRequest?.draftNote == "fix flicker")
    }

    /// git's suggestion left as it was is not the reader's words.
    @Test func anUntouchedSuggestionIsNoNote() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(
            defaults: merging(mergeText), generator: StubCommitMessageGenerator(channel: channel))
        await client.set(stagedPatch: stagedPatch)
        #expect(state.commitMessage == mergeText)

        await generate(state, channel, writing: message)
        #expect(channel.generateCalls == 1)
        #expect(channel.lastRequest?.draftNote == nil)
    }

    /// Pressing Generate again does not feed the model its own answer; editing that
    /// answer first makes it the reader's note.
    @Test func regeneratingSendsOnlyAnEditedAnswerAsTheNote() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: StubCommitMessageGenerator(channel: channel))
        await client.set(stagedPatch: stagedPatch)

        await generate(state, channel, writing: message)
        await generate(state, channel, writing: message)
        #expect(channel.generateCalls == 2)
        #expect(channel.lastRequest?.draftNote == nil)

        state.commitMessage = "Add the picker for commits"
        await generate(state, channel, writing: message)
        #expect(channel.generateCalls == 3)
        #expect(channel.lastRequest?.draftNote == "Add the picker for commits")
    }

    /// A rejected commit puts the generated message back, and it is still the model's
    /// answer rather than a note.
    @Test func aGeneratedMessageRestoredAfterAFailedCommitIsNoNote() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: StubCommitMessageGenerator(channel: channel))
        await client.set(stagedPatch: stagedPatch)
        await generate(state, channel, writing: message)

        await client.fail(commit: true)
        await state.commit()
        #expect(state.commitMessage == message)

        await generate(state, channel, writing: message)
        #expect(channel.generateCalls == 2)
        #expect(channel.lastRequest?.draftNote == nil)
    }

    /// A named HEAD is sent as the branch, and a detached one sends none; the prompt
    /// decides whether it says anything.
    @Test(
        arguments: [(HeadState, String?)]([
            (.named("main"), "main"),
            (.detached(sha: String(repeating: "a", count: 40)), nil),
        ]))
    func theBranchSentFollowsHead(head: HeadState, branch: String?) async throws {
        let channel = StubGenerationChannel()
        let (h, state, client, root) = try await settled(generator: StubCommitMessageGenerator(channel: channel))
        await client.set(stagedPatch: stagedPatch)
        // The fixture starts on main; any other HEAD arrives through a tick.
        if head != .named("main") {
            await client.set(headState: head)
            h.tick(root, [.refs])
        }
        #expect(await eventually { await state.headState == head })

        await generate(state, channel, writing: message)
        #expect(channel.generateCalls == 1)
        #expect(channel.lastRequest?.branch == branch)
    }

    /// A run that outlived a switch would pair the old branch name with the new branch's
    /// patch, so the switch stops it; what it wrote stays.
    @Test func aBranchSwitchCancelsGeneration() async throws {
        let channel = StubGenerationChannel()
        let (_, state, client, _) = try await settled(generator: StubCommitMessageGenerator(channel: channel))
        await client.set(stagedPatch: stagedPatch)
        await client.set(headStateAfterSwitch: .named("side"))

        state.generateCommitMessage()
        #expect(await eventually { channel.generateCalls == 1 })
        channel.yield("Add")
        #expect(await eventually { await state.commitMessage == "Add" })
        let task = try #require(state.session?.commitGenerationTask)

        await state.switchBranch(to: "side")
        #expect(!state.isGeneratingCommitMessage)

        channel.yield("Add the pic")
        await task.value
        #expect(state.commitMessage == "Add", "a cancelled run writes nothing more")
    }
}
