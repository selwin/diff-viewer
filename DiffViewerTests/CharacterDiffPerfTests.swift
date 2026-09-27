import Foundation
import Testing

@testable import DiffViewer

struct CharacterDiffPerfTests {
    private static func codeLine(_ i: Int) -> String {
        "    let value\(i) = compute(alpha: first\(i), beta: second\(i * 7)) // adjusts the running total here"
    }

    /// Rewrites are the costly case: Myers runs to completion before the similarity check
    /// rejects them.
    @Test func threeThousandLinePairs() {
        let edits = (0..<2000).map { i in
            let line = Self.codeLine(i)
            return (line, line.replacingOccurrences(of: "compute", with: "compote"))
        }
        let rewrites = (0..<1000).map { i in
            let other = "\tXYZ.QK[\(i)] |= 0b1011; /* 8472 %% JJ */ #pragma VVV {WWW} <<\(i % 97)>> ### !!! ??? ~~~ ^^^"
            return (Self.codeLine(i), other)
        }
        let start = ContinuousClock.now
        let editResults = edits.map { CharacterDiff.ranges(old: $0.0, new: $0.1, hideWhitespace: false) }
        let rewriteResults = rewrites.map { CharacterDiff.ranges(old: $0.0, new: $0.1, hideWhitespace: false) }
        let elapsed = ContinuousClock.now - start
        #expect(editResults.allSatisfy { $0?.new.count == 1 })
        #expect(rewriteResults.allSatisfy { $0 == nil })
        #expect(elapsed < .seconds(10), "character diffs took \(elapsed)")
    }

    /// Sparse one-letter edits in a long file, with difftastic-style token hints, so the
    /// character diff and token refinement run on every modified row.
    @Test func twentyThousandLineFileWithSparseEdits() {
        let oldLines = (0..<20000).map(Self.codeLine)
        var newLines = oldLines
        var hints = DifftHints()
        for i in stride(from: 0, to: oldLines.count, by: 50) {
            newLines[i] = oldLines[i].replacingOccurrences(of: "compute", with: "compote")
            let token = oldLines[i].utf8.firstRange(of: "compute".utf8)!
            let lower = oldLines[i].utf8.distance(from: oldLines[i].utf8.startIndex, to: token.lowerBound)
            hints.oldChanges[i] = [lower..<lower + 7]
            hints.newChanges[i] = [lower..<lower + 7]
            hints.pairs.append((i, i))
        }
        let start = ContinuousClock.now
        let rows = DiffAligner.align(oldLines: oldLines, newLines: newLines, hideWhitespace: false, hints: hints)
        let elapsed = ContinuousClock.now - start
        let modified = rows.filter { $0.kind == .modified }
        #expect(rows.count == oldLines.count)
        #expect(modified.count == 400)
        // Refinement narrowed each seven-letter token to the one changed letter.
        #expect(modified.allSatisfy { $0.new?.highlights.map(\.count) == [1] })
        #expect(elapsed < .seconds(10), "alignment took \(elapsed)")
    }

    /// Many small edits per line, each inside its own difftastic token, so refinement
    /// walks dozens of token and character ranges per row.
    @Test func fragmentedLinesWithManyTokens() {
        let wordCount = 50
        let oldLine = Array(repeating: "abcde", count: wordCount).joined(separator: " ")
        let newLine = Array(repeating: "abXde", count: wordCount).joined(separator: " ")
        let tokens = (0..<wordCount).map { $0 * 6..<$0 * 6 + 5 }
        let lineCount = 300
        var hints = DifftHints()
        for i in 0..<lineCount {
            hints.oldChanges[i] = tokens
            hints.newChanges[i] = tokens
            hints.pairs.append((i, i))
        }
        let start = ContinuousClock.now
        let rows = DiffAligner.align(
            oldLines: Array(repeating: oldLine, count: lineCount),
            newLines: Array(repeating: newLine, count: lineCount), hideWhitespace: false, hints: hints)
        let elapsed = ContinuousClock.now - start
        // Every five-letter token narrows to its one changed letter.
        let expected = (0..<wordCount).map { $0 * 6 + 2..<$0 * 6 + 3 }
        #expect(rows.count == lineCount)
        #expect(rows.allSatisfy { $0.old?.highlights == expected && $0.new?.highlights == expected })
        #expect(elapsed < .seconds(10), "alignment took \(elapsed)")
    }
}
