import Foundation
import Testing

@testable import DiffViewer

/// A key derived from `name`, so distinct names are distinct keys.
private func key(_ name: String, fileName: String = "a.swift", hideWhitespace: Bool = false) -> DiffResultCache.Key {
    DiffResultCache.Key(
        difftKey: DifftCache.key(old: Data(name.utf8), new: Data("\(name)!".utf8), fileName: fileName),
        hideWhitespace: hideWhitespace)
}

/// An entry of `rows` lines per side, so its cost grows with `rows`.
private func entry(rows: Int = 4) -> DiffResultCache.Entry {
    guard case let .text(document) = textContent(rows: rows, modified: [0..<1]) else { fatalError("text expected") }
    let runs = document.newLines.map { _ in [StyleRun(range: 0..<1, style: .keyword)] }
    return DiffResultCache.Entry(document: document, styles: SyntaxStyles(old: runs, new: runs))
}

struct DiffResultCacheTests {
    // MARK: Lookup

    @Test func hitsAndMissesAreCounted() async {
        let cache = DiffResultCache()
        let stored = entry()
        #expect(await cache.entry(for: key("a")) == nil)
        await cache.store(stored, for: key("a"))
        #expect(await cache.entry(for: key("a"))?.document.id == stored.document.id)
        #expect(await cache.stats == DiffResultCache.Stats(hits: 1, misses: 1, evictions: 0, rejected: 0))
    }

    @Test func whitespaceModeAndFileNameAreBothPartOfTheKey() async {
        let cache = DiffResultCache()
        await cache.store(entry(), for: key("a"))
        #expect(await cache.entry(for: key("a", hideWhitespace: true)) == nil, "the other whitespace mode misses")
        #expect(await cache.entry(for: key("a", fileName: "a.py")) == nil, "same bytes under another name miss")
        #expect(await cache.entry(for: key("a")) != nil)
    }

    // MARK: Eviction

    @Test func theOldestEntryGoesFirstWhenTheCountIsExceeded() async {
        let cache = DiffResultCache(limits: DiffResultCache.Limits(entries: 2))
        for name in ["a", "b", "c"] { await cache.store(entry(), for: key(name)) }
        #expect(await cache.entry(for: key("a")) == nil)
        #expect(await cache.entry(for: key("b")) != nil)
        #expect(await cache.entry(for: key("c")) != nil)
        #expect(await cache.stats.evictions == 1)
    }

    @Test func theOldestEntryGoesFirstWhenTheByteBudgetIsExceeded() async {
        let one = entry()
        let cache = DiffResultCache(limits: DiffResultCache.Limits(bytes: one.cost * 2, maxEntryCost: one.cost))
        for name in ["a", "b", "c"] { await cache.store(entry(), for: key(name)) }
        #expect(await cache.entry(for: key("a")) == nil)
        #expect(await cache.entry(for: key("b")) != nil)
        #expect(await cache.entry(for: key("c")) != nil)
        #expect(await cache.stats.evictions == 1)
    }

    @Test func anEntryOverTheCostCapIsRejectedWithoutEvictingAnything() async {
        let small = entry(rows: 2)
        let big = entry(rows: 40)
        let cache = DiffResultCache(limits: DiffResultCache.Limits(maxEntryCost: small.cost))
        await cache.store(small, for: key("small"))
        await cache.store(big, for: key("big"))
        #expect(await cache.entry(for: key("big")) == nil)
        #expect(await cache.entry(for: key("small")) != nil, "the table is not flushed for an entry it cannot hold")
        #expect(await cache.stats.evictions == 0)
        #expect(await cache.stats.rejected == 1)
    }

    /// The byte budget caps what one entry may cost as well: an entry that could never
    /// fit is rejected before it empties the table.
    @Test func anEntryLargerThanTheByteBudgetIsRejectedEvenUnderTheCostCap() async {
        let small = entry(rows: 2)
        let big = entry(rows: 40)
        let cache = DiffResultCache(limits: DiffResultCache.Limits(bytes: small.cost, maxEntryCost: big.cost))
        await cache.store(small, for: key("small"))
        await cache.store(big, for: key("big"))
        #expect(await cache.entry(for: key("big")) == nil)
        #expect(await cache.entry(for: key("small")) != nil)
        #expect(await cache.stats.rejected == 1)
    }

    @Test func zeroLimitsRetainNothing() async {
        let byCount = DiffResultCache(limits: DiffResultCache.Limits(entries: 0))
        await byCount.store(entry(), for: key("a"))
        #expect(await byCount.entry(for: key("a")) == nil)
        #expect(await byCount.isEmpty)

        let byBytes = DiffResultCache(limits: DiffResultCache.Limits(bytes: 0))
        await byBytes.store(entry(), for: key("a"))
        #expect(await byBytes.entry(for: key("a")) == nil)
        #expect(await byBytes.isEmpty)

        // A zero-cost entry fits any budget; only the explicit check keeps it out.
        let free = DiffResultCache.Entry(document: .empty(), styles: SyntaxStyles(old: nil, new: nil))
        #expect(free.cost == 0)
        await byBytes.store(free, for: key("b"))
        #expect(await byBytes.isEmpty)
    }

    // MARK: Duplicate stores

    @Test func aDuplicateStoreKeepsTheFirstEntryAndCountsItOnce() async {
        let first = entry()
        let cache = DiffResultCache(limits: DiffResultCache.Limits(bytes: first.cost * 2))
        await cache.store(first, for: key("a"))
        await cache.store(entry(), for: key("a"))
        #expect(await cache.entry(for: key("a"))?.document.id == first.document.id)
        #expect(await cache.count == 1)

        // Two entries fit exactly, so "b" evicts nothing only if the duplicate was not
        // charged; "c" then evicts "a", once.
        await cache.store(entry(), for: key("b"))
        #expect(await cache.entry(for: key("a")) != nil, "the duplicate did not count against the budget")
        await cache.store(entry(), for: key("c"))
        #expect(await cache.entry(for: key("a")) == nil)
        #expect(await cache.entry(for: key("b")) != nil)
        #expect(await cache.stats.evictions == 1)
    }
}

// MARK: - DiffEngine.build

private func probeCache(_ probe: RunnerProbe) -> DifftCache {
    DifftCache(runner: { old, new, fileName, qos in
        try await probe.run(old: old, new: new, fileName: fileName, qualityOfService: qos)
    })
}

private func sources(_ fileName: String) -> DiffEngine.Sources {
    DiffEngine.Sources(old: Data("a\nb\n".utf8), new: Data("a\nc\n".utf8), fileName: fileName)
}

struct DiffEngineResultCacheTests {
    @Test func aSecondIdenticalBuildRunsNeitherDifftNorTheHighlighter() async throws {
        let probe = RunnerProbe()
        let cache = probeCache(probe)
        let resultCache = DiffResultCache()
        let highlighter = HighlighterProbe()

        let first = try await DiffEngine.build(
            sources("a.swift"), hideWhitespace: false, cache: cache, resultCache: resultCache, priority: .foreground,
            highlight: highlighter.callback())
        #expect(await probe.launches.count == 1)
        #expect(await highlighter.fileNames == ["a.swift", "a.swift"])
        #expect(first.styles?.new?.count == 2)

        let second = try await DiffEngine.build(
            sources("a.swift"), hideWhitespace: false, cache: cache, resultCache: resultCache, priority: .foreground,
            highlight: highlighter.callback())
        #expect(await probe.launches.count == 1)
        #expect(await highlighter.fileNames.count == 2)
        guard case let .text(document) = first.content, case let .text(again) = second.content else {
            Issue.record("text expected")
            return
        }
        #expect(again.id == document.id, "the same document comes back")
        #expect(second.styles?.new?.count == 2)
        #expect(await resultCache.stats.hits == 1)
    }

    /// A file the highlighter cannot colour is still a finished result.
    @Test func anUnhighlightedResultStillHits() async throws {
        let probe = RunnerProbe()
        let cache = probeCache(probe)
        let resultCache = DiffResultCache()
        let highlighter = HighlighterProbe()

        let first = try await DiffEngine.build(
            sources("a.txt"), hideWhitespace: false, cache: cache, resultCache: resultCache, priority: .foreground,
            highlight: highlighter.callback())
        #expect(first.styles?.old == nil && first.styles?.new == nil)
        _ = try await DiffEngine.build(
            sources("a.txt"), hideWhitespace: false, cache: cache, resultCache: resultCache, priority: .foreground,
            highlight: highlighter.callback())
        #expect(await probe.launches.count == 1)
        #expect(await highlighter.fileNames.count == 2)
        #expect(await resultCache.stats.hits == 1)
    }

    /// Without difft the document is a plain line diff, which must be rebuilt once
    /// difft is back rather than remembered for good.
    @Test func aDifftFailureIsNotStoredButALaterSuccessIs() async throws {
        let probe = RunnerProbe()
        await probe.fail(true)
        let cache = probeCache(probe)
        let resultCache = DiffResultCache()

        let failed = try await DiffEngine.build(
            sources("a.swift"), hideWhitespace: false, cache: cache, resultCache: resultCache, priority: .foreground,
            highlight: HighlighterProbe().callback())
        guard case let .text(fallback) = failed.content else {
            Issue.record("text expected")
            return
        }
        #expect(fallback.language == nil)
        #expect(await resultCache.isEmpty)

        // The failure is remembered by the difft cache; a fresh one stands in for expiry.
        await probe.fail(false)
        let succeeded = try await DiffEngine.build(
            sources("a.swift"), hideWhitespace: false, cache: probeCache(probe), resultCache: resultCache,
            priority: .foreground, highlight: HighlighterProbe().callback())
        guard case let .text(document) = succeeded.content else {
            Issue.record("text expected")
            return
        }
        #expect(document.language == "Swift")
        #expect(await resultCache.count == 1)
    }

    /// Cancellation between the two side highlights: the build throws and the second
    /// side is never parsed.
    @Test func aBuildCancelledDuringTheFirstHighlightNeverStartsTheSecond() async {
        let probe = RunnerProbe()
        let cache = probeCache(probe)
        let resultCache = DiffResultCache()
        let highlighter = HighlighterProbe()
        await highlighter.hold(["a.swift"])

        let task = Task {
            try await DiffEngine.build(
                sources("a.swift"), hideWhitespace: false, cache: cache, resultCache: resultCache,
                priority: .foreground, highlight: highlighter.callback())
        }
        #expect(await eventually { await highlighter.fileNames.count == 1 }, "the first side is being highlighted")
        task.cancel()
        await highlighter.release("a.swift")

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await highlighter.fileNames.count == 1, "the second side never started")
        #expect(await resultCache.isEmpty)
    }
}
