import Foundation

/// A pull request pinned to exact commits, ready to become a comparison.
struct ResolvedPullRequest: Equatable, Sendable {
    let advertised: AdvertisedPullRequest
    let base: PullRequestComparisonBase
}
