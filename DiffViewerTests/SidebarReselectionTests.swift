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

    /// One pending row, the rows it is looked up in, and which of them it must land on.
    struct PathTierCase: CustomTestStringConvertible {
        let name: String
        let rows: [ChangedFile]
        let pending: WindowState.PendingSelection
        /// Index into `rows`.
        let expected: Int

        var testDescription: String { name }
    }

    private static let commitArea = ChangedFile.Area.commit(commitSummary("c1").ref)
    private static let duplicated = [changedFile("dup.swift"), changedFile("dup.swift", area: .staged)]

    static let pathTierCases: [PathTierCase] = [
        PathTierCase(
            name: "the path wins over the remembered row, in whichever area it moved to",
            rows: [changedFile("b.swift"), changedFile("a.swift", area: .staged)],
            pending: WindowState.PendingSelection(path: "a.swift", area: .unstaged, row: 0), expected: 1),
        PathTierCase(
            name: "the original area wins when the path is in both: staged", rows: duplicated,
            pending: WindowState.PendingSelection(path: "dup.swift", area: .staged, row: nil), expected: 1),
        PathTierCase(
            name: "the original area wins when the path is in both: unstaged", rows: duplicated,
            pending: WindowState.PendingSelection(path: "dup.swift", area: .unstaged, row: nil), expected: 0),
        PathTierCase(
            name: "unstaged wins when the original area is gone", rows: duplicated,
            pending: WindowState.PendingSelection(path: "dup.swift", area: commitArea, row: nil), expected: 0),
        PathTierCase(
            name: "any area is taken when neither matches", rows: [changedFile("only.swift", area: .staged)],
            pending: WindowState.PendingSelection(path: "only.swift", area: commitArea, row: nil), expected: 0),
    ]

    @Test(arguments: pathTierCases) func aPathIsFoundAgainByTier(_ testCase: PathTierCase) {
        let result = selection(testCase.pending, in: testCase.rows)
        #expect(result == [.file(testCase.rows[testCase.expected].id)])
    }

    @Test func theRememberedRowIsClampedToTheLastRow() {
        let rows = [changedFile("a.swift"), changedFile("b.swift")]
        let result = selection(pending("gone.swift", row: 5), in: rows)
        #expect(result == [.file(rows[1].id)], "discarding the bottom row selects the new bottom row")
        let onlyRow = [rows[0]]
        #expect(selection(pending("gone.swift", row: 4), in: onlyRow) == [.file(onlyRow[0].id)])
    }

    // MARK: A whole selection at once

    @Test func everyPendingPathThatSurvivedIsSelectedAgain() {
        let rows = [changedFile("a.swift", area: .staged), changedFile("b.swift", area: .staged)]
        let result = SidebarReselection.selection(
            after: [pending("a.swift", row: 0), pending("b.swift", row: 1)], surviving: [], in: rows)
        #expect(result == [.file(rows[0].id), .file(rows[1].id)], "every path still there is selected again")
    }

    @Test func survivorsAreKeptAlongsideTheFoundPaths() {
        let rows = [changedFile("keep.swift"), changedFile("a.swift", area: .staged)]
        let result = SidebarReselection.selection(
            after: [pending("a.swift", row: 1)], surviving: [.file(rows[0].id)], in: rows)
        #expect(result == [.file(rows[0].id), .file(rows[1].id)])
    }

    @Test func onlyTheSurvivingPathsAreSelectedWhenSomeAreGone() {
        let rows = [changedFile("a.swift"), changedFile("c.swift")]
        let result = SidebarReselection.selection(
            after: [pending("a.swift", row: 0), pending("gone.swift", row: 1)], surviving: [], in: rows)
        #expect(result == [.file(rows[0].id)], "the row index is for when nothing at all was found")
    }

    @Test func theRowFallbackAppliesOnceAtTheLowestPendingRow() {
        let rows = [changedFile("x.swift"), changedFile("y.swift"), changedFile("z.swift")]
        #expect(selection(pending("gone1.swift", row: 1), in: rows) == [.file(rows[1].id)])
        let result = SidebarReselection.selection(
            after: [pending("gone2.swift", row: 2), pending("gone1.swift", row: 1)], surviving: [], in: rows)
        #expect(result == [.file(rows[1].id)], "discarding two rows leaves one selected, where the topmost was")
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

    // MARK: Stage moves on to the neighbour

    private func neighbour(
        from area: ChangedFile.Area, at index: Int, surviving: Set<DiffSelection> = [], in rows: [ChangedFile]
    ) -> Set<DiffSelection> {
        SidebarReselection.neighbour(from: area, at: index, surviving: surviving, in: rows)
    }

    @Test func stagingMovesOnWithinTheChangesRows() {
        // b.swift, the middle Changes row, was staged: the row below slid up.
        let middle = [changedFile("a.swift"), changedFile("c.swift"), changedFile("b.swift", area: .staged)]
        #expect(neighbour(from: .unstaged, at: 1, in: middle) == [.file(middle[1].id)])

        // c.swift, the last Changes row, was staged; the staged rows follow in sidebar order.
        let last = [
            changedFile("a.swift"), changedFile("b.swift"),
            changedFile("c.swift", area: .staged), changedFile("d.swift", area: .staged),
        ]
        #expect(neighbour(from: .unstaged, at: 2, in: last) == [.file(last[1].id)], "never a staged row")
    }

    @Test func aSurvivingRowIsKeptAndNoNeighbourIsAdded() {
        let rows = [changedFile("a.swift"), changedFile("c.swift"), changedFile("keep.swift", area: .staged)]
        let result = neighbour(from: .unstaged, at: 0, surviving: [.file(rows[2].id)], in: rows)
        #expect(result == [.file(rows[2].id)])
    }

    // MARK: Unstage clears the selection

    @Test func unstagingClearsTheSelection() {
        let rows = [changedFile("a.swift"), changedFile("x.swift", area: .staged)]
        let kept: Set<DiffSelection> = [.file(rows[1].id)]
        #expect(SidebarReselection.selection(for: .clear, surviving: kept, in: rows).isEmpty)
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
