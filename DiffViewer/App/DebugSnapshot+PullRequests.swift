import Foundation

extension DebugLaunchOptions {
    /// Pins the `DIFFVIEWER_PULL_REQUEST_FIXTURE` list on the window, so the branch picker's
    /// pull request capsules can be screenshotted in every state without GitHub. A malformed
    /// value is ignored.
    @MainActor
    static func applyPullRequestFixture(_ value: String?, in windowState: WindowState) {
        #if DEBUG
            let repository =
                windowState.originGitHubRepository ?? GitHubRepository(owner: "selwin", name: "diff-viewer")
            guard let value, let listing = pullRequestFixture(value, repository: repository) else { return }
            windowState.pinBranchPullRequests(BranchPullRequests(headRepository: repository, listing: listing))
        #endif
    }

    #if DEBUG
        /// Whether a valid fixture was given at launch. Read before any listing can start, so
        /// a scripted run never asks GitHub for pull requests.
        static let pinsPullRequestList: Bool = {
            guard let value = ProcessInfo.processInfo.environment["DIFFVIEWER_PULL_REQUEST_FIXTURE"] else {
                return false
            }
            return pullRequestFixture(value, repository: GitHubRepository(owner: "selwin", name: "diff-viewer")) != nil
        }()

        private static let fixtureStates: [String: ListedPullRequest.State] = [
            "open": .open, "draft": .draft, "merged": .merged, "closed": .closed,
        ]

        /// Comma-separated `headBranch:state` pairs, numbered 1, 2, 3… in order, all headed in
        /// `repository` so they match its branches. Nil when a pair is malformed.
        static func pullRequestFixture(_ value: String, repository: GitHubRepository) -> PullRequestListing? {
            var pullRequests: [ListedPullRequest] = []
            // Empty entries are kept, so "" or "a:open,,b:closed" is malformed, not a shorter list.
            for (index, pair) in value.split(separator: ",", omittingEmptySubsequences: false).enumerated() {
                let number = index + 1
                guard let colon = pair.lastIndex(of: ":"), colon != pair.startIndex,
                    let state = fixtureStates[String(pair[pair.index(after: colon)...])],
                    let url = URL(string: "https://github.com/\(repository.fullName)/pull/\(number)")
                else { return nil }
                pullRequests.append(
                    ListedPullRequest(
                        number: number, state: state, url: url, headBranch: String(pair[..<colon]),
                        headRepository: repository, updatedAt: Date(timeIntervalSince1970: 1_789_300_000)))
            }
            return PullRequestListing(
                pullRequests: pullRequests, headDefaultBranch: nil, allSourcesSucceeded: true,
                openSourcesSucceeded: true)
        }
    #endif
}
