import Foundation

/// The repositories one branch picker listing reads: origin's, whose branches the rows show,
/// and the base a pull request from it targets.
struct PullRequestListIdentity: Sendable {
    let head: GitHubRepository
    let base: GitHubRepository
}

extension PullRequestListIdentity: Equatable {
    /// GitHub ignores the case of repository names, so a remote URL that only changes case
    /// is the same listing.
    static func == (lhs: PullRequestListIdentity, rhs: PullRequestListIdentity) -> Bool {
        lhs.head.matches(rhs.head) && lhs.base.matches(rhs.base)
    }
}
