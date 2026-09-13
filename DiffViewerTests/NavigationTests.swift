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
}
