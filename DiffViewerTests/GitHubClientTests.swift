import Foundation
import Synchronization
import Testing

@testable import DiffViewer

/// Answers GitHub requests by URL and records them. A first page is routed by its path, a
/// later one by its whole URL; anything unrouted is a 404.
private final class FakeGitHub: Sendable {
    enum Reply: Sendable {
        case http(Int, headers: [String: String] = [:], body: String)
        /// Waits until the request's task is cancelled.
        case hang
    }

    private let routes: [String: Reply]
    private let recorded = Mutex<[URLRequest]>([])

    init(_ routes: [String: Reply] = [:]) { self.routes = routes }

    var requests: [URLRequest] { recorded.withLock { $0 } }
    var paths: [String] { requests.compactMap { $0.url?.path } }
    var authorizations: [String?] { requests.map { $0.value(forHTTPHeaderField: "Authorization") } }

    var transport: GitHubTransport { { [self] request in try await respond(to: request) } }

    private func respond(to request: URLRequest) async throws -> (Data, URLResponse) {
        recorded.withLock { $0.append(request) }
        let url = request.url!
        switch routes[url.absoluteString] ?? routes[url.path] ?? .http(404, body: #"{"message":"Not Found"}"#) {
        case let .http(status, headers, body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        case .hang:
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
    }
}

/// Token resolution, the account check and the pull request lookup, with a fake `gh` script
/// on the command environment's PATH and a scripted transport.
struct GitHubClientTests {
    private let identity = PullRequestIdentity(
        remoteName: "origin", remoteBranchName: "remote-feature",
        headRepository: GitHubRepository(owner: "me", name: "widgets"),
        baseRepository: GitHubRepository(owner: "acme", name: "widgets"))
    /// Fresh per test, on a fixed clock, so no test's cooldown reaches another.
    private let gate = GitHubRateLimitGate(now: { Date(timeIntervalSince1970: 1_800_000_000) })

    private static let base = "/repos/acme/widgets/pulls"
    private static let head = "/repos/me/widgets/pulls"

    /// A directory holding `gh` with `body` as its script, unless `body` is nil.
    private func makeDirectory(gh body: String?) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DiffViewerGitHub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let body {
            let script = directory.appendingPathComponent("gh")
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        return directory
    }

    /// A client whose command environment is `variables` with PATH holding only `directory`.
    private func client(
        _ directory: URL, variables: [String: String] = [:], inheritance: ProcessEnvironment.Inheritance = .replace,
        github: FakeGitHub = FakeGitHub()
    ) -> GitClient {
        let environment = ProcessEnvironment(
            variables: variables.merging(["PATH": directory.path]) { own, _ in own }, inheritance: inheritance)
        return GitClient(
            repoRoot: directory, resolveCommandEnvironment: { environment }, gitHubTransport: github.transport,
            gitHubRateLimitGate: gate)
    }

    private static func item(_ number: Int, in repository: String = "acme/widgets", headRepo: Bool = true) -> String {
        let repo = headRepo ? #"{"full_name":"me/widgets"}"# : "null"
        return
            #"{"number":\#(number),"html_url":"https://github.com/\#(repository)/pull/\#(number)","head":{"repo":\#(repo)}}"#
    }

    private static func page(_ items: [String], next: String? = nil) -> FakeGitHub.Reply {
        .http(
            200, headers: next.map { ["Link": "<\($0)>; rel=\"next\""] } ?? [:],
            body: "[\(items.joined(separator: ","))]")
    }

    // MARK: Credentials

    @Test func theFirstNonBlankSourceWins() async throws {
        // Like the real `gh`, a non-empty token variable beats the stored login.
        let directory = try makeDirectory(
            gh: #"""
                if [ -n "$GH_TOKEN" ]; then echo "$GH_TOKEN"
                elif [ -n "$GITHUB_TOKEN" ]; then echo "$GITHUB_TOKEN"
                else echo '  from-gh  '; fi
                """#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [([String: String], String, GitHubTokenSource)] = [
            (["GH_TOKEN": "first", "GITHUB_TOKEN": "second"], "first", .environment(name: "GH_TOKEN")),
            (["GITHUB_TOKEN": "second"], "second", .environment(name: "GITHUB_TOKEN")),
            (["GH_TOKEN": " \n", "GITHUB_TOKEN": ""], "from-gh", .gitHubCLI),
            ([:], "from-gh", .gitHubCLI),
        ]
        for (variables, value, source) in cases {
            let token = try await client(directory, variables: variables).resolveGitHubToken()
            #expect(token?.value == value)
            #expect(token?.source == source)
        }

        let noGitHubCLI = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: noGitHubCLI) }
        #expect(try await client(noGitHubCLI).resolveGitHubToken() == nil)
    }

    @Test(arguments: ["exit 1", "echo token; exit 1", "echo '   '", "exit 0"])
    func aFailedOrEmptyGitHubCLIRunIsNoToken(script: String) async throws {
        let directory = try makeDirectory(gh: script)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await client(directory).resolveGitHubToken() == nil)
    }

    @Test func anInheritedEnvironmentIsOverlaidByTheResolvedOne() async throws {
        let directory = try makeDirectory(gh: "echo from-gh")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Whatever the app's own environment holds, an explicit value wins, and an explicit
        // blank skips to the next source rather than bringing an inherited one back.
        let explicit = try await client(directory, variables: ["GH_TOKEN": "explicit"], inheritance: .inherit)
            .resolveGitHubToken()
        #expect(explicit?.value == "explicit")
        let skipped = try await client(
            directory, variables: ["GH_TOKEN": "", "GITHUB_TOKEN": "second"], inheritance: .inherit
        ).resolveGitHubToken()
        #expect(skipped?.source == .environment(name: "GITHUB_TOKEN"))

        // With nothing set here, the app's own environment decides under `.inherit` only.
        let own = ProcessInfo.processInfo.environment
        let ownName = ["GH_TOKEN", "GITHUB_TOKEN"].first {
            !(own[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let inherited = try await client(directory, inheritance: .inherit).resolveGitHubToken()
        let expected = ownName.map { GitHubTokenSource.environment(name: $0) } ?? .gitHubCLI
        #expect(inherited?.source == expected)
        #expect(try await client(directory).resolveGitHubToken()?.source == .gitHubCLI)
    }

    @Test func cancellingWhileGitHubCLIRunsThrowsCancellation() async throws {
        // gh still prints a token once it exits; the cancel must win over it.
        let directory = try makeDirectory(gh: ": > started\n/bin/sleep 1\necho from-gh")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = self.client(directory)
        let task = Task { try await client.resolveGitHubToken() }
        let started = directory.appendingPathComponent("started").path
        try #require(await eventually { FileManager.default.fileExists(atPath: started) })

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: Account

    @Test func noTokenIsAnonymousWithoutARequest() async throws {
        let directory = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let github = FakeGitHub()
        #expect(try await client(directory, github: github).gitHubAuthenticationStatus() == .anonymous)
        #expect(github.requests.isEmpty)
    }

    @Test func theUserEndpointNamesTheAccountOrRejectsTheToken() async throws {
        let directory = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = GitHubTokenSource.environment(name: "GH_TOKEN")
        let cases: [(FakeGitHub.Reply, GitHubAuthenticationStatus)] = [
            (.http(200, body: #"{"login":"selwin"}"#), .token(source: source, login: "selwin")),
            (.http(401, body: "{}"), .rejected(source: source)),
            // Installation tokens can't read `/user` but can still list pull requests.
            (
                .http(403, body: #"{"message":"Resource not accessible by integration"}"#),
                .token(source: source, login: nil)
            ),
        ]
        for (reply, expected) in cases {
            let github = FakeGitHub(["/user": reply])
            let status = try await client(directory, variables: ["GH_TOKEN": "secret"], github: github)
                .gitHubAuthenticationStatus()
            #expect(status == expected)
            #expect(github.authorizations == ["Bearer secret"])
        }
    }

    @Test func cancellingTheAccountCheckThrowsCancellation() async throws {
        let directory = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let github = FakeGitHub(["/user": .hang])
        let client = self.client(directory, variables: ["GH_TOKEN": "secret"], github: github)
        let task = Task { try await client.gitHubAuthenticationStatus() }
        try #require(await eventually { !github.requests.isEmpty })

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: Lookup

    @Test func theBaseRepositoryIsAskedFirstThenTheHead() async throws {
        let directory = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let github = FakeGitHub([Self.base: Self.page([]), Self.head: Self.page([Self.item(4, in: "me/widgets")])])

        let found = try await client(directory, github: github).findOpenPullRequest(identity)

        #expect(found?.number == 4)
        #expect(github.paths == [Self.base, Self.head])
        let url = try #require(github.requests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(
            query == [
                "head": "me:remote-feature", "state": "open", "sort": "created", "direction": "asc",
                "per_page": "100",
            ])
        #expect(github.authorizations == [nil, nil])
    }

    @Test func aFailingBaseRepositoryFallsBackToTheHead() async throws {
        let directory = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The base repository is unrouted, so it answers 404.
        let github = FakeGitHub([Self.head: Self.page([Self.item(4, in: "me/widgets")])])
        #expect(try await client(directory, github: github).findOpenPullRequest(identity)?.number == 4)
    }

    @Test func theFirstFailureIsThrownWhenNothingIsFound() async throws {
        let directory = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let github = FakeGitHub([Self.head: Self.page([])])
        await #expect(throws: GitHubAPIError.notFound) {
            try await client(directory, github: github).findOpenPullRequest(identity)
        }
        #expect(github.paths == [Self.base, Self.head])
    }

    @Test func noneOnEitherRepositoryIsNil() async throws {
        let directory = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let github = FakeGitHub([Self.base: Self.page([]), Self.head: Self.page([])])
        #expect(try await client(directory, github: github).findOpenPullRequest(identity) == nil)
    }

    @Test func aRepositoryThatIsBothBaseAndHeadIsSearchedOnce() async throws {
        let directory = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let own = GitHubRepository(owner: "me", name: "widgets")
        let ownIdentity = PullRequestIdentity(
            remoteName: "origin", remoteBranchName: "remote-feature", headRepository: own, baseRepository: own)
        let github = FakeGitHub([Self.head: Self.page([])])

        _ = try await client(directory, github: github).findOpenPullRequest(ownIdentity)

        #expect(github.paths == [Self.head])
    }

    @Test func aRateLimitEndsTheSearchBeforeTheHeadRepository() async throws {
        let directory = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let limited = FakeGitHub.Reply.http(
            403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000600"], body: "{}")
        let github = FakeGitHub([Self.base: limited, Self.head: Self.page([Self.item(4, in: "me/widgets")])])

        await #expect(throws: GitHubAPIError.rateLimited(retryAfter: Date(timeIntervalSince1970: 1_800_000_600))) {
            try await client(directory, github: github).findOpenPullRequest(identity)
        }
        #expect(github.paths == [Self.base])
    }

    @Test func aPullRequestWhoseHeadRepositoryWasDeletedIsSkipped() async throws {
        let directory = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let github = FakeGitHub([Self.base: Self.page([Self.item(3, headRepo: false)]), Self.head: Self.page([])])

        #expect(try await client(directory, github: github).findOpenPullRequest(identity) == nil)
        #expect(github.paths == [Self.base, Self.head])
    }

    @Test func theOldestEligiblePullRequestEndsTheSearch() async throws {
        let directory = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = "https://api.github.com\(Self.base)?page=2"
        let github = FakeGitHub([
            Self.base: Self.page([Self.item(3, headRepo: false)], next: second),
            second: Self.page([Self.item(8), Self.item(12)], next: "https://api.github.com\(Self.base)?page=3"),
        ])

        #expect(try await client(directory, github: github).findOpenPullRequest(identity)?.number == 8)
        #expect(github.paths == [Self.base, Self.base])
    }

    @Test func malformedJSONIsAFailureNotNone() async throws {
        let directory = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let github = FakeGitHub([Self.base: .http(200, body: "{"), Self.head: Self.page([])])

        await #expect(throws: GitHubAPIError.unreadableResponse) {
            try await client(directory, github: github).findOpenPullRequest(identity)
        }
    }

    @Test func theTokenIsResolvedOnceForEveryRepositoryAndPage() async throws {
        let directory = try makeDirectory(gh: #"echo "$*" >> calls.txt; echo gh-token"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = "https://api.github.com\(Self.base)?page=2"
        let github = FakeGitHub([
            Self.base: Self.page([], next: second), second: Self.page([]), Self.head: Self.page([]),
        ])

        #expect(try await client(directory, github: github).findOpenPullRequest(identity) == nil)
        #expect(github.authorizations == Array(repeating: "Bearer gh-token", count: 3))
        // The script ran in the repository, so that is where it wrote.
        let calls = try String(contentsOf: directory.appendingPathComponent("calls.txt"), encoding: .utf8)
        #expect(calls == "auth token --hostname github.com\n")
    }
}
