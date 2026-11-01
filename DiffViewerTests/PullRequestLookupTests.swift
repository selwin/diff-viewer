import Foundation
import Testing

@testable import DiffViewer

/// Which branch states a pull request lookup is about, and when a shared tip leaves its
/// match unproven.
struct PullRequestLookupTests {
    private static let tip = objectID("tip")
    private static let tracked = localBranch("feature", upstream: upstream("origin/feature"))
    private static let remoteTip = remoteBranch("feature", tipSha: tip)

    @Test(
        arguments: [
            (BranchReadStatus.unread, tracked, [remoteTip]),
            (.failed, tracked, [remoteTip]),
            (.loaded, localBranch("feature", upstream: upstream("origin/feature", tracking: .gone)), [remoteTip]),
            (.loaded, tracked, []),
        ] as [(BranchReadStatus, LocalBranch, [RemoteBranch])])
    func noKeyWithoutALoadedReadOfAnUpstreamAndItsTip(
        readStatus: BranchReadStatus, branch: LocalBranch, remoteBranches: [RemoteBranch]
    ) {
        #expect(
            PullRequestLookupKey.make(
                headState: .named("feature"), branches: [branch], remoteBranches: remoteBranches,
                readStatus: readStatus) == nil)
    }

    @Test func aKeyNamesTheUpstreamAndItsRemoteTrackingTip() {
        let key = PullRequestLookupKey.make(
            headState: .named("feature"), branches: [Self.tracked],
            remoteBranches: [remoteBranch("main", tipSha: objectID("main")), Self.remoteTip], readStatus: .loaded)
        #expect(
            key
                == PullRequestLookupKey(
                    branchName: "feature", upstreamRemote: "origin", upstreamRemoteRef: "refs/heads/feature",
                    remoteTrackingTipSha: Self.tip))
    }

    @Test func aSharedTipIsAmbiguousUnlessItIsTheSameBranchOnAMirror() throws {
        let key = try #require(
            PullRequestLookupKey.make(
                headState: .named("feature"), branches: [Self.tracked], remoteBranches: [Self.remoteTip],
                readStatus: .loaded))
        let mirrors: Set<String> = ["origin", "mirror"]
        func isAmbiguous(_ also: RemoteBranch) -> Bool {
            PullRequestLookup.isAmbiguous(key: key, remoteBranches: [Self.remoteTip, also], mirrorRemotes: mirrors)
        }

        #expect(!isAmbiguous(remoteBranch("feature", remote: "mirror", tipSha: Self.tip)))
        #expect(!isAmbiguous(remoteBranch("other", tipSha: objectID("other"))))
        #expect(isAmbiguous(remoteBranch("other", tipSha: Self.tip)))
        #expect(isAmbiguous(remoteBranch("feature", remote: "fork", tipSha: Self.tip)))
    }

    @Test func aCachedMatchIsPresentedOnlyForTheKeyAndConfigurationItWasFoundUnder() throws {
        let key = try #require(
            PullRequestLookupKey.make(
                headState: .named("feature"), branches: [Self.tracked], remoteBranches: [Self.remoteTip],
                readStatus: .loaded))
        let movedKey = PullRequestLookupKey(
            branchName: key.branchName, upstreamRemote: key.upstreamRemote, upstreamRemoteRef: key.upstreamRemoteRef,
            remoteTrackingTipSha: objectID("moved"))
        let repository = GitHubRepository(owner: "me", name: "widgets")
        let configuration = PullRequestLookupConfiguration(
            targets: [PullRequestLookupTarget(remote: "origin", repository: repository)], mirrorRemotes: ["origin"])
        let renamed = PullRequestLookupConfiguration(
            targets: [
                PullRequestLookupTarget(remote: "origin", repository: GitHubRepository(owner: "acme", name: "widgets"))
            ],
            mirrorRemotes: ["origin"])
        let found = PullRequestLookupResult(number: 88, url: URL(string: "https://github.com/me/widgets/pull/88")!)
        let cache = PullRequestLookupCache(
            key: key, configuration: configuration, checkedAt: Date(timeIntervalSince1970: 0), result: found)
        func presented(
            key current: PullRequestLookupKey?, observing observed: PullRequestLookupConfiguration
        ) -> PullRequestLookupResult? {
            PullRequestLookup.presentedResult(
                cache: cache, key: current,
                observation: PullRequestLookupObservation(key: current ?? key, configuration: observed),
                remoteBranches: [Self.remoteTip])
        }

        #expect(presented(key: key, observing: configuration) == found)
        #expect(presented(key: movedKey, observing: configuration) == nil)
        #expect(presented(key: nil, observing: configuration) == nil)
        #expect(presented(key: key, observing: renamed) == nil)
    }
}
