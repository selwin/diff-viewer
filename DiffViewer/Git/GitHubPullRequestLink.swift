import Foundation

/// GitHub's "Open a pull request" page for a pushed branch. It names no base branch, so
/// GitHub compares against the base repository's default branch, and no title or body,
/// so GitHub fills in its own defaults and the repository's template.
enum GitHubPullRequestLink {
    /// Why a branch has no pull request page to open.
    enum Failure: Error, Equatable {
        /// No upstream, or a gone one: the branch moved since the button showed.
        case branchChanged
        /// The upstream isn't under `refs/heads/` on its remote.
        case notABranch
        case remoteMissing(String)
        case notOnGitHub(String)
        case pushesElsewhere(String)
        /// The branch has commits its upstream doesn't.
        case unpushed
    }

    /// The page for `branch` pushed to its upstream, decided from fresh remote URLs.
    static func make(for branch: LocalBranch, remotes: [String: RemoteURLs]) -> Result<URL, Failure> {
        guard let upstream = branch.upstream, case let .counts(ahead, _) = upstream.tracking else {
            return .failure(.branchChanged)
        }
        guard let branchName = remoteBranchName(upstream.remoteRef) else { return .failure(.notABranch) }
        let head: GitHubRepository
        switch GitHubRemoteValidation.validate(remotes[upstream.remote]) {
        case let .repository(repository): head = repository
        case .missing: return .failure(.remoteMissing(upstream.remote))
        case .notOnGitHub: return .failure(.notOnGitHub(upstream.remote))
        case .pushesElsewhere: return .failure(.pushesElsewhere(upstream.remote))
        }
        guard ahead == 0 else { return .failure(.unpushed) }
        let base = base(head: head, remotes: remotes)
        guard let url = compareURL(head: head, base: base, branch: branchName) else {
            return .failure(.notABranch)
        }
        return .success(url)
    }

    /// A remote named `upstream` on another GitHub repository, by the convention that a
    /// fork's `upstream` is the repository it was forked from; otherwise `head` itself.
    /// Nothing proves the fork relationship, and GitHub's page lets the reader change the
    /// base. Only the fetch URL counts: nothing is pushed to the base, and a disabled push
    /// URL is a common guard on `upstream`.
    private static func base(head: GitHubRepository, remotes: [String: RemoteURLs]) -> GitHubRepository {
        guard let fetchURL = remotes["upstream"]?.fetchURL,
            let upstream = GitHubRepository.parse(remoteURL: fetchURL), !upstream.matches(head)
        else { return head }
        return upstream
    }

    /// `/{base}/compare/{branch}` for one repository, or `/{base}/compare/{owner}:{repo}:{branch}`
    /// from a fork.
    private static func compareURL(head: GitHubRepository, base: GitHubRepository, branch: String) -> URL? {
        let compared =
            head.matches(base)
            ? encoded(branch) : "\(encoded(head.owner)):\(encoded(head.name)):\(encoded(branch))"
        return URL(
            string: "https://github.com/\(encoded(base.owner))/\(encoded(base.name))/compare/\(compared)?quick_pull=1")
    }

    private static func remoteBranchName(_ remoteRef: String) -> String? {
        let prefix = "refs/heads/"
        guard remoteRef.hasPrefix(prefix), remoteRef.count > prefix.count else { return nil }
        return String(remoteRef.dropFirst(prefix.count))
    }

    /// Escaped once for a path, keeping `/` so a branch like `feature/x` reads as GitHub
    /// writes it; `%`, `#`, `?` and non-ASCII characters are escaped.
    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
    }
}
