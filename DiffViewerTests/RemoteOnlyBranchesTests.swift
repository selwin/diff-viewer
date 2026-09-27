import Foundation
import Testing

@testable import DiffViewer

struct RemoteOnlyBranchesTests {
    @Test func aTrackedRefIsDropped() {
        let locals = [localBranch("foo", upstream: upstream("origin/foo"))]
        let remotes = [remoteBranch("foo"), remoteBranch("bar")]
        #expect(RemoteOnlyBranches.filter(remotes: remotes, locals: locals).map(\.ref) == ["refs/remotes/origin/bar"])
    }

    /// Matching is by the tracked ref, never by name alone.
    @Test func aSameNamedLocalThatTracksSomethingElseKeepsTheRemote() {
        let remotes = [remoteBranch("foo")]
        let untracked = [localBranch("foo")]
        let elsewhere = [localBranch("foo", upstream: upstream("upstream/foo", remote: "upstream"))]
        #expect(RemoteOnlyBranches.filter(remotes: remotes, locals: untracked) == remotes)
        #expect(RemoteOnlyBranches.filter(remotes: remotes, locals: elsewhere) == remotes)
    }

    @Test func theSameNameOnTwoRemotesBothStay() {
        let remotes = [remoteBranch("foo"), remoteBranch("foo", remote: "upstream")]
        #expect(RemoteOnlyBranches.filter(remotes: remotes, locals: [localBranch("main")]) == remotes)
    }
}
