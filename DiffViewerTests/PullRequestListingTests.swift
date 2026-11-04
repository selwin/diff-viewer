import Foundation
import Testing

@testable import DiffViewer

/// `listPullRequests` against a scripted transport. Requests are routed by full URL because the
/// open and closed sources share a path.
struct PullRequestListingTests {
    private let head = GitHubRepository(owner: "me", name: "widgets")
    private let base = GitHubRepository(owner: "acme", name: "widgets")
    private let gate = GitHubRateLimitGate(now: { Date(timeIntervalSince1970: 1_800_000_000) })

    private func openURL(_ repository: String) -> String {
        "https://api.github.com/repos/\(repository)/pulls?state=open&per_page=100"
    }

    private func closedURL(_ repository: String) -> String {
        "https://api.github.com/repos/\(repository)/pulls?state=closed&sort=updated&direction=desc&per_page=100"
    }

    private func page(_ items: String..., next: String? = nil) -> FakeGitHub.Reply {
        .http(
            200, headers: next.map { ["Link": "<\($0)>; rel=\"next\""] } ?? [:],
            body: "[\(items.joined(separator: ","))]")
    }

    private func list(
        _ github: FakeGitHub, head: GitHubRepository? = nil, base: GitHubRepository? = nil
    ) async throws -> PullRequestListing {
        let environment = ProcessEnvironment(
            variables: ["GH_TOKEN": "token", "PATH": "/nonexistent"], inheritance: .replace)
        let client = GitClient(
            repoRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            resolveCommandEnvironment: { environment }, gitHubTransport: github.transport, gitHubRateLimitGate: gate)
        return try await client.listPullRequests(head: head ?? self.head, base: base ?? self.base)
    }

    private func numbers(_ listing: PullRequestListing) -> [Int] { listing.pullRequests.map(\.number) }

    @Test func everySourceOfBothRepositoriesIsReadBaseFirst() async throws {
        let github = FakeGitHub([
            openURL("acme/widgets"): page(PullRequestJSON.item(1)),
            closedURL("acme/widgets"): page(PullRequestJSON.item(2, state: "closed")),
            openURL("me/widgets"): page(PullRequestJSON.item(3)),
            closedURL("me/widgets"): page(PullRequestJSON.item(4, state: "closed")),
        ])

        let listing = try await list(github)

        #expect(numbers(listing) == [1, 2, 3, 4])
        #expect(listing.allSourcesSucceeded && listing.openSourcesSucceeded)
        #expect(
            github.requests.compactMap { $0.url?.absoluteString } == [
                openURL("acme/widgets"), closedURL("acme/widgets"), openURL("me/widgets"), closedURL("me/widgets"),
            ])
    }

    @Test func anUnavailableBaseLeavesTheHeadsPullRequests() async throws {
        let github = FakeGitHub([
            openURL("me/widgets"): page(PullRequestJSON.item(3)),
            closedURL("me/widgets"): page(PullRequestJSON.item(4, state: "closed")),
        ])

        let listing = try await list(github)

        #expect(numbers(listing) == [3, 4])
        #expect(!listing.allSourcesSucceeded)
        #expect(!listing.openSourcesSucceeded)
    }

    @Test func aFailedClosedHistoryKeepsTheOpenPullRequests() async throws {
        let github = FakeGitHub([openURL("me/widgets"): page(PullRequestJSON.item(3))])

        let listing = try await list(github, base: head)

        #expect(numbers(listing) == [3])
        #expect(listing.openSourcesSucceeded)
        #expect(!listing.allSourcesSucceeded)
    }

    @Test func everyOpenPageContributes() async throws {
        let second = openURL("me/widgets") + "&page=2"
        let github = FakeGitHub([
            openURL("me/widgets"): page(PullRequestJSON.item(3), next: second),
            second: page(PullRequestJSON.item(5)),
            closedURL("me/widgets"): page(),
        ])

        let listing = try await list(github, base: head)

        #expect(numbers(listing) == [3, 5])
    }

    @Test func aFailedLaterOpenPageDropsTheEarlierPages() async throws {
        let second = openURL("me/widgets") + "&page=2"
        let github = FakeGitHub([
            openURL("me/widgets"): page(PullRequestJSON.item(3), next: second),
            closedURL("me/widgets"): page(PullRequestJSON.item(4, state: "closed")),
        ])

        let listing = try await list(github, base: head)

        #expect(numbers(listing) == [4])
        #expect(!listing.openSourcesSucceeded)
    }

    @Test func openPagesPastTheCapDropTheSource() async throws {
        let urls = [openURL("me/widgets")] + (2...GitHubAPI.maxPages).map { openURL("me/widgets") + "&page=\($0)" }
        var routes: [String: FakeGitHub.Reply] = [
            closedURL("me/widgets"): page(PullRequestJSON.item(4, state: "closed"))
        ]
        for (index, url) in urls.enumerated() {
            // The last page still links on, past the cap.
            routes[url] = page(PullRequestJSON.item(100 + index), next: openURL("me/widgets") + "&page=\(index + 2)")
        }

        let listing = try await list(FakeGitHub(routes), base: head)

        #expect(numbers(listing) == [4])
        #expect(!listing.openSourcesSucceeded)
    }

    @Test func cancellingStopsBeforeAnyFurtherSource() async throws {
        let github = FakeGitHub([openURL("acme/widgets"): .hang])
        let task = Task { try await list(github) }
        try #require(await eventually { !github.requests.isEmpty })

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(github.requests.count == 1)
    }

    @Test func theFirstFailureIsThrownWhenEverySourceFails() async throws {
        let github = FakeGitHub([
            openURL("acme/widgets"): .http(500, body: "{}"), openURL("me/widgets"): .http(404, body: "{}"),
        ])

        await #expect(throws: GitHubAPIError.http(status: 500)) { try await list(github) }
        #expect(github.requests.count == 4)
    }

    @Test func aRateLimitStopsBeforeAnyFurtherSource() async throws {
        let limited = FakeGitHub.Reply.http(
            403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000600"], body: "{}")
        let github = FakeGitHub([openURL("acme/widgets"): limited, openURL("me/widgets"): page()])

        await #expect(throws: GitHubAPIError.rateLimited(retryAfter: Date(timeIntervalSince1970: 1_800_000_600))) {
            try await list(github)
        }
        #expect(github.requests.count == 1)
    }

    @Test func theDefaultBranchComesOnlyFromAPullRequestHeadedByTheHeadRepository() async throws {
        let fork = #"{"owner":{"login":"other"},"name":"widgets","default_branch":"fork-main"}"#
        let mine = #"{"owner":{"login":"ME"},"name":"Widgets","default_branch":"trunk"}"#
        let forkOnly = FakeGitHub([openURL("acme/widgets"): page(PullRequestJSON.item(1, repo: fork))])
        let both = FakeGitHub([
            openURL("acme/widgets"): page(PullRequestJSON.item(1, repo: fork), PullRequestJSON.item(2, repo: mine))
        ])

        #expect(try await list(forkOnly).headDefaultBranch == nil)
        #expect(try await list(both).headDefaultBranch == "trunk")
    }
}
