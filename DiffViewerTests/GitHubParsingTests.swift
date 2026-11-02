import Foundation
import Testing

@testable import DiffViewer

/// Decoding the REST answers the pull request lookup and the account check read.
struct GitHubParsingTests {
    private func openPullRequest(_ json: String) throws -> GitHubPullRequest? {
        try GitClient.parseOpenPullRequests(Data(json.utf8))
    }

    private func item(_ number: Int, url: String? = nil, headRepo: Bool = true) -> String {
        let link = url ?? "https://github.com/acme/widgets/pull/\(number)"
        let repo = headRepo ? #"{"full_name":"me/widgets"}"# : "null"
        return #"{"number":\#(number),"html_url":"\#(link)","head":{"ref":"feature","repo":\#(repo)}}"#
    }

    @Test func aPageGivesItsFirstPullRequestWithAHeadRepository() throws {
        #expect(try openPullRequest("[]") == nil)
        #expect(try openPullRequest("[\(item(3, headRepo: false))]") == nil)
        #expect(
            try openPullRequest("[\(item(3, headRepo: false)),\(item(5)),\(item(9))]")
                == GitHubPullRequest(
                    number: 5, url: try #require(URL(string: "https://github.com/acme/widgets/pull/5"))))
    }

    @Test func malformedPagesAndNonWebURLsThrow() {
        for json in [
            "{", #"{"message":"Not Found"}"#, #"[{"number":"7"}]"#, "[\(item(7, url: "http://github.com/a/b/pull/7"))]",
        ] {
            #expect(throws: GitHubAPIError.unreadableResponse) { try openPullRequest(json) }
        }
    }

    @Test func theLoginIsReadFromTheUser() throws {
        #expect(try GitClient.parseLogin(Data(#"{"login":"selwin","id":1}"#.utf8)) == "selwin")
        #expect(throws: GitHubAPIError.unreadableResponse) { try GitClient.parseLogin(Data(#"{"id":1}"#.utf8)) }
    }
}

/// Which pull request a branch's upstream names.
struct PullRequestIdentityTests {
    private let widgets = GitHubRepository(owner: "me", name: "widgets")

    private func urls(_ url: String) -> RemoteURLs { RemoteURLs(fetchURL: url, pushURLs: [url]) }

    private let branch = localBranch("feature", upstream: upstream("origin/remote-feature"))

    @Test func identityNamesTheUpstreamsRemoteBranch() throws {
        let identity = try #require(
            PullRequestIdentity.make(branch: branch, remotes: ["origin": urls("git@github.com:me/widgets.git")]))
        #expect(identity.remoteName == "origin")
        #expect(identity.remoteBranchName == "remote-feature")
        #expect(identity.headRepository == widgets)
        #expect(identity.baseRepository == widgets)
    }

    @Test func theBaseIsTheUpstreamRemotesRepositoryWhenItDiffers() throws {
        let identity = try #require(
            PullRequestIdentity.make(
                branch: branch,
                remotes: [
                    "origin": urls("https://github.com/me/widgets"),
                    "upstream": urls("https://github.com/acme/widgets"),
                ]))
        #expect(identity.headRepository == widgets)
        #expect(identity.baseRepository == GitHubRepository(owner: "acme", name: "widgets"))
    }

    @Test func aRemoteThatIsNotGitHubHasNoIdentity() {
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
