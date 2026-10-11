import Foundation
import Testing

@testable import DiffViewer

/// How a window reads and publishes the stash list, and what choosing a stash does.
@MainActor
struct WindowStateStashTests {
    private func stash(_ index: Int, _ message: String, untracked: Bool = false) -> StashEntry {
        StashEntry(
            stashIndex: index, sha: objectID("stash\(index)\(message)"), shortSha: "s\(index)",
            parents: [objectID("base"), objectID("index\(index)")] + (untracked ? [objectID("untracked\(index)")] : []),
            committedAt: Date(timeIntervalSince1970: 1_789_300_000), author: "Tester", message: message,
            sourceBranch: "main", hasDefaultMessage: false, churn: .init(additions: 1, deletions: 0))
    }

    /// Adopts a repository whose first stash read returns `stashes`, and waits for it and
    /// the working tree's churn.
    private func adopt(
        _ h: Harness, _ state: WindowState, stashes: [StashEntry], files: [ChangedFile] = [changedFile("a.swift")]
    ) async throws -> Window {
        let repo = await h.adopt(state, "A", files: files) { await $0.set(stashes: stashes) }
        try #require(await eventually { await state.stashList.readStatus == .loaded })
        try #require(await eventually { await state.workingTreeChurn != nil })
        return (h, state, repo.client, repo.root)
    }

    @Test func aRefsTickRereadsTheStashes() async throws {
        let h = Harness()
        let state = h.makeState()
        let w = try await adopt(h, state, stashes: [stash(0, "first")])
        #expect(state.stashList.entries.map(\.message) == ["first"])

        await w.client.set(stashes: [stash(0, "second"), stash(1, "first")])
        h.tick(w.root, [.refs])

        #expect(await eventually { await state.stashList.entries.map(\.message) == ["second", "first"] })
    }

    /// The newest request wins, whether the older read finishes with a list or an error.
    @Test(arguments: [false, true])
    func anOlderReadNeverOverwritesANewerOne(olderFails: Bool) async throws {
        let h = Harness()
        let state = h.makeState()
        let w = try await adopt(h, state, stashes: [])
        await w.client.set(stashes: [stash(0, "old")])
        await w.client.fail(stashes: olderFails)
        await w.client.hold(.stashes)
        h.tick(w.root, [.refs])
        try #require(await eventually { await w.client.heldCount(.stashes) == 1 })
        let older = try #require(state.session?.stashTask)

        await w.client.set(stashes: [stash(0, "new")])
        await w.client.fail(stashes: false)
        h.tick(w.root, [.refs])
        try #require(await eventually { await w.client.heldCount(.stashes) == 2 })
        await w.client.releaseLast(.stashes)
        try #require(await eventually { await state.stashList.entries.map(\.message) == ["new"] })

        await w.client.release(.stashes)
        await older.value

        #expect(state.stashList.entries.map(\.message) == ["new"])
        #expect(state.stashList.readStatus == .loaded)
    }

    @Test func aClosedWindowPublishesNoStashes() async throws {
        let h = Harness()
        let state = h.makeState()
        let w = try await adopt(h, state, stashes: [stash(0, "kept")])
        await w.client.set(stashes: [stash(0, "late")])
        await w.client.hold(.stashes)
        h.tick(w.root, [.refs])
        try #require(await eventually { await w.client.heldCount(.stashes) == 1 })
        let read = try #require(state.session?.stashTask)

        state.close()
        await w.client.release(.stashes)
        await read.value

        #expect(state.stashList.entries.map(\.message) == ["kept"])
    }

    @Test func aFailedReadKeepsTheLastListAndMarksItFailed() async throws {
        let h = Harness()
        let state = h.makeState()
        let w = try await adopt(h, state, stashes: [stash(0, "kept")])

        await w.client.fail(stashes: true)
        h.tick(w.root, [.refs])

        #expect(await eventually { await state.stashList.readStatus == .failed })
        #expect(state.stashList.entries.map(\.message) == ["kept"])
    }

    @Test func choosingAStashShowsItAsACommitAndClosesThePicker() async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "picked")
        _ = try await adopt(h, state, stashes: [entry])
        state.isStashPickerPresented = true

        state.selectStash(entry)

        #expect(!state.isStashPickerPresented)
        guard case let .commit(ref) = state.scope else {
            Issue.record("expected a commit scope, got \(state.scope)")
            return
        }
        #expect(ref.sha == entry.sha)
        #expect(ref.firstParentSHA == objectID("base"))
    }

    /// A stash's untracked files are an area of their own, and their lines are counted too.
    @Test func choosingAStashCountsItsUntrackedFiles() async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "both", untracked: true)
        let ref = entry.commitSummary.ref
        let untracked = try #require(ref.untrackedCommit)
        let w = try await adopt(h, state, stashes: [entry])
        await w.client.set(
            files: [
                ChangedFile(path: "a.swift", originalPath: nil, kind: .modified, area: .commit(ref)),
                ChangedFile(path: "new.swift", originalPath: nil, kind: .added, area: .commit(untracked)),
            ], forCommit: entry.sha)
        await w.client.set(
            numstat: [NumstatEntry(path: "a.swift", stats: .counted(added: 1, deleted: 1))], area: .commit(ref))
        await w.client.set(
            numstat: [NumstatEntry(path: "new.swift", stats: .counted(added: 3, deleted: 0))],
            area: .commit(untracked))

        state.selectStash(entry)

        let expected: [String: LineStats?] = [
            "a.swift": .counted(added: 1, deleted: 1), "new.swift": .counted(added: 3, deleted: 0),
        ]
        #expect(
            await eventually {
                await Dictionary(uniqueKeysWithValues: state.files.map { ($0.path, $0.lineStats) }) == expected
            })
    }

    /// The stash and the history row of one commit are different scopes: switching either
    /// way loads the other's list, adding or dropping the untracked files.
    @Test func theStashAndTheHistoryViewOfItsCommitAreDifferentScopes() async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "both", untracked: true)
        let stashRef = entry.commitSummary.ref
        let untracked = try #require(stashRef.untrackedCommit)
        let plain = CommitSummary(
            sha: entry.sha, shortSha: entry.shortSha, parents: entry.parents, subject: entry.message,
            committedAt: entry.committedAt, author: entry.author)
        let w = try await adopt(h, state, stashes: [entry])
        await w.client.set(
            files: [ChangedFile(path: "a.swift", originalPath: nil, kind: .modified, area: .commit(stashRef))],
            forCommit: entry.sha)
        await w.client.set(
            files: [ChangedFile(path: "new.swift", originalPath: nil, kind: .added, area: .commit(untracked))],
            forCommit: untracked.sha)

        state.select(commit: plain)
        #expect(await eventually { await state.files.map(\.path) == ["a.swift"] })
        state.selectStash(entry)
        #expect(await eventually { await state.files.map(\.path) == ["a.swift", "new.swift"] })
        state.select(commit: plain)
        #expect(await eventually { await state.files.map(\.path) == ["a.swift"] })
        let picker = StashPickerState(snapshot: state.stashPickerSnapshot, grouping: CommitDayGrouping())
        #expect(picker.rows.map(\.isDisplayed) == [false], "the history view does not tick the stash")
    }

    /// Choosing a summary of the shown commit refreshes its label, such as a longer abbreviation.
    @Test func choosingTheShownStashAgainTakesItsFreshSummary() async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "same")
        let longer = StashEntry(
            stashIndex: 0, sha: entry.sha, shortSha: entry.shortSha + "a", parents: entry.parents,
            committedAt: entry.committedAt, author: entry.author, message: entry.message, sourceBranch: nil,
            hasDefaultMessage: false, churn: entry.churn)
        _ = try await adopt(h, state, stashes: [entry])
        state.selectStash(entry)

        state.selectStash(longer)

        #expect(state.selectedCommit?.ref.shortSha == longer.shortSha)
    }

    /// Two stashes can share a commit; choosing the other one relabels the scope.
    @Test func choosingADuplicateStashShowsItsOwnMessage() async throws {
        let h = Harness()
        let state = h.makeState()
        let first = stash(0, "first")
        let second = StashEntry(
            stashIndex: 1, sha: first.sha, shortSha: first.shortSha, parents: first.parents,
            committedAt: first.committedAt, author: first.author, message: "second", sourceBranch: nil,
            hasDefaultMessage: false, churn: first.churn)
        _ = try await adopt(h, state, stashes: [first, second])
        state.selectStash(first)

        state.selectStash(second)

        #expect(state.scopeDisplayTitle == "second")
    }

    // MARK: Pop and drop

    /// Waits for the list `selectStash` asked for, so a later refresh is the action's own.
    private func show(_ entry: StashEntry, in state: WindowState) async throws {
        state.selectStash(entry)
        try #require(await eventually { await !state.isLoadingScope })
    }

    @Test(arguments: StashAction.allCases)
    func actingOnTheDisplayedStashLeavesForTheWorkingTree(_ action: StashAction) async throws {
        let h = Harness()
        let state = h.makeState()
        let shown = stash(0, "shown")
        let other = stash(1, "other")
        _ = try await adopt(h, state, stashes: [shown, other])
        try await show(shown, in: state)

        await action.run(other, in: state)
        #expect(state.scope == .commit(shown.commitSummary.ref))

        await action.run(shown, in: state)
        #expect(state.scope == .workingTree)
    }

    /// A pop failure whose changes still reached the working tree.
    struct AppliedFailure: CustomTestStringConvertible, Sendable {
        let error: StashError
        let filesAfter: [ChangedFile]
        var testDescription: String { "\(error.kind)" }
    }

    nonisolated static let appliedFailures = [
        AppliedFailure(error: .conflicts, filesAfter: [changedFile("a.swift", kind: .unmerged)]),
        AppliedFailure(
            error: .appliedButNotDropped(underlying: StashError.staleEntry),
            filesAfter: [changedFile("a.swift"), changedFile("popped.swift")]),
    ]

    @Test(arguments: appliedFailures, [false, true])
    func aPopThatAppliedChangesShowsThemInTheWorkingTree(
        _ failure: AppliedFailure, startsInCommitScope: Bool
    ) async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "popped")
        let w = try await adopt(h, state, stashes: [entry])
        if startsInCommitScope { try await show(entry, in: state) }
        await w.client.fail(stashActionsWith: failure.error)
        await w.client.set(filesAfterPop: failure.filesAfter)

        await state.popStash(entry)

        #expect(state.scope == .workingTree)
        let expected = failure.filesAfter.map { "\($0.kind.rawValue) \($0.path)" }
        #expect(await eventually { await state.files.map { "\($0.kind.rawValue) \($0.path)" } == expected })
        #expect(state.errorMessage == failure.error.localizedDescription)
    }

    /// Git refused, so the scope stays; the working tree is re-read all the same.
    @Test(arguments: [false, true])
    func anyOtherPopFailureKeepsTheScope(startsInCommitScope: Bool) async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "kept")
        let w = try await adopt(h, state, stashes: [entry])
        if startsInCommitScope { try await show(entry, in: state) }
        let scope = state.scope
        let error = ProcessError.failed(command: "git stash apply", status: 1, stderr: "would be overwritten")
        await w.client.fail(stashActionsWith: error)
        await w.client.set(filesAfterPop: [changedFile("a.swift"), changedFile("b.swift")])

        await state.popStash(entry)

        #expect(state.scope == scope)
        if startsInCommitScope {
            #expect(await eventually { await state.workingTreeChurn?.changedFileCount == 2 })
        } else {
            #expect(state.files.map(\.path) == ["a.swift", "b.swift"])
        }
        #expect(state.errorMessage == error.localizedDescription)
    }

    /// What holds the window's writes while a stash action is asked for.
    enum Blocker: CaseIterable, Sendable {
        case committing
        case switchingBranch
    }

    /// A running `blocker`, held in git until `finish`.
    struct RunningBlocker {
        let client: StubRepoClient
        let held: StubCall
        let task: Task<Void, Never>

        func finish() async {
            await client.hold(held, false)
            await client.release(held)
            await task.value
        }
    }

    /// Starts `blocker` in a window with a staged file to commit, and waits until git holds it.
    private func start(_ blocker: Blocker, in state: WindowState, client: StubRepoClient) async throws
        -> RunningBlocker
    {
        let held: StubCall
        let task: Task<Void, Never>
        switch blocker {
        case .committing:
            held = .actions
            state.commitMessage = "Commit"
            await client.hold(held)
            task = Task { await state.commit() }
        case .switchingBranch:
            held = .switchBranch
            await client.hold(held)
            task = Task { await state.switchBranch(to: "side") }
        }
        try #require(await eventually { await client.heldCount(held) == 1 })
        return RunningBlocker(client: client, held: held, task: task)
    }

    @Test(arguments: Blocker.allCases, StashAction.allCases)
    func stashActionsWaitForNoCommitOrBranchSwitch(_ blocker: Blocker, _ action: StashAction) async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "blocked")
        let repo = await h.adopt(state, "A", files: [changedFile("a.swift", area: .staged)]) {
            await $0.set(stashes: [entry])
        }
        let running = try await start(blocker, in: state, client: repo.client)
        #expect(state.stashPickerSnapshot.actionsBlockedReason != nil)

        await action.run(entry, in: state)

        #expect(state.activeStashOperation == nil)
        await running.finish()
        #expect(await repo.client.popCalls.isEmpty)
        #expect(await repo.client.dropCalls.isEmpty)
    }

    @Test(arguments: StashAction.allCases)
    func anActionQueuedWhenTheWindowClosesNeverRuns(_ action: StashAction) async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "queued")
        let w = try await adopt(h, state, stashes: [entry])
        await w.client.hold(.actions)
        let stage = Task { await state.perform(.stage, on: [changedFile("a.swift")]) }
        try #require(await eventually { await w.client.heldCount(.actions) == 1 })
        let queued = Task { await action.run(entry, in: state) }
        try #require(await eventually { await state.activeStashOperation != nil })

        state.close()
        await w.client.hold(.actions, false)
        await w.client.release(.actions)
        await stage.value
        await queued.value

        #expect(await w.client.popCalls.isEmpty)
        #expect(await w.client.dropCalls.isEmpty)
        #expect(state.activeStashOperation == nil)
    }

    @Test(arguments: StashAction.allCases)
    func aFailedActionLetsTheNextOneRun(_ action: StashAction) async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "retried")
        let w = try await adopt(h, state, stashes: [entry])
        await w.client.fail(
            stashActionsWith: ProcessError.failed(command: "git stash", status: 1, stderr: "refused"))

        await action.run(entry, in: state)
        #expect(state.activeStashOperation == nil)
        #expect(state.stashList.entries == [entry])

        await w.client.fail(stashActionsWith: nil)
        await action.run(entry, in: state)
        #expect(state.stashList.entries.isEmpty)
    }

    @Test func aSecondActionWhileOneRunsIsRefused() async throws {
        let h = Harness()
        let state = h.makeState()
        let first = stash(0, "first")
        let second = stash(1, "second")
        let w = try await adopt(h, state, stashes: [first, second])
        await w.client.hold(.stashActions)
        let running = Task { await state.popStash(first) }
        try #require(await eventually { await w.client.heldCount(.stashActions) == 1 })

        await state.dropStash(second)

        #expect(state.stashPickerSnapshot.activeOperation?.acts(on: first) == true)
        await w.client.hold(.stashActions, false)
        await w.client.release(.stashActions)
        await running.value
        #expect(await w.client.popCalls == [first])
        #expect(await w.client.dropCalls.isEmpty)
    }

    // MARK: Stashing changes

    /// One submission from the Stash sheet, and what git and Changes then hold.
    struct PushCase: CustomTestStringConvertible, Sendable {
        let name: String
        let typedMessage: String
        let includeUntracked: Bool
        let expectedCall: StashPushCall
        let remainingPaths: [String]

        var testDescription: String { name }
    }

    nonisolated static let pushCases = [
        PushCase(
            name: "trimmed message", typedMessage: "  Half-done refactor \n", includeUntracked: false,
            expectedCall: StashPushCall(message: "Half-done refactor", includeUntracked: false),
            remainingPaths: ["new.txt"]),
        PushCase(
            name: "blank message with untracked", typedMessage: " \n ", includeUntracked: true,
            expectedCall: StashPushCall(message: nil, includeUntracked: true), remainingPaths: []),
    ]

    @Test(arguments: pushCases)
    func stashingRunsGitOnceAndRereadsChangesAndTheList(_ testCase: PushCase) async throws {
        let h = Harness()
        let state = h.makeState()
        let w = try await adopt(
            h, state, stashes: [stash(0, "older")],
            files: [changedFile("a.swift"), changedFile("new.txt", kind: .untracked)])

        await state.stashChanges(message: testCase.typedMessage, includeUntracked: testCase.includeUntracked)

        #expect(await w.client.stashPushCalls == [testCase.expectedCall])
        #expect(state.files.map(\.path) == testCase.remainingPaths)
        #expect(state.stashList.entries.map(\.message) == [testCase.expectedCall.message ?? "WIP on main", "older"])
        #expect(!state.isStashingChanges)
    }

    @Test func anUntrackedOnlyTreeOpensTheSheetButStashesOnlyWithUntrackedIncluded() async throws {
        let h = Harness()
        let state = h.makeState()
        let w = try await adopt(h, state, stashes: [], files: [changedFile("new.txt", kind: .untracked)])
        #expect(state.canOpenStashSheet)
        #expect(state.stashSubmissionBlockedReason(includeUntracked: true) == nil)

        await state.stashChanges(message: "", includeUntracked: false)
        #expect(await w.client.stashPushCalls.isEmpty)

        await state.stashChanges(message: "", includeUntracked: true)
        #expect(await w.client.stashPushCalls == [StashPushCall(message: nil, includeUntracked: true)])
    }

    @Test func aCleanTreeHasNothingToStash() async throws {
        let h = Harness()
        let state = h.makeState()
        _ = try await adopt(h, state, stashes: [], files: [])
        #expect(state.stashChangesUnavailableReason == "No changes to stash")
        #expect(!state.canOpenStashSheet)
    }

    @Test func aRunningPopKeepsTheSheetClosed() async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "popped")
        let w = try await adopt(h, state, stashes: [entry])
        await w.client.hold(.stashActions)
        let pop = Task { await state.popStash(entry) }
        try #require(await eventually { await w.client.heldCount(.stashActions) == 1 })
        #expect(state.stashChangesUnavailableReason == "Another stash action is running")
        #expect(!state.canOpenStashSheet)
        await w.client.hold(.stashActions, false)
        await w.client.release(.stashActions)
        await pop.value
    }

    @Test func aPushInCommitScopeRecountsTheWorkingTreeAndKeepsTheCommit() async throws {
        let h = Harness()
        let state = h.makeState()
        let shown = stash(0, "shown")
        _ = try await adopt(h, state, stashes: [shown], files: [changedFile("a.swift"), changedFile("b.swift")])
        try await show(shown, in: state)

        await state.stashChanges(message: "", includeUntracked: false)

        #expect(state.workingTreeChurn?.changedFileCount == 0)
        #expect(state.scope == .commit(shown.commitSummary.ref))
    }

    /// What refuses a push outright: a running write, a pop still in git, or another sheet.
    enum PushBlocker: CustomTestStringConvertible, Sendable {
        case write(Blocker)
        case heldPop
        case commitSheet

        static let allCases = Blocker.allCases.map(PushBlocker.write) + [.heldPop, .commitSheet]

        var testDescription: String {
            switch self {
            case let .write(blocker): "\(blocker)"
            case .heldPop: "heldPop"
            case .commitSheet: "commitSheet"
            }
        }
    }

    @Test(arguments: PushBlocker.allCases)
    func aPushIsRefusedWhileSomethingElseHoldsTheWindow(_ blocker: PushBlocker) async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "listed")
        let w = try await adopt(h, state, stashes: [entry], files: [changedFile("a.swift", area: .staged)])
        var running: RunningBlocker?
        switch blocker {
        case let .write(write):
            running = try await start(write, in: state, client: w.client)
        case .heldPop:
            await w.client.hold(.stashActions)
            let pop = Task { await state.popStash(entry) }
            try #require(await eventually { await w.client.heldCount(.stashActions) == 1 })
            running = RunningBlocker(client: w.client, held: .stashActions, task: pop)
        case .commitSheet:
            state.isCommitSheetPresented = true
        }

        await state.stashChanges(message: "", includeUntracked: false)

        #expect(!state.isStashingChanges)
        await running?.finish()
        #expect(await w.client.stashPushCalls.isEmpty)
    }

    @Test func aHeldPushRefusesAnotherPushAPopAndADrop() async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "listed")
        let w = try await adopt(h, state, stashes: [entry])
        await w.client.hold(.stashActions)
        let push = Task { await state.stashChanges(message: "first", includeUntracked: false) }
        try #require(await eventually { await w.client.heldCount(.stashActions) == 1 })

        await state.stashChanges(message: "second", includeUntracked: false)
        await state.popStash(entry)
        await state.dropStash(entry)

        await w.client.hold(.stashActions, false)
        await w.client.release(.stashActions)
        await push.value
        #expect(await w.client.stashPushCalls == [StashPushCall(message: "first", includeUntracked: false)])
        #expect(await w.client.popCalls.isEmpty)
        #expect(await w.client.dropCalls.isEmpty)
    }

    @Test func aPushQueuedWhenTheWindowClosesNeverRuns() async throws {
        let h = Harness()
        let state = h.makeState()
        let w = try await adopt(h, state, stashes: [])
        await w.client.hold(.actions)
        let stage = Task { await state.perform(.stage, on: [changedFile("a.swift")]) }
        try #require(await eventually { await w.client.heldCount(.actions) == 1 })
        let queued = Task { await state.stashChanges(message: "", includeUntracked: false) }
        try #require(await eventually { await state.isStashingChanges })

        state.close()
        await w.client.hold(.actions, false)
        await w.client.release(.actions)
        await stage.value
        await queued.value

        #expect(await w.client.stashPushCalls.isEmpty)
        #expect(!state.isStashingChanges)
    }

    @Test func aFailedPushReportsRereadsTheListAndLetsTheNextOneRun() async throws {
        let h = Harness()
        let state = h.makeState()
        let w = try await adopt(h, state, stashes: [])
        let error = ProcessError.failed(command: "git stash push", status: 1, stderr: "needs merge")
        await w.client.fail(stashActionsWith: error)
        await w.client.set(stashes: [stash(0, "outside")])

        await state.stashChanges(message: "", includeUntracked: false)
        #expect(state.errorMessage == error.localizedDescription)
        #expect(state.stashList.entries.map(\.message) == ["outside"])

        await w.client.fail(stashActionsWith: nil)
        await state.stashChanges(message: "retried", includeUntracked: false)
        #expect(state.stashList.entries.map(\.message) == ["retried", "outside"])
    }

    @Test func thePickerHandsOverToTheSheet() async throws {
        let h = Harness()
        let state = h.makeState()
        _ = try await adopt(h, state, stashes: [])
        state.isStashPickerPresented = true
        #expect(state.stashPickerSnapshot.stashChangesDisabledReason == nil)

        state.openStashSheet()
        #expect(!state.isStashPickerPresented)
        #expect(state.isStashSheetPresented)
    }

    @Test func anotherOverlayBesideThePickerKeepsTheSheetClosed() async throws {
        let h = Harness()
        let state = h.makeState()
        _ = try await adopt(h, state, stashes: [])
        state.isStashPickerPresented = true
        state.isCommitSheetPresented = true
        #expect(!state.canOpenStashSheet)
    }
}

extension StashAction {
    @MainActor func run(_ entry: StashEntry, in state: WindowState) async {
        switch self {
        case .pop: await state.popStash(entry)
        case .drop: await state.dropStash(entry)
        }
    }
}
