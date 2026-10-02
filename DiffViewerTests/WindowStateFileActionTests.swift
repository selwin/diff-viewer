import Foundation
import Testing

@testable import DiffViewer

/// A rename row. At file scope, so a test table's arguments can build one.
private func rename(_ path: String, from original: String, area: ChangedFile.Area = .staged) -> ChangedFile {
    ChangedFile(path: path, originalPath: original, kind: .renamed, area: area, fingerprint: nil)
}

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

    /// The reader works down Changes: the staged file lands in the tray unselected, and the
    /// file below it takes its place.
    @Test func stagingTheSelectedFileSelectsTheNextUnstagedFile() async {
        let h = Harness()
        let state = h.makeState()
        let staged = changedFile("a.swift", area: .staged)
        let client = await adopt(h, state, after: [staged, files[1], files[2]])
        state.selection = [.file(files[0].id)]

        await state.perform(.stage, on: [files[0]])

        let performed = await client.performed
        #expect(performed.map(\.action) == [.stage])
        #expect(performed.map(\.paths) == [["a.swift"]])
        #expect(await eventually { await state.selection == [.file(files[1].id)] })
        #expect(!state.selection.contains(.file(staged.id)))
        #expect(h.published.last?.cause == .fileAction)
        #expect(state.errorMessage == nil)
    }

    /// The next row is the next one the sidebar draws: a plain path sort would put
    /// `a/b/c.swift` between `a/b.swift` and `a/z.swift`, but directory order keeps `a` together.
    @Test func stagingSelectsTheNextRowInDirectoryOrder() async {
        let h = Harness()
        let state = h.makeState()
        let rows = [changedFile("a/b.swift"), changedFile("a/b/c.swift"), changedFile("a/z.swift")]
        let repo = await h.adopt(state, "A", files: rows)
        await repo.client.set(filesAfterWrite: [changedFile("a/b.swift", area: .staged), rows[1], rows[2]])
        #expect(state.sidebarRows.map(\.id) == ["unstaged:a/b.swift", "unstaged:a/z.swift", "unstaged:a/b/c.swift"])
        state.selection = [.file(rows[0].id)]

        await state.perform(.stage, on: [rows[0]])

        #expect(await eventually { await state.selection == [.file("unstaged:a/z.swift")] })
    }

    /// Unstaging backs out of the tray rather than working down it.
    @Test func unstagingTheSelectedFileClearsTheSelection() async {
        let h = Harness()
        let state = h.makeState()
        let stagedD = changedFile("d.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: [files[0], files[2], stagedD])
        await repo.client.set(filesAfterWrite: [files[0], changedFile("c.swift"), stagedD])
        state.selection = [.file(files[2].id)]

        await state.perform(.unstage, on: [files[2]])

        #expect(await eventually { await state.selection.isEmpty })
    }

    /// The reader lands below the last staged row, wherever the others were.
    @Test func stagingSeveralRowsSelectsTheRowBelowTheLast() async {
        let h = Harness()
        let state = h.makeState()
        let rows = ["1", "2", "3", "4", "5"].map { changedFile("\($0).swift") }
        let repo = await h.adopt(state, "A", files: rows)
        let staged = [changedFile("1.swift", area: .staged), changedFile("3.swift", area: .staged)]
        await repo.client.set(filesAfterWrite: [rows[1], rows[3], rows[4]] + staged)
        state.selection = [.file(rows[0].id), .file(rows[2].id)]

        await state.perform(.stage, on: [rows[0], rows[2]])

        #expect(await eventually { await state.selection == [.file(rows[3].id)] })
    }

    @Test func stagingTheLastRowSelectsTheNewLast() async {
        let h = Harness()
        let state = h.makeState()
        let client = await adopt(h, state, after: [files[0], changedFile("b.swift", area: .staged), files[2]])
        state.selection = [.file(files[1].id)]

        await state.perform(.stage, on: [files[1]])

        #expect(await eventually { await state.selection == [.file(files[0].id)] })
        #expect(await client.performed.map(\.paths) == [["b.swift"]])
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
        #expect(state.files == inPublishedFileOrder(files))
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
        await client.hold(.actions)

        let first = Task { await state.perform(.stage, on: [files[0]]) }
        #expect(await eventually { await client.heldCount(.actions) == 1 })
        let second = Task { await state.perform(.discard, on: [files[1]]) }
        // Let the second write reach the queue, where it waits on the first.
        for _ in 0..<10 { await Task.yield() }
        // What the second write's status read will find: b is a deletion now, so the
        // queued discard no longer means what the menu offered.
        await client.set(files: [files[0], changedFile("b.swift", kind: .deleted), files[2]])
        await client.hold(.actions, false)
        await client.release(.actions)
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
        await client.hold(.status)
        let readsBefore = await client.statusCalls

        let first = Task { await state.perform(.stage, on: [untracked]) }
        let second = Task { await state.perform(.trash, on: [untracked]) }
        // (1) the stage's own validation read.
        #expect(await eventually { await client.statusCalls == readsBefore + 1 })
        await client.releaseFirst(.status)
        // The stage runs, the repository becomes `[staged]`, and (2) its refresh read
        // waits.
        #expect(await eventually { await client.statusCalls == readsBefore + 2 })
        // A watcher refresh overtakes it: (3) waits behind (2) and owns the serial.
        h.watcherCallbacks[repo.root]?()
        #expect(await eventually { await client.statusCalls == readsBefore + 3 })
        await client.releaseFirst(.status)
        await first.value
        // Ids only: the background line-stats task can attach counts to the same list at
        // any moment, and whether it has yet is not what this is about.
        #expect(state.files.map(\.id) == [untracked.id], "the superseded refresh must publish nothing")

        // Only now does the queued trash validate, with (4), which is the last one held.
        #expect(await eventually { await client.statusCalls == readsBefore + 4 })
        await client.releaseLast(.status)
        await second.value

        #expect(await client.trashed.isEmpty, "u.txt is tracked now; the menu's trash is stale")
        let performed = await client.performed
        #expect(performed.map(\.action) == [.stage])
        #expect(performed.map(\.paths) == [["u.txt"]])

        await client.releaseFirst(.status)
        #expect(await eventually { await state.files == [staged] })
    }

    /// The write's own refresh is not always the one that publishes its result: a watcher
    /// refresh can land while `git` is still running and clear the selection, because the
    /// row's id has gone. The restoration is recorded from what was selected before the
    /// write, so the reader still moves on to the next file.
    @Test func aRefreshDuringTheWriteStillSelectsTheNextFile() async {
        let h = Harness()
        let state = h.makeState()
        let staged = changedFile("a.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: [files[0], files[1]])
        let client = repo.client
        state.selection = [.file(files[0].id)]
        await client.hold(.actions)

        let write = Task { await state.perform(.stage, on: [files[0]]) }
        #expect(await eventually { await client.heldCount(.actions) == 1 })
        let afterWatcher = [staged, files[1]]
        await client.set(files: afterWatcher)
        h.watcherCallbacks[repo.root]?()
        #expect(
            await eventually {
                guard await state.selectedFileID == nil else { return false }
                return await state.files == afterWatcher
            })
        await client.release(.actions)
        await write.value

        #expect(await eventually { await state.selectedFileID == files[1].id })
        #expect(state.errorMessage == nil)
    }

    /// The same race, except the reader chose something while `git` was running: nothing,
    /// or All changes, which is a choice rather than the absence of one. That choice is
    /// newer than the write, so the next file is not selected for them.
    @Test(arguments: [Set<DiffSelection>(), [.allChanges]])
    func aSelectionChangedDuringTheWriteIsLeftAlone(_ chosen: Set<DiffSelection>) async {
        let h = Harness()
        let state = h.makeState()
        let staged = changedFile("a.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: [files[0], files[1]])
        let client = repo.client
        state.selection = [.file(files[0].id)]
        await client.hold(.actions)

        let write = Task { await state.perform(.stage, on: [files[0]]) }
        #expect(await eventually { await client.heldCount(.actions) == 1 })
        let afterWatcher = [staged, files[1]]
        await client.set(files: afterWatcher)
        h.watcherCallbacks[repo.root]?()
        #expect(
            await eventually {
                guard await state.selectedFileID == nil else { return false }
                return await state.files == afterWatcher
            })
        state.selection = chosen
        await client.release(.actions)
        await write.value

        #expect(await eventually { await h.published.last?.cause == .fileAction })
        #expect(state.selection == chosen)
    }

    // MARK: Batches

    /// One git process for the whole batch. Changes is empty afterwards, so there is no
    /// next file to move on to.
    @Test func stagingEveryUnstagedFileWritesOnceAndEmptiesTheSelection() async {
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
        #expect(await eventually { await state.files.map(\.id) == [stagedA.id, stagedB.id, files[2].id] })
        #expect(state.selection.isEmpty)
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
    /// so it leaves the batch while the rest of it runs. It stays selected, since nothing
    /// was done to it; the row that was staged does not.
    @Test func aRowWhoseKindChangedLeavesTheBatchAtTheFirstPass() async {
        let h = Harness()
        let state = h.makeState()
        let stagedA = changedFile("a.swift", area: .staged)
        let client = await adopt(h, state, after: [stagedA, files[1], files[2]])
        let staleB = changedFile("b.swift", kind: .deleted)
        state.selection = [.file(files[0].id), .file(files[1].id)]

        await state.perform(.stage, on: [files[0], staleB])

        #expect(await client.performed.map(\.paths) == [["a.swift"]])
        #expect(await eventually { await state.selection == [.file(files[1].id)] })
    }

    /// The same, one pass later: `files` still agrees with the menu, and the fresh status
    /// read the write validates against is what disagrees.
    @Test func aRowWhoseKindChangedLeavesTheBatchAtTheStatusPass() async {
        let h = Harness()
        let state = h.makeState()
        let stagedA = changedFile("a.swift", area: .staged)
        let client = await adopt(h, state, after: [stagedA, files[1], files[2]])
        // What the write's own validation read will find: b is a deletion now.
        await client.set(files: [files[0], changedFile("b.swift", kind: .deleted), files[2]])
        state.selection = [.file(files[0].id), .file(files[1].id)]

        await state.perform(.stage, on: [files[0], files[1]])

        #expect(await client.performed.map(\.paths) == [["a.swift"]])
        #expect(await eventually { await state.selection == [.file(files[1].id)] })
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
        await client.hold(.actions)

        let write = Task { await state.perform(.stage, on: [files[0], files[1]]) }
        #expect(await eventually { await client.heldCount(.actions) == 1 })
        state.selection = [.file(files[0].id)]
        await client.release(.actions)
        await write.value

        #expect(await eventually { await state.files == [stagedA, stagedB] })
        #expect(!state.selection.contains(.file(stagedA.id)), "the reader's newer choice wins")
        #expect(!state.selection.contains(.file(stagedB.id)))
        #expect(state.selection.isEmpty)
        #expect(state.selectedFiles.isEmpty)
    }

    /// The gap the revision also has to cover: the restoration is recorded, and only then
    /// does the reader choose, while the write's own refresh is still reading status. The
    /// setter drops the pending restoration, so their choice stands.
    @Test(arguments: [Set<DiffSelection>(), [.allChanges]])
    func aSelectionChosenWhileTheRefreshWaitsIsNotUndone(_ chosen: Set<DiffSelection>) async {
        let h = Harness()
        let state = h.makeState()
        let staged = changedFile("a.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: [files[0], files[1]])
        let client = repo.client
        await client.set(filesAfterWrite: [staged, files[1]])
        state.selection = [.file(files[0].id)]
        await client.hold(.status)
        let readsBefore = await client.statusCalls

        let write = Task { await state.perform(.stage, on: [files[0]]) }
        // (1) the write's own validation read.
        #expect(await eventually { await client.statusCalls == readsBefore + 1 })
        await client.releaseFirst(.status)
        // The stage runs and (2) its refresh read waits.
        #expect(await eventually { await client.statusCalls == readsBefore + 2 })
        state.selection = chosen
        await client.releaseFirst(.status)
        await write.value
        #expect(await eventually { await h.published.last?.cause == .fileAction })
        #expect(state.selection == chosen)
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
        await client.hold(.actions)

        let write = Task { await state.perform(.discard, on: [files[0], files[1]]) }
        #expect(await eventually { await client.heldCount(.actions) == 1 })
        // b was restored, then git failed on a.
        await client.set(files: [files[0]])
        await client.release(.actions)
        await write.value

        #expect(await client.performed.map(\.paths) == [["a.swift", "b.swift"]])
        #expect(await eventually { await state.files == [files[0]] })
        #expect(state.errorMessage?.contains("index.lock exists") == true)
        #expect(h.published.last?.cause == .fileAction)

        h.watcherCallbacks[repo.root]?()
        #expect(await eventually { await h.published.last?.cause == .watcher })
        #expect(state.errorMessage?.contains("index.lock exists") == true, "an action's error outlives a refresh")
    }

    /// A partly done discard can leave one selected file with only its staged row and the
    /// other with only its unstaged one. Path restoration finds both, but a selection keeps
    /// to one list, so the first in sidebar order wins and the capsule still has an action.
    @Test func aPartlyDoneDiscardRestoresRowsFromOneListOnly() async {
        let h = Harness()
        let state = h.makeState()
        let stagedA = changedFile("a.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: [files[0], files[1], stagedA])
        let client = repo.client
        await client.fail(actions: true)
        await client.hold(.actions)
        state.selection = [.file(files[0].id), .file(files[1].id)]

        let write = Task { await state.perform(.discard, on: [files[0], files[1]]) }
        #expect(await eventually { await client.heldCount(.actions) == 1 })
        // a's worktree edit was discarded, leaving its staged row, then git failed on b.
        await client.set(files: [files[1], stagedA])
        await client.release(.actions)
        await write.value

        #expect(await eventually { await Set(state.files.map(\.id)) == [files[1].id, stagedA.id] })
        #expect(state.selection == [.file(files[1].id)])
        #expect(state.stagingCapsule?.action == .stage)
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
        await client.hold(.actions)

        let write = Task { await state.perform(.stage, on: [files[0], files[1]]) }
        // Held after the write's own validation read, which had to succeed to get here;
        // from now on the follow-up refresh's status read fails too.
        #expect(await eventually { await client.heldCount(.actions) == 1 })
        await client.fail(true)
        await client.release(.actions)
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
        await client.hold(.actions)

        let write = Task { await state.perform(.trash, on: [first, second]) }
        #expect(await eventually { await client.heldCount(.actions) == 1 })
        await client.set(files: [second])
        await client.release(.actions)
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

    struct WritePathsCase: CustomTestStringConvertible {
        let name: String
        let rows: [ChangedFile]
        let expected: [String]

        var testDescription: String { name }
    }

    /// The paths a stage or unstage hands to git for each row.
    @Test(arguments: [
        WritePathsCase(
            name: "a rename writes its old path, then its new one", rows: [rename("b.swift", from: "a.swift")],
            expected: ["a.swift", "b.swift"]),
        // A copy's source is untouched by the copy and may have a row of its own.
        WritePathsCase(
            name: "a copy writes only its own path",
            rows: [
                ChangedFile(path: "b.swift", originalPath: "a.swift", kind: .copied, area: .staged, fingerprint: nil)
            ],
            expected: ["b.swift"]),
        WritePathsCase(
            name: "duplicates are dropped, keeping the first",
            rows: [changedFile("a.swift", area: .staged), rename("b.swift", from: "a.swift"), changedFile("b.swift")],
            expected: ["a.swift", "b.swift"]),
    ])
    func writePathsFollowTheRowKind(_ testCase: WritePathsCase) {
        #expect(WindowState.writePaths(of: testCase.rows) == testCase.expected)
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

    // MARK: Stage All

    /// Stage All hands `stageableUnstagedFiles` to `perform`: the conflict is not one of them,
    /// so it stays in Changes rather than being marked resolved.
    @Test func stagingTheStageableFilesLeavesConflictsAndStagedRowsAlone() async {
        let h = Harness()
        let state = h.makeState()
        let conflict = changedFile("conflict.swift", kind: .unmerged)
        let staged = changedFile("s.swift", area: .staged)
        let stagedA = changedFile("a.swift", area: .staged)
        let stagedB = changedFile("b.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: [files[0], files[1], conflict, staged])
        await repo.client.set(filesAfterWrite: [stagedA, stagedB, conflict, staged])
        #expect(state.selectedFiles.isEmpty, "no row is selected, only All changes")

        await state.perform(.stage, on: state.stageableUnstagedFiles)

        #expect(await repo.client.performed.map(\.paths) == [["a.swift", "b.swift"]])
        #expect(await eventually { await state.unstagedFiles.map(\.id) == [conflict.id] })
    }

    @Test func stageAllIsUnavailableWithOnlyConflictsOrNothingUnstaged() async {
        let h = Harness()
        let state = h.makeState()
        _ = await h.adopt(state, "A", files: [changedFile("x.swift", kind: .unmerged), files[2]])

        #expect(state.stageableUnstagedFiles.isEmpty)
        #expect(!state.canStageAll)
    }

    @Test func stageAllIsUnavailableWhileAConfirmationIsUp() async {
        let h = Harness()
        let state = h.makeState()
        _ = await h.adopt(state, "A", files: files)
        #expect(state.canStageAll, "ordinary unstaged rows")

        state.isConfirmingFileAction = true

        #expect(!state.canStageAll)
    }

    /// The commit list's files replace Changes, so this also holds for an empty list; the
    /// scope check is what keeps it false once a commit's rows are on screen.
    @Test func stageAllIsUnavailableInCommitScope() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let repo = h.repo("A", files: files)
        await repo.client.set(head: commit.ref.sha)
        await repo.client.set(commits: [commit])
        await repo.client.set(
            files: [ChangedFile(path: "p.swift", originalPath: nil, kind: .modified, area: .commit(commit.ref))],
            forCommit: commit.ref.sha)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await !state.history.commits.isEmpty })

        state.select(commit: commit)
        #expect(await eventually { await state.files.map(\.path) == ["p.swift"] })

        #expect(!state.canStageAll)
    }

    @Test func stageAllIsUnavailableWhileABranchSwitchRuns() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        let client = repo.client
        await client.hold(.switchBranch)

        let task = Task { await state.switchBranch(to: "side") }
        #expect(await eventually { await client.heldCount(.switchBranch) == 1 })

        #expect(state.isSwitchingBranch)
        #expect(!state.canStageAll)

        await client.hold(.switchBranch, false)
        await client.release(.switchBranch)
        await task.value
    }

    /// The commit is queued behind a held stage, which is the only way to see it in flight.
    @Test func stageAllIsUnavailableWhileACommitRuns() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        let client = repo.client
        state.commitMessage = "Add the picker"
        await client.hold(.actions)
        let stage = Task { await state.perform(.stage, on: [files[0]]) }
        #expect(await eventually { await client.heldCount(.actions) == 1 })

        let commit = Task { await state.commit() }
        #expect(await eventually { await state.isCommitting })

        #expect(!state.canStageAll)

        await client.hold(.actions, false)
        await client.release(.actions)
        await stage.value
        await commit.value
    }
}
