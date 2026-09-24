import Foundation
import Testing

@testable import DiffViewer

struct SidebarReselectionTests {
    private func pending(_ path: String, area: ChangedFile.Area = .unstaged, row: Int? = nil)
        -> WindowState.PendingSelection
    {
        WindowState.PendingSelection(path: path, area: area, row: row)
    }

    /// Where one pending row lands, which is the same rule at arity one.
    private func selection(_ previous: WindowState.PendingSelection, in rows: [ChangedFile]) -> Set<DiffSelection> {
        SidebarReselection.selection(after: [previous], surviving: [], in: rows)
    }

    @Test func thePathWinsOverTheRememberedRow() {
        let rows = [changedFile("b.swift"), changedFile("a.swift", area: .staged)]
        let result = selection(pending("a.swift", row: 0), in: rows)
        #expect(result == [.file(rows[1].id)], "staging a file moves it, and the selection follows the path")
    }

    @Test func theOriginalAreaWinsWhenThePathIsInBoth() {
        let rows = [changedFile("dup.swift"), changedFile("dup.swift", area: .staged)]
        #expect(selection(pending("dup.swift", area: .staged), in: rows) == [.file(rows[1].id)])
        #expect(selection(pending("dup.swift", area: .unstaged), in: rows) == [.file(rows[0].id)])
    }

    @Test func unstagedWinsWhenTheOriginalAreaIsGone() {
        let commit = commitSummary("c1")
        let rows = [changedFile("dup.swift"), changedFile("dup.swift", area: .staged)]
        #expect(selection(pending("dup.swift", area: .commit(commit.ref)), in: rows) == [.file(rows[0].id)])
    }

    @Test func anyAreaIsTakenWhenNeitherMatches() {
        let rows = [changedFile("only.swift", area: .staged)]
        let commit = commitSummary("c1")
        #expect(selection(pending("only.swift", area: .commit(commit.ref)), in: rows) == [.file(rows[0].id)])
    }

    @Test func theRememberedRowIsUsedWhenThePathIsGone() {
        let rows = [changedFile("a.swift"), changedFile("b.swift"), changedFile("c.swift")]
        #expect(selection(pending("gone.swift", row: 1), in: rows) == [.file(rows[1].id)])
    }

    @Test func theRememberedRowIsClampedToTheLastRow() {
        let rows = [changedFile("a.swift"), changedFile("b.swift")]
        let result = selection(pending("gone.swift", row: 5), in: rows)
        #expect(result == [.file(rows[1].id)], "discarding the bottom row selects the new bottom row")
    }

    @Test func anEmptyListSelectsNothing() {
        #expect(selection(pending("a.swift", row: 0), in: []) == [])
    }

    @Test func aMissingPathWithoutARowSelectsNothing() {
        let rows = [changedFile("a.swift"), changedFile("b.swift")]
        #expect(selection(pending("gone.swift"), in: rows) == [])
    }

    // MARK: A whole selection at once

    @Test func everyPendingPathThatSurvivedIsSelectedAgain() {
        let rows = [changedFile("a.swift", area: .staged), changedFile("b.swift", area: .staged)]
        let result = SidebarReselection.selection(
            after: [pending("a.swift", row: 0), pending("b.swift", row: 1)], surviving: [], in: rows)
        #expect(result == [.file(rows[0].id), .file(rows[1].id)], "staging two files keeps both selected")
    }

    @Test func survivorsAreKeptAlongsideTheFoundPaths() {
        let rows = [changedFile("keep.swift"), changedFile("a.swift", area: .staged)]
        let result = SidebarReselection.selection(
            after: [pending("a.swift", row: 1)], surviving: [.file(rows[0].id)], in: rows)
        #expect(result == [.file(rows[0].id), .file(rows[1].id)])
    }

    @Test func allChangesIsKeptWhateverHappensToTheRows() {
        let rows = [changedFile("a.swift", area: .staged)]
        let result = SidebarReselection.selection(
            after: [pending("a.swift", row: 0), pending("gone.swift", row: 1)], surviving: [.allChanges], in: rows)
        #expect(result == [.allChanges, .file(rows[0].id)])
    }

    @Test func onlyTheSurvivingPathsAreSelectedWhenSomeAreGone() {
        let rows = [changedFile("a.swift"), changedFile("c.swift")]
        let result = SidebarReselection.selection(
            after: [pending("a.swift", row: 0), pending("gone.swift", row: 1)], surviving: [], in: rows)
        #expect(result == [.file(rows[0].id)], "the row index is for when nothing at all was found")
    }

    @Test func theRowFallbackAppliesOnceAtTheLowestPendingRow() {
        let rows = [changedFile("x.swift"), changedFile("y.swift"), changedFile("z.swift")]
        let result = SidebarReselection.selection(
            after: [pending("gone2.swift", row: 2), pending("gone1.swift", row: 1)], surviving: [], in: rows)
        #expect(result == [.file(rows[1].id)], "discarding two rows leaves one selected, where the topmost was")
    }

    @Test func theRowFallbackIsClampedToTheLastRow() {
        let rows = [changedFile("x.swift")]
        let result = SidebarReselection.selection(
            after: [pending("gone.swift", row: 4)], surviving: [], in: rows)
        #expect(result == [.file(rows[0].id)])
    }

    @Test func theRowFallbackIsSkippedWhenSomethingElseIsStillSelected() {
        let rows = [changedFile("x.swift"), changedFile("keep.swift")]
        let result = SidebarReselection.selection(
            after: [pending("gone.swift", row: 0)], surviving: [.file(rows[1].id)], in: rows)
        #expect(result == [.file(rows[1].id)], "the reader still has a file on screen; nothing slides under them")
    }

    @Test func nothingFoundAndNothingSurvivingLeavesAnEmptySelection() {
        #expect(SidebarReselection.selection(after: [pending("gone.swift", row: 0)], surviving: [], in: []).isEmpty)
        let rows = [changedFile("x.swift")]
        #expect(SidebarReselection.selection(after: [pending("gone.swift")], surviving: [], in: rows).isEmpty)
    }

    // MARK: Surviving a refresh

    private func unstagedRename(_ path: String, from original: String) -> ChangedFile {
        ChangedFile(path: path, originalPath: original, kind: .renamed, area: .unstaged, fingerprint: nil)
    }

    private func byID(_ files: [ChangedFile]) -> [ChangedFile.ID: ChangedFile] {
        Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
    }

    @Test func aSelectedDeletionFollowsTheRenameThatAbsorbedIt() {
        let old = changedFile("a.swift", kind: .deleted)
        let rows = [unstagedRename("b.swift", from: "a.swift")]
        let result = SidebarReselection.surviving([.file(old.id)], before: byID([old]), in: rows)
        #expect(result == [.file(rows[0].id)])
    }

    @Test func aVanishedRowDoesNotFollowARenameInAnotherArea() {
        let old = changedFile("a.swift", area: .staged, kind: .deleted)
        let rows = [unstagedRename("b.swift", from: "a.swift")]
        #expect(SidebarReselection.surviving([.file(old.id)], before: byID([old]), in: rows).isEmpty)
    }

    @Test func survivorsStayAndAnUnrelatedVanishedRowIsDropped() {
        let kept = changedFile("keep.swift")
        let gone = changedFile("gone.swift", kind: .deleted)
        let rows = [kept, unstagedRename("b.swift", from: "a.swift")]
        let result = SidebarReselection.surviving(
            [.allChanges, .file(kept.id), .file(gone.id)], before: byID([kept, gone]), in: rows)
        #expect(result == [.allChanges, .file(kept.id)])
    }
}
