import Foundation
import Testing

@testable import DiffViewer

/// The pull request button: finding a branch's existing pull request, what it opens, and
/// what it reports when the repository moved while its fresh reads ran.
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

    private static let unpublished = localBranch("feature")
    private static let main = localBranch("main", upstream: upstream("origin/main"))

    /// Adopts a repository on `feature` and waits until Create Pull Request is enabled.
    /// With `publishFirst`, `feature` starts unpublished and a publish then sets the offer.
    private func adopt(
        _ h: Harness, browser: Browser, publishFirst: Bool = false
    ) async throws -> (state: WindowState, client: StubRepoClient) {
        let state = h.makeState(openURL: { url in
            browser.opened.append(url)
            return browser.opens
        })
        let repo = await h.adopt(state, "A", files: []) { client in
            await client.set(headState: .named("feature"))
            await client.set(localBranches: publishFirst ? [Self.main, Self.unpublished] : [Self.tracked])
            await client.set(remoteURLs: Self.origin)
        }
        if publishFirst { try await publish(state, repo.client, branchesAfterPublish: [Self.main, Self.tracked]) }
        try #require(await eventually { @MainActor in state.pullRequestAvailability == .enabled })
        return (state, repo.client)
    }

    /// Publishes `feature`, which the repository reports as `branchesAfterPublish` once the push lands.
    private func publish(
        _ state: WindowState, _ client: StubRepoClient, branchesAfterPublish: [LocalBranch]
    ) async throws {
        state.isBranchPickerPresented = true
        await state.fetchForBranchPicker()
        await client.hold(.publish)
        let publishing = Task { await state.publish(branch: "feature", to: "origin") }
        try #require(await eventually { await client.heldCount(.publish) == 1 })
        await client.set(localBranches: branchesAfterPublish)
        await client.hold(.publish, false)
        await client.release(.publish)
        await publishing.value
        state.isBranchPickerPresented = false
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

    @Test func openingTheBrowserClearsTheOffer() async throws {
        let h = Harness()
        let (state, _) = try await adopt(h, browser: Browser(), publishFirst: true)
        try #require(state.pullRequestOfferedBranchName == "feature")

        await state.openPullRequest()
        #expect(state.pullRequestOfferedBranchName == nil)
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
        let (state, _) = try await adopt(h, browser: browser, publishFirst: true)
        try #require(state.pullRequestOfferedBranchName == "feature")

        await state.openPullRequest()
        #expect(browser.opened.count == 1)
        #expect(state.errorMessage == "Couldn't open the browser")
        #expect(state.pullRequestOfferedBranchName == "feature", "the offer stays for a retry")
    }

    // MARK: Offer after publishing

    @Test(
        arguments: [("feature", false, "feature"), ("feature", true, nil), ("main", false, nil)]
            as [(String, Bool, String?)])
    func onlyASuccessfulPublishOfTheCurrentBranchSetsTheOffer(head: String, fails: Bool, offered: String?) async throws
    {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: []) { client in
            await client.set(headState: .named(head))
            await client.set(localBranches: [Self.main, Self.unpublished])
            await client.set(remoteURLs: Self.origin)
        }
        try #require(await eventually { @MainActor in state.branchReadStatus == .loaded })
        await repo.client.fail(publish: fails)

        try await publish(state, repo.client, branchesAfterPublish: [Self.main, Self.tracked])
        #expect(state.pullRequestOfferedBranchName == offered)
    }

    /// Push shows while the branch is ahead, so Create PR waits for it rather than being lost.
    @Test func theOfferSurvivesPushTemporarilyShowing() async throws {
        let h = Harness()
        let (state, client) = try await adopt(h, browser: Browser(), publishFirst: true)
        let ahead = localBranch(
            "feature",
            upstream: upstream(
                "origin/remote-feature", remoteRef: "refs/heads/remote-feature", tracking: .counts(ahead: 1, behind: 0))
        )
        await client.set(localBranches: [Self.main, ahead])
        await state.refresh()
        try #require(await eventually { @MainActor in state.currentBranchSync?.pullRequest == .hidden })
        try #require(state.pullRequestOfferedBranchName == "feature")

        await client.hold(.push)
        let pushing = Task { await state.push(branch: "feature") }
        try #require(await eventually { await client.heldCount(.push) == 1 })
        await client.set(localBranches: [Self.main, Self.tracked])
        await client.hold(.push, false)
        await client.release(.push)
        await pushing.value
        #expect(await eventually { @MainActor in state.currentBranchSync?.pullRequest == .enabled })
    }

    @Test(arguments: [HeadState.named("main"), .detached(sha: objectID("d"))])
    func movingOffTheBranchEndsTheOfferForGood(away: HeadState) async throws {
        let h = Harness()
        let (state, client) = try await adopt(h, browser: Browser(), publishFirst: true)
        try #require(state.pullRequestOfferedBranchName == "feature")

        await client.set(headStateAfterSwitch: away)
        await state.switchBranch(to: "main")
        #expect(state.pullRequestOfferedBranchName == nil)

        await client.set(headStateAfterSwitch: .named("feature"))
        await state.switchBranch(to: "feature")
        #expect(state.headState == .named("feature"))
        #expect(state.pullRequestOfferedBranchName == nil)
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

    // MARK: Existing pull request

    /// `feature` tracks `origin/feature`, whose remote-tracking tip `origin` advertises as
    /// pull request 88.
    private static let pushedTip = objectID("pushed")
    private static let feature = localBranch("feature", upstream: upstream("origin/feature"))
    private static let featureTip = remoteBranch("feature", tipSha: pushedTip)
    private static let sharedTip = [featureTip, remoteBranch("other", tipSha: pushedTip)]
    private static let pullURL = "https://github.com/me/widgets/pull/88"
    private static let acmePullURL = "https://github.com/acme/widgets/pull/88"
    private static let acme = RemoteURLs(
        fetchURL: "https://github.com/acme/widgets", pushURLs: ["https://github.com/acme/widgets"])
    private static let withUpstream = origin.merging(["upstream": acme]) { $1 }
    private static let offline = ProcessError.failed(command: "git ls-remote", status: 128, stderr: "offline")

    private static func existing(at url: String = pullURL) -> PullRequestAvailability {
        .existing(number: 88, url: URL(string: url)!)
    }

    /// Adopts a repository on a pushed `feature`. `configure` runs after the defaults.
    private func adoptPushed(
        _ h: Harness, browser: Browser = Browser(), configure: (StubRepoClient) async -> Void = { _ in }
    ) async -> (state: WindowState, client: StubRepoClient) {
        let state = h.makeState(openURL: { url in
            browser.opened.append(url)
            return browser.opens
        })
        let repo = await h.adopt(state, "A", files: []) { client in
            await client.set(headState: .named("feature"))
            await client.set(localBranches: [Self.feature])
            await client.set(remoteBranches: [Self.featureTip])
            await client.set(remoteURLs: Self.origin)
            await client.set(pullRequestHeads: [Self.pushedTip: 88], remote: "origin")
            await configure(client)
        }
        return (state, repo.client)
    }

    /// Waits for the newest lookup, and any that replaced it meanwhile.
    private func settle(_ state: WindowState) async {
        while let task = state.session?.pullRequestLookupTask {
            await task.value
            if state.session?.pullRequestLookupTask == task { return }
        }
    }

    private func releaseHeads(_ client: StubRepoClient) async {
        await client.hold(.pullRequestHeads, false)
        await client.release(.pullRequestHeads)
    }

    @Test func adoptionFindsThePullRequestOfTheFullyPublishedBranch() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h)

        #expect(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })
        #expect(await client.pullRequestHeadsCalls == ["origin"])
    }

    @Test func discoveryFinishingAfterTheBranchReadReplacesTheUnqueriedLookup() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h) { await $0.hold(.remoteURLs) }
        // Discovery's read, then the lookup's.
        try #require(await eventually { await client.heldCount(.remoteURLs) == 2 })
        await client.releaseFirst(.remoteURLs)
        try #require(await eventually { await client.heldCount(.remoteURLs) == 2 })

        await client.hold(.remoteURLs, false)
        await client.release(.remoteURLs)
        #expect(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })
        #expect(await client.pullRequestHeadsCalls == ["origin"])
    }

    @Test func anUnchangedKeyIsCheckedAgainOnlyAfterTheCooldown() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h)
        try #require(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })

        await state.refresh()
        #expect(state.session?.inFlightPullRequestLookup == nil)
        h.clock += WindowState.fetchCooldown + 1
        await state.refresh()
        #expect(await eventually { await client.pullRequestHeadsCalls.count == 2 })
    }

    @Test func aFailedLookupRetriesOnTheNextPublishedRead() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h) {
            await $0.fail(pullRequestHeads: Self.offline, remote: "origin")
        }
        try #require(await eventually { await client.pullRequestHeadsCalls.count == 1 })
        await settle(state)
        #expect(state.pullRequestLookupCache == nil)

        await client.fail(pullRequestHeads: nil, remote: "origin")
        await state.refresh()
        #expect(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })
    }

    @Test func aMatchOnTheOwnRemoteNeedsNoAnswerFromUpstream() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h) { client in
            await client.set(remoteURLs: Self.withUpstream)
            await client.fail(pullRequestHeads: Self.offline, remote: "upstream")
        }

        #expect(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })
        #expect(await client.pullRequestHeadsCalls == ["origin"])
    }

    @Test func anUpstreamMatchAfterAnOwnRemoteFailureIsInconclusive() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h) { client in
            await client.set(remoteURLs: Self.withUpstream)
            await client.fail(pullRequestHeads: Self.offline, remote: "origin")
            await client.set(pullRequestHeads: [Self.pushedTip: 5], remote: "upstream")
        }
        try #require(await eventually { await !client.pullRequestHeadsCalls.isEmpty })
        await settle(state)

        #expect(state.pullRequestLookupCache == nil)
        #expect(state.pullRequestAvailability == .enabled)
    }

    @Test func returningToABranchShowsItsPullRequestAgain() async throws {
        let h = Harness()
        let main = localBranch("main", upstream: upstream("origin/main"))
        let (state, client) = await adoptPushed(h) { client in
            await client.set(localBranches: [Self.feature, main])
            await client.set(remoteBranches: [Self.featureTip, remoteBranch("main", tipSha: objectID("main"))])
        }
        try #require(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })

        await client.set(headStateAfterSwitch: .named("main"))
        await state.switchBranch(to: "main")
        try #require(await eventually { @MainActor in state.pullRequestLookupCache?.key.branchName == "main" })
        #expect(state.pullRequestAvailability == .enabled)

        await client.set(headStateAfterSwitch: .named("feature"))
        await state.switchBranch(to: "feature")
        #expect(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })
    }

    @Test func aCachedMatchHidesWhileItsTipIsSharedAndReturnsWithoutALookup() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h)
        try #require(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })

        await client.set(remoteBranches: Self.sharedTip)
        await state.refresh()
        #expect(state.pullRequestAvailability == .enabled)

        await client.set(remoteBranches: [Self.featureTip])
        await state.refresh()
        #expect(state.pullRequestAvailability == Self.existing())
        #expect(await client.pullRequestHeadsCalls.count == 1)
    }

    @Test func aTipThatStopsBeingSharedIsLookedUpAtOnce() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h) { await $0.set(remoteBranches: Self.sharedTip) }
        try #require(await eventually { @MainActor in state.session?.observedLookupConfiguration != nil })
        await settle(state)
        let reads = await client.remoteURLsCalls

        // The last URL read already shows the tip is shared.
        await state.refresh()
        #expect(state.session?.inFlightPullRequestLookup == nil)
        #expect(await client.remoteURLsCalls == reads)

        await client.set(remoteBranches: [Self.featureTip])
        await state.refresh()
        #expect(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })
        #expect(await client.pullRequestHeadsCalls.count == 1)
    }

    @Test func aTipSharedWhileTheLookupRunsPublishesNothing() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h) { await $0.hold(.pullRequestHeads) }
        try #require(await eventually { await client.heldCount(.pullRequestHeads) == 1 })

        await client.set(remoteBranches: Self.sharedTip)
        await state.refresh()
        await releaseHeads(client)
        await settle(state)
        #expect(state.pullRequestLookupCache == nil)
        #expect(state.pullRequestAvailability == .enabled)
    }

    @Test func aTipSharedWhileANoMatchLookupRunsIsNotCachedAndLooksUpAgainOnceUnshared() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h) { client in
            await client.set(pullRequestHeads: [:], remote: "origin")
            await client.hold(.pullRequestHeads)
        }
        try #require(await eventually { await client.heldCount(.pullRequestHeads) == 1 })

        await client.set(remoteBranches: Self.sharedTip)
        await state.refresh()
        await releaseHeads(client)
        await settle(state)
        #expect(state.pullRequestLookupCache == nil)

        await client.set(remoteBranches: [Self.featureTip])
        await state.refresh()
        await settle(state)
        #expect(await client.pullRequestHeadsCalls.count == 2)
        #expect(state.pullRequestLookupCache?.result == nil)
        #expect(state.pullRequestLookupCache?.key.branchName == "feature")
    }

    @Test func aRemoteURLChangeDuringTheFirstLookupPublishesTheReplacementsRepository() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h) { await $0.hold(.pullRequestHeads) }
        try #require(await eventually { await client.heldCount(.pullRequestHeads) == 1 })
        let first = state.session?.pullRequestLookupTask

        await client.set(remoteURLs: ["origin": Self.acme])
        await state.fetchAllRemotes()
        try #require(await eventually { await client.heldCount(.pullRequestHeads) == 2 })
        await client.releaseFirst(.pullRequestHeads)
        await first?.value
        #expect(state.existingPullRequest == nil)

        await releaseHeads(client)
        #expect(
            await eventually { @MainActor in state.pullRequestAvailability == Self.existing(at: Self.acmePullURL) })
    }

    @Test func aRemoteURLChangeUnderTheSameKeyDropsTheMatchAndStartsOneReplacement() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h)
        try #require(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })

        await client.hold(.pullRequestHeads)
        await client.set(remoteURLs: ["origin": Self.acme])
        await state.fetchAllRemotes()
        try #require(await eventually { await client.heldCount(.pullRequestHeads) == 1 })
        #expect(state.pullRequestAvailability == .enabled)

        await releaseHeads(client)
        #expect(
            await eventually { @MainActor in state.pullRequestAvailability == Self.existing(at: Self.acmePullURL) })
        #expect(await client.pullRequestHeadsCalls.count == 2)
    }

    enum KeyChange: CaseIterable {
        case switchesBranch
        case losesUpstream
    }

    @Test(arguments: KeyChange.allCases)
    func aKeyChangeWhileTheLookupIsHeldRunsNothingFurther(change: KeyChange) async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h) { client in
            await client.set(remoteURLs: Self.withUpstream)
            await client.hold(.pullRequestHeads)
        }
        try #require(await eventually { await client.heldCount(.pullRequestHeads) == 1 })
        let held = state.session?.pullRequestLookupTask

        switch change {
        case .switchesBranch:
            await client.set(headState: .named("main"))
            await client.set(localBranches: [Self.feature, localBranch("main")])
        case .losesUpstream:
            await client.set(localBranches: [
                localBranch("feature", upstream: upstream("origin/feature", tracking: .gone))
            ])
        }
        await state.refresh()
        let reads = await client.remoteURLsCalls
        await releaseHeads(client)
        await held?.value

        #expect(await client.pullRequestHeadsCalls == ["origin"])
        #expect(await client.remoteURLsCalls == reads)
        #expect(state.pullRequestLookupCache == nil)
    }

    @Test func anOlderLookupLeavesItsReplacementsSlot() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h) { await $0.hold(.pullRequestHeads) }
        try #require(await eventually { await client.heldCount(.pullRequestHeads) == 1 })
        let older = state.session?.pullRequestLookupTask

        await client.set(remoteURLs: ["origin": Self.acme])
        await state.fetchAllRemotes()
        try #require(await eventually { await client.heldCount(.pullRequestHeads) == 2 })
        let replacement = try #require(state.session?.inFlightPullRequestLookup)
        await client.releaseFirst(.pullRequestHeads)
        await older?.value

        #expect(state.session?.inFlightPullRequestLookup == replacement)
        await releaseHeads(client)
    }

    @Test func sameKeyRequestsShareOneLookup() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h) { await $0.hold(.pullRequestHeads) }
        try #require(await eventually { await client.heldCount(.pullRequestHeads) == 1 })
        let reads = await client.remoteURLsCalls

        await state.refresh()
        await state.refresh()
        #expect(await client.remoteURLsCalls == reads)

        await releaseHeads(client)
        #expect(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })
        #expect(await client.pullRequestHeadsCalls.count == 1)
    }

    @Test func aManualRoundLooksUpAgainOnlyAfterItsBranchRead() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h)
        try #require(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })

        await client.hold(.fetch)
        let round = Task { await state.fetchAllRemotes() }
        try #require(await eventually { await client.heldCount(.fetch) == 1 })
        // Published mid-round, so still from before the fetch.
        await state.refresh()
        #expect(state.session?.inFlightPullRequestLookup == nil)

        await client.hold(.fetch, false)
        await client.release(.fetch)
        await round.value
        #expect(await eventually { await client.pullRequestHeadsCalls.count == 2 })
    }

    @Test func aPushLooksUpTheNewTipWithoutThePicker() async throws {
        let h = Harness()
        let newTip = objectID("new")
        let ahead = localBranch(
            "feature", upstream: upstream("origin/feature", tracking: .counts(ahead: 1, behind: 0)), tipSha: newTip)
        let (state, client) = await adoptPushed(h) { client in
            await client.set(localBranches: [ahead])
            await client.set(pullRequestHeads: [newTip: 88], remote: "origin")
        }
        try #require(await eventually { @MainActor in state.pullRequestLookupCache != nil })
        #expect(state.pullRequestAvailability == .disabled(help: "Push first"))

        await client.hold(.push)
        let pushing = Task { await state.push(branch: "feature") }
        try #require(await eventually { await client.heldCount(.push) == 1 })
        await client.set(localBranches: [localBranch("feature", upstream: upstream("origin/feature"), tipSha: newTip)])
        await client.set(remoteBranches: [remoteBranch("feature", tipSha: newTip)])
        await client.hold(.push, false)
        await client.release(.push)
        await pushing.value

        #expect(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })
        #expect(!state.isBranchPickerPresented)
    }

    @Test func aClosedWindowDiscardsTheLookup() async throws {
        let h = Harness()
        let (state, client) = await adoptPushed(h) { await $0.hold(.pullRequestHeads) }
        try #require(await eventually { await client.heldCount(.pullRequestHeads) == 1 })
        let held = state.session?.pullRequestLookupTask

        state.close()
        await releaseHeads(client)
        await held?.value
        #expect(state.pullRequestLookupCache == nil)
    }

    @Test(arguments: [(true, nil), (false, "Couldn't open the browser")] as [(Bool, String?)])
    func viewingOpensThePullRequestPage(opens: Bool, error: String?) async throws {
        let h = Harness()
        let browser = Browser()
        browser.opens = opens
        let (state, _) = await adoptPushed(h, browser: browser)
        try #require(await eventually { @MainActor in state.pullRequestAvailability == Self.existing() })

        await state.openPullRequest()
        #expect(browser.opened.map(\.absoluteString) == [Self.pullURL])
        #expect(state.errorMessage == error)
    }
}
