import Testing

@testable import DiffViewer

struct HighlighterTests {
    @Test func languageDetection() {
        #expect(LanguageRegistry.spec(forFileNamed: "App.swift")?.name == "Swift")
        #expect(LanguageRegistry.spec(forFileNamed: "x.TSX")?.name == "TSX")
        #expect(LanguageRegistry.spec(forFileNamed: "Makefile")?.name == "Bash")
        #expect(LanguageRegistry.spec(forFileNamed: "Main.kt")?.name == "Kotlin")
        #expect(LanguageRegistry.spec(forFileNamed: "build.gradle.kts")?.name == "Kotlin")
        #expect(LanguageRegistry.spec(forFileNamed: "notes.txt") == nil)
    }

    @Test func captureNamesMapToStyles() {
        #expect(TokenStyle.from(captureName: "keyword.function") == .keyword)
        #expect(TokenStyle.from(captureName: "string.escape") == .escape)
        #expect(TokenStyle.from(captureName: "variable.member") == .property)
        #expect(TokenStyle.from(captureName: "variable") == .plain)
        #expect(TokenStyle.from(captureName: "markup.heading.1") == .heading)
    }

    @Test func paintStyleSkipsHelpersAndUnknownCapturesButResetsPlainClasses() {
        #expect(TokenStyle.paintStyle(forCaptureName: "keyword.function") == .keyword)
        #expect(TokenStyle.paintStyle(forCaptureName: "variable") == .plain)
        #expect(TokenStyle.paintStyle(forCaptureName: "variable.parameter") == .plain)
        #expect(TokenStyle.paintStyle(forCaptureName: "none") == .plain)
        #expect(TokenStyle.paintStyle(forCaptureName: "_function") == nil)
        #expect(TokenStyle.paintStyle(forCaptureName: "spell") == nil)
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

    @Test func kotlinAnnotationsInterpolationAndReturnsAreStyled() {
        let lines = [
            "@Deprecated(\"old\")",
            "fun greet(who: String): String {",
            "    val msg = \"Hi ${who} $who\" // note",
            "    return msg.trim()",
            "}",
        ]
        let runs = Highlighter.highlight(lines: lines, fileName: "a.kt")
        #expect(runs?.count == 5)
        // The annotation name is an attribute, not a type: the later query pattern wins.
        #expect(runs?[0].contains { $0.style == .attribute && $0.range == 0..<11 } == true)
        #expect(runs?[1].contains { $0.style == .keyword && $0.range == 0..<3 } == true)
        // Interpolated identifiers reset to plain inside the string.
        #expect(runs?[2].contains { $0.style == .string && $0.range == 14..<18 } == true)
        #expect(runs?[2].contains { $0.range.overlaps(20..<23) } == false)
        #expect(runs?[2].contains { $0.range.overlaps(26..<29) } == false)
        #expect(runs?[2].contains { $0.style == .comment && $0.range == 31..<38 } == true)
        // `return` paints the whole jump expression as keyword; the identifier inside resets.
        #expect(runs?[3].contains { $0.style == .keyword && $0.range.lowerBound == 4 } == true)
        #expect(runs?[3].contains { $0.range.overlaps(11..<14) } == false)
        #expect(runs?[3].contains { $0.style == .function && $0.range == 15..<19 } == true)
    }

    @Test func swiftAttributeNameIsAnAttribute() {
        let runs = Highlighter.highlight(lines: ["@MainActor final class A {}"], fileName: "a.swift")
        #expect(runs?[0].contains { $0.style == .attribute && $0.range == 0..<10 } == true)
    }

    @Test func goKeepsEarlierPatternPrecedenceForCalls() {
        let line = "func main() { fmt.Println(len(xs)) }"
        let runs = Highlighter.highlight(lines: [line], fileName: "a.go")
        #expect(runs?[0].contains { $0.style == .function && $0.range == 18..<25 } == true)
        #expect(runs?[0].contains { $0.style == .function && $0.range == 26..<29 } == true)
    }

    @Test func everyBundledGrammarLoads() {
        for name in [
            "a.swift", "a.py", "a.js", "a.ts", "a.tsx", "a.json", "a.go", "a.rs", "a.c", "a.cpp", "a.html", "a.css",
            "a.sh", "a.rb", "a.yml", "a.toml", "a.java", "a.php", "a.md", "a.kt", "a.kts",
        ] {
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
