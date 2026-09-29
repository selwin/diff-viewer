import Testing

@testable import DiffViewer

struct HighlightCacheTests {
    /// Counts fallback calls and returns fixed runs, or nil when `runs` is nil.
    private actor Counter {
        private(set) var calls = 0
        func increment() { calls += 1 }
    }

    private static let runs = [[StyleRun(range: 0..<2, style: .keyword)]]

    private func highlighter(_ cache: HighlightCache, counter: Counter, runs: [[StyleRun]]?)
        -> DiffEngine.Highlight
    {
        cache.highlight(fallback: { _, _ in
            await counter.increment()
            return runs
        })
    }

    @Test func theSameLinesAndFileNameAreHighlightedOnce() async {
        let counter = Counter()
        let highlight = highlighter(HighlightCache(), counter: counter, runs: Self.runs)
        let first = await highlight(["let a = 1"], "a.swift")
        let second = await highlight(["let a = 1"], "a.swift")
        #expect(first == Self.runs)
        #expect(second == first)
        #expect(await counter.calls == 1)
    }

    @Test func aDifferentFileNameOrChangedLinesAreHighlightedAgain() async {
        let counter = Counter()
        let highlight = highlighter(HighlightCache(), counter: counter, runs: Self.runs)
        _ = await highlight(["let a = 1"], "a.swift")
        _ = await highlight(["let a = 1"], "a.py")
        #expect(await counter.calls == 2)
        _ = await highlight(["let a = 2"], "a.swift")
        #expect(await counter.calls == 3)
    }

    @Test func lineBoundariesArePartOfTheKey() async {
        let counter = Counter()
        let highlight = highlighter(HighlightCache(), counter: counter, runs: Self.runs)
        _ = await highlight(["ab"], "a.txt")
        _ = await highlight(["a", "b"], "a.txt")
        #expect(await counter.calls == 2)
    }

    @Test func aNilResultIsNotCached() async {
        let counter = Counter()
        let highlight = highlighter(HighlightCache(), counter: counter, runs: nil)
        #expect(await highlight(["x"], "a.unknown") == nil)
        #expect(await highlight(["x"], "a.unknown") == nil)
        #expect(await counter.calls == 2)
    }
}
