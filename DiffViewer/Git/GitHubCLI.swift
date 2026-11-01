import Foundation

/// Whether the GitHub CLI can answer for github.com, as `gh auth status` reports it.
enum GitHubCLIStatus: Equatable, Sendable {
    case notInstalled
    case signedOut
    case signedIn(login: String)
    /// `gh` ran but couldn't confirm a login; the text says why.
    case failed(String)
}

/// An open pull request on github.com.
struct GitHubPullRequest: Equatable, Sendable {
    let number: Int
    /// The page a browser opens (`html_url`), not the API endpoint.
    let url: URL
}

/// Everything that decides which pull request a branch has. Two local branches tracking the
/// same remote branch share one. Changing a remote URL changes it, even when the remote name
/// and ref stay the same.
struct PullRequestIdentity: Sendable {
    let remoteName: String
    /// The upstream's name on the remote, which can differ from the local branch's.
    let remoteBranchName: String
    /// The upstream remote's repository.
    let headRepository: GitHubRepository
    /// Where a new pull request is opened, per the `upstream` remote convention.
    let baseRepository: GitHubRepository

    /// Nil unless `branch` tracks a branch under `refs/heads/` that still exists, on a remote
    /// that is one GitHub repository for fetch and push.
    static func make(branch: LocalBranch, remotes: [String: RemoteURLs]) -> PullRequestIdentity? {
        guard let upstream = branch.upstream, case .counts = upstream.tracking,
            let remoteBranchName = upstream.remoteBranchName,
            case let .repository(head) = GitHubRemoteValidation.validate(remotes[upstream.remote])
        else { return nil }
        return PullRequestIdentity(
            remoteName: upstream.remote, remoteBranchName: remoteBranchName, headRepository: head,
            baseRepository: head.pullRequestBase(in: remotes))
    }
}

extension PullRequestIdentity: Equatable {
    /// GitHub ignores the case of repository names but not of branch names, and remote names
    /// are git's, which are case-sensitive.
    static func == (lhs: PullRequestIdentity, rhs: PullRequestIdentity) -> Bool {
        lhs.remoteName == rhs.remoteName && lhs.remoteBranchName == rhs.remoteBranchName
            && lhs.headRepository.matches(rhs.headRepository) && lhs.baseRepository.matches(rhs.baseRepository)
    }
}

/// A completed lookup. A nil `pullRequest` means GitHub reported no open pull request; a nil
/// `PullRequestLookup` means no completed result is available.
struct PullRequestLookup: Equatable, Sendable {
    let identity: PullRequestIdentity
    let pullRequest: GitHubPullRequest?
}

/// Why a `gh` run gave no usable output. The descriptions are what the reader sees.
enum GitHubCLIError: Error, Equatable, Sendable, LocalizedError {
    case notInstalled
    case couldNotLaunch
    case exited(status: Int32)
    case timedOut
    case outputTooLarge
    case unreadableOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled: "The GitHub CLI (gh) isn't installed"
        case .couldNotLaunch: "Couldn't start the GitHub CLI"
        case let .exited(status): "The GitHub CLI exited with status \(status)"
        case .timedOut: "The GitHub CLI request timed out"
        case .outputTooLarge: "The GitHub CLI's answer was too large"
        case .unreadableOutput: "Couldn't read the GitHub CLI's answer"
        }
    }
}
