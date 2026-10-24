import Foundation
import Testing

@testable import DiffViewer

/// Create Pull Request: what it opens, and what it reports when the repository moved
/// while its fresh reads ran.
@MainActor
struct WindowStatePullRequestTests {
    /// The URLs the window asked the browser to open.
    @MainActor private final class Browser {
        var opened: [URL] = []
        var opens = true
    }

    /// Local `feature` tracks `remote-feature`, so the URL shows which name it took.
    private static let tracked = localBranch(
        "feature", upstream: upstream("origin/remote-feature", remoteRef: "refs/heads/remote-feature"))
    private static let origin = [
        "origin": RemoteURLs(fetchURL: "git@github.com:me/widgets.git", pushURLs: ["git@github.com:me/widgets.git"])
    ]
    private static let changedMessage = "Branch or upstream changed before the pull request could open. Try again."

    /// Adopts a repository on `feature` and waits until Create Pull Request is enabled.
    private func adopt(_ h: Harness, browser: Browser) async throws -> (state: WindowState, client: StubRepoClient) {
        let state = h.makeState(openURL: { url in
            browser.opened.append(url)
            return browser.opens
        })
        let repo = await h.adopt(state, "A", files: []) { client in
            await client.set(headState: .named("feature"))
            await client.set(localBranches: [Self.tracked])
            await client.set(remoteURLs: Self.origin)
        }
        try #require(await eventually { @MainActor in state.pullRequestAvailability == .enabled })
        return (state, repo.client)
    }

    @Test func opensTheUpstreamsRemoteBranchNotTheLocalName() async throws {
        let h = Harness()
        let browser = Browser()
        let (state, _) = try await adopt(h, browser: browser)

        await state.openPullRequest()
        #expect(
            browser.opened.map(\.absoluteString) == [
                "https://github.com/me/widgets/compare/remote-feature?quick_pull=1"
            ])
        #expect(state.errorMessage == nil)
    }

    enum Race: CaseIterable {
        case gainsACommit
        case switchesBranch
        case changesRemote
        case changesRemoteRef
        case headMovesDuringBranchRead
        case closes
    }

    @Test(arguments: Race.allCases)
    func aRepositoryThatMovesDuringTheReadOpensNothing(race: Race) async throws {
        let h = Harness()
        let browser = Browser()
        let (state, client) = try await adopt(h, browser: browser)
        // Held reads park again on the re-read that follows a report, so the hold is lifted before release.
        let held: StubCall = race == .headMovesDuringBranchRead ? .localBranches : .remoteURLs
        await client.hold(held)
        let opening = Task { await state.openPullRequest() }
        try #require(await eventually { await client.heldCount(held) == 1 })

        let expected: String?
        switch race {
        case .gainsACommit:
            await client.set(localBranches: [
                localBranch(
                    "feature",
                    upstream: upstream(
                        "origin/remote-feature", remoteRef: "refs/heads/remote-feature",
                        tracking: .counts(ahead: 1, behind: 0)))
            ])
            expected = "feature has commits that aren't pushed. Push first."
        case .switchesBranch:
            await client.set(headState: .named("main"))
            await client.set(localBranches: [Self.tracked, localBranch("main", upstream: upstream("origin/main"))])
            expected = Self.changedMessage
        case .changesRemote:
            await client.set(localBranches: [
                localBranch(
                    "feature",
                    upstream: upstream("fork/remote-feature", remote: "fork", remoteRef: "refs/heads/remote-feature"))
            ])
            expected = Self.changedMessage
        case .changesRemoteRef:
            await client.set(localBranches: [localBranch("feature", upstream: upstream("origin/other"))])
            expected = Self.changedMessage
        case .headMovesDuringBranchRead:
            await client.set(headState: .named("main"))
            expected = Self.changedMessage
        case .closes:
            state.close()
            expected = nil
        }
        await client.hold(held, false)
        await client.release(held)
        await opening.value

        #expect(browser.opened.isEmpty)
        #expect(state.errorMessage == expected)
    }

    @Test func aRemoteGoneFromTheFreshReadIsReportedAndHidesTheButton() async throws {
        let h = Harness()
        let browser = Browser()
        let (state, client) = try await adopt(h, browser: browser)
        await client.set(remoteURLs: [:])

        await state.openPullRequest()
        #expect(browser.opened.isEmpty)
        #expect(state.errorMessage == "The remote origin no longer exists")
        #expect(state.pullRequestAvailability == .hidden)
    }

    @Test func aBrowserThatCannotOpenIsReported() async throws {
        let h = Harness()
        let browser = Browser()
        browser.opens = false
        let (state, _) = try await adopt(h, browser: browser)

        await state.openPullRequest()
        #expect(browser.opened.count == 1)
        #expect(state.errorMessage == "Couldn't open the browser")
    }

    /// The failures the tests above don't reach.
    @Test func messagesNameTheBranchAndRemote() {
        let messages = [GitHubPullRequestLink.Failure.notABranch, .notOnGitHub("fork"), .pushesElsewhere("fork")]
            .map { WindowState.pullRequestMessage(for: $0, branch: "feature") }
        #expect(
            messages == [
                "feature's upstream isn't a branch on its remote",
                "fork isn't a GitHub repository",
                "fork pushes somewhere other than its GitHub repository",
            ])
    }

    // MARK: Remote cache

    @Test func anOlderRemoteReadFinishingLaterCannotOverwriteANewerOne() async throws {
        let h = Harness()
        let browser = Browser()
        let (state, client) = try await adopt(h, browser: browser)
        await client.hold(.remoteURLs)
        let older = Task { await state.openPullRequest() }
        try #require(await eventually { await client.heldCount(.remoteURLs) == 1 })
        await client.set(remoteURLs: [:])
        let newer = Task { await state.openPullRequest() }
        try #require(await eventually { await client.heldCount(.remoteURLs) == 2 })

        await client.hold(.remoteURLs, false)
        await client.releaseLast(.remoteURLs)
        await newer.value
        #expect(state.pullRequestAvailability == .hidden)

        await client.release(.remoteURLs)
        await older.value
        #expect(state.pullRequestAvailability == .hidden)
    }

    @Test func aFailedReadKeepsTheCacheAndTheFetchStillRuns() async throws {
        let h = Harness()
        let (state, client) = try await adopt(h, browser: Browser())
        await client.fail(remoteURLs: true)
        let readsBefore = await client.remoteURLsCalls

        state.isBranchPickerPresented = true
        #expect(await eventually { await client.fetchCalls == ["origin"] })
        #expect(await eventually { @MainActor in state.fetchStatus == .idle && state.lastFetchRound != nil })
        #expect(await client.remoteURLsCalls > readsBefore)
        #expect(state.pullRequestAvailability == .enabled)
    }
}
