import Foundation

enum PullRequestRemoteError: Error, Equatable {
    /// The link names a GitHub repository that none of the remotes is.
    case notARemote(GitHubRepository)
    /// No remote is on GitHub, whatever the input names.
    case noGitHubRemote
}

/// Which remote a pull request is fetched from.
enum PullRequestRemote {
    /// A link needs a remote on its repository; `#n` accepts any GitHub remote. When several
    /// qualify, `upstream` wins over `origin`, then the rest by name: a fork's `upstream` is
    /// where its pull requests live.
    static func choose(
        for input: PullRequestInput, remotes: [GitRemote]
    ) throws(PullRequestRemoteError) -> GitRemote {
        let onGitHub = remotes.compactMap { remote in
            GitHubRepository.parse(remoteURL: remote.fetchURL).map { (remote, $0) }
        }
        guard !onGitHub.isEmpty else { throw .noGitHubRemote }
        var candidates = onGitHub
        if case let .url(repository, _) = input {
            candidates = onGitHub.filter { $0.1.matches(repository) }
            guard !candidates.isEmpty else { throw .notARemote(repository) }
        }
        guard let best = candidates.map(\.0).min(by: { (rank($0.name), $0.name) < (rank($1.name), $1.name) }) else {
            throw .noGitHubRemote
        }
        return best
    }

    private static func rank(_ name: String) -> Int {
        switch name {
        case "upstream": 0
        case "origin": 1
        default: 2
        }
    }
}
