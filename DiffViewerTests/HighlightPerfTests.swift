import SwiftTreeSitter
import Testing

@testable import DiffViewer

struct HighlightPerfTests {
    private static let bigFile =
        ["func big() {"] + (0..<20000).map { "    let v\($0) = compute(a: \($0), b: \($0 * 2)) // comment \($0)" }
        + ["}"]

    @Test func twentyThousandLineSwiftFile() {
        let lines = Self.bigFile
        let start = ContinuousClock.now
        let runs = Highlighter.highlight(lines: lines, fileName: "big.swift")
        let elapsed = ContinuousClock.now - start
        #expect(runs?.runs.count == lines.count)
        #expect(elapsed < .seconds(10), "highlighting took \(elapsed)")
    }

    /// The outline rides on the highlighter's parse, so its walk must stay a small share of
    /// highlighting. The target is about a tenth of it; the check allows a fifth so a loaded
    /// machine doesn't fail the suite.
    @Test func outlineBuildIsASmallShareOfHighlighting() throws {
        let lines = Self.bigFile
        let text = lines.joined(separator: "\n")
        let config = try #require(LanguageRegistry.configuration(forFileNamed: "big.swift"))
        let rules = try #require(LanguageRegistry.scopeRules(forFileNamed: "big.swift"))
        let parser = Parser()
        try parser.setLanguage(config.language)
        let tree = try #require(parser.parse(text))

        let build = Self.median {
            _ = ScopeOutline.build(tree: tree, text: text, lines: lines, rules: rules)
        }
        let highlight = Self.median {
            _ = Highlighter.highlight(lines: lines, fileName: "big.swift")
        }
        print("outline build median \(build), highlight median \(highlight)")
        #expect(build <= highlight / 5, "outline build \(build) vs highlight \(highlight)")
    }

    private static func median(of iterations: Int = 3, _ work: () -> Void) -> Duration {
        let times = (0..<iterations).map { _ in ContinuousClock().measure(work) }
        return times.sorted()[iterations / 2]
    }
}
