import Foundation
import Testing

@testable import DiffViewer

/// What the branch picker reads from a window, and how the paired HEAD + branch read
/// publishes.
@MainActor
struct WindowStateBranchPickerTests {
    private let workingFiles = [changedFile("a.swift")]

    /// Adopts a repository and waits for the first file list and branch read to land.
    private func adopt(
        _ h: Harness, _ state: WindowState, branches: [LocalBranch] = [localBranch("main")],
        files: [ChangedFile]? = nil
    ) async -> (root: RepositoryRoot, client: StubRepoClient) {
        let repo = h.repo("A", files: files ?? workingFiles)
        await repo.client.set(localBranches: branches)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count == 1 })
        #expect(await eventually { await state.branchReadStatus == .loaded })
        return repo
    }

    // MARK: Paired publish

    @Test func headAndBranchesPublishTogether() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        #expect(state.headState == .named("main"))

        await repo.client.holdLocalBranches(true)
        await repo.client.set(headState: .named("feature"))
        await repo.client.set(localBranches: [localBranch("main"), localBranch("feature")])
        h.tick(repo.root, [.refs])
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        #expect(state.headState == .named("main"), "HEAD waits for the branch list")
        #expect(state.localBranches == ["main"])

        await repo.client.holdLocalBranches(false)
        await repo.client.releaseLocalBranches()
        #expect(await eventually { await state.headState == .named("feature") })
        #expect(state.localBranches == ["main", "feature"])
        #expect(state.branchReadStatus == .loaded)
    }

    @Test func aFailedBranchReadKeepsThePairAndReportsIt() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)

        await repo.client.set(headState: .named("feature"))
        await repo.client.fail(localBranches: true)
        h.tick(repo.root, [.refs])
        #expect(await eventually { await state.branchReadStatus == .failed })
        #expect(state.headState == .named("main"), "the last good pair stays up")
        #expect(state.localBranches == ["main"])
    }

    @Test func aSupersededFailureIsNotPublished() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)

        // Two reads are held at the branch list; the second supersedes the first.
        await repo.client.holdLocalBranches(true)
        Task { await state.refresh() }
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        await repo.client.set(localBranches: [localBranch("main"), localBranch("feature")])
        Task { await state.refresh() }
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 2 })

        await repo.client.holdLocalBranches(false)
        // The newest read finishes first, then the superseded one fails.
        await repo.client.releaseLastLocalBranches()
        #expect(await eventually { await state.localBranches == ["main", "feature"] })
        await repo.client.fail(localBranches: true)
        await repo.client.releaseLocalBranches()
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 0 })
        #expect(state.branchReadStatus == .loaded, "the superseded failure publishes nothing")
    }

    // MARK: Presentation

    @Test func onlyOnePickerOrSheetCanOpenAtOnce() async {
        let h = Harness()
        let state = h.makeState()
        // A staged file, so the commit sheet is open-able to begin with.
        _ = await adopt(h, state, files: [changedFile("a.swift", area: .staged)])
        #expect(state.canOpenBranchPicker)
        #expect(state.canOpenCommitPicker)
        #expect(state.canOpenCommitSheet)

        state.isBranchPickerPresented = true
        #expect(!state.canOpenCommitPicker)
        #expect(!state.canOpenCommitSheet)
        state.isBranchPickerPresented = false
        #expect(state.canOpenCommitSheet)

        state.isCommitPickerPresented = true
        #expect(!state.canOpenBranchPicker)
        state.isCommitPickerPresented = false

        state.isCommitSheetPresented = true
        #expect(!state.canOpenBranchPicker)
    }

    @Test func closingClearsTheBranchPicker() async {
        let h = Harness()
        let state = h.makeState()
        _ = await adopt(h, state)
        state.isBranchPickerPresented = true

        state.close()
        #expect(!state.isBranchPickerPresented)
        #expect(!state.canOpenBranchPicker)
    }

    @Test func theSnapshotCarriesTheSwitchInFlight() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [localBranch("main"), localBranch("feature")])
        #expect(state.branchPickerSnapshot.headState == .named("main"))
        #expect(state.branchPickerSnapshot.branches.map(\.name) == ["main", "feature"])
        #expect(!state.branchPickerSnapshot.isSwitchingBranch)

        await repo.client.holdSwitchBranch(true)
        Task { await state.switchBranch(to: "feature") }
        #expect(await eventually { await repo.client.heldSwitchBranchCount == 1 })
        #expect(state.branchPickerSnapshot.isSwitchingBranch)

        await repo.client.holdSwitchBranch(false)
        await repo.client.releaseSwitchBranch()
        #expect(await eventually { await !state.isSwitchingBranch })
    }

    /// The picker refuses to activate a row while a switch runs; the window refuses too.
    @Test func aSecondSwitchDuringTheFirstIsIgnored() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [localBranch("main"), localBranch("feature")])

        await repo.client.holdSwitchBranch(true)
        Task { await state.switchBranch(to: "feature") }
        #expect(await eventually { await repo.client.heldSwitchBranchCount == 1 })
        #expect(state.branchPickerSnapshot.isSwitchingBranch)

        var picker = BranchPickerState(snapshot: state.branchPickerSnapshot, grouping: CommitDayGrouping())
        #expect(!picker.rows.isEmpty)
        #expect(picker.rows.indices.allSatisfy { !picker.canActivate(tableRow: $0) })

        await state.switchBranch(to: "feature")
        await repo.client.holdSwitchBranch(false)
        await repo.client.releaseSwitchBranch()
        #expect(await eventually { await !state.isSwitchingBranch })
        #expect(await repo.client.switchBranchCalls == ["feature"], "the second call was ignored")

        picker = BranchPickerState(snapshot: state.branchPickerSnapshot, grouping: CommitDayGrouping())
        #expect(picker.rows.indices.contains { picker.canActivate(tableRow: $0) }, "rows unlock once it settles")
    }
}
