import Foundation

/// Where a GitHub token came from, which the branch picker names.
enum GitHubTokenSource: Equatable, Sendable {
    /// `GH_TOKEN` or `GITHUB_TOKEN` in the repository's shell environment.
    case environment(name: String)
    /// `gh auth token`.
    case gitHubCLI
}

/// A github.com token and its source. Its description omits the token value.
struct GitHubToken: Sendable, CustomStringConvertible {
    let value: String
    let source: GitHubTokenSource

    var description: String { "GitHubToken(source: \(source))" }
}

/// What the app can say about its GitHub credentials. Display only: a lookup runs with
/// whatever token there is, or none.
enum GitHubAuthenticationStatus: Equatable, Sendable {
    /// A token from `source`; `login` is nil when GitHub wouldn't name its account, as with
    /// a GitHub App installation token.
    case token(source: GitHubTokenSource, login: String?)
    /// GitHub answered 401 to the token from `source`.
    case rejected(source: GitHubTokenSource)
    /// No token, so only public repositories' pull requests are found.
    case anonymous
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
