import Testing

@testable import DiffViewer

struct NavigationTests {
    @Test func nextAndPreviousClampToBlockRange() {
        #expect(ChangeNavigator.next(after: nil, count: 3) == 0)
        #expect(ChangeNavigator.next(after: 0, count: 3) == 1)
        #expect(ChangeNavigator.next(after: 2, count: 3) == 2)
        #expect(ChangeNavigator.previous(before: nil, count: 3) == 0)
        #expect(ChangeNavigator.previous(before: 2, count: 3) == 1)
        #expect(ChangeNavigator.previous(before: 0, count: 3) == 0)
        #expect(ChangeNavigator.next(after: 1, count: 0) == nil)
    }

    /// A changeset passes its file boundaries in, so a deletion ending one file and an
    /// addition starting the next are two changes to walk, not one.
    @Test func boundariesSplitAdjacentRowsIntoSeparateBlocks() {
        let document = DiffDocument(
            oldLines: ["a"], newLines: ["b"], rows: [deletedRow(0), addedRow(0)], language: nil,
            blockBoundaries: [1])
        #expect(document.changeBlocks == [0..<1, 1..<2])
        #expect(ChangeNavigator.next(after: 0, count: 2) == 1)
    }

    @Test func clampHandlesShrinkingBlockLists() {
        #expect(ChangeNavigator.clamp(5, count: 3) == 2)
        #expect(ChangeNavigator.clamp(1, count: 3) == 1)
        #expect(ChangeNavigator.clamp(1, count: 0) == nil)
        #expect(ChangeNavigator.clamp(nil, count: 3) == nil)
    }

    @MainActor
    @Test func debouncerCoalescesBursts() async throws {
        var fires = 0
        let debouncer = Debouncer(interval: .milliseconds(50)) { fires += 1 }
        debouncer.call()
        debouncer.call()
        debouncer.call()
        try await Task.sleep(for: .milliseconds(150))
        #expect(fires == 1)
        debouncer.call()
        try await Task.sleep(for: .milliseconds(150))
        #expect(fires == 2)
    }

    /// Calls arrive more often than `interval`, so only `maxWait` can end the burst.
    @MainActor
    @Test func maxWaitFiresWhileCallsContinueThenStartsANewBurst() async {
        let clock = ManualClock()
        let counter = FireCounter()
        let debouncer = Debouncer(interval: .milliseconds(100), maxWait: .milliseconds(250), clock: clock) {
            counter.fires += 1
        }

        // A call at 0, 80, 160 and 240 ms: the quiet timer never reaches 100 ms.
        for step in 0..<4 {
            if step > 0 { clock.advance(by: .milliseconds(80)) }
            debouncer.call()
            #expect(await eventually { clock.sleeperCount == 2 }, "quiet timer plus the burst deadline")
        }
        #expect(counter.fires == 0)

        clock.advance(by: .milliseconds(10))
        #expect(await eventually { await counter.fires == 1 }, "250 ms after the first call")
        #expect(clock.sleeperCount == 0)

        // The next call is a new burst whose deadline is 250 ms from itself, not from
        // the old first call.
        for _ in 0..<3 {
            debouncer.call()
            #expect(await eventually { clock.sleeperCount == 2 })
            clock.advance(by: .milliseconds(80))
        }
        debouncer.call()
        #expect(await eventually { clock.sleeperCount == 2 })
        #expect(counter.fires == 1, "240 ms into the new burst, before its deadline")

        clock.advance(by: .milliseconds(10))
        #expect(await eventually { await counter.fires == 2 }, "250 ms after the new burst's first call")
    }

    @MainActor
    @Test func withoutMaxWaitRepeatedCallsKeepPostponing() async {
        let clock = ManualClock()
        let counter = FireCounter()
        let debouncer = Debouncer(interval: .milliseconds(100), clock: clock) { counter.fires += 1 }

        for _ in 0..<12 {
            debouncer.call()
            #expect(await eventually { clock.sleeperCount == 1 })
            clock.advance(by: .milliseconds(80))
        }
        #expect(counter.fires == 0)

        clock.advance(by: .milliseconds(20))
        #expect(await eventually { await counter.fires == 1 }, "100 ms after the last call")
    }
}

@MainActor
private final class FireCounter {
    var fires = 0
}
