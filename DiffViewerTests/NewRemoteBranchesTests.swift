import Foundation
import Testing

@testable import DiffViewer

struct NewRemoteBranchesTests {
    private let main = remoteBranch("main")
    private let feature = remoteBranch("feature")
    private let forkMain = remoteBranch("main", remote: "fork")
    private let forkTopic = remoteBranch("topic", remote: "fork")

    @Test func aRefMissingBeforeTheRoundIsNew() {
        let new = NewRemoteBranches.update(
            previous: [], before: [main.ref], after: [main, feature], fetched: ["origin"])
        #expect(new == [feature.ref])
    }

    @Test func withoutABeforeNothingIsNew() {
        let new = NewRemoteBranches.update(previous: [], before: nil, after: [main, feature], fetched: ["origin"])
        #expect(new.isEmpty)
    }

    /// Only a remote that fetched this round can contribute: another may have gained a ref
    /// from some other git process.
    @Test func aFailedRemoteKeepsItsEntriesAndGainsNone() {
        let new = NewRemoteBranches.update(
            previous: [forkMain.ref], before: [main.ref], after: [main, feature, forkMain, forkTopic],
            fetched: ["origin"])
        #expect(new == [feature.ref, forkMain.ref])
    }

    @Test func aNewRefStaysNewUntilItsRemoteFetchesAgain() {
        let first = NewRemoteBranches.update(
            previous: [], before: [main.ref], after: [main, feature], fetched: ["origin"])
        #expect(first == [feature.ref])

        let afterFailure = NewRemoteBranches.update(
            previous: first, before: [main.ref, feature.ref], after: [main, feature], fetched: [])
        #expect(afterFailure == [feature.ref], "a failed fetch of origin carries it forward")

        let afterSuccess = NewRemoteBranches.update(
            previous: afterFailure, before: [main.ref, feature.ref], after: [main, feature], fetched: ["origin"])
        #expect(afterSuccess.isEmpty, "a later successful fetch finds it already there")
    }

    @Test func aRefThatIsGoneIsDropped() {
        let new = NewRemoteBranches.update(previous: [feature.ref], before: nil, after: [main], fetched: [])
        #expect(new.isEmpty)
    }
}
