import Foundation
import Testing

@testable import DiffViewer

struct CharacterDiffTests {
    @Test func typoHighlightsOnlyTheInsertedLetter() throws {
        let new = "let s = \"Hello world\""
        let result = try #require(CharacterDiff.ranges(old: "let s = \"Helo world\"", new: new, hideWhitespace: false))
        #expect(result.old == [])
        #expect(result.new == [12..<13])
        let units = Array(new.utf16)
        #expect(units[12] == "l".utf16.first)
    }

    @Test func insertedArgumentHighlightsOnlyTheInsertion() throws {
        let result = try #require(CharacterDiff.ranges(old: "call(a)", new: "call(a, b)", hideWhitespace: false))
        #expect(result.old == [])
        #expect(result.new == [6..<9])
    }

    @Test func rewrittenLineFallsBack() {
        #expect(CharacterDiff.ranges(old: "return total", new: "print(error)", hideWhitespace: false) == nil)
    }

    @Test func mostlyChangedWordSnapsWhole() throws {
        let result = try #require(
            CharacterDiff.ranges(old: "frame.width = 10", new: "frame.height = 10", hideWhitespace: false))
        #expect(result.old == [6..<11])
        #expect(result.new == [6..<12])
    }

    @Test func hiddenWhitespaceIsNeverFlagged() throws {
        let result = try #require(CharacterDiff.ranges(old: "foo(a)", new: "  foo(b)", hideWhitespace: true))
        #expect(result.old == [4..<5])
        #expect(result.new == [6..<7])
    }

    @Test func nonBreakingSpaceStaysAChangeWithWhitespaceHidden() throws {
        let result = try #require(CharacterDiff.ranges(old: "a b", new: "a\u{00A0}b", hideWhitespace: true))
        #expect(result.old == [])
        #expect(result.new == [1..<2])
    }

    @Test func ignorableWhitespaceIsASCIIOnlyAndWholeGrapheme() {
        #expect(DiffAligner.isIgnorableWhitespace(" "))
        #expect(DiffAligner.isIgnorableWhitespace("\t"))
        #expect(DiffAligner.isIgnorableWhitespace("\r\n"))
        #expect(!DiffAligner.isIgnorableWhitespace("\u{00A0}"))
        #expect(!DiffAligner.isIgnorableWhitespace(" \u{301}"))
    }

    @Test func offsetsCountUTF16UnitsAndKeepGraphemesWhole() throws {
        let emoji = try #require(CharacterDiff.ranges(old: "😀 a", new: "😀 b", hideWhitespace: false))
        #expect(emoji.old == [3..<4])
        #expect(emoji.new == [3..<4])

        let combining = try #require(CharacterDiff.ranges(old: "e\u{301}x", new: "e\u{301}y", hideWhitespace: false))
        #expect(combining.old == [2..<3])
        #expect(combining.new == [2..<3])

        let swapped = try #require(CharacterDiff.ranges(old: "a😀b", new: "a😃b", hideWhitespace: false))
        #expect(swapped.old == [1..<3])
        #expect(swapped.new == [1..<3])
    }

    @Test func tabIndentedRangeMapsThroughTabExpansion() throws {
        let line = "\tfoo(y)"
        let result = try #require(CharacterDiff.ranges(old: "\tfoo(x)", new: line, hideWhitespace: false))
        #expect(result.old == [5..<6])
        #expect(result.new == [5..<6])
        let map = try #require(TabExpander.expand(line, tabWidth: 4).map)
        #expect(map[5] == 8)
    }

    @Test func overlongLineFallsBack() {
        let long = String(repeating: "a", count: CharacterDiff.maxUTF16Length + 1)
        #expect(CharacterDiff.ranges(old: long, new: long + "b", hideWhitespace: false) == nil)
    }

    @Test func lineAtTheCapIsCompared() throws {
        let prefix = String(repeating: "a", count: CharacterDiff.maxUTF16Length - 2)
        let result = try #require(CharacterDiff.ranges(old: prefix + "😀", new: prefix + "😃", hideWhitespace: false))
        #expect(result.old == [498..<500])
        #expect(result.new == [498..<500])
    }
}
