import Foundation

/// Whether a remote is one GitHub repository for both fetch and push, so a branch pushed
/// to it is a branch of that repository.
enum GitHubRemoteValidation {
    enum Result: Equatable, Sendable {
        case repository(GitHubRepository)
        /// The remote's fetch URL names no GitHub repository.
        case notOnGitHub
        /// A push URL names a different repository, or none, so the branch may not be there.
        case pushesElsewhere
        /// The remote isn't configured.
        case missing
    }

    /// SSH and HTTPS forms of one repository count as the same. Nil is a remote that
    /// isn't configured.
    static func validate(_ urls: RemoteURLs?) -> Result {
        guard let urls else { return .missing }
        guard let repository = GitHubRepository.parse(remoteURL: urls.fetchURL) else { return .notOnGitHub }
        let pushesHere = urls.pushURLs.allSatisfy {
            GitHubRepository.parse(remoteURL: $0)?.matches(repository) ?? false
        }
        return pushesHere ? .repository(repository) : .pushesElsewhere
    }

    /// The names of the remotes that validate.
    static func qualifyingRemoteNames(in remotes: [String: RemoteURLs]) -> Set<String> {
        Set(
            remotes.compactMap { name, urls in
                if case .repository = validate(urls) { name } else { nil }
            })
    }
}
