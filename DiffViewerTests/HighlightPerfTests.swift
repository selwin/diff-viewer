import Testing
@testable import DiffViewer

struct HighlightPerfTests {
    @Test func twentyThousandLineSwiftFile() {
        let lines =
            ["func big() {"] + (0..<20000).map { "    let v\($0) = compute(a: \($0), b: \($0 * 2)) // comment \($0)" }
            + ["}"]
        let start = ContinuousClock.now
        let runs = Highlighter.highlight(lines: lines, fileName: "big.swift")
        let elapsed = ContinuousClock.now - start
        #expect(runs?.count == lines.count)
        #expect(elapsed < .seconds(10), "highlighting took \(elapsed)")
    }
}
