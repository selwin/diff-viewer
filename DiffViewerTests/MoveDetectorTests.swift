import Foundation
import Testing

@testable import DiffViewer

struct MoveDetectorTests {
    /// Aligns the texts as the engine does (no difft hints) and detects moves.
    private func moves(_ old: [String], _ new: [String], hideWhitespace: Bool = false) -> (
        moves: [DiffMove], rows: [DiffRow]
    ) {
        let rows = DiffAligner.align(oldLines: old, newLines: new, hideWhitespace: hideWhitespace, hints: DifftHints())
        return (detect(old, new, rows, hideWhitespace: hideWhitespace), rows)
    }

    private func detect(_ old: [String], _ new: [String], _ rows: [DiffRow], hideWhitespace: Bool = false)
        -> [DiffMove]
    {
        MoveDetector.detect(
            oldLines: old, newLines: new, rows: rows, changeBlocks: DiffDocument.changeBlocks(of: rows),
            hideWhitespace: hideWhitespace)
    }

    private func row(old line: Int, in rows: [DiffRow]) -> Int { rows.firstIndex { $0.old?.lineIndex == line }! }
    private func row(new line: Int, in rows: [DiffRow]) -> Int { rows.firstIndex { $0.new?.lineIndex == line }! }

    private let block = [
        "func total(of items: [Item]) -> Int {",
        "    items.reduce(0) { $0 + $1.price }",
        "}",
    ]
    /// Longer than `block`, so the alignment keeps these equal and moves the block instead.
    private let middle = ["let a = 1", "let b = 2", "let c = 3", "let d = 4"]

    private func indented(_ lines: [String]) -> [String] { lines.map { "    " + $0 } }

    // MARK: Finding moves

    @Test func movedBlockIsFound() {
        let (found, rows) = moves(
            ["// head"] + block + middle + ["// foot"], ["// head"] + middle + block + ["// foot"])
        #expect(found.count == 1)
        #expect(found.first?.oldLineRange == 1..<4)
        #expect(found.first?.newLineRange == 5..<8)
        #expect(found.first?.oldRowRange == row(old: 1, in: rows)..<(row(old: 3, in: rows) + 1))
        #expect(found.first?.newRowRange == row(new: 5, in: rows)..<(row(new: 7, in: rows) + 1))
    }

    @Test func reindentedBlockIsFound() {
        let (found, _) = moves(
            ["// head"] + block + middle + ["// foot"], ["// head"] + middle + indented(block) + ["// foot"])
        #expect(found.map(\.oldLineRange) == [1..<4])
        #expect(found.map(\.newLineRange) == [5..<8])
    }

    @Test func interiorSpacingMattersUnlessWhitespaceIsHidden() {
        let respaced = block.map { $0.replacingOccurrences(of: " -> ", with: "  ->  ") }
        let old = ["// head"] + block + middle + ["// foot"]
        let new = ["// head"] + middle + respaced + ["// foot"]
        // Only the first line changed spacing; the other two are still a move, but too
        // small on their own.
        #expect(moves(old, new, hideWhitespace: false).moves.isEmpty)
        #expect(moves(old, new, hideWhitespace: true).moves.map(\.newLineRange) == [5..<8])
    }

    @Test func blockUnderTheSizeBarIsNotAMove() {
        let small = ["x = 1", "y = 2"]
        let (found, _) = moves(["// head"] + small + middle + ["// foot"], ["// head"] + middle + small + ["// foot"])
        #expect(found.isEmpty)
    }

    @Test func inPlaceEditIsNotAMove() {
        // Re-indenting in place changes every line, but old and new share one block.
        let (found, rows) = moves(["// head"] + block + ["// foot"], ["// head"] + indented(block) + ["// foot"])
        #expect(DiffDocument.changeBlocks(of: rows).count == 1)
        #expect(found.isEmpty)
    }

    @Test func movedTextInModifiedRowsIsFound() {
        // The removed "unrelated" line zips beside the pasted block's first line.
        let unrelated = "let unrelated = true"
        let (found, rows) = moves(
            ["// head"] + block + middle + [unrelated, "// foot"], ["// head"] + middle + block + ["// foot"])
        let destination = row(new: 5, in: rows)
        #expect(rows[destination].kind == .modified)
        #expect(rows[destination].old?.lineIndex == 8)
        #expect(found.map(\.oldLineRange) == [1..<4])
        #expect(found.map(\.newLineRange) == [5..<8])
    }

    @Test func rowRangeSpansAnAddedOnlyRowBetweenMovedLines() {
        let old = ["let first = computeFirstValue()", "let second = computeSecondValue()", "anchor"]
        let new = ["unrelated", "anchor", old[0], old[1]]
        let rows = [deletedRow(0), addedRow(0), deletedRow(1), DiffRow.equal(old: 2, new: 1), addedRow(2), addedRow(3)]
        let found = detect(old, new, rows)
        #expect(found == [DiffMove(oldLineRange: 0..<2, newLineRange: 2..<4, oldRowRange: 0..<3, newRowRange: 4..<6)])
    }

    // MARK: Overlaps

    @Test func blockPastedTwiceMatchesTheEarlierDestination() {
        let (found, _) = moves(
            ["// head"] + block + middle + ["// foot"],
            ["// head"] + middle + indented(block) + ["let spacer = 0"] + indented(block) + ["// foot"])
        #expect(found.map(\.oldLineRange) == [1..<4])
        #expect(found.map(\.newLineRange) == [5..<8])
    }

    @Test func overlappedRunKeepsARemainderThatMeetsTheBar() {
        let a = "let alpha = makeAlpha()"
        let b = "let bravo = makeBravo()"
        let c = "let charlie = makeCharlie()"
        let d = "let delta = makeDelta(charlie)"
        // New pastes a, b, c together and c, d again; the second run loses c to the first.
        let (found, rows) = moves(
            ["// head", a, b, c, d] + middle + ["// foot"],
            ["// head"] + middle + indented([a, b, c, c, d]) + ["// foot"])
        #expect(found.count == 2)
        #expect(found.first?.oldLineRange == 1..<4)
        #expect(found.first?.newLineRange == 5..<8)
        let remainder = found.last
        #expect(remainder?.oldLineRange == 4..<5)
        #expect(remainder?.newLineRange == 9..<10)
        #expect(remainder?.oldRowRange == row(old: 4, in: rows)..<(row(old: 4, in: rows) + 1))
        #expect(remainder?.newRowRange == row(new: 9, in: rows)..<(row(new: 9, in: rows) + 1))
    }

    @Test func overlappedRunDropsARemainderUnderTheBar() {
        let a = "let alpha = makeAlpha()"
        let b = "let bravo = makeBravo()"
        let c = "let charlie = makeCharlie()"
        let d = "d()"
        let (found, _) = moves(
            ["// head", a, b, c, d] + middle + ["// foot"],
            ["// head"] + middle + indented([a, b, c, c, d]) + ["// foot"])
        #expect(found.map(\.oldLineRange) == [1..<4])
        #expect(found.map(\.newLineRange) == [5..<8])
    }

    // MARK: Common lines

    /// One removed line pasted `copies` times after an equal anchor.
    private func pasted(_ line: String, copies: Int) -> [DiffMove] {
        let rows = [deletedRow(0), DiffRow.equal(old: 1, new: 0)] + (1...copies).map(addedRow)
        return detect([line, "anchor"], ["anchor"] + Array(repeating: line, count: copies), rows)
    }

    @Test func overLimitKeyDoesNotStartARun() {
        let line = "let distinctive = computeSomethingLong()"
        #expect(pasted(line, copies: MoveDetector.maxStartOccurrences).map(\.newLineRange) == [1..<2])
        #expect(pasted(line, copies: MoveDetector.maxStartOccurrences + 1).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func thousandsOfRepeatedLinesFinishWithoutMoves() {
        let count = 5000
        let line = "total += computeValue(item)"
        let rows = (0..<count).map(deletedRow) + [DiffRow.equal(old: count, new: 0)] + (1...count).map(addedRow)
        let found = detect(
            Array(repeating: line, count: count) + ["anchor"], ["anchor"] + Array(repeating: line, count: count), rows)
        #expect(found.isEmpty)
    }

    @Test func blockStartingWithBlankAndOverLimitLinesIsFound() {
        // 70 added braces put "}" over the start limit; the blank line never starts a run.
        let moved = ["", "}", "func distinctiveName() {", "    return computeSomething(alpha)", "}"]
        let braces = Array(repeating: "}", count: 70)
        let (found, _) = moves(
            ["// head"] + moved + middle + ["// foot"], ["// head"] + middle + braces + indented(moved) + ["// foot"])
        // The run starts at the first distinctive line and extends through the brace.
        #expect(found.map(\.oldLineRange) == [3..<6])
        #expect(found.map(\.newLineRange) == [(5 + 70 + 2)..<(5 + 70 + 5)])
    }

    @Test(.timeLimit(.minutes(1)))
    func largeBlockPastedManyTimesYieldsOneMove() {
        let size = 200
        let copies = MoveDetector.maxStartOccurrences
        let lines = (0..<size).map { "let value\($0) = compute(\($0))" }
        let new = ["anchor"] + (0..<copies).flatMap { _ in lines }
        let rows = (0..<size).map(deletedRow) + [DiffRow.equal(old: size, new: 0)] + (1..<new.count).map(addedRow)
        let found = detect(lines + ["anchor"], new, rows)
        #expect(found.map(\.oldLineRange) == [0..<size])
        #expect(found.map(\.newLineRange) == [1..<(size + 1)])
    }
}
