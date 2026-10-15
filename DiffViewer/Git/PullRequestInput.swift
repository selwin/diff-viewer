import Foundation

/// What the reader typed to name a pull request.
enum PullRequestInput: Equatable {
    /// A link, so the repository is known.
    case url(GitHubRepository, Int)
    /// `#n`, which leaves the repository to the remotes.
    case number(Int)

    /// Parses `https://github.com/o/r/pull/n`, with an optional trailing path, query or
    /// fragment, or `#n`. Nil for anything else, such as an issue link, a plain `http` link,
    /// an empty path component or a number of zero.
    static func parse(_ text: String) -> PullRequestInput? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { return number(String(text.dropFirst())).map { .number($0) } }
        guard let components = URLComponents(string: text), components.host?.lowercased() == "github.com",
            components.scheme?.lowercased() == "https"
        else { return nil }
        // Keep empty components so `acme//widgets` shifts the fields and fails instead of
        // being read as `acme/widgets`; a trailing slash only adds an empty component after them.
        let parts = Array(components.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst())
        guard parts.count >= 4, !parts[..<4].contains(where: \.isEmpty), parts[2] == "pull",
            let number = number(String(parts[3]))
        else { return nil }
        return .url(GitHubRepository(owner: String(parts[0]), name: String(parts[1])), number)
    }

    /// A positive number written in digits only, which `Int(_:)` alone would not insist on.
    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text), value > 0 else {
            return nil
        }
        return value
    }
}
