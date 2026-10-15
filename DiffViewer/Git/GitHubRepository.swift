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
}
