import Foundation
import Testing

@testable import DiffViewer

@MainActor
struct PullRequestCompareModelTests {
    private let link = "https://github.com/acme/widgets/pull/61"
    private let origin = GitRemote(name: "origin", fetchURL: "https://github.com/acme/widgets.git")
    private let summary = IncomingChangeSummary(fileCount: 4, addedLineCount: 30, deletedLineCount: 2)
    /// The stub's default answers: `main` at `pr-base-tip`, the head at `pr-head`, based on `pr-base`.
    private let range = CommitRange(
        baseName: "main", targetName: "PR #61", mergeBaseSHA: objectID("pr-base"), targetSHA: objectID("pr-head"))

    private func client() async -> StubRepoClient {
        let client = StubRepoClient(files: [])
        await client.set(remotes: [origin])
        await client.set(churn: summary)
        return client
    }

    /// Remotes already loaded unless `loaded` is false.
    private func model(
        _ client: StubRepoClient, clock: ManualClock = ManualClock(), loaded: Bool = true
    ) async -> PullRequestCompareModel {
        let model = PullRequestCompareModel(client: client, clock: clock)
        if loaded { await model.loadRemotes() }
        return model
    }

    private func held(_ client: StubRepoClient, _ call: StubCall) async -> Bool {
        await eventually { await client.heldCount(call) == 1 }
    }

    // MARK: When resolution runs

    @Test func resolutionStartsAfterTheDebounce() async {
        let client = await client()
        let clock = ManualClock()
        let model = await model(client, clock: clock)

        model.input = link
        #expect(await eventually { clock.sleeperCount == 2 })
        clock.advance(by: .milliseconds(499))
        #expect(model.resolution == .idle)
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await model.resolution == .resolved(range) })
    }

    @Test func returnResolvesAtOnce() async {
        let client = await client()
        let model = await model(client)

        model.input = "#61"
        model.resolveNow()
        #expect(await eventually { await model.churn == .ready(summary) })
        #expect(await client.advertisedPullRequestCalls.map(\.number) == [61])
    }

    @Test func editsThatKeepTheParsedRequestStartNoFetch() async {
        let client = await client()
        let clock = ManualClock()
        let model = await model(client, clock: clock)
        model.input = link
        model.resolveNow()
        #expect(await eventually { await model.resolution == .resolved(range) })

        for edit in ["  \(link) ", "\(link)/files", "\(link)#discussion", "https://github.com/ACME/Widgets/pull/61"] {
            model.input = edit
        }
        #expect(model.resolution == .resolved(range))
        #expect(await client.advertisedPullRequestCalls.count == 1)
    }

    @Test func returnDuringARunningFetchJoinsIt() async {
        let client = await client()
        await client.hold(.fetchPullRequest)
        let model = await model(client)

        model.input = link
        model.resolveNow()
        #expect(await held(client, .fetchPullRequest))
        model.resolveNow()
        model.resolveNow()
        await client.release(.fetchPullRequest)
        #expect(await eventually { await model.resolution == .resolved(range) })
        #expect(await client.fetchPullRequestCalls.count == 1)
    }

    @Test(arguments: [true, false])
    func editingDropsAStaleFetchsProgressAndResult(fails: Bool) async throws {
        let client = await client()
        await client.hold(.fetchPullRequest)
        if fails {
            await client.fail(
                .fetchPullRequest, with: ProcessError.failed(command: "git fetch", status: 128, stderr: "x"))
        }
        let model = await model(client)

        model.input = "#61"
        model.resolveNow()
        #expect(await held(client, .fetchPullRequest))
        #expect(model.resolutionText == "Fetching #61 from origin…")
        model.input = "#62"
        #expect(model.resolution == .idle)
        #expect(model.resolutionText == nil)

        let read = try #require(model.readTask)
        await client.release(.fetchPullRequest)
        await read.value
        #expect(model.resolution == .idle)
        #expect(model.churn == .pending)
        #expect(await client.pinPullRequestCalls.isEmpty)
    }

    @Test func inputThatStopsParsingMidResolutionDisablesCompareAndPublishesNothing() async throws {
        let client = await client()
        await client.hold(.pinPullRequest)
        let model = await model(client)

        model.input = link
        model.resolveNow()
        #expect(await held(client, .pinPullRequest))
        #expect(model.canCompare)
        model.input = "\(link)x"
        #expect(!model.canCompare)
        #expect(model.inputError == "That isn't a pull request link.")

        let read = try #require(model.readTask)
        await client.release(.pinPullRequest)
        await read.value
        #expect(model.resolution == .idle)
        #expect(model.churn == .hidden)
        #expect(await client.pullRequestBaseRequests.isEmpty)
    }

    @Test func theSpinnerWaitsEightHundredMillisecondsFromTheRequestChange() async {
        let client = await client()
        await client.hold(.advertisedPullRequest)
        let clock = ManualClock()
        let model = await model(client, clock: clock)

        model.input = link
        #expect(await eventually { clock.sleeperCount == 2 })
        clock.advance(by: .milliseconds(300))
        #expect(model.churn == .pending)
        clock.advance(by: .milliseconds(200))
        #expect(await held(client, .advertisedPullRequest))
        #expect(model.resolution == .resolving)
        clock.advance(by: .milliseconds(299))
        #expect(model.churn == .pending)
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await model.churn == .comparing })
        await client.release(.advertisedPullRequest)
    }

    // MARK: Remotes

    @Test func inputEnteredWhileRemotesLoadIsMatchedOnceTheyLoad() async {
        let client = await client()
        await client.hold(.remotes)
        let model = await model(client, loaded: false)
        let load = Task { await model.loadRemotes() }
        #expect(await held(client, .remotes))

        model.input = link
        #expect(model.request == nil)
        #expect(model.inputError == nil)
        #expect(!model.canCompare)
        await client.release(.remotes)
        await load.value
        let repository = GitHubRepository(owner: "acme", name: "widgets")
        #expect(model.request == PullRequestComparisonRequest(remote: "origin", repository: repository, number: 61))
        #expect(model.canCompare)
    }

    @Test func aRemoteReadFailureShowsItsOwnError() async {
        let client = await client()
        await client.fail(.remotes, with: ProcessError.failed(command: "git remote", status: 128, stderr: "bad config"))
        let model = await model(client)

        model.input = "#61"
        let message = "Couldn't read this repository's remotes: git remote exited with status 128: bad config"
        #expect(model.inputError == message)
        #expect(model.request == nil)
    }

    @Test(
        arguments: [
            (
                "https://github.com/acme/widgets.git", "https://github.com/someone/else/pull/3",
                "This pull request is in someone/else, which isn't a remote of this repository."
            ),
            (
                "https://github.com/acme/widgets.git", "github.com/acme/widgets/pull/3",
                "That isn't a pull request link."
            ),
            ("https://gitlab.com/acme/widgets.git", "#3", "No GitHub remote."),
        ])
    func unusableInputSaysWhy(remoteURL: String, input: String, message: String) async {
        let client = await client()
        await client.set(remotes: [GitRemote(name: "origin", fetchURL: remoteURL)])
        let model = await model(client)

        model.input = input
        #expect(model.inputError == message)
        #expect(model.request == nil)
    }

    // MARK: Closing

    @Test func closingWhileRemotesLoadStartsNoAdvertisement() async {
        let client = await client()
        await client.hold(.remotes)
        let clock = ManualClock()
        let model = await model(client, clock: clock, loaded: false)
        let load = Task { await model.loadRemotes() }
        #expect(await held(client, .remotes))
        model.input = "#61"

        model.close()
        await client.release(.remotes)
        await load.value
        #expect(model.remotes == .loading)
        #expect(model.request == nil)
        #expect(clock.sleeperCount == 0)
        #expect(await client.advertisedPullRequestCalls.isEmpty)
    }

    @Test func closingDuringTheAdvertisementLaunchesNoFetch() async throws {
        let client = await client()
        await client.hold(.advertisedPullRequest)
        let model = await model(client)
        model.input = link
        model.resolveNow()
        #expect(await held(client, .advertisedPullRequest))

        let read = try #require(model.readTask)
        model.close()
        await client.release(.advertisedPullRequest)
        await read.value
        #expect(await client.fetchPullRequestCalls.isEmpty)
    }

    @Test func closingDuringTheFetchRunsNoLaterStep() async throws {
        let client = await client()
        await client.hold(.fetchPullRequest)
        let model = await model(client)
        model.input = link
        model.resolveNow()
        #expect(await held(client, .fetchPullRequest))

        let read = try #require(model.readTask)
        model.close()
        await client.release(.fetchPullRequest)
        await read.value
        #expect(await client.pinPullRequestCalls.isEmpty)
        #expect(await client.pullRequestBaseRequests.isEmpty)
        #expect(await client.churnCalls == 0)
    }

    // MARK: Results and wording

    @Test func aFetchFailureShowsInTheCardAndARetryFetchesAgain() async {
        let client = await client()
        await client.fail(
            .fetchPullRequest, with: ProcessError.failed(command: "git fetch", status: 128, stderr: "network down"))
        let clock = ManualClock()
        let model = await model(client, clock: clock)

        model.input = link
        model.resolveNow()
        let message = "git fetch exited with status 128: network down"
        #expect(await eventually { await model.resolution == .failed(message) })
        #expect(model.resolutionText == message)
        #expect(model.churn == .failed(message))

        // The retry's spinner is measured from the retry.
        await client.fail(.fetchPullRequest, with: nil)
        await client.hold(.fetchPullRequest)
        model.resolveNow()
        #expect(model.churn == .pending)
        #expect(await held(client, .fetchPullRequest))
        #expect(model.resolution == .resolving)
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: PullRequestCompareModel.spinnerDelay)
        #expect(await eventually { await model.churn == .comparing })

        await client.release(.fetchPullRequest)
        #expect(await eventually { await model.resolution == .resolved(range) })
        #expect(await client.fetchPullRequestCalls.count == 2)
    }

    @Test func aRecoveredBaseIsLabelledAsAComparisonBase() async {
        let client = await client()
        await client.set(pullRequestBase: PullRequestComparisonBase(commitSHA: objectID("fork"), isRecovered: true))
        let model = await model(client)

        model.input = link
        let recovered = CommitRange(
            baseName: "main", targetName: "PR #61", mergeBaseSHA: objectID("fork"), targetSHA: objectID("pr-head"))
        #expect(await model.resolvedRange() == .range(recovered))
        guard case let .resolved(resolved) = model.resolution else {
            Issue.record("The pull request did not resolve")
            return
        }
        #expect(resolved.title == "main … PR #61")
        #expect(resolved.baseLabel == "Comparison base for PR #61")
    }

    @Test func theNoteNamesTheDefaultBranchOnceTheRemoteAnswers() async {
        let client = await client()
        await client.hold(.fetchPullRequest)
        let model = await model(client)

        model.input = link
        model.resolveNow()
        #expect(await held(client, .fetchPullRequest))
        #expect(model.note == "Compares against origin's default branch (main).")
        await client.release(.fetchPullRequest)
    }

    @Test func aClearedAndReenteredRequestForgetsTheEarlierAdvertisement() async {
        let client = await client()
        await client.hold(.fetchPullRequest)
        let model = await model(client)
        model.input = link
        model.resolveNow()
        #expect(await held(client, .fetchPullRequest))
        #expect(model.note == "Compares against origin's default branch (main).")

        model.input = ""
        await client.release(.fetchPullRequest)
        await client.hold(.advertisedPullRequest)
        model.input = link
        model.resolveNow()
        #expect(await held(client, .advertisedPullRequest))
        #expect(model.note == "Compares against origin's default branch.")
        await client.release(.advertisedPullRequest)
    }

    @Test func theNoteAndWellsFillInOnceResolved() async {
        let client = await client()
        let model = await model(client)
        #expect(model.note == "Compares against origin's default branch.")
        #expect(model.wellContent(.base) == nil)
        #expect(model.wellPlaceholder(.base) == ("Default branch", "Found when the pull request resolves"))

        model.input = link
        model.resolveNow()
        #expect(await eventually { await model.resolution == .resolved(range) })
        #expect(model.note == "Compares against origin's default branch (main).")
        #expect(
            model.wellContent(.base) == CompareWellContent(title: "main", subtitle: "Base branch", isWarning: false))
        let head = "Head · \(objectID("pr-head").prefix(7))"
        #expect(model.wellContent(.target) == CompareWellContent(title: "PR #61", subtitle: head, isWarning: false))
    }

    @Test(
        arguments: [
            (StubCall.advertisedPullRequest, PullRequestError.notFound, "Pull request #61 wasn't found on origin"),
            (.advertisedPullRequest, .noDefaultBranch, "origin has no default branch"),
            (.pinPullRequest, .commitsUnavailable, "Couldn't get #61's commits from origin. Try again."),
            (
                .pullRequestBase, .alreadyInBase,
                "#61's commits are already in main. A comparison base couldn't be recovered."
            ),
            (.pullRequestBase, .noCommonHistory(isShallow: false), "#61 and main share no history."),
            (
                .pullRequestBase, .noCommonHistory(isShallow: true),
                "This clone is shallow; fetch more history to compare."
            ),
        ])
    func typedFailuresAreWorded(call: StubCall, error: PullRequestError, message: String) async {
        let client = await client()
        await client.fail(call, with: error)
        let model = await model(client)

        model.input = "#61"
        model.resolveNow()
        #expect(await eventually { await model.resolution == .failed(message) })
    }
}
