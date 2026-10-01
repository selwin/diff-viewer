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
}
