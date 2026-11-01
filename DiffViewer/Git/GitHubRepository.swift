import Foundation

/// A repository on github.com, named by its owner and repository.
struct GitHubRepository: Equatable, Sendable {
    let owner: String
    let name: String

    var fullName: String { "\(owner)/\(name)" }

    /// GitHub treats owner and repository names as case-insensitive.
    func matches(_ other: GitHubRepository) -> Bool {
        owner.caseInsensitiveCompare(other.owner) == .orderedSame
            && name.caseInsensitiveCompare(other.name) == .orderedSame
    }

    /// The repository a remote URL names: `https://github.com/o/r`, `git@github.com:o/r` or
    /// `ssh://git@github.com/o/r`, each with an optional `.git`. Nil for any other host or shape.
    static func parse(remoteURL: String) -> GitHubRepository? {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: Substring
        if url.contains("://") {
            guard let components = URLComponents(string: url), components.host?.lowercased() == "github.com",
                ["https", "ssh"].contains(components.scheme?.lowercased())
            else { return nil }
            path = components.path[...]
        } else if let colon = url.firstIndex(of: ":"), url[..<colon].lowercased().hasSuffix("@github.com") {
            path = url[url.index(after: colon)...]
        } else {
            return nil
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        var name = String(parts[1])
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !name.isEmpty else { return nil }
        return GitHubRepository(owner: String(parts[0]), name: name)
    }

    /// The repository a pull request from this one targets: a remote named `upstream` on
    /// another GitHub repository, by the convention that a fork's `upstream` is the
    /// repository it was forked from; otherwise this one. Nothing proves the fork
    /// relationship, so this is a heuristic. Only the fetch URL counts: nothing is pushed to
    /// the base, and a disabled push URL is a common guard on `upstream`. It decides where a
    /// new pull request goes.
    func pullRequestBase(in remotes: [String: RemoteURLs]) -> GitHubRepository {
        guard let fetchURL = remotes["upstream"]?.fetchURL,
            let upstream = GitHubRepository.parse(remoteURL: fetchURL), !upstream.matches(self)
        else { return self }
        return upstream
    }
}
