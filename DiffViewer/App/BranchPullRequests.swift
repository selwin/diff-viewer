import Foundation

/// Each branch's pull request from one listing: the best match per head branch, built once.
/// A branch with several pull requests gets the newest active one, unlike the title bar's
/// lookup, which takes the oldest open one.
struct BranchPullRequests: Equatable, Sendable {
    /// The repository whose branches the rows show: `origin`.
    let headRepository: GitHubRepository
    /// The head repository's default branch. The picker shows no pull request for it.
    let headDefaultBranch: String?
    private let byHeadBranch: [String: ListedPullRequest]

    /// Keeps the pull requests whose head is `headRepository`. Without a complete open list a
    /// merged or closed one could hide an active one, so those are dropped.
    init(headRepository: GitHubRepository, listing: PullRequestListing) {
        self.headRepository = headRepository
        headDefaultBranch = listing.headDefaultBranch
        var best: [String: ListedPullRequest] = [:]
        for pullRequest in listing.pullRequests {
            guard pullRequest.headRepository?.matches(headRepository) == true,
                listing.openSourcesSucceeded || pullRequest.isActive
            else { continue }
            if let current = best[pullRequest.headBranch], !Self.wins(pullRequest, over: current) { continue }
            best[pullRequest.headBranch] = pullRequest
        }
        byHeadBranch = best
    }

    func pullRequest(forHeadBranch name: String) -> ListedPullRequest? {
        name == headDefaultBranch ? nil : byHeadBranch[name]
    }

    /// A picker row's pull request, matched by its branch on origin.
    func pullRequest(for source: BranchPickerRow.Source) -> ListedPullRequest? {
        Self.headBranch(for: source).flatMap(pullRequest(forHeadBranch:))
    }

    /// The branch on `origin` that a row's pull request would have as its head. A branch on
    /// another remote has no pull request from `origin`, so it must not borrow one by name.
    static func headBranch(for source: BranchPickerRow.Source) -> String? {
        switch source {
        case let .local(branch):
            guard let upstream = branch.upstream else { return branch.name }
            return upstream.remote == "origin" ? upstream.remoteBranchName : nil
        case let .remote(branch):
            return branch.remote == "origin" ? branch.name : nil
        }
    }

    /// Active first, then the most recently updated, then the higher number. The URL breaks the
    /// last tie: numbers repeat across repositories.
    private static func wins(_ candidate: ListedPullRequest, over current: ListedPullRequest) -> Bool {
        if candidate.isActive != current.isActive { return candidate.isActive }
        if candidate.updatedAt != current.updatedAt { return candidate.updatedAt > current.updatedAt }
        if candidate.number != current.number { return candidate.number > current.number }
        return candidate.url.absoluteString < current.url.absoluteString
    }
}
