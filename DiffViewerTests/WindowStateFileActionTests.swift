import Foundation
import Testing

@testable import DiffViewer

@MainActor
struct WindowStateFileActionTests {
    /// The sidebar order is unstaged then staged, so these draw as a, b, c.
    let files = [
        changedFile("a.swift"), changedFile("b.swift"), changedFile("c.swift", area: .staged),
    ]

    /// Adopts `files`, then says what the repository becomes once the write lands, so the
    /// action validates against the world it clicked on and refreshes into the new one.
    private func adopt(_ h: Harness, _ state: WindowState, after: [ChangedFile]) async -> StubRepoClient {
        let repo = await h.adopt(state, "A", files: files)
        await repo.client.set(filesAfterWrite: after)
        return repo.client
    }

    @Test func stagingTheSelectedFileMovesTheSelectionWithIt() async {
        let h = Harness()
        let state = h.makeState()
        let staged = changedFile("a.swift", area: .staged)
        let client = await adopt(h, state, after: [staged, files[1], files[2]])
        state.selection = [.file(files[0].id)]

        await state.perform(.stage, on: [files[0]])

        let performed = await client.performed
        #expect(performed.map(\.action) == [.stage])
        #expect(performed.map(\.paths) == [["a.swift"]])
        #expect(await eventually { await state.selectedFileID == staged.id })
        #expect(state.selectedFile?.area == .staged)
        #expect(h.published.last?.cause == .fileAction)
        #expect(state.errorMessage == nil)
    }

    @Test func discardingTheSelectedFileSelectsTheRowThatTookItsPlace() async {
        let h = Harness()
        let state = h.makeState()
        let client = await adopt(h, state, after: [files[1], files[2]])
        state.selection = [.file(files[0].id)]
        let next = files[1].id

        await state.perform(.discard, on: [files[0]])

        #expect(await client.performed.map(\.action) == [.discard])
        #expect(await eventually { await state.selectedFileID == next })
        #expect(state.errorMessage == nil)
    }

    @Test func discardingTheOnlyRowLeavesNothingSelected() async {
        let h = Harness()
        let state = h.makeState()
        let only = [changedFile("a.swift")]
        let repo = await h.adopt(state, "A", files: only)
        await repo.client.set(filesAfterWrite: [])
        state.selection = [.file(only[0].id)]

        await state.perform(.discard, on: [only[0]])

        #expect(await eventually { await state.files.isEmpty })
        #expect(state.selectedFileID == nil)
        #expect(state.errorMessage == nil)
    }

    /// Right-clicking outside the selection acts on the rows under the pointer and leaves
    /// the selection where the reader put it, batch or not.
    @Test func actingOnOtherRowsLeavesTheSelectionAlone() async {
        let h = Harness()
        let state = h.makeState()
        let stagedA = changedFile("a.swift", area: .staged)
        let stagedB = changedFile("b.swift", area: .staged)
        _ = await adopt(h, state, after: [stagedA, stagedB, files[2]])
        state.selection = [.file(files[2].id)]

        await state.perform(.stage, on: [files[0], files[1]])

        #expect(await eventually { await h.published.last?.cause == .fileAction })
        #expect(state.selection == [.file(files[2].id)])
    }

    /// A failed write still republishes: git does not roll back what it already did, so
    /// the list on screen has to be re-read rather than assumed unchanged. Here the stub
    /// changed nothing, so the same list comes back, and the error outlives that refresh.
    @Test func aFailedWriteReportsGitsMessageAndRepublishes() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        await repo.client.fail(actions: true)

        await state.perform(.stage, on: [files[0]])

        #expect(state.errorMessage?.contains("index.lock exists") == true)
        #expect(state.files == files)
        #expect(h.published.last?.cause == .fileAction)
    }

    /// A write is only as safe as the list it was checked against, and `status()` is that
    /// list. When the read fails there is nothing to check, so nothing runs.
    @Test func aWriteWhoseStatusReadFailsRunsNothingAndReportsTheError() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        await repo.client.fail(true)

        await state.perform(.stage, on: [files[0]])

        #expect(await repo.client.performed.isEmpty)
        #expect(state.errorMessage != nil)
        #expect(state.files == files)
    }

    @Test func trashingAnUntrackedFileCallsTheClientAndRepublishes() async {
        let h = Harness()
        let state = h.makeState()
        let untracked = changedFile("u.txt", kind: .untracked)
        let repo = await h.adopt(state, "A", files: [untracked])
        await repo.client.set(filesAfterWrite: [])

        await state.perform(.trash, on: [untracked])

        #expect(await repo.client.trashed == [["u.txt"]])
        #expect(await eventually { await h.published.last?.cause == .fileAction })
        #expect(state.files.isEmpty)
    }

    @Test func aClosedWindowPerformsNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        state.close()

        await state.perform(.stage, on: [files[0]])

        #expect(await repo.client.performed.isEmpty)
    }

    @Test func aFileThatLeftTheListPerformsNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)

        await state.perform(.stage, on: [changedFile("stale.swift")])

        #expect(await repo.client.performed.isEmpty)
    }

    /// A queued write is checked again, against a fresh status read, once the write ahead
    /// of it has finished. `ChangedFile.id` is area and path only, so the same row can
    /// come back with a new kind — and "Restore File" on a deleted row would then be an
    /// unconfirmed discard of a modified one.
    @Test func aQueuedWriteIsDroppedWhenItsRowCameBackWithAnotherKind() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        let client = repo.client
        await client.holdActions(true)

        let first = Task { await state.perform(.stage, on: [files[0]]) }
        #expect(await eventually { await client.heldActionCount == 1 })
        let second = Task { await state.perform(.discard, on: [files[1]]) }
        // Let the second write reach the queue, where it waits on the first.
        for _ in 0..<10 { await Task.yield() }
        // What the second write's status read will find: b is a deletion now, so the
        // queued discard no longer means what the menu offered.
        await client.set(files: [files[0], changedFile("b.swift", kind: .deleted), files[2]])
        await client.holdActions(false)
        await client.releaseActions()
        await first.value
        await second.value

        let performed = await client.performed
        #expect(performed.map(\.action) == [.stage])
        #expect(performed.map(\.paths) == [["a.swift"]])
        #expect(state.errorMessage == nil)
    }

    /// The reason the check reads status rather than `files`: a refresh publishes nothing
    /// when a newer one supersedes it, so the list on screen can still describe the world
    /// from before the write ahead of this one. Trusting it here would trash a file that
    /// is no longer untracked.
    @Test func aQueuedWriteIsDroppedEvenWhenTheEarlierRefreshWasSuperseded() async {
        let h = Harness()
        let state = h.makeState()
        let untracked = changedFile("u.txt", kind: .untracked)
        let staged = changedFile("u.txt", area: .staged, kind: .added)
        let repo = await h.adopt(state, "A", files: [untracked])
        let client = repo.client
        await client.set(filesAfterWrite: [staged])
        // Every status read from here on is held, so their order can be chosen by hand.
        await client.hold(true)
        let readsBefore = await client.statusCalls

        let first = Task { await state.perform(.stage, on: [untracked]) }
        let second = Task { await state.perform(.trash, on: [untracked]) }
        // (1) the stage's own validation read.
        #expect(await eventually { await client.statusCalls == readsBefore + 1 })
        await client.releaseFirst()
        // The stage runs, the repository becomes `[staged]`, and (2) its refresh read
        // waits.
        #expect(await eventually { await client.statusCalls == readsBefore + 2 })
        // A watcher refresh overtakes it: (3) waits behind (2) and owns the serial.
        h.watcherCallbacks[repo.root]?()
        #expect(await eventually { await client.statusCalls == readsBefore + 3 })
        await client.releaseFirst()
        await first.value
        // Ids only: the background line-stats task can attach counts to the same list at
        // any moment, and whether it has yet is not what this is about.
        #expect(state.files.map(\.id) == [untracked.id], "the superseded refresh must publish nothing")

        // Only now does the queued trash validate, with (4), which is the last one held.
        #expect(await eventually { await client.statusCalls == readsBefore + 4 })
        await client.releaseLast()
        await second.value

        #expect(await client.trashed.isEmpty, "u.txt is tracked now; the menu's trash is stale")
        let performed = await client.performed
        #expect(performed.map(\.action) == [.stage])
        #expect(performed.map(\.paths) == [["u.txt"]])

        await client.releaseFirst()
        #expect(await eventually { await state.files == [staged] })
    }

    /// The write's own refresh is not always the one that publishes its result: a watcher
    /// refresh can land while `git` is still running and clear the selection, because the
    /// row's id has gone. The restoration is recorded from what was selected before the
    /// write, so the reader still lands on the file they were reading.
    @Test func aRefreshDuringTheWriteStillMovesTheSelection() async {
        let h = Harness()
        let state = h.makeState()
        let staged = changedFile("a.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: [files[0], files[1]])
        let client = repo.client
        state.selection = [.file(files[0].id)]
        await client.holdActions(true)

        let write = Task { await state.perform(.stage, on: [files[0]]) }
        #expect(await eventually { await client.heldActionCount == 1 })
        let afterWatcher = [staged, files[1]]
        await client.set(files: afterWatcher)
        h.watcherCallbacks[repo.root]?()
        #expect(
            await eventually {
                guard await state.selectedFileID == nil else { return false }
                return await state.files == afterWatcher
            })
        await client.releaseActions()
        await write.value

        #expect(await eventually { await state.selectedFileID == staged.id })
        #expect(state.errorMessage == nil)
    }

    /// The same race, except the reader picked another row while `git` was running. That
    /// choice is newer than the write and is left alone.
    @Test func aSelectionMadeDuringTheWriteIsNotOverridden() async {
        let h = Harness()
        let state = h.makeState()
        let staged = changedFile("a.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: [files[0], files[1]])
        let client = repo.client
        state.selection = [.file(files[0].id)]
        await client.holdActions(true)

        let write = Task { await state.perform(.stage, on: [files[0]]) }
        #expect(await eventually { await client.heldActionCount == 1 })
        let afterWatcher = [staged, files[1]]
        await client.set(files: afterWatcher)
        h.watcherCallbacks[repo.root]?()
        #expect(
            await eventually {
                guard await state.selectedFileID == nil else { return false }
                return await state.files == afterWatcher
            })
        state.selection = [.file(files[1].id)]
        await client.releaseActions()
        await write.value

        #expect(await eventually { await h.published.last?.cause == .fileAction })
        #expect(state.selectedFileID == files[1].id)
    }

    // MARK: Batches

    /// One git process for the whole batch, and every row the reader was on is found
    /// again in the area it moved to.
    @Test func stagingTwoSelectedFilesWritesOnceAndKeepsBothSelected() async {
        let h = Harness()
        let state = h.makeState()
        let stagedA = changedFile("a.swift", area: .staged)
        let stagedB = changedFile("b.swift", area: .staged)
        let client = await adopt(h, state, after: [stagedA, stagedB, files[2]])
        state.selection = [.file(files[0].id), .file(files[1].id)]

        await state.perform(.stage, on: [files[0], files[1]])

        let performed = await client.performed
        #expect(performed.map(\.action) == [.stage])
        #expect(performed.map(\.paths) == [["a.swift", "b.swift"]])
        #expect(await eventually { await state.selection == [.file(stagedA.id), .file(stagedB.id)] })
        #expect(state.detailSelection == .files)
        #expect(state.errorMessage == nil)
    }

    /// Every selected path is gone, so the remembered index applies once, for the topmost
    /// row that was lost: the reader lands on whatever slid up into its place.
    @Test func discardingTwoSelectedRowsSelectsTheRowThatTookTheFirstPlace() async {
        let h = Harness()
        let state = h.makeState()
        let client = await adopt(h, state, after: [files[2]])
        state.selection = [.file(files[0].id), .file(files[1].id)]

        await state.perform(.discard, on: [files[0], files[1]])

        #expect(await client.performed.map(\.paths) == [["a.swift", "b.swift"]])
        #expect(await eventually { await state.selection == [.file(files[2].id)] })
        #expect(state.errorMessage == nil)
    }

    /// A row that came back with another kind means something else than the menu offered,
    /// so it leaves the batch while the rest of it runs. It stays selected: nothing was
    /// done to it.
    @Test func aRowWhoseKindChangedLeavesTheBatchAtTheFirstPass() async {
        let h = Harness()
        let state = h.makeState()
        let stagedA = changedFile("a.swift", area: .staged)
        let stagedB = changedFile("b.swift", area: .staged)
        let client = await adopt(h, state, after: [stagedA, stagedB, files[2]])
        let staleC = changedFile("c.swift", area: .staged, kind: .deleted)
        state.selection = [.file(files[0].id), .file(files[1].id), .file(files[2].id)]

        await state.perform(.stage, on: [files[0], files[1], staleC])

        #expect(await client.performed.map(\.paths) == [["a.swift", "b.swift"]])
        #expect(
            await eventually {
                await state.selection == [.file(stagedA.id), .file(stagedB.id), .file(files[2].id)]
            })
    }

    /// The same, one pass later: `files` still agrees with the menu, and the fresh status
    /// read the write validates against is what disagrees.
    @Test func aRowWhoseKindChangedLeavesTheBatchAtTheStatusPass() async {
        let h = Harness()
        let state = h.makeState()
        let stagedA = changedFile("a.swift", area: .staged)
        let stagedB = changedFile("b.swift", area: .staged)
        let client = await adopt(h, state, after: [stagedA, stagedB, files[2]])
        // What the write's own validation read will find: c is a deletion now.
        await client.set(files: [files[0], files[1], changedFile("c.swift", area: .staged, kind: .deleted)])
        state.selection = [.file(files[0].id), .file(files[1].id), .file(files[2].id)]

        await state.perform(.stage, on: [files[0], files[1], files[2]])

        #expect(await client.performed.map(\.paths) == [["a.swift", "b.swift"]])
        #expect(
            await eventually {
                await state.selection == [.file(stagedA.id), .file(stagedB.id), .file(files[2].id)]
            })
    }

    /// Narrowing the selection while git runs is the reader's own choice and outranks the
    /// write: nothing is restored. What they chose then prunes itself, because the row
    /// they left selected is the unstaged one the write has just removed.
    @Test func aDeselectionDuringTheWriteDropsTheRestoration() async {
        let h = Harness()
        let state = h.makeState()
        let stagedA = changedFile("a.swift", area: .staged)
        let stagedB = changedFile("b.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: [files[0], files[1]])
        let client = repo.client
        await client.set(filesAfterWrite: [stagedA, stagedB])
        state.selection = [.file(files[0].id), .file(files[1].id)]
        await client.holdActions(true)

        let write = Task { await state.perform(.stage, on: [files[0], files[1]]) }
        #expect(await eventually { await client.heldActionCount == 1 })
        state.selection = [.file(files[0].id)]
        await client.releaseActions()
        await write.value

        #expect(await eventually { await state.files == [stagedA, stagedB] })
        #expect(!state.selection.contains(.file(stagedA.id)), "the reader's newer choice wins")
        #expect(!state.selection.contains(.file(stagedB.id)))
        #expect(state.selection.isEmpty)
        #expect(state.selectedFiles.isEmpty)
    }

    /// The gap the revision also has to cover: the restoration is recorded, and only then
    /// does the reader clear the selection, while the write's own refresh is still reading
    /// status. The setter drops the pending restoration, so the empty selection stands.
    @Test func aSelectionClearedWhileTheRefreshWaitsIsNotUndone() async {
        let h = Harness()
        let state = h.makeState()
        await stageWithRefreshHeld(h, state) { $0.selection = [] }
        #expect(state.selection.isEmpty)
    }

    /// And the same for All changes, which is a choice rather than the absence of one.
    @Test func allChangesChosenWhileTheRefreshWaitsIsNotUndone() async {
        let h = Harness()
        let state = h.makeState()
        await stageWithRefreshHeld(h, state) { $0.selection = [.allChanges] }
        #expect(state.selection == [.allChanges])
    }

    /// Stages the selected row with every status read held, so `change` runs after the
    /// restoration was recorded and before the refresh that would have granted it.
    private func stageWithRefreshHeld(_ h: Harness, _ state: WindowState, change: (WindowState) -> Void) async {
        let staged = changedFile("a.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: [files[0], files[1]])
        let client = repo.client
        await client.set(filesAfterWrite: [staged, files[1]])
        state.selection = [.file(files[0].id)]
        await client.hold(true)
        let readsBefore = await client.statusCalls

        let write = Task { await state.perform(.stage, on: [files[0]]) }
        // (1) the write's own validation read.
        #expect(await eventually { await client.statusCalls == readsBefore + 1 })
        await client.releaseFirst()
        // The stage runs and (2) its refresh read waits.
        #expect(await eventually { await client.statusCalls == readsBefore + 2 })
        change(state)
        await client.releaseFirst()
        await write.value
        #expect(await eventually { await h.published.last?.cause == .fileAction })
    }

    /// git stops at the file it cannot handle and does not roll back the ones it
    /// finished, so the half-done list has to be published — with the failure still on
    /// screen, and still there after the next refresh.
    @Test func aPartlyDoneDiscardPublishesTheHalfDoneListAndKeepsItsError() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: [files[0], files[1]])
        let client = repo.client
        await client.fail(actions: true)
        await client.holdActions(true)

        let write = Task { await state.perform(.discard, on: [files[0], files[1]]) }
        #expect(await eventually { await client.heldActionCount == 1 })
        // b was restored, then git failed on a.
        await client.set(files: [files[0]])
        await client.releaseActions()
        await write.value

        #expect(await client.performed.map(\.paths) == [["a.swift", "b.swift"]])
        #expect(await eventually { await state.files == [files[0]] })
        #expect(state.errorMessage?.contains("index.lock exists") == true)
        #expect(h.published.last?.cause == .fileAction)

        h.watcherCallbacks[repo.root]?()
        #expect(await eventually { await h.published.last?.cause == .watcher })
        #expect(state.errorMessage?.contains("index.lock exists") == true, "an action's error outlives a refresh")
    }

    /// The failed write's own refresh can fail too, so the refresh's error is on screen
    /// when the batch's message replaces it. That message is an action's, not a refresh's,
    /// and still outlives the next successful refresh.
    @Test func aFailedBatchErrorSurvivesEvenWhenItsRefreshFailedFirst() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        let client = repo.client
        await client.fail(actions: true)
        await client.holdActions(true)

        let write = Task { await state.perform(.stage, on: [files[0], files[1]]) }
        // Held after the write's own validation read, which had to succeed to get here;
        // from now on the follow-up refresh's status read fails too.
        #expect(await eventually { await client.heldActionCount == 1 })
        await client.fail(true)
        await client.releaseActions()
        await write.value
        #expect(state.errorMessage?.contains("index.lock exists") == true)

        await client.fail(false)
        h.watcherCallbacks[repo.root]?()
        #expect(await eventually { await h.published.last?.cause == .watcher })
        #expect(
            state.errorMessage?.contains("index.lock exists") == true,
            "a refresh clears only the error a refresh raised")
    }

    /// The same for a trash loop, which can equally fail halfway down its list.
    @Test func aPartlyDoneTrashPublishesTheHalfDoneListAndKeepsItsError() async {
        let h = Harness()
        let state = h.makeState()
        let first = changedFile("u.txt", kind: .untracked)
        let second = changedFile("v.txt", kind: .untracked)
        let repo = await h.adopt(state, "A", files: [first, second])
        let client = repo.client
        await client.fail(actions: true)
        await client.holdActions(true)

        let write = Task { await state.perform(.trash, on: [first, second]) }
        #expect(await eventually { await client.heldActionCount == 1 })
        await client.set(files: [second])
        await client.releaseActions()
        await write.value

        #expect(await client.trashed == [["u.txt", "v.txt"]])
        // Ids only: an untracked file's line counts are read in the background and may or
        // may not have arrived, which is not what this is about.
        #expect(await eventually { await state.files.map(\.id) == [second.id] })
        #expect(state.errorMessage?.contains("could not move to Trash") == true)
        #expect(h.published.last?.cause == .fileAction)

        h.watcherCallbacks[repo.root]?()
        #expect(await eventually { await h.published.last?.cause == .watcher })
        #expect(state.errorMessage?.contains("could not move to Trash") == true)
    }

    /// Reveal, Open, and Copy Path speak about files on disk, and a path staged and
    /// edited is two rows but one file. Tested here rather than through the pasteboard,
    /// which is the user's and not the test's to clobber.
    @Test func harmlessActionsWorkOnUniquePaths() {
        let rows = [
            changedFile("a.swift"), changedFile("a.swift", area: .staged), changedFile("b.swift"),
        ]
        #expect(WindowState.uniquePaths(of: rows) == ["a.swift", "b.swift"])
        #expect(WindowState.uniquePaths(of: []).isEmpty)
    }

    // MARK: Renames

    private func rename(_ path: String, from original: String, area: ChangedFile.Area = .staged) -> ChangedFile {
        ChangedFile(path: path, originalPath: original, kind: .renamed, area: area, fingerprint: nil)
    }

    @Test func aRenameWritesItsOldPathThenItsNewOne() {
        #expect(WindowState.writePaths(of: [rename("b.swift", from: "a.swift")]) == ["a.swift", "b.swift"])
    }

    /// A copy's source is untouched by the copy and may have a row of its own.
    @Test func aCopyWritesOnlyItsOwnPath() {
        let copy = ChangedFile(
            path: "b.swift", originalPath: "a.swift", kind: .copied, area: .staged, fingerprint: nil)
        #expect(WindowState.writePaths(of: [copy]) == ["b.swift"])
    }

    @Test func writePathsDropsDuplicatesKeepingTheFirst() {
        let rows = [
            changedFile("a.swift", area: .staged), rename("b.swift", from: "a.swift"), changedFile("b.swift"),
        ]
        #expect(WindowState.writePaths(of: rows) == ["a.swift", "b.swift"])
    }

    @Test func unstagingARenamePassesBothPaths() async {
        let h = Harness()
        let state = h.makeState()
        let renamed = rename("b.swift", from: "a.swift")
        let repo = await h.adopt(state, "A", files: [renamed])
        await repo.client.set(filesAfterWrite: [])

        await state.perform(.unstage, on: [renamed])

        #expect(await repo.client.performed.map(\.paths) == [["a.swift", "b.swift"]])
    }

    /// The id is area and path only, so a rename from another source keeps it. Unstaging
    /// the stale row would pass the wrong old path.
    @Test func aRenameFromAnotherSourceIsNotWritten() async {
        let h = Harness()
        let state = h.makeState()
        let stale = rename("b.swift", from: "a.swift")
        let repo = await h.adopt(state, "A", files: [stale])
        await repo.client.set(files: [rename("b.swift", from: "c.swift")])

        await state.perform(.unstage, on: [stale])

        #expect(await repo.client.performed.isEmpty)
    }

    /// Against real git: unstaging only the new path would leave the old one's deletion
    /// staged.
    @Test func unstagingAGitMoveClearsTheIndex() async throws {
        let repo = try GitCommandTests.Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try await repo.git(["mv", "a.txt", "b.txt"])

        let h = Harness()
        let state = h.makeState()
        let before = h.published.count
        #expect(state.adopt(root: RepositoryRoot(path: repo.url.path), client: repo.client))
        #expect(await eventually { await h.published.count > before })
        let renamed = try #require(state.files.first { $0.kind == .renamed })

        await state.perform(.unstage, on: [renamed])

        #expect(try await repo.git(["diff", "--cached", "--name-only"]).isEmpty)
        #expect(state.errorMessage == nil)
    }

    /// A plain `mv` pairs into an unstaged rename whose old path is gone from disk and
    /// whose new path is untracked; staging it must record both halves.
    @Test func stagingAPairedMoveStagesTheRename() async throws {
        let repo = try GitCommandTests.Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try FileManager.default.moveItem(
            at: repo.url.appendingPathComponent("a.txt"), to: repo.url.appendingPathComponent("b.txt"))

        let h = Harness()
        let state = h.makeState()
        let before = h.published.count
        #expect(state.adopt(root: RepositoryRoot(path: repo.url.path), client: repo.client))
        #expect(await eventually { await h.published.count > before })
        let paired = try #require(state.files.first { $0.kind == .renamed && $0.area == .unstaged })

        await state.perform(.stage, on: [paired])

        #expect(state.errorMessage == nil)
        let files = try await repo.client.status()
        #expect(files.map(\.kind) == [.renamed])
        #expect(files.first?.area == .staged)
        #expect(files.first?.originalPath == "a.txt")
    }

    @Test func anEmptyBatchPerformsNothingAndPublishesNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        let publishes = h.published.count

        await state.perform(.stage, on: [])

        #expect(await repo.client.performed.isEmpty)
        #expect(h.published.count == publishes)
    }
}
