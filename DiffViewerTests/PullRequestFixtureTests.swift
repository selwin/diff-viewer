#if DEBUG
    import Foundation
    import Testing

    @testable import DiffViewer

    /// Parsing `DIFFVIEWER_PULL_REQUEST_FIXTURE`, which only Debug builds read.
    struct PullRequestFixtureTests {
        private static let repository = GitHubRepository(owner: "me", name: "widgets")

        private func fixture(_ value: String) -> PullRequestListing? {
            DebugLaunchOptions.pullRequestFixture(value, repository: Self.repository)
        }

        @Test func aPairBecomesAPullRequestOnThatBranch() throws {
            let pullRequest = try #require(fixture("feature/x:draft")?.pullRequests.first)
            #expect(pullRequest.headBranch == "feature/x")
            #expect(pullRequest.state == .draft)
            #expect(pullRequest.headRepository == Self.repository)
        }

        @Test func pairsAreNumberedInOrder() {
            #expect(fixture("feature:open,old:closed")?.pullRequests.map(\.number) == [1, 2])
        }

        @Test(arguments: ["", ",", "feature:open,,old:closed", "feature:reopened", "feature", ":open"])
        func aMalformedValueIsRejected(value: String) {
            #expect(fixture(value) == nil)
        }
    }
#endif
