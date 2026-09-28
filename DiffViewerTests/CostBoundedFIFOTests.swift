import Testing

@testable import DiffViewer

struct CostBoundedFIFOTests {
    /// Two entries fit, by count in the first case and by bytes in the second.
    @Test(arguments: [(entries: 2, bytes: 100, cost: 1), (entries: 10, bytes: 20, cost: 10)])
    func theOldestEntryGoesFirstPastALimit(entries: Int, bytes: Int, cost: Int) {
        var fifo = CostBoundedFIFO<String, Int>(entries: entries, bytes: bytes, maxEntryCost: 100)
        #expect(fifo.insert(1, cost: cost, for: "a") == .stored(evicted: 0))
        #expect(fifo.insert(2, cost: cost, for: "b") == .stored(evicted: 0))
        #expect(fifo.insert(3, cost: cost, for: "c") == .stored(evicted: 1))
        #expect(fifo.value(for: "a") == nil)
        #expect(fifo.value(for: "b") == 2)
        #expect(fifo.value(for: "c") == 3)
    }

    @Test func anEntryOverTheCostCapIsRejectedWithoutEvictingAnything() {
        var fifo = CostBoundedFIFO<String, Int>(entries: 10, bytes: 100, maxEntryCost: 5)
        #expect(fifo.insert(1, cost: 5, for: "small") == .stored(evicted: 0))
        #expect(fifo.insert(2, cost: 6, for: "big") == .rejected)
        #expect(fifo.value(for: "big") == nil)
        #expect(fifo.value(for: "small") == 1, "the table is not flushed for an entry it cannot hold")
    }

    /// The byte budget caps what one entry may cost as well: an entry that could never
    /// fit is rejected before it empties the table.
    @Test func anEntryLargerThanTheByteBudgetIsRejectedEvenUnderTheCostCap() {
        var fifo = CostBoundedFIFO<String, Int>(entries: 10, bytes: 5, maxEntryCost: 100)
        #expect(fifo.insert(1, cost: 5, for: "small") == .stored(evicted: 0))
        #expect(fifo.insert(2, cost: 6, for: "big") == .rejected)
        #expect(fifo.value(for: "big") == nil)
        #expect(fifo.value(for: "small") == 1)
    }

    @Test func zeroLimitsRetainNothing() {
        var byCount = CostBoundedFIFO<String, Int>(entries: 0, bytes: 100, maxEntryCost: 100)
        #expect(byCount.insert(1, cost: 1, for: "a") == .skipped)
        #expect(byCount.isEmpty)

        // A zero-cost entry fits any budget; only the explicit check keeps it out.
        var byBytes = CostBoundedFIFO<String, Int>(entries: 10, bytes: 0, maxEntryCost: 100)
        #expect(byBytes.insert(1, cost: 0, for: "a") == .skipped)
        #expect(byBytes.isEmpty)
    }

    @Test func aDuplicateKeyKeepsTheFirstEntryAndCountsItOnce() {
        var fifo = CostBoundedFIFO<String, Int>(entries: 10, bytes: 20, maxEntryCost: 10)
        #expect(fifo.insert(1, cost: 10, for: "a") == .stored(evicted: 0))
        #expect(fifo.insert(2, cost: 10, for: "a") == .skipped)
        #expect(fifo.value(for: "a") == 1)
        #expect(fifo.count == 1)

        // Two entries fit exactly, so "b" evicts nothing only if the duplicate was not
        // charged; "c" then evicts "a", once.
        #expect(fifo.insert(3, cost: 10, for: "b") == .stored(evicted: 0))
        #expect(fifo.insert(4, cost: 10, for: "c") == .stored(evicted: 1))
        #expect(fifo.value(for: "a") == nil)
        #expect(fifo.value(for: "b") == 3)
    }
}
