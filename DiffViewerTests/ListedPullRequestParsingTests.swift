import Foundation
import Testing

@testable import DiffViewer

/// Builds `/pulls` JSON for the pull request listing tests.
enum PullRequestJSON {
    static let headRepository = #"{"owner":{"login":"me"},"name":"widgets","default_branch":"main"}"#

    static func item(
        _ number: Int = 1, state: String = "open", draft: Bool = false, mergedAt: String? = nil,
        updatedAt: String = "2026-01-02T03:04:05Z", url: String? = nil, branch: String = "feature",
        repo: String? = headRepository
    ) -> String {
        let url = url ?? "https://github.com/acme/widgets/pull/\(number)"
        let merged = mergedAt.map { #""\#($0)""# } ?? "null"
        return
            #"{"number":\#(number),"state":"\#(state)","draft":\#(draft),"merged_at":\#(merged),"updated_at":"\#(updatedAt)","html_url":"\#(url)","head":{"ref":"\#(branch)","repo":\#(repo ?? "null")}}"#
    }

    static func page(_ items: String...) -> Data { Data("[\(items.joined(separator: ","))]".utf8) }
}

struct ListedPullRequestParsingTests {
    @Test(
        arguments: [
            ("open", false, nil, ListedPullRequest.State.open),
            ("open", true, nil, .draft),
            ("closed", false, "2026-01-01T00:00:00Z", .merged),
            ("closed", false, nil, .closed),
        ] as [(String, Bool, String?, ListedPullRequest.State)])
    func theStateIsDerivedFromStateDraftAndMergedAt(
        state: String, draft: Bool, mergedAt: String?, expected: ListedPullRequest.State
    ) throws {
        let data = PullRequestJSON.page(PullRequestJSON.item(state: state, draft: draft, mergedAt: mergedAt))
        let entry = try #require(try GitClient.parsePullRequestPage(data).first)

        #expect(entry.pullRequest.state == expected)
    }

    @Test func theFieldsAreDecoded() throws {
        let data = PullRequestJSON.page(PullRequestJSON.item(7))
        let entry = try #require(try GitClient.parsePullRequestPage(data).first)

        #expect(entry.pullRequest.number == 7)
        #expect(entry.pullRequest.url == URL(string: "https://github.com/acme/widgets/pull/7"))
        #expect(entry.pullRequest.headBranch == "feature")
        #expect(entry.pullRequest.headRepository == GitHubRepository(owner: "me", name: "widgets"))
        #expect(entry.pullRequest.updatedAt == Date(timeIntervalSince1970: 1_767_323_045))
        #expect(entry.headDefaultBranch == "main")
    }

    @Test func anEmptyPageHasNoPullRequests() throws {
        #expect(try GitClient.parsePullRequestPage(Data("[]".utf8)).isEmpty)
    }

    @Test func aDeletedHeadRepositoryHasNone() throws {
        let entry = try #require(
            try GitClient.parsePullRequestPage(PullRequestJSON.page(PullRequestJSON.item(repo: nil))).first)
        #expect(entry.pullRequest.headRepository == nil)
        #expect(entry.headDefaultBranch == nil)
    }

    @Test(arguments: [
        PullRequestJSON.item(url: "http://github.com/acme/widgets/pull/1"),
        PullRequestJSON.item(url: "file:///etc/passwd"),
        PullRequestJSON.item(updatedAt: "yesterday"),
        PullRequestJSON.item(state: "locked"),
    ])
    func anUnreadablePullRequestThrows(item: String) {
        #expect(throws: GitHubAPIError.unreadableResponse) {
            try GitClient.parsePullRequestPage(PullRequestJSON.page(item))
        }
    }

    @Test func malformedJSONThrows() {
        #expect(throws: GitHubAPIError.unreadableResponse) { try GitClient.parsePullRequestPage(Data("{".utf8)) }
    }
}
