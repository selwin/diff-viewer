import Foundation

/// What a remote advertised for a pull request: the SHAs a comparison is pinned to. Later
/// pushes to the remote don't change it.
struct AdvertisedPullRequest: Equatable, Sendable {
    let remote: String
    let number: Int
    /// The branch the remote's HEAD names, without `refs/heads/`.
    let defaultBranch: String
    let baseTipSHA: String
    let headSHA: String
}

/// The commit a pull request is compared from.
struct PullRequestComparisonBase: Equatable, Sendable {
    let commitSHA: String
    /// True when the head was already merged and the commit comes from before that merge.
    let isRecovered: Bool
}
