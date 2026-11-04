import Foundation
import Testing

@testable import DiffViewer

/// Listing origin's pull requests for the branch picker: when a listing starts, is coalesced
/// or dropped, and which results replace the list on show.
@MainActor
struct WindowStateBranchPullRequestTests {
    private static let feature = localBranch("feature", upstream: upstream("origin/feature"))
    private static let main = localBranch("main", upstream: upstream("origin/main"))
    nonisolated private static let withToken = GitHubAuthenticationStatus.token(source: .gitHubCLI, login: "me")
    nonisolated private static let widgets = GitHubRepository(owner: "me", name: "widgets")

    nonisolated private static func remote(_ url: String) -> RemoteURLs {
        RemoteURLs(fetchURL: url, pushURLs: [url])
    }

    nonisolated private static let widgetsRemotes = ["origin": remote("git@github.com:me/widgets.git")]

    private static func pullRequest(_ number: Int, branch: String = "feature") -> ListedPullRequest {
        ListedPullRequest(
            number: number, state: .open, url: URL(string: "https://github.com/me/widgets/pull/\(number)")!,
            headBranch: branch, headRepository: widgets, updatedAt: Date(timeIntervalSince1970: 100))
    }

    private static func listing(_ pullRequests: [ListedPullRequest], complete: Bool = true) -> PullRequestListing {
        PullRequestListing(
            pullRequests: pullRequests, headDefaultBranch: nil, allSourcesSucceeded: complete,
            openSourcesSucceeded: complete)
    }

    /// Adopts a repository on `feature` whose account check reports `status`, and waits for
    /// the status to publish. `configure` stubs the client further before adoption reads it.
    private func adopt(
        _ h: Harness, status: GitHubAuthenticationStatus = withToken,
        listing: PullRequestListing = listing([pullRequest(7)]),
        configure: (StubRepoClient) async -> Void = { _ in }
    ) async throws -> Window {
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: []) { client in
            await client.set(headState: .named("feature"))
            await client.set(localBranches: [Self.feature, Self.main])
            await client.set(remoteURLs: Self.widgetsRemotes)
            await client.set(gitHubAuthenticationStatus: status)
            await client.set(pullRequestListing: listing)
            await configure(client)
        }
        try #require(await eventually { @MainActor in state.gitHubAuthenticationStatus == status })
        return (h, state, repo.client, repo.root)
    }

    /// Whether the session has fully handled `count` listings. Pass a session captured
    /// earlier when the window closes.
    private func listed(_ session: RepoSession?, _ count: Int) async -> Bool {
        await eventually { @MainActor in session?.pullRequestListsFinished == count }
    }

    private func listed(_ w: Window, _ count: Int) async -> Bool {
        await listed(w.state.session, count)
    }

    /// A refresh as opening the picker or a fetch round asks for one. Synchronous, so what it
    /// decided can be checked straight after.
    private func trigger(_ w: Window) throws {
        w.state.refreshBranchPullRequests(session: try #require(w.state.session))
    }

    /// The pull request the list shows for `feature`.
    private func featurePullRequest(_ w: Window) -> Int? {
        w.state.branchPullRequests?.pullRequest(forHeadBranch: "feature")?.number
    }

    /// Re-reads the remotes as a configuration change does, and waits for them to publish.
    private func changeRemotes(_ w: Window, to remotes: [String: RemoteURLs]) async throws {
        await w.client.set(remoteURLs: remotes)
        w.h.tick(w.root, [.configuration])
        try #require(await eventually { @MainActor in w.state.remoteURLsByName == remotes })
    }

    // MARK: Starting

    @Test func openingThePickerListsAgainOnceTheCooldownHasPassed() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await listed(w, 1))
        h.clock += 120

        w.state.isBranchPickerPresented = true
        w.state.isBranchPickerPresented = false
        #expect(await eventually { await w.client.listPullRequestsCalls.count == 2 })
    }

    @Test func triggersDuringAListingAreCoalesced() async throws {
        let h = Harness()
        let w = try await adopt(h) { await $0.hold(.listPullRequests) }
        try #require(await eventually { await w.client.heldCount(.listPullRequests) == 1 })
        // Past any cooldown, so only the listing in flight holds the triggers back.
        h.clock += 600

        try trigger(w)
        try trigger(w)
        await w.client.hold(.listPullRequests, false)
        await w.client.release(.listPullRequests)
        try #require(await listed(w, 1))
        #expect(await w.client.listPullRequestsCalls.count == 1)
    }

    @Test(arguments: [(withToken, 120), (.anonymous, 600)] as [(GitHubAuthenticationStatus, TimeInterval)])
    func aListingWaitsOutItsCooldown(status: GitHubAuthenticationStatus, cooldown: TimeInterval) async throws {
        let h = Harness()
        let w = try await adopt(h, status: status)
        try #require(await listed(w, 1))

        h.clock += cooldown - 1
        try trigger(w)
        #expect(w.state.session?.pullRequestListInFlight == nil)

        h.clock += 1
        try trigger(w)
        #expect(await eventually { await w.client.listPullRequestsCalls.count == 2 })
    }

    @Test func aFailedListingIsRetriedOnlyAfterTheCooldown() async throws {
        let h = Harness()
        let w = try await adopt(h) { await $0.fail(.listPullRequests, with: GitHubAPIError.network) }
        try #require(await listed(w, 1))

        try trigger(w)
        #expect(w.state.session?.pullRequestListInFlight == nil)

        h.clock += 120
        try trigger(w)
        #expect(await eventually { await w.client.listPullRequestsCalls.count == 2 })
    }

    // MARK: Which results stay

    @Test func aSuccessfulEmptyListingClearsTheList() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await listed(w, 1))
        try #require(featurePullRequest(w) == 7)
        await w.client.set(pullRequestListing: Self.listing([]))

        h.clock += 120
        try trigger(w)
        try #require(await listed(w, 2))
        #expect(w.state.branchPullRequests != nil)
        #expect(featurePullRequest(w) == nil)
    }

    @Test func aFailedListingKeepsTheList() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await listed(w, 1))
        await w.client.fail(.listPullRequests, with: GitHubAPIError.network)

        h.clock += 120
        try trigger(w)
        try #require(await listed(w, 2))
        #expect(featurePullRequest(w) == 7)
    }

    @Test func aPartialListingPublishesOnlyWithoutAList() async throws {
        let h = Harness()
        let w = try await adopt(h, listing: Self.listing([Self.pullRequest(7)], complete: false))
        try #require(await listed(w, 1))
        #expect(featurePullRequest(w) == 7)
        await w.client.set(pullRequestListing: Self.listing([Self.pullRequest(8)], complete: false))

        h.clock += 120
        try trigger(w)
        try #require(await listed(w, 2))
        #expect(featurePullRequest(w) == 7)
    }

    @Test func closingTheWindowDuringAListingPublishesNothing() async throws {
        let h = Harness()
        let w = try await adopt(h) { await $0.hold(.listPullRequests) }
        try #require(await eventually { await w.client.heldCount(.listPullRequests) == 1 })
        let session = try #require(w.state.session)
        w.state.close()

        await w.client.hold(.listPullRequests, false)
        await w.client.release(.listPullRequests)
        try #require(await listed(session, 1))
        #expect(w.state.branchPullRequests == nil)
    }

    // MARK: Identity

    enum RemoteChange: CaseIterable, Sendable {
        case originMoves
        case upstreamAppears
        case originDisappears

        var remotes: [String: RemoteURLs] {
            let origin = WindowStateBranchPullRequestTests.widgetsRemotes
            switch self {
            case .originMoves:
                return ["origin": WindowStateBranchPullRequestTests.remote("git@github.com:me/gadgets.git")]
            case .upstreamAppears:
                return origin.merging(
                    ["upstream": WindowStateBranchPullRequestTests.remote("git@github.com:them/widgets.git")]
                ) { old, _ in old }
            case .originDisappears:
                return [:]
            }
        }

        /// Whether the new remotes start a listing of their own.
        var listsAgain: Bool { self != .originDisappears }
    }

    @Test(arguments: RemoteChange.allCases)
    func aNewIdentityClearsTheListAndDropsTheOldListing(change: RemoteChange) async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await listed(w, 1))
        await w.client.hold(.listPullRequests)
        h.clock += 120
        try trigger(w)
        try #require(await eventually { await w.client.heldCount(.listPullRequests) == 1 })

        try await changeRemotes(w, to: change.remotes)
        #expect(w.state.branchPullRequests == nil)
        // Both listings parked, so the new one can't finish before the old one is checked.
        let held = change.listsAgain ? 2 : 1
        try #require(await eventually { await w.client.heldCount(.listPullRequests) == held })

        await w.client.hold(.listPullRequests, false)
        await w.client.releaseFirst(.listPullRequests)
        try #require(await listed(w, 2))
        #expect(w.state.branchPullRequests == nil)
        if change.listsAgain {
            await w.client.release(.listPullRequests)
            try #require(await listed(w, 3))
        }
    }

    @Test func anOldListingFinishingLateLeavesTheNewOneInFlight() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await listed(w, 1))
        await w.client.hold(.listPullRequests)
        h.clock += 120
        try trigger(w)
        try #require(await eventually { await w.client.heldCount(.listPullRequests) == 1 })
        try await changeRemotes(w, to: RemoteChange.originMoves.remotes)
        try #require(await eventually { await w.client.heldCount(.listPullRequests) == 2 })

        await w.client.hold(.listPullRequests, false)
        await w.client.releaseFirst(.listPullRequests)
        try #require(await listed(w, 2))
        h.clock += 120
        try trigger(w)
        await w.client.release(.listPullRequests)
        try #require(await listed(w, 3))
        #expect(await w.client.listPullRequestsCalls.count == 3)
    }

    @Test func aRemoteURLThatOnlyChangesCaseKeepsTheList() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await listed(w, 1))

        try await changeRemotes(w, to: ["origin": Self.remote("git@github.com:Me/Widgets.git")])
        #expect(featurePullRequest(w) == 7)
        #expect(w.state.session?.pullRequestListInFlight == nil)
        #expect(await w.client.listPullRequestsCalls.count == 1)
    }

    // MARK: Opening

    /// The URLs a stubbed browser was asked to open.
    @MainActor private final class Browser {
        var opened: [URL] = []
    }

    @Test(arguments: [true, false])
    func openingARowsPullRequestClosesThePickerOnlyOnceTheBrowserOpens(opens: Bool) async throws {
        let h = Harness()
        let w = try await adopt(h)
        let browser = Browser()
        w.state.openURL = { url in
            browser.opened.append(url)
            return opens
        }
        w.state.isBranchPickerPresented = true
        let url = try #require(URL(string: "https://github.com/me/widgets/pull/7"))

        w.state.openPullRequest(url: url)
        #expect(browser.opened == [url])
        #expect(w.state.isBranchPickerPresented == !opens)
        #expect(w.state.errorMessage == (opens ? nil : "Couldn't open the browser"))
        #expect(await w.client.switchBranchCalls.isEmpty)
    }
}
