import Foundation
import Testing

@testable import DiffViewer

/// What the floating capsule offers for the selection, and when it offers nothing.
@MainActor
struct StagingCapsuleTests {
    /// The sidebar order is unstaged then staged, so these draw as a, b, c, d.
    let files = [
        changedFile("a.swift"), changedFile("b.swift"), changedFile("c.swift", area: .staged),
        changedFile("d.swift", area: .staged),
    ]

    @Test(arguments: [Set<DiffSelection>(), [.allChanges]])
    func withNoFileSelectedItStagesAll(_ selection: Set<DiffSelection>) async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: files)
        state.selection = selection

        #expect(state.stagingCapsule == StagingCapsule(action: .stageAll, files: [files[0], files[1]]))
        #expect(state.stagingCapsule?.title == "Stage All")
    }

    @Test func oneUnstagedRowSelectedStagesIt() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: files)
        state.selection = [.file(files[1].id)]

        #expect(state.stagingCapsule == StagingCapsule(action: .stage, files: [files[1]]))
        #expect(state.stagingCapsule?.title == "Stage 1 File")
    }

    @Test func twoStagedRowsSelectedUnstagesThem() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: files)
        state.selection = [.file(files[2].id), .file(files[3].id)]

        #expect(state.stagingCapsule == StagingCapsule(action: .unstage, files: [files[2], files[3]]))
        #expect(state.stagingCapsule?.title == "Unstage 2 Files")
    }

    @Test func nothingToStageShowsNoCapsule() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: [files[2]])
        state.selection = []

        #expect(state.stagingCapsule == nil)
    }

    /// Stage All leaves conflicts out, so with only conflicts it has nothing to do.
    @Test func onlyConflictsShowNoCapsule() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: [changedFile("x.swift", kind: .unmerged), files[2]])
        state.selection = []

        #expect(state.stagingCapsule == nil)
    }

    @Test func aCommitShowsNoCapsule() async {
        let h = Harness()
        let state = h.makeState()
        let commit = commitSummary("c1")
        let repo = h.repo("A", files: files)
        await repo.client.set(head: commit.ref.sha)
        await repo.client.set(commits: [commit])
        let file = ChangedFile(path: "p.swift", originalPath: nil, kind: .modified, area: .commit(commit.ref))
        await repo.client.set(files: [file], forCommit: commit.ref.sha)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await !state.history.commits.isEmpty })

        state.select(commit: commit)
        #expect(await eventually { await state.files.map(\.path) == ["p.swift"] })
        state.selection = [.file(file.id)]

        #expect(state.stagingCapsule == nil)
    }

    @Test func offeringReturnsTheCapsuleForTheSelectedFiles() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: files)
        state.selection = [.file(files[1].id)]

        #expect(state.stagingCapsule(offering: .stage) == StagingCapsule(action: .stage, files: [files[1]]))
    }

    /// The caller's capsule is from the last render; the selection may have moved to staged rows.
    @Test func offeringReturnsNilOnceTheActionNoLongerMatches() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: files)
        state.selection = [.file(files[2].id)]

        #expect(state.stagingCapsule(offering: .stage) == nil)
    }

    @Test func offeringReturnsNilWhileAStagingActionCannotStart() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: files)
        state.selection = [.file(files[1].id)]
        state.isConfirmingFileAction = true

        #expect(state.stagingCapsule(offering: .stage) == nil)
    }

    // MARK: Churn

    private static func capsule(_ stats: [LineStats?], action: StagingCapsule.Action = .stage) -> StagingCapsule {
        let files = stats.enumerated().map { changedFile("f\($0.offset).swift").with(lineStats: $0.element) }
        return StagingCapsule(action: action, files: files)
    }

    @Test func churnSumsCountedFilesAndSkipsBinaries() {
        let sizes = BinarySizes(oldByteCount: 1, newByteCount: 2)
        let capsule = Self.capsule([.counted(added: 30, deleted: 5), .binary(sizes), .counted(added: 10, deleted: 15)])

        #expect(capsule.churn == .counted(added: 40, deleted: 20))
    }

    @Test func churnWithKnownCountsButNoLinesIsNoLineChanges() {
        #expect(Self.capsule([.binary(nil), .binary(nil)]).churn == .noLineChanges)
        #expect(Self.capsule([.counted(added: 0, deleted: 0), .binary(nil)]).churn == .noLineChanges)
    }

    @Test func churnIsUnknownWhenAnyTargetHasNoCounts() {
        #expect(Self.capsule([nil, nil]).churn == .unknown)
        #expect(Self.capsule([.counted(added: 3, deleted: 1), nil]).churn == .unknown)
    }

    struct LabelCase: CustomTestStringConvertible {
        let action: StagingCapsule.Action
        let stats: [LineStats?]
        let expected: String

        var testDescription: String { expected }
    }

    nonisolated static let labelCases = [
        LabelCase(
            action: .stage, stats: [.counted(added: 1, deleted: 1)], expected: "Stage 1 File, 1 addition, 1 deletion"),
        LabelCase(
            action: .stage, stats: [.counted(added: 30, deleted: 5), .counted(added: 10, deleted: 15)],
            expected: "Stage 2 Files, 40 additions, 20 deletions"),
        LabelCase(
            action: .stageAll, stats: [.counted(added: 72, deleted: 29)],
            expected: "Stage All, 72 additions, 29 deletions"),
        LabelCase(
            action: .unstage, stats: [.counted(added: 2, deleted: 0)],
            expected: "Unstage 1 File, 2 additions, 0 deletions"),
        LabelCase(action: .stage, stats: [.binary(nil)], expected: "Stage 1 File, no line changes"),
        LabelCase(action: .stage, stats: [nil], expected: "Stage 1 File"),
    ]

    @Test(arguments: labelCases)
    func labelCarriesTheTitleAndTheChurn(_ testCase: LabelCase) {
        #expect(Self.capsule(testCase.stats, action: testCase.action).accessibilityLabel == testCase.expected)
    }

    @Test(arguments: [
        (StagingCapsule.Action.stageAll, "Command S"), (.stage, "Command S"), (.unstage, "Shift Command S"),
    ])
    func spokenShortcutNamesTheKeys(_ action: StagingCapsule.Action, _ expected: String) {
        #expect(Self.capsule([], action: action).spokenShortcut == expected)
    }

    // MARK: Churn from the live list

    private func setCounts(_ client: StubRepoClient) async {
        await client.set(numstat: [counted("a.swift", 3, 1), counted("b.swift", 2, 0)], area: .unstaged)
        await client.set(numstat: [counted("c.swift", 10, 4)], area: .staged)
    }

    /// Stage All covers the unstaged files only, and waits for every one of their counts.
    @Test func stageAllChurnWaitsForTheCountsThenSumsTheUnstagedFiles() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: files)
        await setCounts(repo.client)
        await repo.client.hold(.numstat)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await repo.client.heldCount(.numstat) == 2 })
        #expect(state.stagingCapsule?.churn == .unknown)

        await repo.client.release(.numstat)
        await h.settleStats(state)
        #expect(state.stagingCapsule?.churn == .counted(added: 5, deleted: 1))

        state.selection = [.file(files[0].id)]
        #expect(state.stagingCapsule?.churn == .counted(added: 3, deleted: 1))
    }

    /// A conflict's churn is its working file against HEAD: what Mark Resolved stages.
    @Test func aConflictsChurnIsItsWorkingFileAgainstHead() async {
        let h = Harness()
        let state = h.makeState()
        let conflict = changedFile("x.swift", kind: .unmerged)
        await h.adopt(state, "A", files: [conflict]) { await $0.set(headNumstat: [counted("x.swift", 4, 0)]) }
        await h.settleStats(state)
        state.selection = [.file(conflict.id)]

        #expect(state.stagingCapsule?.churn == .counted(added: 4, deleted: 0))
    }

    @Test func aFailedNumstatLeavesTheChurnUnknown() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: files) { await $0.fail(numstat: true) }
        await h.settleStats(state)

        #expect(state.stagingCapsule?.churn == .unknown)
    }
}
