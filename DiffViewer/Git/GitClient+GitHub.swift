import Foundation

/// GitHub's REST API for one repository: which token to use, whose account it is, whether it can
/// read the repository, and the current branch's open pull request. `GitHubAPI` does the HTTP;
/// the decoders live here.
extension GitClient {
    static let defaultGitHubCLITimeout: Duration = .seconds(10)

    /// Bounds the captured CLI output.
    private static let gitHubCLIOutputLimit = 64 << 10

    /// No prompts, no update check and no colour codes: nobody is there to answer, and the
    /// output is read.
    private static let gitHubCLIEnvironment = [
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "NO_COLOR": "1",
    ]

    /// Checked in this order, as `gh` itself does.
    private static let gitHubTokenVariables = ["GH_TOKEN", "GITHUB_TOKEN"]

    var gitHubAPI: GitHubAPI { GitHubAPI(transport: gitHubTransport, gate: gitHubRateLimitGate) }

    /// The token for github.com: `GH_TOKEN`, then `GITHUB_TOKEN` in the command environment,
    /// then `gh auth token`; nil when none has one. An empty or whitespace-only value counts
    /// as unset, and an explicit empty value hides an inherited one. Throws only
    /// `CancellationError`; a cancel while `gh` runs takes effect once it exits or times out.
    func resolveGitHubToken() async throws -> GitHubToken? {
        try await resolveGitHubToken(in: try await commandEnvironment())
    }

    private func resolveGitHubToken(in environment: ProcessEnvironment) async throws -> GitHubToken? {
        let inherited = environment.inheritance == .inherit ? ProcessInfo.processInfo.environment : [:]
        let effective = inherited.merging(environment.variables) { _, own in own }
        for name in Self.gitHubTokenVariables {
            if let value = Self.nonBlank(effective[name]) {
                return GitHubToken(value: value, source: .environment(name: name))
            }
        }
        return try await gitHubCLIToken(in: environment)
    }

    /// Whose account the token is, for display only. No token is `.anonymous`, with no request
    /// made. Only a 401 reads as rejected: any other failure keeps the token, since GitHub App
    /// installation tokens can't read `/user` but can list pull requests. Throws only
    /// `CancellationError`.
    func gitHubAuthenticationStatus() async throws -> GitHubAuthenticationStatus {
        try await resolveTokenAndStatus(in: try await commandEnvironment()).status
    }

    /// Everything the title bar needs about `origin`: the token's status, as
    /// `gitHubAuthenticationStatus` reports it, then whether that token can read the
    /// repository. With no token, whether `gh` is installed instead. Throws only
    /// `CancellationError`.
    func gitHubRepositoryCheck(_ origin: GitHubRepository) async throws -> GitHubRepositoryCheck {
        let environment = try await commandEnvironment()
        let (token, status) = try await resolveTokenAndStatus(in: environment)
        switch (token, status) {
        case let (token?, .token(source, login)):
            return .token(source: source, login: login, access: try await repositoryAccess(origin, token: token))
        case let (_, .rejected(source)):
            return .rejected(source: source)
        default:
            return .anonymous(cli: try await probeGitHubCLI(in: environment))
        }
    }

    /// The token, resolved once, and what `/user` says about it.
    private func resolveTokenAndStatus(
        in environment: ProcessEnvironment
    ) async throws -> (token: GitHubToken?, status: GitHubAuthenticationStatus) {
        guard let token = try await resolveGitHubToken(in: environment) else { return (nil, .anonymous) }
        do {
            let data = try await gitHubAPI.get(path: "/user", token: token.value)
            return (token, .token(source: token.source, login: try Self.parseLogin(data)))
        } catch is CancellationError {
            throw CancellationError()
        } catch GitHubAPIError.unauthorized {
            return (token, .rejected(source: token.source))
        } catch {
            return (token, .token(source: token.source, login: nil))
        }
    }

    private func repositoryAccess(_ origin: GitHubRepository, token: GitHubToken) async throws
        -> GitHubRepositoryAccess
    {
        do {
            let data = try await gitHubAPI.get(
                path: "/repos/\(Self.pathComponent(origin.owner))/\(Self.pathComponent(origin.name))",
                token: token.value)
            return Self.parseRepositoryAccess(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch GitHubAPIError.unauthorized {
            return .unauthorized
        } catch GitHubAPIError.notFound, GitHubAPIError.forbidden {
            // `forbidden` is a 403 the API didn't read as a rate limit.
            return .denied
        } catch {
            return .transient
        }
    }

    /// Whether `gh` is on the command environment's PATH, and its version when it says.
    private func probeGitHubCLI(in environment: ProcessEnvironment) async throws -> GitHubCLIProbe {
        guard let executable = Self.gitHubCLIExecutable(in: environment) else { return .missing }
        var environment = environment
        environment.variables.merge(Self.gitHubCLIEnvironment) { _, cli in cli }
        try Task.checkCancellation()
        guard
            let run = ShellRun<Data>.spawn(
                executable: executable, arguments: ["--version"], environment: environment,
                currentDirectory: repoRoot)
        else { return .found(version: nil) }
        let outcome = await run.output(timeout: gitHubCLITimeout, outputLimit: Self.gitHubCLIOutputLimit)
        try Task.checkCancellation()
        guard case let .output(data) = outcome else { return .found(version: nil) }
        return .found(version: GitHubCLIProbe.parseVersion(String(decoding: data, as: UTF8.self)))
    }

    /// The oldest open pull request from `identity`'s head branch whose head repository still
    /// exists. The base repository is searched first, then the head repository when it is a
    /// different one: the base heuristic picks where a new pull request would go, not where an
    /// existing one targets. A failing repository (an `upstream` remote can name one that is
    /// gone or private) doesn't stop the search, except for cancellation and a rate limit,
    /// which end it at once. Returns nil only when every searched repository successfully
    /// reports no eligible open pull request; otherwise returns the first match or throws the
    /// first failure.
    func findOpenPullRequest(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest? {
        let token = try await resolveGitHubToken()?.value
        var repositories = [identity.baseRepository]
        if !identity.headRepository.matches(identity.baseRepository) { repositories.append(identity.headRepository) }
        var firstFailure: (any Error)?
        for repository in repositories {
            do {
                if let pullRequest = try await findOpenPullRequest(in: repository, identity, token: token) {
                    return pullRequest
                }
            } catch {
                // Another repository can't be luckier: one is the user stopping, the other
                // applies to every request.
                if error is CancellationError { throw error }
                if case GitHubAPIError.rateLimited = error { throw error }
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
        return nil
    }

    private func findOpenPullRequest(
        in repository: GitHubRepository, _ identity: PullRequestIdentity, token: String?
    ) async throws -> GitHubPullRequest? {
        // The server filters by head owner and branch; oldest first, so the first eligible
        // pull request ends the search.
        var found: GitHubPullRequest?
        try await gitHubAPI.forEachPage(
            path: "/repos/\(Self.pathComponent(repository.owner))/\(Self.pathComponent(repository.name))/pulls",
            query: [
                ("head", "\(identity.headRepository.owner):\(identity.remoteBranchName)"),
                ("state", "open"), ("sort", "created"), ("direction", "asc"), ("per_page", "100"),
            ],
            token: token
        ) { page in
            found = try Self.parseOpenPullRequests(page)
            return found != nil
        }
        return found
    }

    /// `gh auth token` for github.com, run from the command environment's PATH in the
    /// repository. A missing `gh`, a failed run or empty output is no token.
    private func gitHubCLIToken(in environment: ProcessEnvironment) async throws -> GitHubToken? {
        guard let executable = Self.gitHubCLIExecutable(in: environment) else { return nil }
        var environment = environment
        environment.variables.merge(Self.gitHubCLIEnvironment) { _, cli in cli }
        // `gh` would print a whitespace-only token variable back instead of its stored login;
        // empty is unset to it, and both variables were already tried.
        for name in Self.gitHubTokenVariables { environment.variables[name] = "" }
        try Task.checkCancellation()
        guard
            let run = ShellRun<Data>.spawn(
                executable: executable, arguments: ["auth", "token", "--hostname", "github.com"],
                environment: environment, currentDirectory: repoRoot)
        else { return nil }
        // `output` doesn't observe cancellation, so it is checked once the run settles.
        let outcome = await run.output(timeout: gitHubCLITimeout, outputLimit: Self.gitHubCLIOutputLimit)
        try Task.checkCancellation()
        guard case let .output(data) = outcome, let value = Self.nonBlank(String(decoding: data, as: UTF8.self))
        else { return nil }
        return GitHubToken(value: value, source: .gitHubCLI)
    }

    /// The first executable `gh` on the environment's PATH, or on the app's own when an
    /// inherited environment names none. Relative entries are skipped: they would resolve
    /// against whatever directory the app happens to be in.
    private static func gitHubCLIExecutable(in environment: ProcessEnvironment) -> String? {
        let inheritedPath = environment.inheritance == .inherit ? ProcessInfo.processInfo.environment["PATH"] : nil
        let path = environment.variables["PATH"] ?? inheritedPath ?? ""
        for directory in path.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("gh").path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
                FileManager.default.isExecutableFile(atPath: candidate)
            {
                return candidate
            }
        }
        return nil
    }

    /// Escapes a repository's owner or name for the API path, so it stays one segment.
    static func pathComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? text
    }

    /// `text` trimmed, or nil when nothing is left.
    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The first pull request on one page of `/pulls` whose head repository still exists;
    /// one whose head repository was deleted has no head to compare. Nil when the page has
    /// none. Throws `GitHubAPIError.unreadableResponse` for malformed JSON or a non-https URL.
    static func parseOpenPullRequests(_ page: Data) throws -> GitHubPullRequest? {
        let pullRequests: [PullRequestObject]
        do {
            pullRequests = try JSONDecoder().decode([PullRequestObject].self, from: page)
        } catch {
            throw GitHubAPIError.unreadableResponse
        }
        guard let eligible = pullRequests.first(where: { $0.head.repo != nil }) else { return nil }
        // The URL is opened in a browser, so anything but a web page is refused.
        guard eligible.url.scheme?.lowercased() == "https" else { throw GitHubAPIError.unreadableResponse }
        return GitHubPullRequest(number: eligible.number, url: eligible.url)
    }

    /// Decodes repository metadata; malformed JSON or a non-HTTPS browser URL returns `.transient`.
    static func parseRepositoryAccess(_ data: Data) -> GitHubRepositoryAccess {
        guard let repository = try? JSONDecoder().decode(RepositoryObject.self, from: data),
            repository.url.scheme?.lowercased() == "https"
        else { return .transient }
        return .found(isPrivate: repository.isPrivate, url: repository.url)
    }

    /// The account name `/user` reports. Throws `GitHubAPIError.unreadableResponse` for
    /// malformed JSON.
    static func parseLogin(_ data: Data) throws -> String {
        do {
            return try JSONDecoder().decode(UserObject.self, from: data).login
        } catch {
            throw GitHubAPIError.unreadableResponse
        }
    }
}

/// The parts of a `/pulls` item the lookup reads.
private struct PullRequestObject: Decodable {
    struct Head: Decodable {
        /// Null once the head repository is deleted; only its presence matters.
        let repo: Repository?
    }

    struct Repository: Decodable {}

    let number: Int
    let url: URL
    let head: Head

    enum CodingKeys: String, CodingKey {
        case number
        case url = "html_url"
        case head
    }
}

/// The part of `/user` the account check reads.
private struct UserObject: Decodable {
    let login: String
}

/// The parts of `/repos/{owner}/{repo}` the connection check reads.
private struct RepositoryObject: Decodable {
    let isPrivate: Bool
    let url: URL

    enum CodingKeys: String, CodingKey {
        case isPrivate = "private"
        case url = "html_url"
    }
}
