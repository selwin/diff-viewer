import Foundation
import Testing

@testable import DiffViewer

struct BranchPullRequestsTests {
    private static let origin = GitHubRepository(owner: "me", name: "widgets")

    private static func pullRequest(
        _ number: Int, branch: String = "feature", state: ListedPullRequest.State = .open, updated: TimeInterval = 100,
        repository: GitHubRepository? = origin, url: String? = nil
    ) -> ListedPullRequest {
        ListedPullRequest(
            number: number, state: state, url: URL(string: url ?? "https://github.com/me/widgets/pull/\(number)")!,
            headBranch: branch, headRepository: repository, updatedAt: Date(timeIntervalSince1970: updated))
    }

    private static func pullRequests(
        _ pullRequests: [ListedPullRequest], defaultBranch: String? = nil, openSourcesSucceeded: Bool = true
    ) -> BranchPullRequests {
        BranchPullRequests(
            headRepository: origin,
            listing: PullRequestListing(
                pullRequests: pullRequests, headDefaultBranch: defaultBranch, allSourcesSucceeded: openSourcesSucceeded,
                openSourcesSucceeded: openSourcesSucceeded))
    }

    @Test(
        arguments: [
            (BranchPickerRow.Source.local(localBranch("mine", upstream: upstream("origin/theirs"))), "theirs"),
            (.local(localBranch("unpublished")), "unpublished"),
            (.local(localBranch("elsewhere", upstream: upstream("fork/elsewhere", remote: "fork"))), nil),
            (.remote(remoteBranch("feature")), "feature"),
            (.remote(remoteBranch("feature", remote: "fork")), nil),
        ] as [(BranchPickerRow.Source, String?)])
    func aRowMapsToItsBranchOnOriginOnly(source: BranchPickerRow.Source, expected: String?) {
        #expect(BranchPullRequests.headBranch(for: source) == expected)
    }

    @Test func onlyPullRequestsHeadedByOriginMatch() {
        let matches = Self.pullRequests([
            Self.pullRequest(1, repository: GitHubRepository(owner: "me", name: "gadgets")),
            Self.pullRequest(2, repository: GitHubRepository(owner: "other", name: "widgets")),
            Self.pullRequest(3, repository: nil),
            Self.pullRequest(4, branch: "cased", repository: GitHubRepository(owner: "ME", name: "Widgets")),
            Self.pullRequest(5, branch: "Cased"),
        ])

        #expect(matches.pullRequest(forHeadBranch: "feature") == nil)
        #expect(matches.pullRequest(forHeadBranch: "cased")?.number == 4)
        #expect(matches.pullRequest(forHeadBranch: "Cased")?.number == 5)
    }

    @Test(
        arguments: [
            // Each case lists the winner first; the test also reads the list reversed.
            (
                "newer update", [Self.pullRequest(2, updated: 200), Self.pullRequest(5, updated: 100)],
                "https://github.com/me/widgets/pull/2"
            ),
            (
                "higher number", [Self.pullRequest(5), Self.pullRequest(2)], "https://github.com/me/widgets/pull/5"
            ),
            (
                "lower URL",
                [
                    Self.pullRequest(7, url: "https://github.com/a/widgets/pull/7"),
                    Self.pullRequest(7, url: "https://github.com/b/widgets/pull/7"),
                ], "https://github.com/a/widgets/pull/7"
            ),
            (
                "active over newer closed",
                [Self.pullRequest(1, state: .draft, updated: 100), Self.pullRequest(2, state: .closed, updated: 200)],
                "https://github.com/me/widgets/pull/1"
            ),
        ] as [(String, [ListedPullRequest], String)])
    func theBestPullRequestWinsRegardlessOfOrder(_: String, candidates: [ListedPullRequest], expected: String) {
        for ordered in [candidates, candidates.reversed()] {
            let chosen = Self.pullRequests(ordered).pullRequest(forHeadBranch: "feature")
            #expect(chosen?.url.absoluteString == expected)
        }
    }

    @Test func withoutACompleteOpenListNoClosedPullRequestIsAssigned() {
        let matches = Self.pullRequests(
            [Self.pullRequest(1, branch: "old", state: .closed), Self.pullRequest(2, branch: "live")],
            openSourcesSucceeded: false)

        #expect(matches.pullRequest(forHeadBranch: "old") == nil)
        #expect(matches.pullRequest(forHeadBranch: "live")?.number == 2)
    }

    @Test func theDefaultBranchAndUnknownBranchesHaveNone() {
        let matches = Self.pullRequests([Self.pullRequest(1, branch: "main")], defaultBranch: "main")

        #expect(matches.pullRequest(forHeadBranch: "main") == nil)
        #expect(matches.pullRequest(forHeadBranch: "unknown") == nil)
    }
}
