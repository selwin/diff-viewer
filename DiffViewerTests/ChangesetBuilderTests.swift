import Foundation
import Testing

@testable import DiffViewer

struct ChangesetBuilderTests {
    private let loadID = UUID()

    private func build(_ results: [(file: ChangedFile, result: ChangesetBuilder.FileResult)], revision: Int = 1)
        -> ChangesetDocument
    {
        ChangesetBuilder.build(results: results, loadID: loadID, revision: revision)
    }

    private func text(_ old: [String], _ new: [String], _ rows: [DiffRow], language: String? = "Swift")
        -> ChangesetBuilder.FileResult
    {
        .content(.text(DiffDocument(oldLines: old, newLines: new, rows: rows, language: language)))
    }

    // MARK: Offsets

    @Test func rowsAndLinesAreConcatenatedWithOffsets() {
        let a = text(
            ["a0", "a1"], ["a0", "A1"],
            [.equal(old: 0, new: 0), modifiedRow(1, 1, highlights: [0..<2])])
        let b = text(
            ["b0", "b1", "b2"], ["b0", "b1"], [.equal(old: 0, new: 0), .equal(old: 1, new: 1), deletedRow(2)])
        let changeset = build([(changedFile("a.swift"), a), (changedFile("b.swift"), b)])

        #expect(changeset.document.rows.count == 5)
        #expect(changeset.document.oldLines == ["a0", "a1", "b0", "b1", "b2"])
        #expect(changeset.document.newLines == ["a0", "A1", "b0", "b1"])
        #expect(changeset.document.language == nil)
        #expect(changeset.loadID == loadID)

        #expect(changeset.sections.map(\.rowRange) == [0..<2, 2..<5])
        #expect(changeset.sections[1].oldLineOffset == 2)
        #expect(changeset.sections[1].newLineOffset == 2)
        #expect(changeset.sections[1].oldLineCount == 3)
        #expect(changeset.sections[1].newLineCount == 2)
        #expect(changeset.sections[1].outcome == .text(language: "Swift"))

        // B's rows point at B's lines in the flat arrays.
        #expect(changeset.document.rows[2].new?.lineIndex == 2)
        #expect(changeset.document.rows[4].old?.lineIndex == 4)
        #expect(changeset.document.oldLines[4] == "b2")
        // Token highlights survive the shift.
        #expect(changeset.document.rows[1].old?.highlights == [0..<2])
    }

    @Test func lineOffsetsGiveFileLocalNumbers() {
        let a = text(["a0", "a1"], ["a0", "A1"], [.equal(old: 0, new: 0), modifiedRow(1, 1)])
        let b = text(
            ["b0", "b1", "b2"], ["b0", "b1"], [.equal(old: 0, new: 0), .equal(old: 1, new: 1), deletedRow(2)])
        let changeset = build([(changedFile("a.swift"), a), (changedFile("b.swift"), b)])
        let section = changeset.sections[1]

        let deleted = changeset.document.rows[4]
        #expect(deleted.old.map { $0.lineIndex - section.oldLineOffset + 1 } == 3)
        let firstRow = changeset.document.rows[2]
        #expect(firstRow.new.map { $0.lineIndex - section.newLineOffset + 1 } == 1)
    }

    @Test func unequalOffsetsShiftEachSideIndependently() {
        // A shrinks 4 old lines to 1 new one, so the two sides shift by different amounts.
        let a = text(
            ["a0", "a1", "a2", "a3"], ["a0"],
            [.equal(old: 0, new: 0), deletedRow(1), deletedRow(2), deletedRow(3)])
        let b = text(
            ["b0", "b1"], ["b0", "B1", "b2"],
            [.equal(old: 0, new: 0), modifiedRow(1, 1, highlights: [1..<2]), addedRow(2)])
        let changeset = build([(changedFile("a.swift"), a), (changedFile("b.swift"), b)])
        let section = changeset.sections[1]

        #expect(section.oldLineOffset == 4)
        #expect(section.newLineOffset == 1)
        #expect(section.oldLineCount == 2)
        #expect(section.newLineCount == 3)

        // B's rows point at B's lines in the flat arrays, one offset per side.
        let modified = changeset.document.rows[5]
        #expect(modified.old?.lineIndex == 5)
        #expect(modified.new?.lineIndex == 2)
        #expect(changeset.document.oldLines[5] == "b1")
        #expect(changeset.document.newLines[2] == "B1")
        let added = changeset.document.rows[6]
        #expect(added.new?.lineIndex == 3)
        #expect(added.old == nil)
        #expect(changeset.document.newLines[3] == "b2")

        // File-local numbers come back from the section's own offsets.
        #expect(modified.old.map { $0.lineIndex - section.oldLineOffset + 1 } == 2)
        #expect(modified.new.map { $0.lineIndex - section.newLineOffset + 1 } == 2)
        #expect(added.new.map { $0.lineIndex - section.newLineOffset + 1 } == 3)

        // Token highlights survive the nonzero shift on both sides.
        #expect(modified.old?.highlights == [1..<2])
        #expect(modified.new?.highlights == [1..<2])
    }

    // MARK: Counts

    @Test func perSectionCountsComeFromTheSectionsRows() {
        let a = text(
            ["a0"], ["a0", "a1", "a2"],
            [.equal(old: 0, new: 0), addedRow(1), addedRow(2)])
        let b = text(
            ["b0", "b1", "b2"], ["b0"],
            [.equal(old: 0, new: 0), deletedRow(1), deletedRow(2)])
        let c = text(["c0", "c1"], ["c0", "c1"], [modifiedRow(0, 0), modifiedRow(1, 1)])
        // Numstat is ignored for a text section: the rows are the truth.
        let file = changedFile("a.swift").with(lineStats: .counted(added: 99, deleted: 99))
        let changeset = build([(file, a), (changedFile("b.swift"), b), (changedFile("c.swift"), c)])

        #expect(changeset.sections.map(\.added) == [2, 0, 2])
        #expect(changeset.sections.map(\.deleted) == [0, 2, 2])
    }

    // MARK: Block boundaries

    @Test func aBlockSpanningTheFileBoundaryIsSplit() {
        let a = text(["a0"], [], [deletedRow(0)])
        let b = text([], ["b0"], [addedRow(0)])
        let changeset = build([(changedFile("a.swift"), a), (changedFile("b.swift"), b)])

        #expect(changeset.document.rows.count == 2)
        #expect(changeset.document.changeBlocks == [0..<1, 1..<2])
    }

    @Test func blocksInsideOneFileStillMerge() {
        let a = text(["a0", "a1"], ["A0", "A1"], [modifiedRow(0, 0), modifiedRow(1, 1)])
        let changeset = build([(changedFile("a.swift"), a)])
        #expect(changeset.document.changeBlocks == [0..<2])
    }

    // MARK: Sections that contribute nothing

    @Test func nonTextSectionsAreEmptyAndCountFromNumstat() {
        let binary = changedFile("logo.png").with(lineStats: .binary)
        let identical = changedFile("same.swift")
        let failed = changedFile("gone.swift").with(lineStats: .counted(added: 3, deleted: 4))
        let tooLarge = changedFile("huge.json").with(lineStats: .counted(added: 10, deleted: 0))
        let notShown = changedFile("tail.swift")
        let changeset = build([
            (binary, .content(.binary)),
            (identical, .content(.identical)),
            (failed, .failed("could not read")),
            (tooLarge, .tooLarge),
            (notShown, .notShown),
        ])

        #expect(changeset.document.rows.isEmpty)
        #expect(changeset.document.oldLines.isEmpty)
        #expect(changeset.document.newLines.isEmpty)
        #expect(
            changeset.sections.map(\.outcome) == [
                .binary, .identical, .failed("could not read"), .tooLarge, .notShown,
            ])
        #expect(changeset.sections.allSatisfy { $0.rowRange.isEmpty })
        #expect(changeset.sections.allSatisfy { $0.oldLineCount == 0 && $0.newLineCount == 0 })
        #expect(changeset.sections.map(\.added) == [0, 0, 3, 10, 0])
        #expect(changeset.sections.map(\.deleted) == [0, 0, 4, 0, 0])
    }

    @Test func textWithoutChangeBlocksBecomesNoVisibleChanges() {
        let unchanged = text(["a0", "a1"], ["a0", "a1"], [.equal(old: 0, new: 0), .equal(old: 1, new: 1)])
        let file = changedFile("ws.swift").with(lineStats: .counted(added: 1, deleted: 1))
        let changeset = build([(file, unchanged), (changedFile("b.swift"), text(["b0"], ["B0"], [modifiedRow(0, 0)]))])

        #expect(changeset.sections[0].outcome == .noVisibleChanges)
        #expect(changeset.sections[0].rowRange == 0..<0)
        #expect(changeset.sections[0].oldLineCount == 0)
        #expect(changeset.sections[0].added == 1)
        #expect(changeset.sections[0].deleted == 1)
        // It contributed no lines, so the next file starts at zero.
        #expect(changeset.sections[1].rowRange == 0..<1)
        #expect(changeset.sections[1].oldLineOffset == 0)
        #expect(changeset.document.oldLines == ["b0"])
    }

    @Test func emptyChangesetIsEmpty() {
        let changeset = build([])
        #expect(changeset.sections.isEmpty)
        #expect(changeset.document.rows.isEmpty)
        #expect(changeset.revision == 1)
    }

    // MARK: Identity

    @Test func aPathInBothAreasYieldsTwoSections() {
        let staged = changedFile("a.swift", area: .staged)
        let unstaged = changedFile("a.swift", area: .unstaged)
        let changeset = build([
            (staged, text(["a0"], ["A0"], [modifiedRow(0, 0)])),
            (unstaged, text(["A0"], ["B0"], [modifiedRow(0, 0)])),
        ])

        #expect(changeset.sections.count == 2)
        #expect(changeset.sections[0].file.id != changeset.sections[1].file.id)
        #expect(changeset.sections.map(\.rowRange) == [0..<1, 1..<2])
        #expect(changeset.document.changeBlocks == [0..<1, 1..<2])
    }
}
