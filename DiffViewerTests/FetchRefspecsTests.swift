import Testing

@testable import DiffViewer

/// When the app's fetch may prune: only when nothing but remote-tracking refs can go.
struct FetchRefspecsTests {
    private func prunes(_ refspecs: [String]) -> Bool {
        FetchRefspecs.prunesOnlyTrackingRefs(refspecs)
    }

    @Test func theDefaultMappingPrunes() {
        #expect(prunes(["+refs/heads/*:refs/remotes/origin/*"]))
    }

    @Test func aCustomTrackingNamespacePrunes() {
        #expect(prunes(["+refs/heads/*:refs/remotes/company/*"]))
        #expect(prunes(["+refs/heads/*:refs/remotes/origin/*", "refs/heads/main:refs/remotes/mirror/main"]))
    }

    @Test func aTagMappingStopsThePrune() {
        #expect(!prunes(["+refs/heads/*:refs/remotes/origin/*", "refs/tags/*:refs/tags/*"]))
    }

    @Test func aMirrorMappingStopsThePrune() {
        #expect(!prunes(["+refs/*:refs/*"]))
    }

    /// A negative or destination-less refspec stores nothing, so it neither allows nor
    /// stops a prune; with nothing else, there is nothing to prune.
    @Test func refspecsThatStoreNothingDoNotCount() {
        #expect(!prunes([]))
        #expect(!prunes(["^refs/heads/wip/*"]))
        #expect(!prunes(["refs/heads/main", "refs/heads/main:"]))
        #expect(prunes(["+refs/heads/*:refs/remotes/origin/*", "^refs/heads/wip/*", "refs/heads/main"]))
    }
}
