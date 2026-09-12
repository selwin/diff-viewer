import Testing
@testable import DiffViewer

struct HighlighterTests {
    @Test func languageDetection() {
        #expect(LanguageRegistry.spec(forFileNamed: "App.swift")?.name == "Swift")
        #expect(LanguageRegistry.spec(forFileNamed: "x.TSX")?.name == "TSX")
        #expect(LanguageRegistry.spec(forFileNamed: "Makefile")?.name == "Bash")
        #expect(LanguageRegistry.spec(forFileNamed: "notes.txt") == nil)
    }

    @Test func captureNamesMapToStyles() {
        #expect(TokenStyle.from(captureName: "keyword.function") == .keyword)
        #expect(TokenStyle.from(captureName: "string.escape") == .escape)
        #expect(TokenStyle.from(captureName: "variable.member") == .property)
        #expect(TokenStyle.from(captureName: "variable") == .plain)
        #expect(TokenStyle.from(captureName: "markup.heading.1") == .heading)
    }

    @Test func swiftKeywordsAndCommentsAreStyled() {
        let lines = ["/* multi", "line */ func foo() {", "    return 42", "}"]
        let runs = Highlighter.highlight(lines: lines, fileName: "a.swift")
        #expect(runs?.count == 4)
        #expect(runs?[0].contains { $0.style == .comment && $0.range == 0..<8 } == true)
        #expect(runs?[1].contains { $0.style == .comment && $0.range == 0..<7 } == true)
        #expect(runs?[1].contains { $0.style == .keyword && $0.range == 8..<12 } == true)
        #expect(runs?[2].contains { $0.style == .number && $0.range == 11..<13 } == true)
    }

    @Test func everyBundledGrammarLoads() {
        for name in ["a.swift", "a.py", "a.js", "a.ts", "a.tsx", "a.json", "a.go", "a.rs", "a.c", "a.cpp", "a.html", "a.css", "a.sh", "a.rb", "a.yml", "a.toml", "a.java", "a.php", "a.md"] {
            let config = LanguageRegistry.configuration(forFileNamed: name)
            #expect(config != nil, "\(name) failed to load")
            #expect(config?.queries[.highlights] != nil, "\(name) has no highlights query")
        }
    }

    @Test func unknownLanguageReturnsNil() {
        #expect(Highlighter.highlight(lines: ["hello"], fileName: "a.txt") == nil)
    }

    @Test func painterSplitsRangesAcrossLines() {
        var painter = Highlighter.LinePainter(lines: ["ab", "cd", "ef"])
        painter.paint(start: 1, end: 7, style: .string)
        let runs = painter.runs()
        #expect(runs[0] == [StyleRun(range: 1..<2, style: .string)])
        #expect(runs[1] == [StyleRun(range: 0..<2, style: .string)])
        #expect(runs[2] == [StyleRun(range: 0..<1, style: .string)])
    }
}
