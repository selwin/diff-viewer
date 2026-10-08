import Foundation
import Testing

@testable import DiffViewer

/// What the branch picker reads from a window, and how the paired HEAD + branch read
/// publishes.
@MainActor
struct WindowStateBranchPickerTests {
    private let workingFiles = [changedFile("a.swift")]
    private let mergeTarget = MergeTarget(
        sourceName: "side", sourceRef: "refs/heads/side", sourceTipSha: objectID("side"),
        destinationBranch: "main", destinationTipSha: objectID("main"))

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

    // MARK: New Branch sheet

    /// The picker hands over to the sheet, and while the sheet is up neither picker nor
    /// the commit sheet can open.
    @Test func theNewBranchSheetReplacesThePickerAndBlocksTheOthers() async {
        let h = Harness()
        let state = h.makeState()
        _ = await adopt(h, state, files: [changedFile("a.swift", area: .staged)])
        #expect(state.canOpenCommitSheet)
        state.isBranchPickerPresented = true
        #expect(!state.canOpenNewBranchSheet)

        state.openNewBranchSheet(initialName: nil)

        #expect(!state.isBranchPickerPresented)
        #expect(state.isNewBranchSheetPresented)
        #expect(!state.canOpenBranchPicker)
        #expect(!state.canOpenCommitPicker)
        #expect(!state.canOpenCommitSheet)
    }

    /// The picker's proposal reaches the sheet, and closing the sheet forgets it.
    @Test func theSheetOpensWithTheProposedNameUntilItCloses() async {
        let h = Harness()
        let state = h.makeState()
        _ = await adopt(h, state)
        state.isBranchPickerPresented = true

        state.openNewBranchSheet(initialName: "feature-x")
        #expect(state.isNewBranchSheetPresented)
        #expect(state.newBranchInitialName == "feature-x")

        state.isNewBranchSheetPresented = false
        state.newBranchSheetDismissed()
        #expect(state.newBranchInitialName == nil)
    }

    /// A switch in flight keeps the sheet shut, and the name isn't kept for later.
    @Test func aRefusedOpenStoresNoName() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [localBranch("main"), localBranch("feature")])
        await repo.client.hold(.switchBranch)
        Task { await state.switchBranch(to: "feature") }
        #expect(await eventually { await repo.client.heldCount(.switchBranch) == 1 })

        state.openNewBranchSheet(initialName: "feature-x")
        #expect(!state.isNewBranchSheetPresented)
        #expect(state.newBranchInitialName == nil)

        await repo.client.hold(.switchBranch, false)
        await repo.client.release(.switchBranch)
        #expect(await eventually { await !state.isSwitchingBranch })
    }

    // MARK: Paired publish

    @Test func headAndBranchesPublishTogether() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        #expect(state.headState == .named("main"))

        await repo.client.hold(.localBranches)
        await repo.client.set(headState: .named("feature"))
        await repo.client.set(localBranches: [localBranch("main"), localBranch("feature")])
        h.tick(repo.root, [.refs])
        #expect(await eventually { await repo.client.heldCount(.localBranches) == 1 })
        #expect(state.headState == .named("main"), "HEAD waits for the branch list")
        #expect(state.localBranches == ["main"])

        await repo.client.hold(.localBranches, false)
        await repo.client.release(.localBranches)
        #expect(await eventually { await state.headState == .named("feature") })
        #expect(state.localBranches == ["main", "feature"])
        #expect(state.branchReadStatus == .loaded)
    }

    /// The two lists a branch read makes.
    enum BranchList {
        case local, remote
    }

    /// Either list failing fails the pair: HEAD and both lists stay as they were.
    @Test(arguments: [BranchList.local, .remote])
    func aFailedBranchReadKeepsThePairAndReportsIt(_ failing: BranchList) async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)

        await repo.client.set(headState: .named("feature"))
        await repo.client.set(localBranches: [localBranch("main"), localBranch("feature")])
        await repo.client.set(remoteBranches: [remoteBranch("feature")])
        switch failing {
        case .local: await repo.client.fail(localBranches: true)
        case .remote: await repo.client.fail(remoteBranches: true)
        }
        h.tick(repo.root, [.refs])
        #expect(await eventually { await state.branchReadStatus == .failed })
        #expect(state.headState == .named("main"), "the last good pair stays up")
        #expect(state.localBranches == ["main"])
        #expect(state.remoteBranches.isEmpty)
    }

    @Test func aSupersededFailureIsNotPublished() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)

        // Two reads are held at the branch list; the second supersedes the first.
        await repo.client.hold(.localBranches)
        Task { await state.refresh() }
        #expect(await eventually { await repo.client.heldCount(.localBranches) == 1 })
        await repo.client.set(localBranches: [localBranch("main"), localBranch("feature")])
        Task { await state.refresh() }
        #expect(await eventually { await repo.client.heldCount(.localBranches) == 2 })

        await repo.client.hold(.localBranches, false)
        // The newest read finishes first, then the superseded one fails.
        await repo.client.releaseLast(.localBranches)
        #expect(await eventually { await state.localBranches == ["main", "feature"] })
        await repo.client.fail(localBranches: true)
        await repo.client.release(.localBranches)
        #expect(await eventually { await repo.client.heldCount(.localBranches) == 0 })
        #expect(state.branchReadStatus == .loaded, "the superseded failure publishes nothing")
    }

    // MARK: Presentation

    private static let overlays: [WindowState.Overlay] = [
        .commitSheet, .commitPicker, .branchPicker, .stashPicker, .newBranchSheet, .mergeSheet,
    ]

    private func setPresented(_ overlay: WindowState.Overlay, _ on: Bool, in state: WindowState) {
        switch overlay {
        case .commitSheet: state.isCommitSheetPresented = on
        case .commitPicker: state.isCommitPickerPresented = on
        case .branchPicker: state.isBranchPickerPresented = on
        case .stashPicker: state.isStashPickerPresented = on
        case .newBranchSheet: state.isNewBranchSheetPresented = on
        case .mergeSheet: state.pendingMerge = on ? mergeTarget : nil
        }
    }

    private func canOpen(_ overlay: WindowState.Overlay, in state: WindowState) -> Bool {
        switch overlay {
        case .commitSheet: state.canOpenCommitSheet
        case .commitPicker: state.canOpenCommitPicker
        case .branchPicker: state.canOpenBranchPicker
        case .stashPicker: state.canOpenStashPicker
        case .newBranchSheet: state.canOpenNewBranchSheet
        case .mergeSheet: state.canOpenMergeSheet
        }
    }

    /// Only one picker or sheet is up at a time, and Stage All waits for it to close.
    @Test(arguments: [
        WindowState.Overlay.commitSheet, .commitPicker, .branchPicker, .stashPicker, .newBranchSheet, .mergeSheet,
    ])
    func anOpenOverlayBlocksTheOthersAndStageAll(_ presented: WindowState.Overlay) async {
        let h = Harness()
        let state = h.makeState()
        // A staged file, so the commit sheet can open, and an unstaged one for Stage All.
        _ = await adopt(h, state, files: [changedFile("a.swift"), changedFile("b.swift", area: .staged)])
        let others = Self.overlays.filter { $0 != presented }
        #expect(others.allSatisfy { canOpen($0, in: state) })
        #expect(state.canStageAll)

        setPresented(presented, true, in: state)
        for other in others {
            #expect(!canOpen(other, in: state), "\(other) waits for \(presented) to close")
        }
        #expect(!state.canStageAll)

        setPresented(presented, false, in: state)
        #expect(others.allSatisfy { canOpen($0, in: state) })
        #expect(state.canStageAll)
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

        await repo.client.hold(.switchBranch)
        Task { await state.switchBranch(to: "feature") }
        #expect(await eventually { await repo.client.heldCount(.switchBranch) == 1 })
        #expect(state.branchPickerSnapshot.isSwitchingBranch)

        await repo.client.hold(.switchBranch, false)
        await repo.client.release(.switchBranch)
        #expect(await eventually { await !state.isSwitchingBranch })
        let picker = BranchPickerState(snapshot: state.branchPickerSnapshot, grouping: CommitDayGrouping())
        #expect(picker.items.indices.contains { picker.canActivate(tableRow: $0) }, "rows unlock once it settles")
    }
}
