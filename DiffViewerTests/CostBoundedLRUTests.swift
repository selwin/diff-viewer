import Testing

@testable import DiffViewer

struct CostBoundedLRUTests {
    /// Two entries fit, by count in the first case and by bytes in the second.
    @Test(arguments: [(entries: 2, bytes: 100, cost: 1), (entries: 10, bytes: 20, cost: 10)])
    func theLeastRecentlyUsedEntryGoesFirstPastALimit(entries: Int, bytes: Int, cost: Int) {
        var lru = CostBoundedLRU<String, Int>(entries: entries, bytes: bytes, maxEntryCost: 100)
        #expect(lru.insert(1, cost: cost, for: "a") == .stored(evicted: 0))
        #expect(lru.insert(2, cost: cost, for: "b") == .stored(evicted: 0))
        #expect(lru.insert(3, cost: cost, for: "c") == .stored(evicted: 1))
        #expect(lru.value(for: "a") == nil)
        #expect(lru.value(for: "b") == 2)
        #expect(lru.value(for: "c") == 3)
    }

    @Test func aReadEntryOutlivesTheOneInsertedAfterIt() {
        var lru = CostBoundedLRU<String, Int>(entries: 2, bytes: 100, maxEntryCost: 100)
        _ = lru.insert(1, cost: 1, for: "a")
        _ = lru.insert(2, cost: 1, for: "b")
        #expect(lru.value(for: "a") == 1)
        #expect(lru.insert(3, cost: 1, for: "c") == .stored(evicted: 1))
        #expect(lru.value(for: "b") == nil)
        #expect(lru.value(for: "a") == 1)
        #expect(lru.value(for: "c") == 3)
    }

    /// Storing a key again means its content was just rebuilt, so it counts as a use.
    @Test func reinsertingAStoredKeyCountsAsAUse() {
        var lru = CostBoundedLRU<String, Int>(entries: 2, bytes: 100, maxEntryCost: 100)
        _ = lru.insert(1, cost: 1, for: "a")
        _ = lru.insert(2, cost: 1, for: "b")
        #expect(lru.insert(9, cost: 1, for: "a") == .skipped)
        #expect(lru.insert(3, cost: 1, for: "c") == .stored(evicted: 1))
        #expect(lru.value(for: "b") == nil)
        #expect(lru.value(for: "a") == 1)
    }

    @Test func anEntryOverTheCostCapIsRejectedWithoutEvictingAnything() {
        var lru = CostBoundedLRU<String, Int>(entries: 10, bytes: 100, maxEntryCost: 5)
        #expect(lru.insert(1, cost: 5, for: "small") == .stored(evicted: 0))
        #expect(lru.insert(2, cost: 6, for: "big") == .rejected)
        #expect(lru.value(for: "big") == nil)
        #expect(lru.value(for: "small") == 1, "the table is not flushed for an entry it cannot hold")
    }

    /// The byte budget caps what one entry may cost as well: an entry that could never
    /// fit is rejected before it empties the table.
    @Test func anEntryLargerThanTheByteBudgetIsRejectedEvenUnderTheCostCap() {
        var lru = CostBoundedLRU<String, Int>(entries: 10, bytes: 5, maxEntryCost: 100)
        #expect(lru.insert(1, cost: 5, for: "small") == .stored(evicted: 0))
        #expect(lru.insert(2, cost: 6, for: "big") == .rejected)
        #expect(lru.value(for: "big") == nil)
        #expect(lru.value(for: "small") == 1)
    }

    @Test func zeroLimitsRetainNothing() {
        var byCount = CostBoundedLRU<String, Int>(entries: 0, bytes: 100, maxEntryCost: 100)
        #expect(byCount.insert(1, cost: 1, for: "a") == .skipped)
        #expect(byCount.isEmpty)

        // A zero-cost entry fits any budget; only the explicit check keeps it out.
        var byBytes = CostBoundedLRU<String, Int>(entries: 10, bytes: 0, maxEntryCost: 100)
        #expect(byBytes.insert(1, cost: 0, for: "a") == .skipped)
        #expect(byBytes.isEmpty)
    }

    @Test func aDuplicateKeyKeepsTheFirstEntryAndCountsItOnce() {
        var lru = CostBoundedLRU<String, Int>(entries: 10, bytes: 20, maxEntryCost: 10)
        #expect(lru.insert(1, cost: 10, for: "a") == .stored(evicted: 0))
        #expect(lru.insert(2, cost: 10, for: "a") == .skipped)
        #expect(lru.value(for: "a") == 1)
        #expect(lru.count == 1)

        // Two entries fit exactly, so "b" evicts nothing only if the duplicate was not
        // charged; "c" then evicts "a", once.
        #expect(lru.insert(3, cost: 10, for: "b") == .stored(evicted: 0))
        #expect(lru.insert(4, cost: 10, for: "c") == .stored(evicted: 1))
        #expect(lru.value(for: "a") == nil)
        #expect(lru.value(for: "b") == 3)
    }
}
