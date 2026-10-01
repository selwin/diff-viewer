import Testing

@testable import DiffViewer

@Suite struct NativeWindowRegistryTests {
    let a = WindowID()
    let b = WindowID()
    let c = WindowID()
    let d = WindowID()
    let x = WindowID()

    private func arrange(_ ids: [WindowID], groups: [[WindowID]]) -> [WindowID] {
        NativeWindowRegistry.arrange(ids) { id in groups.first { $0.contains(id) } }
    }

    @Test func oneGroupIsReordered() {
        #expect(arrange([a, b, c], groups: [[c, a, b]]) == [c, a, b])
    }

    @Test func groupIsPlacedAtItsFirstMember() {
        #expect(arrange([a, x, b], groups: [[b, a]]) == [b, a, x])
    }

    @Test func twoGroupsAndAStandaloneWindow() {
        #expect(arrange([a, x, c, b, d], groups: [[b, a], [d, c]]) == [b, a, x, d, c])
    }

    @Test func groupMembersOutsideTheInputAreExcludedAndNothingRepeats() {
        #expect(arrange([a, b], groups: [[c, b, a, b]]) == [b, a])
    }

    @Test func repeatedInputIDIsEmittedOnce() {
        #expect(arrange([a, x, a], groups: []) == [a, x])
    }

    @Test func emptyGroupStillEmitsTheIDOnce() {
        let result = NativeWindowRegistry.arrange([a, b]) { _ in [] }
        #expect(result == [a, b])
    }

    @Test func groupMissingTheQueriedIDStillEmitsItOnce() {
        #expect(NativeWindowRegistry.arrange([a, b]) { _ in [b] } == [b, a])
    }

    @Test func idsWithoutAGroupKeepTheirRelativeOrder() {
        let result = NativeWindowRegistry.arrange([c, a, b]) { _ in nil }
        #expect(result == [c, a, b])
    }
}
