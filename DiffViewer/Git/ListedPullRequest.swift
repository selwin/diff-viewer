import Foundation

/// A pull request as the branch picker lists it, open or not.
struct ListedPullRequest: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case open
        case draft
        case merged
        case closed
    }

    let number: Int
    let state: State
    /// The page a browser opens (`html_url`), not the API endpoint.
    let url: URL
    let headBranch: String
    /// Nil once the head repository is deleted; such a pull request never matches a branch.
    let headRepository: GitHubRepository?
    let updatedAt: Date

    /// Still open for review: a merged or closed one is history.
    var isActive: Bool { state == .open || state == .draft }
}

/// What one listing read of the base and head repositories found.
struct PullRequestListing: Equatable, Sendable {
    let pullRequests: [ListedPullRequest]
    /// The head repository's default branch, read from a pull request whose head is that
    /// repository. Nil when none of the pull requests read has one.
    let headDefaultBranch: String?
    /// True when every requested source succeeded. Closed history is one page by design, so
    /// this does not mean every closed pull request was read.
    let allSourcesSucceeded: Bool
    /// True when every repository's open source succeeded. Only then can a closed or merged
    /// match be trusted not to hide an active pull request.
    let openSourcesSucceeded: Bool
}
