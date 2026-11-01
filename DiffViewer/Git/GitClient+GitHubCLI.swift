import Foundation

/// Asking the GitHub CLI about github.com, with the user's own `gh` login. Running `gh` and
/// reading its answer are kept apart: the runner returns the output or a `GitHubCLIError`,
/// and pure parsers decode it.
extension GitClient {
    static let defaultGitHubCLITimeout: Duration = .seconds(10)

    /// Bounds the captured CLI output.
    private static let gitHubCLIOutputLimit = 64 << 10

    /// No prompts, no update check and no colour codes: nobody is there to answer, and the
    /// output is parsed.
    private static let gitHubCLIEnvironment = [
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "NO_COLOR": "1",
    ]

    /// Whether `gh` is installed and signed in to github.com. Throws `GitHubCLIError` for
    /// any other failure to run it.
    func gitHubCLIStatus() async throws -> GitHubCLIStatus {
        let output: Data
        do {
            output = try await runGitHubCLI([
                "auth", "status", "--hostname", "github.com", "--active", "--json", "hosts",
            ])
        } catch GitHubCLIError.notInstalled {
            return .notInstalled
        }
        return try Self.decodeGitHubCLIOutput { try Self.parseAuthStatus(output) }
    }

    /// The oldest open pull request from `identity`'s head branch, or nil when GitHub reports
    /// none. The base repository is searched first, then the head repository when it is a
    /// different one: the base heuristic picks where a new pull request would go, not where an
    /// existing one targets. The first repository with a pull request wins. A repository whose
    /// query fails (an `upstream` remote can name one that is gone or private) doesn't stop the
    /// search, but if nothing is found the first failure is thrown: nil means every repository
    /// answered with none. Throws `GitHubCLIError`.
    func findOpenPullRequest(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest? {
        var repositories = [identity.baseRepository]
        if !identity.headRepository.matches(identity.baseRepository) { repositories.append(identity.headRepository) }
        var firstFailure: (any Error)?
        for repository in repositories {
            do {
                if let pullRequest = try await findOpenPullRequest(in: repository, identity) { return pullRequest }
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
        return nil
    }

    private func findOpenPullRequest(
        in repository: GitHubRepository, _ identity: PullRequestIdentity
    ) async throws -> GitHubPullRequest? {
        // The server filters by head owner and branch name, and `--paginate` reads every page.
        // A pull request whose head repository was deleted has no head to compare, so it is
        // skipped. `@json` keeps each object on one line even when `GH_FORCE_TTY` makes gh
        // pretty-print.
        let output = try await runGitHubCLI([
            "api", "--hostname", "github.com", "-X", "GET", "--paginate",
            "repos/\(Self.pathComponent(repository.owner))/\(Self.pathComponent(repository.name))/pulls",
            "-f", "head=\(identity.headRepository.owner):\(identity.remoteBranchName)",
            "-f", "state=open", "-f", "per_page=100",
            "--jq", ".[] | select(.head.repo != null) | {number, html_url} | @json",
        ])
        return try Self.decodeGitHubCLIOutput { try Self.parseOpenPullRequests(output) }
    }

    /// Runs `gh` from the command environment's PATH, in the repository. Every command names
    /// `--hostname github.com`, so an inherited `GH_HOST` can't redirect it.
    private func runGitHubCLI(_ arguments: [String]) async throws -> Data {
        var environment = try await commandEnvironment()
        guard let executable = Self.gitHubCLIExecutable(in: environment) else { throw GitHubCLIError.notInstalled }
        environment.variables.merge(Self.gitHubCLIEnvironment) { _, cli in cli }
        guard
            let run = ShellRun<Data>.spawn(
                executable: executable, arguments: arguments, environment: environment, currentDirectory: repoRoot)
        else { throw GitHubCLIError.couldNotLaunch }
        switch await run.output(timeout: gitHubCLITimeout, outputLimit: Self.gitHubCLIOutputLimit) {
        case let .output(data): return data
        case let .exited(status): throw GitHubCLIError.exited(status: status)
        case .timedOut: throw GitHubCLIError.timedOut
        case .outputTooLarge: throw GitHubCLIError.outputTooLarge
        }
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
    private static func pathComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? text
    }

    private static func decodeGitHubCLIOutput<Value>(_ parse: () throws -> Value) throws -> Value {
        do {
            return try parse()
        } catch {
            throw GitHubCLIError.unreadableOutput
        }
    }

    /// Reads `gh auth status --json hosts` for github.com.
    static func parseAuthStatus(_ data: Data) throws -> GitHubCLIStatus {
        let accounts = try JSONDecoder().decode(AuthStatusOutput.self, from: data).hosts["github.com"] ?? []
        guard !accounts.isEmpty else { return .signedOut }
        guard let account = accounts.first(where: \.active) else {
            return .failed("No active github.com account in the GitHub CLI")
        }
        if account.state == "success", let login = account.login { return .signedIn(login: login) }
        return .failed(account.error ?? "Couldn't verify the GitHub CLI login")
    }

    /// Reads one `{number, html_url}` object per line. Empty output is GitHub reporting no
    /// open pull request. Every page has been read, so the lowest number is exactly the
    /// oldest; a head has several only when they target different base branches.
    static func parseOpenPullRequests(_ data: Data) throws -> GitHubPullRequest? {
        let decoder = JSONDecoder()
        let lines = try data.split(separator: UInt8(ascii: "\n")).map {
            try decoder.decode(PullRequestLine.self, from: Data($0))
        }
        guard let oldest = lines.min(by: { $0.number < $1.number }) else { return nil }
        // The URL is opened in a browser, so anything but a web page is refused.
        guard oldest.url.scheme == "https" else { throw GitHubCLIError.unreadableOutput }
        return GitHubPullRequest(number: oldest.number, url: oldest.url)
    }
}

/// `gh auth status --json hosts`: accounts by host. `login` and `error` depend on `state`.
private struct AuthStatusOutput: Decodable {
    struct Account: Decodable {
        let state: String
        let active: Bool
        let login: String?
        let error: String?
    }

    let hosts: [String: [Account]]
}

/// One pull request as the lookup's `--jq` filter prints it.
private struct PullRequestLine: Decodable {
    let number: Int
    let url: URL

    enum CodingKeys: String, CodingKey {
        case number
        case url = "html_url"
    }
}
