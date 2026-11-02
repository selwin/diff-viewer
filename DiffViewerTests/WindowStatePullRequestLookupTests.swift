import Foundation
import Testing

@testable import DiffViewer

/// Finding HEAD's open pull request on GitHub: when a lookup starts, joins,
/// retries or follows up, and which results the window keeps.
@MainActor
struct WindowStatePullRequestLookupTests {
    /// Local `feature` tracks `remote-feature`, so the lookup shows which name it took.
    private static let feature = localBranch(
        "feature", upstream: upstream("origin/remote-feature", remoteRef: "refs/heads/remote-feature"))
    /// `feature` after its upstream moved to `origin/other`, without a checkout.
    private static let featureTrackingOther = localBranch("feature", upstream: upstream("origin/other"))
    private static let main = localBranch("main", upstream: upstream("origin/main"))
    private static let withToken = GitHubAuthenticationStatus.token(source: .gitHubCLI, login: "me")
    private static let lookupFailure = GitHubAPIError.network

    private static func remotes(_ repository: String) -> [String: RemoteURLs] {
        let url = "git@github.com:me/\(repository).git"
        return ["origin": RemoteURLs(fetchURL: url, pushURLs: [url])]
    }

    private static func pullRequest(_ number: Int) -> GitHubPullRequest {
        GitHubPullRequest(number: number, url: URL(string: "https://github.com/me/widgets/pull/\(number)")!)
    }

    /// Adopts a repository on `feature` whose account check reports `status`, and waits for
    /// the status to publish. `configure` stubs the client further before adoption reads it.
    private func adopt(
        _ h: Harness, status: GitHubAuthenticationStatus = withToken, pullRequest: GitHubPullRequest? = pullRequest(7),
        configure: (StubRepoClient) async -> Void = { _ in }
    ) async throws -> Window {
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: []) { client in
            await client.set(headState: .named("feature"))
            await client.set(localBranches: [Self.feature, Self.main])
            await client.set(remoteURLs: Self.remotes("widgets"))
            await client.set(gitHubAuthenticationStatus: status)
            await client.set(openPullRequest: pullRequest)
            await configure(client)
        }
        try #require(await eventually { @MainActor in state.gitHubAuthenticationStatus == status })
        return (h, state, repo.client, repo.root)
    }

    /// Whether the window's session has fully handled `count` lookups, so what it published
    /// can be checked straight after. Pass a session captured earlier when the window closes.
    private func handled(_ session: RepoSession?, _ count: Int) async -> Bool {
        await eventually { @MainActor in session?.pullRequestLookupsFinished == count }
    }

    private func handled(_ w: Window, _ count: Int) async -> Bool {
        await handled(w.state.session, count)
    }

    private func lift(_ client: StubRepoClient) async {
        await client.hold(.findOpenPullRequest, false)
        await client.release(.findOpenPullRequest)
    }

    // MARK: Starting

    @Test func withoutATokenTheLookupStillRuns() async throws {
        let h = Harness()
        let w = try await adopt(h, status: .anonymous)
        #expect(await eventually { @MainActor in w.state.pullRequestAvailability == .view(Self.pullRequest(7)) })
        #expect(await w.client.findOpenPullRequestCalls.map(\.remoteBranchName) == ["remote-feature"])
        let header = BranchPickerHeaderText.make(snapshot: w.state.branchPickerSnapshot).detail(fetch: nil)
        #expect(header == "GitHub: public only")
    }

    @Test func aHeldAccountCheckNeitherDelaysNorRepeatsTheLookup() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await handled(w, 1))
        await w.client.hold(.gitHubRepositoryCheck)
        await w.client.set(openPullRequest: Self.pullRequest(8))

        await w.state.fetchAllRemotes()
        #expect(await eventually { @MainActor in w.state.pullRequestAvailability == .view(Self.pullRequest(8)) })
        #expect(await w.client.heldCount(.gitHubRepositoryCheck) == 1)

        await w.client.hold(.gitHubRepositoryCheck, false)
        await w.client.release(.gitHubRepositoryCheck)
        try #require(await eventually { @MainActor in w.state.gitHubConnectionModel?.isChecking == false })
        #expect(w.state.session?.pullRequestInFlight == nil)
        #expect(await w.client.findOpenPullRequestCalls.count == 2)
    }

    @Test func anUpstreamChangeWithoutACheckoutLooksUpAgain() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await handled(w, 1))
        await w.client.set(localBranches: [Self.featureTrackingOther, Self.main])
        await w.client.set(openPullRequest: Self.pullRequest(8))

        await w.state.refresh()
        #expect(await eventually { @MainActor in w.state.pullRequestAvailability == .view(Self.pullRequest(8)) })
        #expect(await w.client.findOpenPullRequestCalls.last?.remoteBranchName == "other")
    }

    @Test func aRemoteURLChangeDeliveredAsARescanQueriesTheNewRepository() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await handled(w, 1))
        await w.client.set(remoteURLs: Self.remotes("gadgets"))

        h.tick(w.root, [.rescan])
        #expect(
            await eventually { @MainActor in w.state.pullRequestLookup?.identity.headRepository.name == "gadgets" })
        #expect(await w.client.findOpenPullRequestCalls.last?.headRepository.name == "gadgets")
        // The new origin needs its own connection check.
        #expect(await eventually { await w.client.gitHubRepositoryCheckCalls.last?.name == "gadgets" })
    }

    @Test func aRescanWithUnchangedRemotesLeavesTheConnectionAlone() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await handled(w, 1))
        let remoteReadsBefore = await w.client.remoteURLsCalls

        h.tick(w.root, [.rescan])
        try #require(await eventually { await w.client.remoteURLsCalls > remoteReadsBefore })
        try #require(await eventually { @MainActor in w.state.gitHubConnectionModel?.isChecking == false })
        // A rescan comes with every return to a tab, so the same origin isn't checked again.
        #expect(await w.client.gitHubRepositoryCheckCalls.count == 1)
    }

    @Test func theCreationPathsRemoteReadUpdatesTheIdentity() async throws {
        let h = Harness()
        let w = try await adopt(h, pullRequest: nil)
        try #require(await handled(w, 1))
        try #require(w.state.pullRequestAvailability == .enabled)
        await w.client.set(remoteURLs: Self.remotes("gadgets"))

        await w.state.openPullRequest()
        #expect(w.state.currentPullRequestIdentity?.headRepository.name == "gadgets")
        #expect(await eventually { await w.client.findOpenPullRequestCalls.last?.headRepository.name == "gadgets" })
    }

    // MARK: Joining, following up and retrying

    @Test func aDiscardedLookupIsAskedAgainOnReturningToTheBranch() async throws {
        let h = Harness()
        let w = try await adopt(h) { await $0.hold(.findOpenPullRequest) }
        try #require(await eventually { await w.client.heldCount(.findOpenPullRequest) == 1 })
        await w.client.set(headState: .detached(sha: objectID("d")))
        await w.state.refresh()
        await lift(w.client)
        try #require(await handled(w, 1))
        #expect(w.state.pullRequestLookup == nil)

        await w.client.set(headState: .named("feature"))
        await w.state.refresh()
        #expect(await eventually { @MainActor in w.state.pullRequestAvailability == .view(Self.pullRequest(7)) })
        #expect(await w.client.findOpenPullRequestCalls.count == 2)
    }

    @Test func anIdenticalLookupInFlightIsJoinedOrFollowedOnce() async throws {
        let h = Harness()
        let w = try await adopt(h) { await $0.hold(.findOpenPullRequest) }
        try #require(await eventually { await w.client.heldCount(.findOpenPullRequest) == 1 })

        // A branch read is automatic: it joins.
        await w.state.refresh()
        #expect(w.state.session?.pullRequestPendingForce == false)
        // Fetch forces: it follows the lookup in flight rather than starting beside it.
        await w.state.fetchAllRemotes()
        #expect(await eventually { @MainActor in w.state.session?.pullRequestPendingForce == true })
        #expect(await w.client.findOpenPullRequestCalls.count == 1)

        await lift(w.client)
        #expect(await handled(w, 2))
        #expect(await w.client.findOpenPullRequestCalls.count == 2)
        #expect(w.state.session?.pullRequestInFlight == nil)
    }

    @Test func aQueuedForceDoesNotCarryOverToAnotherIdentity() async throws {
        let h = Harness()
        let w = try await adopt(h) { await $0.hold(.findOpenPullRequest) }
        try #require(await eventually { await w.client.heldCount(.findOpenPullRequest) == 1 })
        await w.state.fetchAllRemotes()
        try #require(await eventually { @MainActor in w.state.session?.pullRequestPendingForce == true })
        await w.client.set(localBranches: [Self.featureTrackingOther, Self.main])
        await w.state.refresh()
        try #require(await eventually { await w.client.heldCount(.findOpenPullRequest) == 2 })

        await lift(w.client)
        try #require(await handled(w, 2))
        // A carried-over force would have started a third lookup while handling the second.
        #expect(w.state.session?.pullRequestInFlight == nil)
        #expect(await w.client.findOpenPullRequestCalls.map(\.remoteBranchName) == ["remote-feature", "other"])
    }

    @Test func aFailedLookupIsRetriedOnlyWhenForced() async throws {
        let h = Harness()
        let w = try await adopt(h) { await $0.fail(.findOpenPullRequest, with: Self.lookupFailure) }
        try #require(await handled(w, 1))

        await w.state.refresh()
        #expect(w.state.session?.pullRequestInFlight == nil)
        #expect(await w.client.findOpenPullRequestCalls.count == 1)

        await w.state.fetchAllRemotes()
        #expect(await eventually { await w.client.findOpenPullRequestCalls.count == 2 })
    }

    @Test func aFailedLookupIsRetriedEvenWhenTheRemoteReadFails() async throws {
        let h = Harness()
        let w = try await adopt(h) { await $0.fail(.findOpenPullRequest, with: Self.lookupFailure) }
        try #require(await handled(w, 1))
        await w.client.fail(remoteURLs: true)
        await w.client.fail(.findOpenPullRequest, with: nil)

        await w.state.fetchAllRemotes()
        #expect(await eventually { @MainActor in w.state.pullRequestAvailability == .view(Self.pullRequest(7)) })
    }

    @Test func aCancelledLookupIsNotRecordedAsFailed() async throws {
        let h = Harness()
        let w = try await adopt(h) { await $0.fail(.findOpenPullRequest, with: CancellationError()) }
        try #require(await handled(w, 1))
        #expect(w.state.session?.failedPullRequestIdentity == nil)
        #expect(w.state.pullRequestLookup == nil)
        await w.client.fail(.findOpenPullRequest, with: nil)

        // Automatic: a recorded failure would have been skipped.
        await w.state.refresh()
        #expect(await eventually { @MainActor in w.state.pullRequestAvailability == .view(Self.pullRequest(7)) })
    }

    @Test func aThrowingAccountCheckKeepsTheLastStatusAndPR() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await handled(w, 1))
        let checksBefore = await w.client.gitHubRepositoryCheckCalls.count
        await w.client.fail(.gitHubRepositoryCheck, with: CancellationError())

        await w.state.fetchAllRemotes()
        try #require(await eventually { await w.client.gitHubRepositoryCheckCalls.count == checksBefore + 1 })
        try #require(await eventually { @MainActor in w.state.gitHubConnectionModel?.isChecking == false })
        #expect(w.state.gitHubAuthenticationStatus == Self.withToken)
        #expect(w.state.pullRequestAvailability == .view(Self.pullRequest(7)))
    }

    // MARK: Which results stay

    @Test func anOlderResponseFinishingLastDoesNotOverwriteTheNewer() async throws {
        let h = Harness()
        let w = try await adopt(h) { await $0.hold(.findOpenPullRequest) }
        try #require(await eventually { await w.client.heldCount(.findOpenPullRequest) == 1 })
        await w.client.set(localBranches: [Self.featureTrackingOther, Self.main])
        await w.client.set(openPullRequest: Self.pullRequest(8))
        await w.state.refresh()
        try #require(await eventually { await w.client.heldCount(.findOpenPullRequest) == 2 })
        await w.client.hold(.findOpenPullRequest, false)

        await w.client.releaseLast(.findOpenPullRequest)
        try #require(await handled(w, 1))
        #expect(w.state.pullRequestAvailability == .view(Self.pullRequest(8)))
        await w.client.release(.findOpenPullRequest)
        try #require(await handled(w, 2))
        #expect(w.state.pullRequestAvailability == .view(Self.pullRequest(8)))
    }

    @Test func losingTheTokenKeepsThePRAndTheLookups() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await handled(w, 1))
        await w.client.hold(.findOpenPullRequest)
        await w.client.set(gitHubAuthenticationStatus: .anonymous)
        await w.client.set(openPullRequest: Self.pullRequest(8))

        await w.state.fetchAllRemotes()
        try #require(await eventually { @MainActor in w.state.gitHubAuthenticationStatus == .anonymous })
        #expect(w.state.pullRequestAvailability == .view(Self.pullRequest(7)))
        try #require(await eventually { await w.client.heldCount(.findOpenPullRequest) == 1 })
        await lift(w.client)
        #expect(await eventually { @MainActor in w.state.pullRequestAvailability == .view(Self.pullRequest(8)) })
    }

    @Test func closingTheWindowDuringALookupPublishesNothing() async throws {
        let h = Harness()
        let w = try await adopt(h) { await $0.hold(.findOpenPullRequest) }
        try #require(await eventually { await w.client.heldCount(.findOpenPullRequest) == 1 })
        let session = try #require(w.state.session)
        w.state.close()

        await lift(w.client)
        try #require(await handled(session, 1))
        #expect(w.state.pullRequestLookup == nil)
    }

    @Test func aSuccessfulEmptyAnswerClearsAnOldPR() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await eventually { @MainActor in w.state.pullRequestAvailability == .view(Self.pullRequest(7)) })
        await w.client.set(openPullRequest: nil)

        await w.state.fetchAllRemotes()
        #expect(await eventually { @MainActor in w.state.pullRequestAvailability == .enabled })
        #expect(w.state.pullRequestLookup?.identity == w.state.currentPullRequestIdentity)
    }

    @Test func aFailedLookupKeepsTheResultOnlyForTheSameIdentity() async throws {
        let h = Harness()
        let w = try await adopt(h)
        try #require(await handled(w, 1))
        await w.client.fail(.findOpenPullRequest, with: Self.lookupFailure)

        await w.state.fetchAllRemotes()
        try #require(await handled(w, 2))
        #expect(w.state.pullRequestAvailability == .view(Self.pullRequest(7)))

        await w.client.set(localBranches: [Self.featureTrackingOther, Self.main])
        await w.state.refresh()
        try #require(await handled(w, 3))
        #expect(w.state.pullRequestLookup == nil)
    }
}
