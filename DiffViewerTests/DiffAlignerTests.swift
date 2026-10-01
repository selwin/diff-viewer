import Foundation
import Testing

@testable import DiffViewer

struct DiffAlignerTests {
    @Test func hidingWhitespaceIgnoresOnlyASCIIWhitespace() {
        // Hide Whitespace means `git diff -w`, which ignores ASCII whitespace only.
        let nonBreaking = DiffAligner.align(
            oldLines: ["ab"], newLines: ["a\u{00A0}b"], hideWhitespace: true, hints: DifftHints())
        #expect(nonBreaking.map(\.kind) == [.modified])

        let spaces = DiffAligner.align(oldLines: ["a b"], newLines: ["a  b"], hideWhitespace: true, hints: DifftHints())
        #expect(spaces.map(\.kind) == [.equal])
    }

    @Test func whitespaceOnlyChangeShownHighlightsSpaces() {
        let rows = DiffAligner.align(
            oldLines: ["x = 1"], newLines: ["x  =  1"], hideWhitespace: false, hints: DifftHints())
        #expect(rows.count == 1)
        #expect(rows[0].kind == .modified)
        // Only the two inserted spaces light up, not the `=` between them.
        #expect(rows[0].old?.highlights == [])
        #expect(rows[0].new?.highlights == [2..<3, 4..<5])
    }

    @Test func rewrittenLineWithoutHintsFallsBackToPrefixSuffix() {
        let rows = DiffAligner.align(
            oldLines: ["return total"], newLines: ["print(error)"], hideWhitespace: false, hints: DifftHints())
        #expect(rows[0].old?.highlights == [0..<12])
        #expect(rows[0].new?.highlights == [0..<12])
    }

    @Test func typoInsideDifftTokenNarrowsToChangedCharacter() {
        // difft marks the whole string literal on both sides.
        var hints = DifftHints()
        hints.oldChanges[0] = [8..<20]
        hints.newChanges[0] = [8..<21]
        let rows = DiffAligner.align(
            oldLines: [#"let s = "Helo world""#], newLines: [#"let s = "Hello world""#],
            hideWhitespace: false, hints: hints)
        #expect(rows[0].old?.highlights == [])
        #expect(rows[0].new?.highlights == [12..<13])
    }

    @Test func mostlyChangedDifftTokenStaysWhole() {
        // Myers finds `done` inside `undone`, but the new literal is mostly changed.
        var hints = DifftHints()
        hints.newChanges[0] = [4..<18]
        let rows = DiffAligner.align(
            oldLines: [#"log("done")"#], newLines: [#"log("undone again")"#], hideWhitespace: false, hints: hints)
        #expect(rows[0].old?.highlights == [])
        #expect(rows[0].new?.highlights == [4..<18])
    }

    @Test func characterChangesOutsideDifftTokensAreDropped() {
        // difft marks `,` and `b`; the inserted space between them is not a token.
        var hints = DifftHints()
        hints.newChanges[0] = [6..<7, 8..<9]
        let rows = DiffAligner.align(
            oldLines: ["call(a)"], newLines: ["call(a, b)"], hideWhitespace: false, hints: hints)
        #expect(rows[0].old?.highlights == [])
        #expect(rows[0].new?.highlights == [6..<7, 8..<9])
    }

    @Test func rewrittenLineKeepsDifftTokens() {
        var hints = DifftHints()
        hints.oldChanges[0] = [0..<6, 7..<12]
        hints.newChanges[0] = [0..<5, 6..<11]
        let rows = DiffAligner.align(
            oldLines: ["return total"], newLines: ["print(error)"], hideWhitespace: false, hints: hints)
        #expect(rows[0].old?.highlights == [0..<6, 7..<12])
        #expect(rows[0].new?.highlights == [0..<5, 6..<11])
    }

    @Test func refinedRangesCoverWholeGraphemes() {
        // difft marks only the combining mark: UTF-8 bytes 13..<15, UTF-16 13..<14.
        var hints = DifftHints()
        hints.oldChanges[0] = [13..<15]
        hints.newChanges[0] = [13..<15]
        let rows = DiffAligner.align(
            oldLines: ["let s = \"cafe\u{301}\""], newLines: ["let s = \"cafe\u{300}\""],
            hideWhitespace: false, hints: hints)
        #expect(rows[0].old?.highlights == [12..<14])
        #expect(rows[0].new?.highlights == [12..<14])
    }

    @Test func equalLinesIgnoreDifftHints() {
        // difft treats a multiline string as one atom and flags every line in it.
        var hints = DifftHints()
        hints.oldChanges = [0: [0..<1], 1: [0..<1], 2: [0..<1]]
        hints.newChanges = [0: [0..<1], 1: [0..<1], 2: [0..<1]]
        let rows = DiffAligner.align(
            oldLines: ["a", "b", "c"], newLines: ["a", "x", "c"], hideWhitespace: false, hints: hints)
        #expect(rows.map(\.kind) == [.equal, .modified, .equal])
        #expect(rows[0].old?.highlights == [] && rows[0].new?.highlights == [])
        #expect(rows[2].old?.highlights == [] && rows[2].new?.highlights == [])
    }

    @Test func pureAdditionProducesPadRows() {
        let rows = DiffAligner.align(
            oldLines: ["a", "c"], newLines: ["a", "b", "c"], hideWhitespace: true, hints: DifftHints())
        #expect(rows.map(\.kind) == [.equal, .added, .equal])
        #expect(rows[1].old == nil)
        #expect(rows[1].new?.lineNumber == 2)
    }

    @Test func replacementZipsLinesSideBySide() {
        let rows = DiffAligner.align(
            oldLines: ["a", "b", "c"], newLines: ["x", "y"], hideWhitespace: true, hints: DifftHints())
        #expect(rows.map(\.kind) == [.modified, .modified, .deleted])
        #expect(rows[2].old?.lineNumber == 3)
    }

    @Test func difftPairsDriveAlignmentWithinBlock() {
        // Old lines 0,1 removed; new lines 0,1,2 added; difft says old 1 pairs with new 2.
        var hints = DifftHints()
        hints.pairs = [(1, 2)]
        hints.oldChanges = [1: [0..<1]]
        hints.newChanges = [2: [0..<1]]
        let rows = DiffAligner.align(
            oldLines: ["p", "q"], newLines: ["r", "s", "t"], hideWhitespace: true, hints: hints)
        #expect(rows.map(\.kind) == [.modified, .added, .modified])
        #expect(rows[2].old?.lineNumber == 2 && rows[2].new?.lineNumber == 3)
        #expect(rows[2].new?.highlights == [0..<1])
    }

    @Test func byteRangesBecomeUTF16Ranges() {
        // "let é = 1": '1' is at byte 9 but UTF-16 offset 8.
        #expect(DiffAligner.utf16Ranges([9..<10], in: "let é = 1") == [8..<9])
        // Emoji: 4 bytes, 2 UTF-16 units.
        #expect(DiffAligner.utf16Ranges([0..<4, 4..<5], in: "😀x") == [0..<3])
        #expect(DiffAligner.utf16Ranges([50..<60], in: "short") == [])
    }

    @Test func changeBlocksGroupConsecutiveRows() {
        let rows: [DiffRow] = [
            .equal(old: 0, new: 0),
            DiffRow(kind: .added, old: nil, new: DiffSide(lineIndex: 1, highlights: [])),
            DiffRow(kind: .added, old: nil, new: DiffSide(lineIndex: 2, highlights: [])),
            .equal(old: 1, new: 3),
            DiffRow(kind: .deleted, old: DiffSide(lineIndex: 2, highlights: []), new: nil),
        ]
        let doc = DiffDocument(oldLines: [], newLines: [], rows: rows, language: nil)
        #expect(doc.changeBlocks == [1..<3, 4..<5])
    }

    @Test func splitLinesDropsFinalNewlineOnly() {
        #expect(TextLines.split("a\nb\n") == ["a", "b"])
        #expect(TextLines.split("a\nb") == ["a", "b"])
        #expect(TextLines.split("a\n\n") == ["a", ""])
        #expect(TextLines.split("") == [])
    }
}
