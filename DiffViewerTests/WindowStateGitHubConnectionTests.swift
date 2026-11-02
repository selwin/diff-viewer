import Foundation
import Testing

@testable import DiffViewer

/// How a window drives its GitHub connection check, apart from the pull request lookup.
@MainActor
struct WindowStateGitHubConnectionTests {
    private static let main = localBranch("main", upstream: upstream("origin/main"))
    private static let remotes = [
        "origin": RemoteURLs(fetchURL: "git@github.com:me/widgets.git", pushURLs: ["git@github.com:me/widgets.git"])
    ]

    /// Adopts a GitHub repository on `main` and waits for its first connection check and pull
    /// request lookup to be handled.
    private func adopt(_ h: Harness, _ state: WindowState) async throws -> Window {
        let repo = await h.adopt(state, "A", files: []) { client in
            await client.set(headState: .named("main"))
            await client.set(localBranches: [Self.main])
            await client.set(remoteURLs: Self.remotes)
            await client.set(gitHubAuthenticationStatus: .token(source: .gitHubCLI, login: "me"))
        }
        try #require(await eventually { @MainActor in state.gitHubConnectionModel?.checksFinished == 1 })
        try #require(await eventually { @MainActor in state.session?.pullRequestLookupsFinished == 1 })
        return (h, state, repo.client, repo.root)
    }

    @Test func adoptionRunsOneConnectionCheck() async throws {
        let h = Harness()
        let w = try await adopt(h, h.makeState())
        #expect(await w.client.gitHubRepositoryCheckCalls == [GitHubRepository(owner: "me", name: "widgets")])
        #expect(w.state.gitHubConnectionModel?.connection?.repository?.fullName == "me/widgets")
    }

    @Test func recheckingTheConnectionStartsNoPullRequestLookup() async throws {
        let h = Harness()
        let w = try await adopt(h, h.makeState())

        w.state.recheckGitHubConnection(refreshingEnvironment: false)
        try #require(await eventually { @MainActor in w.state.gitHubConnectionModel?.checksFinished == 2 })
        #expect(await w.client.gitHubRepositoryCheckCalls.count == 2)
        #expect(await w.client.findOpenPullRequestCalls.count == 1)
    }

    @Test func checkAgainStartsAnEnvironmentRefresh() async throws {
        let h = Harness()
        let w = try await adopt(h, h.makeState())
        #expect(h.environmentRefreshes.isEmpty)

        w.state.recheckGitHubConnection(refreshingEnvironment: true)
        try #require(await eventually { @MainActor in w.state.gitHubConnectionModel?.checksFinished == 2 })
        #expect(h.environmentRefreshes == [w.root])
    }
}
