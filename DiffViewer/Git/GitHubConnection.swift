import Foundation

/// Whether `gh` is installed. A nil probe means it wasn't looked for.
enum GitHubCLIProbe: Equatable, Sendable {
    case missing
    /// Nil when `gh --version` failed or printed something unexpected, so no version is claimed.
    case found(version: String?)

    /// `2.63.0` from `gh version 2.63.0 (2024-11-27)`; nil for any other output.
    static func parseVersion(_ output: String) -> String? {
        let firstLine = output.split(whereSeparator: \.isNewline).first ?? ""
        let words = firstLine.split(separator: " ")
        guard words.count >= 3, words[0] == "gh", words[1] == "version", words[2].first?.isNumber == true else {
            return nil
        }
        return String(words[2])
    }
}

/// How the repository's origin stands with GitHub, as the title bar shows it. "Connected" means
/// the credentials can read the repository's metadata; it says nothing about push access.
enum GitHubConnection: Equatable, Sendable {
    case connected(GitHubRepository, login: String?, source: GitHubTokenSource, isPrivate: Bool, url: URL)
    case cliNotFound(GitHubRepository)
    /// No usable token: none was found (`cliProbe` says whether `gh` is there), or GitHub
    /// rejected the one from `rejectedSource`.
    case notSignedIn(GitHubRepository, cliProbe: GitHubCLIProbe?, rejectedSource: GitHubTokenSource?)
    /// The repository request was denied or returned not found.
    case noAccess(GitHubRepository, login: String?, source: GitHubTokenSource)
    /// The check failed without a previous result for this repository to preserve.
    case unreachable(GitHubRepository)
    case notOnGitHub

    var repository: GitHubRepository? {
        switch self {
        case let .connected(repository, _, _, _, _), let .cliNotFound(repository),
            let .notSignedIn(repository, _, _), let .noAccess(repository, _, _), let .unreachable(repository):
            repository
        case .notOnGitHub:
            nil
        }
    }
}

/// What `GET /repos/{owner}/{repo}` said about one token's access.
enum GitHubRepositoryAccess: Equatable, Sendable {
    case found(isPrivate: Bool, url: URL)
    /// 401.
    case unauthorized
    /// 404, or a 403 that isn't a rate limit.
    case denied
    /// Network, timeout, rate limit, any other status, or an unreadable answer.
    case transient
}

/// The raw inputs of one check of a GitHub origin. Every combination is a valid state.
enum GitHubRepositoryCheck: Equatable, Sendable {
    /// No token anywhere.
    case anonymous(cli: GitHubCLIProbe)
    /// `/user` answered 401.
    case rejected(source: GitHubTokenSource)
    case token(source: GitHubTokenSource, login: String?, access: GitHubRepositoryAccess)
}

/// The displayed connection and current authentication status from one check.
struct GitHubCheckOutcome: Equatable, Sendable {
    let connection: GitHubConnection
    let status: GitHubAuthenticationStatus

    /// A transient failure keeps `previous` when it is about the same repository; otherwise
    /// there is nothing to keep and the origin reads as unreachable.
    static func make(
        origin: GitHubRepository, check: GitHubRepositoryCheck, previous: GitHubConnection?
    ) -> GitHubCheckOutcome {
        switch check {
        case .anonymous(cli: .missing):
            return GitHubCheckOutcome(connection: .cliNotFound(origin), status: .anonymous)
        case let .anonymous(cli):
            return GitHubCheckOutcome(
                connection: .notSignedIn(origin, cliProbe: cli, rejectedSource: nil), status: .anonymous)
        case let .rejected(source), let .token(source, _, .unauthorized):
            return GitHubCheckOutcome(
                connection: .notSignedIn(origin, cliProbe: nil, rejectedSource: source),
                status: .rejected(source: source))
        case let .token(source, login, .found(isPrivate, url)):
            return GitHubCheckOutcome(
                connection: .connected(origin, login: login, source: source, isPrivate: isPrivate, url: url),
                status: .token(source: source, login: login))
        case let .token(source, login, .denied):
            return GitHubCheckOutcome(
                connection: .noAccess(origin, login: login, source: source),
                status: .token(source: source, login: login))
        case let .token(source, login, .transient):
            let kept = previous.flatMap { $0.repository?.matches(origin) == true ? $0 : nil }
            return GitHubCheckOutcome(
                connection: kept ?? .unreachable(origin), status: .token(source: source, login: login))
        }
    }
}

/// What a window's connection model publishes.
enum GitHubCheckResult: Equatable, Sendable {
    case repository(GitHubCheckOutcome)
    /// The origin isn't on GitHub but another remote is, so only the branch picker's status is news.
    case statusOnly(GitHubAuthenticationStatus)
    /// The origin just moved off GitHub; published without a check.
    case notOnGitHub
}
