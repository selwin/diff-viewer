import Testing

@testable import DiffViewer

/// Line numbers and gutter width for a pane that shows a whole changeset: numbering is
/// file-local, so every file starts again at 1.
struct PaneModelTests {
    /// Three rows per text file. The second file's two sides start at different offsets,
    /// so a lookup that read the other side's offset would come out wrong.
    private let rows = [
        modifiedRow(0, 0), modifiedRow(1, 1), modifiedRow(2, 2),
        modifiedRow(3, 5), modifiedRow(4, 6), modifiedRow(5, 7),
    ]
    private let oldLines = (0..<6).map { "old \($0)" }
    private let newLines = (0..<8).map { "new \($0)" }

    private func section(
        _ path: String, rowRange: Range<Int>, old: (offset: Int, count: Int), new: (offset: Int, count: Int),
        outcome: FileOutcome = .text(language: nil)
    ) -> ChangesetSection {
        ChangesetSection(
            file: changedFile(path), rowRange: rowRange, oldLineOffset: old.offset, newLineOffset: new.offset,
            oldLineCount: old.count, newLineCount: new.count, added: new.count, deleted: old.count, outcome: outcome)
    }

    /// Two text files with an empty binary section between them, which starts exactly
    /// where the second file's rows do. The first file grew by two lines, so the second
    /// file's old and new offsets differ.
    private var sections: [ChangesetSection] {
        [
            section("first.swift", rowRange: 0..<3, old: (0, 3), new: (0, 5)),
            section("logo.png", rowRange: 3..<3, old: (3, 0), new: (5, 0), outcome: .binary),
            section("second.swift", rowRange: 3..<6, old: (3, 3), new: (5, 3)),
        ]
    }

    private func model(_ side: PaneModel.Side, sections: [ChangesetSection]) -> PaneModel {
        PaneModel(side: side, rows: rows, lines: side == .old ? oldLines : newLines, sections: sections)
    }

    /// This side's cell of the row at `index`, which is what the pane draws from.
    private func number(_ pane: PaneModel, row index: Int) -> Int? {
        guard let cell = pane.cell(rows[index]) else { return nil }
        return pane.lineNumber(of: cell, inRow: index)
    }

    @Test func emptySectionOnABoundaryIsNeverChosen() {
        let pane = model(.old, sections: sections)
        #expect(pane.section(containingRow: 2)?.file.path == "first.swift")
        #expect(pane.section(containingRow: 3)?.file.path == "second.swift")
        #expect(pane.section(containingRow: 6) == nil)
    }

    @Test func lineNumbersRestartInEachSection() {
        for side in [PaneModel.Side.old, .new] {
            let pane = model(side, sections: sections)
            #expect(number(pane, row: 0) == 1)
            #expect(number(pane, row: 3) == 1)
            #expect(number(pane, row: 5) == 3)
        }
    }

    @Test func lineNumbersAreGlobalWithoutSections() {
        #expect(number(model(.old, sections: []), row: 3) == 4)
        #expect(number(model(.new, sections: []), row: 3) == 6)
    }

    @Test func gutterFitsTheWidestSection() {
        // Short files, so both sides fall back to the minimum: four digits for a
        // changeset, where later sections arrive after the width is set, three for a file.
        #expect(model(.old, sections: sections).gutterDigits == 4)
        #expect(model(.old, sections: []).gutterDigits == 3)

        let wide = [section("huge.swift", rowRange: 0..<6, old: (0, 1), new: (0, 12345))]
        #expect(model(.new, sections: wide).gutterDigits == 5)
    }

    @Test func gutterKeepsTheChangesetMinimumBeforeAnyTextArrives() {
        // A prefix of notices only: the gutter already reserves the changeset minimum, so
        // it does not widen when the first text section lands.
        let notices = [section("logo.png", rowRange: 0..<0, old: (0, 0), new: (0, 0), outcome: .binary)]
        #expect(PaneModel(side: .old, rows: [], lines: [], sections: notices).gutterDigits == 4)
    }
}
