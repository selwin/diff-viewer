import Foundation
import Testing

@testable import DiffViewer

/// Reading `gh auth status` and the open pull request lookup.
struct GitHubCLIParsingTests {
    private func authStatus(_ json: String) throws -> GitHubCLIStatus {
        try GitClient.parseAuthStatus(Data(json.utf8))
    }

    private func openPullRequest(_ lines: String) throws -> GitHubPullRequest? {
        try GitClient.parseOpenPullRequests(Data(lines.utf8))
    }

    @Test func authStatusReadsTheActiveGitHubAccount() throws {
        #expect(
            try authStatus(
                #"{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"selwin"}]}}"#)
                == .signedIn(login: "selwin"))
    }

    @Test func noGitHubAccountIsSignedOut() throws {
        #expect(try authStatus(#"{"hosts":{}}"#) == .signedOut)
    }

    @Test(arguments: ["timeout", "error"])
    func aFailedAccountStateReportsItsError(state: String) throws {
        #expect(
            try authStatus(#"{"hosts":{"github.com":[{"state":"\#(state)","active":true,"error":"no network"}]}}"#)
                == .failed("no network"))
    }

    @Test func accountsWithoutAnActiveOneFail() throws {
        #expect(
            try authStatus(#"{"hosts":{"github.com":[{"state":"success","active":false,"login":"other"}]}}"#)
                == .failed("No active github.com account in the GitHub CLI"))
    }

    @Test func malformedAuthStatusThrows() {
        #expect(throws: (any Error).self) { try authStatus(#"{"hosts":"#) }
    }

    @Test func noOpenPullRequestsGiveNil() throws {
        #expect(try openPullRequest("") == nil)
    }

    @Test func openPullRequestsGiveTheLowestNumberedOne() throws {
        let lines = """
            {"html_url":"https://github.com/acme/widgets/pull/12","number":12}
            {"html_url":"https://github.com/acme/widgets/pull/9","number":9}

            """
        #expect(
            try openPullRequest(lines)
                == GitHubPullRequest(
                    number: 9, url: try #require(URL(string: "https://github.com/acme/widgets/pull/9"))))
    }

    @Test func aMalformedPullRequestLineThrows() {
        #expect(throws: (any Error).self) {
            try openPullRequest(#"{"html_url":"https://github.com/acme/widgets/pull/9","number":9}"# + "\n{\"number\":")
        }
    }
}

/// Which pull request a branch's upstream names.
struct PullRequestIdentityTests {
    private let widgets = GitHubRepository(owner: "me", name: "widgets")

    private func urls(_ url: String) -> RemoteURLs { RemoteURLs(fetchURL: url, pushURLs: [url]) }

    @Test func identityNamesTheRemoteBranchAndTheUpstreamRemotesBase() throws {
        let branch = localBranch("feature", upstream: upstream("origin/remote-feature"))
        let own = try #require(
            PullRequestIdentity.make(branch: branch, remotes: ["origin": urls("git@github.com:me/widgets.git")]))
        #expect(own.remoteName == "origin")
        #expect(own.remoteBranchName == "remote-feature")
        #expect(own.headRepository == widgets)
        #expect(own.baseRepository == widgets)

        let fork = try #require(
            PullRequestIdentity.make(
                branch: branch,
                remotes: [
                    "origin": urls("https://github.com/me/widgets"),
                    "upstream": urls("https://github.com/acme/widgets"),
                ]))
        #expect(fork.headRepository == widgets)
        #expect(fork.baseRepository == GitHubRepository(owner: "acme", name: "widgets"))

        #expect(
            PullRequestIdentity.make(branch: branch, remotes: ["origin": urls("https://gitlab.com/me/widgets")]) == nil)
    }

    @Test func equalityIgnoresRepositoryCaseOnly() {
        func identity(remote: String = "origin", branch: String = "feature", owner: String = "me")
            -> PullRequestIdentity
        {
            let repository = GitHubRepository(owner: owner, name: "widgets")
            return PullRequestIdentity(
                remoteName: remote, remoteBranchName: branch, headRepository: repository, baseRepository: repository)
        }
        #expect(identity() == identity(owner: "ME"))
        #expect(identity() != identity(remote: "Origin"))
        #expect(identity() != identity(branch: "Feature"))
    }
}
