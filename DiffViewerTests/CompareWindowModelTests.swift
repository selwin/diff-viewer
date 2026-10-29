import Foundation
import Testing

@testable import DiffViewer

private let now = Date(timeIntervalSince1970: 1_791_979_200)  // 2026-10-14 12:00 UTC

private func ref(_ name: String, _ kind: GitRef.Kind = .local, sha: String? = nil, hoursAgo: Double = 1) -> GitRef {
    let prefix =
        switch kind {
        case .local: "refs/heads/"
        case .remote: "refs/remotes/"
        case .tag: "refs/tags/"
        }
    return GitRef(
        fullName: prefix + name, name: name, kind: kind, commitSHA: objectID(sha ?? name),
        committedAt: now.addingTimeInterval(-hoursAgo * 3600))
}

/// Records what the model opens; `accepts` false plays a closed repository window.
@MainActor
private final class Opener {
    var opened: [CommitRange] = []
    var accepts = true

    func open(_ range: CommitRange) -> Bool {
        opened.append(range)
        return accepts
    }
}

@MainActor
struct CompareWindowModelTests {
    private let main = ref("main")
    private let feature = ref("feature", hoursAgo: 2)
    private let other = ref("other", hoursAgo: 3)
    private let topic = ref("topic", hoursAgo: 4)
    /// Points at main's commit under another name.
    private let alias = ref("alias", sha: "main", hoursAgo: 5)
    private let summary = IncomingChangeSummary(fileCount: 15, addedLineCount: 411, deletedLineCount: 110)
    private let mergeBase = objectID("base")

    /// Every pair with main has a merge base, asked either way round, unless a test says otherwise.
    private func client(mergeBases: Bool = true) async -> StubRepoClient {
        let client = StubRepoClient(files: [])
        if mergeBases {
            for target in [feature, other, topic] {
                await client.set(mergeBase: mergeBase, for: main.commitSHA, target.commitSHA)
                await client.set(mergeBase: mergeBase, for: target.commitSHA, main.commitSHA)
            }
        }
        await client.set(churn: summary)
        return client
    }

    private func model(
        _ client: StubRepoClient, clock: ManualClock = ManualClock(), opener: Opener = Opener(),
        currentBranch: String? = "main"
    ) -> CompareWindowModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let english = Locale(identifier: "en_US")
        let grouping = CommitDayGrouping(
            calendar: calendar, locale: english, timeZone: TimeZone(identifier: "UTC")!, now: now)
        return CompareWindowModel(
            client: client, currentBranch: currentBranch, clock: clock, grouping: grouping, locale: english,
            open: opener.open)
    }

    /// Fires both directions' debounces and waits until their requests are queued or running.
    /// Each direction's debounce and spinner must be asleep first, or the advance would land
    /// before them.
    private func passDebounce(_ model: CompareWindowModel, _ clock: ManualClock) async throws {
        #expect(await eventually { clock.sleeperCount == 4 })
        let debounces = [try #require(model.debounceTask), try #require(model.reverseDebounceTask)]
        clock.advance(by: CompareWindowModel.debounceDelay)
        for debounce in debounces { await debounce.value }
    }

    /// In Pull Request mode with `#61` entered on an `origin` remote on GitHub.
    private func pullRequestModel(_ client: StubRepoClient, opener: Opener = Opener()) async -> CompareWindowModel {
        await client.set(remotes: [GitRemote(name: "origin", fetchURL: "https://github.com/acme/widgets.git")])
        let model = model(client, opener: opener)
        model.setMode(.pullRequest)
        await model.pullRequest.loadRemotes()
        model.pullRequest.input = "#61"
        return model
    }

    private func held(_ client: StubRepoClient, _ call: StubCall, waiting: Int = 1) async -> Bool {
        await eventually { await client.heldCount(call) == waiting }
    }

    /// `calls` counts every `churn` or `mergeBase` call made, held or finished.
    private func held(_ client: StubRepoClient, _ call: StubCall, waiting: Int = 1, calls: Int) async -> Bool {
        await eventually {
            let count = call == .churn ? await client.churnCalls : await client.mergeBaseCalls
            let parked = await client.heldCount(call)
            return parked == waiting && count == calls
        }
    }

    // MARK: Churn

    @Test func churnWaitsForTheDebounceThenShowsASpinnerUntilTheCountsArrive() async {
        let client = await client()
        await client.hold(.mergeBase)
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        #expect(model.churn(.forward) == .hidden)
        model.select(feature, for: .target)
        #expect(model.churn(.forward) == .pending)
        #expect(await eventually { clock.sleeperCount == 4 })
        clock.advance(by: .milliseconds(149))
        #expect(clock.sleeperCount == 4)
        clock.advance(by: .milliseconds(1))
        #expect(await held(client, .mergeBase, waiting: 2, calls: 2))
        clock.advance(by: .milliseconds(149))
        #expect(model.churn(.forward) == .pending)
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await model.churn(.forward) == .comparing })

        await client.release(.mergeBase)
        #expect(await eventually { await model.churn(.forward) == .ready(summary) })
        #expect(model.churnCounts(.forward) == .init(files: "15 files", added: "+411", deleted: "\u{2212}110"))
    }

    @Test func aReadEndsInNoDifferencesOrAFailure() async throws {
        let client = await client()
        await client.set(churn: IncomingChangeSummary(fileCount: 0, addedLineCount: 0, deletedLineCount: 0))
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await eventually { await model.churn(.forward) == .noDifferences })

        await client.fail(churn: true)
        model.select(other, for: .target)
        try await passDebounce(model, clock)
        #expect(await eventually { await model.churn(.forward) == .failed("git diff exited with status 128: gone") })

        model.select(topic, for: .target)
        model.select(other, for: .base)
        try await passDebounce(model, clock)
        #expect(await eventually { await model.churn(.forward) == .failed("other and topic share no history") })
    }

    @Test func aSupersededReadPublishesNeitherItsCountsNorItsFailure() async throws {
        let client = await client()
        await client.hold(.churn)
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await held(client, .churn, waiting: 2, calls: 2))
        model.select(other, for: .target)
        try await passDebounce(model, clock)
        await client.release(.churn)
        #expect(await held(client, .churn, waiting: 2, calls: 4))
        #expect(model.churn(.forward) == .pending)

        await client.fail(churn: true)
        model.select(topic, for: .target)
        try await passDebounce(model, clock)
        await client.release(.churn)
        #expect(await held(client, .churn, waiting: 2, calls: 6))
        #expect(model.churn(.forward) == .pending)

        await client.fail(churn: false)
        await client.release(.churn)
        #expect(await eventually { await model.churn(.forward) == .ready(summary) })
    }

    @Test func onlyTheLatestQueuedRequestRunsAfterTheOneInFlight() async throws {
        let client = await client()
        let topicBase = objectID("topic-base")
        await client.set(mergeBase: topicBase, for: main.commitSHA, topic.commitSHA)
        await client.set(mergeBase: topicBase, for: topic.commitSHA, main.commitSHA)
        await client.hold(.mergeBase)
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await held(client, .mergeBase, waiting: 2, calls: 2))
        model.select(other, for: .target)
        try await passDebounce(model, clock)
        model.select(topic, for: .target)
        try await passDebounce(model, clock)
        #expect(await client.heldCount(.mergeBase) == 2)

        await client.hold(.mergeBase, false)
        await client.release(.mergeBase)
        #expect(await eventually { await model.churn(.forward) == .ready(summary) })
        #expect(await eventually { await model.churn(.reverse) == .ready(summary) })
        let pairs = [(main, feature), (feature, main), (main, topic), (topic, main)]
        let mergeBaseReads = pairs.map { RevisionPair(baseSHA: $0.commitSHA, targetSHA: $1.commitSHA) }
        #expect(await Set(client.mergeBaseRequests) == Set(mergeBaseReads))
        #expect(await client.mergeBaseCalls == 4)
        let churnReads = [topic, main].map { RevisionPair(baseSHA: topicBase, targetSHA: $0.commitSHA) }
        #expect(await Set(client.churnRequests) == Set(churnReads))
        #expect(await client.churnCalls == 2)
    }

    @Test(arguments: [false, true])
    func aQueuedRequestNeverRunsOnceClearedOrClosed(closes: Bool) async throws {
        let client = await client()
        await client.hold(.mergeBase)
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await held(client, .mergeBase, waiting: 2, calls: 2))
        model.select(other, for: .target)
        try await passDebounce(model, clock)
        let reads = [try #require(model.readTask), try #require(model.reverseReadTask)]
        if closes { model.close() } else { model.clear(.target) }

        await client.release(.mergeBase)
        for read in reads { await read.value }
        #expect(await client.mergeBaseCalls == 2)
        #expect(await client.churnCalls == 0)
    }

    // MARK: Submitting

    @Test func whileOpeningASecondSubmissionAndSelectionChangesAreIgnored() async {
        let client = await client()
        await client.hold(.mergeBase)
        let opener = Opener()
        let model = model(client, opener: opener)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        let submission = Task { await model.submit() }
        #expect(await held(client, .mergeBase, calls: 1))
        #expect(model.isOpening)
        #expect(await model.submit() == false)
        model.select(other, for: .target)
        model.swap()
        model.clear(.base)
        #expect(model.base == main && model.target == feature)

        await client.release(.mergeBase)
        #expect(await submission.value)
        #expect(opener.opened.map(\.title) == ["main … feature"])
        #expect(opener.opened.map(\.revisions) == [RevisionPair(baseSHA: mergeBase, targetSHA: feature.commitSHA)])
    }

    @Test func aFailedSubmissionCanBeRetried() async {
        let client = await client(mergeBases: false)
        let opener = Opener()
        let model = model(client, opener: opener)
        model.select(main, for: .base)
        model.select(feature, for: .target)

        #expect(await model.submit() == false)
        #expect(model.openError == "main and feature share no history")
        #expect(!model.isOpening && model.canCompare(.forward))
        model.select(other, for: .target)
        #expect(model.openError == nil)
        model.select(feature, for: .target)

        await client.set(mergeBase: mergeBase, for: main.commitSHA, feature.commitSHA)
        await client.fail(mergeBase: true)
        #expect(await model.submit() == false)
        #expect(model.openError == "git merge-base exited with status 128: bad object")

        await client.fail(mergeBase: false)
        opener.accepts = false
        #expect(await model.submit() == false)
        #expect(model.openError == "The repository window was closed.")

        // The range resolved last time is reused.
        opener.accepts = true
        #expect(await model.submit())
        #expect(model.openError == nil)
        #expect(opener.opened.count == 2)
        #expect(await client.mergeBaseCalls == 3)
    }

    @Test func aHeldOrFailingCountDoesNotBlockOpening() async throws {
        let client = await client()
        await client.hold(.churn)
        let clock = ManualClock()
        let opener = Opener()
        let model = model(client, clock: clock, opener: opener)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await held(client, .churn, waiting: 2, calls: 2))
        #expect(await model.submit())
        // One merge base per direction, none read again to open.
        #expect(await client.mergeBaseCalls == 2)

        await client.fail(churn: true)
        let failing = self.model(client, opener: opener)
        failing.select(main, for: .base)
        failing.select(other, for: .target)
        await client.hold(.churn, false)
        #expect(await failing.submit())
        #expect(opener.opened.map(\.targetSHA) == [feature.commitSHA, other.commitSHA])
        await client.release(.churn)
    }

    // MARK: Directions

    @Test func bothDirectionsReadAndTheReverseMirrorsTheForwardRequest() async throws {
        let client = await client()
        let reverseSummary = IncomingChangeSummary(fileCount: 2, addedLineCount: 3, deletedLineCount: 4)
        await client.set(churn: reverseSummary, for: RevisionPair(baseSHA: mergeBase, targetSHA: main.commitSHA))
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        #expect(model.previewDirections == [.forward, .reverse])
        #expect(model.rowTitle(.forward) == "main → feature" && model.rowTitle(.reverse) == "feature → main")
        try await passDebounce(model, clock)
        #expect(await eventually { await model.churn(.forward) == .ready(summary) })
        #expect(await eventually { await model.churn(.reverse) == .ready(reverseSummary) })
        let mergeBaseReads = [(main, feature), (feature, main)].map {
            RevisionPair(baseSHA: $0.commitSHA, targetSHA: $1.commitSHA)
        }
        #expect(await Set(client.mergeBaseRequests) == Set(mergeBaseReads))
        let churnReads = [feature, main].map { RevisionPair(baseSHA: mergeBase, targetSHA: $0.commitSHA) }
        #expect(await Set(client.churnRequests) == Set(churnReads))
    }

    @Test func submittingTheReverseOpensTheBaseFromItsMergeBase() async throws {
        let client = await client()
        let opener = Opener()
        let model = model(client, opener: opener)
        model.select(main, for: .base)
        model.select(feature, for: .target)

        #expect(await model.submit(.reverse))
        let range = try #require(opener.opened.first)
        #expect(range.mergeBaseSHA == mergeBase && range.targetSHA == main.commitSHA)
        #expect(range.baseName == "feature" && range.targetName == "main")
    }

    @Test func aDirectionKnownToBeEmptyCannotBeSubmitted() async throws {
        let client = await client()
        let empty = IncomingChangeSummary(fileCount: 0, addedLineCount: 0, deletedLineCount: 0)
        await client.set(churn: empty, for: RevisionPair(baseSHA: mergeBase, targetSHA: main.commitSHA))
        let clock = ManualClock()
        let opener = Opener()
        let model = model(client, clock: clock, opener: opener)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await eventually { await model.churn(.reverse) == .noDifferences })
        #expect(!model.canCompare(.reverse))
        #expect(model.canCompare(.forward))
        #expect(await model.submit(.reverse) == false)
        #expect(opener.opened.isEmpty)
    }

    @Test func theSameRefOrCommitReadsNothing() async {
        let client = await client()
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        model.select(main, for: .target)
        #expect(model.churn(.forward) == .noDifferences && model.churn(.reverse) == .noDifferences)
        #expect(model.previewDirections == [.forward])
        #expect(model.isTargetSameAsBase)
        #expect(model.wellSubtitle(.target) == "Same as base")
        model.select(alias, for: .target)
        #expect(model.churn(.forward) == .noDifferences && model.churn(.reverse) == .noDifferences)
        #expect(!model.isTargetSameAsBase)
        #expect(model.wellSubtitle(.target) == "Today 07:00")

        #expect(clock.sleeperCount == 0)
        #expect(await client.mergeBaseCalls == 0)
    }

    @Test func theReverseCountsArriveWhileTheForwardIsStillPending() async throws {
        let client = await client()
        await client.holdChurn(true, for: RevisionPair(baseSHA: mergeBase, targetSHA: feature.commitSHA))
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await eventually { await model.churn(.reverse) == .ready(summary) })
        #expect(model.churn(.forward) == .pending)
        #expect(model.churnAccessibilityLabel(.forward) == nil)
        #expect(model.churnCounts(.reverse) == .init(files: "15 files", added: "+411", deleted: "\u{2212}110"))
        #expect(model.churnAccessibilityLabel(.reverse) == "15 files changed, 411 additions, 110 deletions")
        #expect(model.canCompare(.reverse))
        await client.release(.churn)
    }

    @Test func aSubmissionWhileTheCountsAreHeldStaysOpenedWhenTheyComeBackEmpty() async throws {
        let client = await client()
        let reverse = RevisionPair(baseSHA: mergeBase, targetSHA: main.commitSHA)
        let empty = IncomingChangeSummary(fileCount: 0, addedLineCount: 0, deletedLineCount: 0)
        await client.set(churn: empty, for: reverse)
        await client.holdChurn(true, for: reverse)
        let clock = ManualClock()
        let opener = Opener()
        let model = model(client, clock: clock, opener: opener)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await held(client, .churn))
        #expect(await model.submit(.reverse))

        await client.release(.churn)
        #expect(await eventually { await model.churn(.reverse) == .noDifferences })
        #expect(opener.opened.map(\.targetSHA) == [main.commitSHA])
    }

    @Test func aPullRequestHasNoReverse() async {
        let client = await client()
        let opener = Opener()
        let model = await pullRequestModel(client, opener: opener)

        #expect(model.churn(.reverse) == .hidden)
        #expect(model.canCompare(.forward) && !model.canCompare(.reverse))
        #expect(await model.submit(.reverse) == false)
        #expect(opener.opened.isEmpty)
    }

    // MARK: Swap

    @Test func swappingAfterTheCountsArriveExchangesThemWithoutReadingAgain() async throws {
        let client = await client()
        let reverseSummary = IncomingChangeSummary(fileCount: 2, addedLineCount: 3, deletedLineCount: 4)
        await client.set(churn: reverseSummary, for: RevisionPair(baseSHA: mergeBase, targetSHA: main.commitSHA))
        let clock = ManualClock()
        let model = model(client, clock: clock)
        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await eventually { await model.churn(.forward) == .ready(summary) })
        #expect(await eventually { await model.churn(.reverse) == .ready(reverseSummary) })

        model.swap()
        #expect(model.churn(.forward) == .ready(reverseSummary) && model.churn(.reverse) == .ready(summary))
        #expect(clock.sleeperCount == 0)
        #expect(await client.mergeBaseCalls == 2)
        #expect(await client.churnCalls == 2)
    }

    @Test func swappingWhileBothArePendingPutsEachCountOnItsRow() async throws {
        let client = await client()
        let reverseSummary = IncomingChangeSummary(fileCount: 2, addedLineCount: 3, deletedLineCount: 4)
        await client.set(churn: reverseSummary, for: RevisionPair(baseSHA: mergeBase, targetSHA: main.commitSHA))
        await client.hold(.mergeBase)
        let clock = ManualClock()
        let opener = Opener()
        let model = model(client, clock: clock, opener: opener)
        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await held(client, .mergeBase, waiting: 2, calls: 2))

        model.swap()
        await client.release(.mergeBase)
        #expect(await eventually { await model.churn(.forward) == .ready(reverseSummary) })
        #expect(await eventually { await model.churn(.reverse) == .ready(summary) })
        #expect(await model.submit(.forward))
        let range = try #require(opener.opened.first)
        #expect(range.targetSHA == main.commitSHA)
        #expect(range.baseName == "feature" && range.targetName == "main")
    }

    // MARK: Lifecycle

    @Test(arguments: [CompareWindowModel.Direction.forward, .reverse])
    func closingWhileTheMergeBaseResolvesOpensNothingAndReadsNoCounts(direction: CompareWindowModel.Direction)
        async throws
    {
        let client = await client()
        await client.hold(.mergeBase)
        let opener = Opener()
        let model = model(client, opener: opener)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        let submission = Task { await model.submit(direction) }
        #expect(await held(client, .mergeBase, calls: 1))
        let read = try #require(direction == .forward ? model.readTask : model.reverseReadTask)
        model.close()
        #expect(await submission.value == false)

        await client.release(.mergeBase)
        await read.value
        #expect(await client.churnCalls == 0)
        #expect(opener.opened.isEmpty)
    }

    // MARK: Modes

    @Test func eachModeKeepsItsInputAndPreview() async throws {
        let client = await client()
        let clock = ManualClock()
        let model = model(client, clock: clock)
        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await eventually { await model.churn(.forward) == .ready(summary) })
        #expect(await eventually { await model.churn(.reverse) == .ready(summary) })

        let pullRequestSummary = IncomingChangeSummary(fileCount: 2, addedLineCount: 5, deletedLineCount: 1)
        await client.set(churn: pullRequestSummary)
        await client.set(remotes: [GitRemote(name: "origin", fetchURL: "https://github.com/acme/widgets.git")])
        model.setMode(.pullRequest)
        #expect(model.churn(.forward) == .hidden)
        #expect(!model.canCompare(.forward))
        await model.pullRequest.loadRemotes()
        model.pullRequest.input = "#61"
        model.pullRequest.resolveNow()
        #expect(await eventually { await model.churn(.forward) == .ready(pullRequestSummary) })

        model.setMode(.branches)
        #expect(model.churn(.forward) == .ready(summary))
        #expect(model.target == feature)
        model.setMode(.pullRequest)
        #expect(model.churn(.forward) == .ready(pullRequestSummary))
        #expect(model.pullRequest.input == "#61")
        #expect(await client.mergeBaseCalls == 2)
        #expect(await client.advertisedPullRequestCalls.count == 1)
    }

    @Test func theModeCannotChangeWhileOpening() async {
        let client = await client()
        await client.hold(.mergeBase)
        let model = model(client)
        model.select(main, for: .base)
        model.select(feature, for: .target)

        let submission = Task { await model.submit() }
        #expect(await held(client, .mergeBase, calls: 1))
        model.setMode(.pullRequest)
        #expect(model.mode == .branches)
        await client.release(.mergeBase)
        #expect(await submission.value)
    }

    @Test func twoSubmitsAcrossModesOpenOneTab() async {
        let client = await client()
        await client.hold(.fetchPullRequest)
        let opener = Opener()
        let model = await pullRequestModel(client, opener: opener)
        model.setMode(.branches)
        model.select(main, for: .base)
        model.select(feature, for: .target)
        model.setMode(.pullRequest)

        let submission = Task { await model.submit() }
        #expect(await held(client, .fetchPullRequest))
        model.setMode(.branches)
        #expect(await model.submit() == false)
        await client.release(.fetchPullRequest)
        #expect(await submission.value)
        #expect(opener.opened.map(\.title) == ["main … PR #61"])
        #expect(await client.mergeBaseCalls == 0)
    }

    @Test func aRequestChangeWhileOpeningAPullRequestReenablesCompare() async {
        let client = await client()
        await client.hold(.fetchPullRequest)
        let opener = Opener()
        let model = await pullRequestModel(client, opener: opener)

        let submission = Task { await model.submit() }
        #expect(await held(client, .fetchPullRequest))
        model.pullRequest.input = "#62"
        #expect(await submission.value == false)
        #expect(!model.isOpening)
        #expect(model.canCompare(.forward))
        #expect(model.openError == nil)
        await client.release(.fetchPullRequest)
        #expect(opener.opened.isEmpty)
    }

    @Test func aPullRequestFailureClearsOnceTheInputNamesAnother() async {
        let client = await client()
        await client.fail(
            .fetchPullRequest, with: ProcessError.failed(command: "git fetch", status: 128, stderr: "network down"))
        let model = await pullRequestModel(client)

        #expect(await model.submit() == false)
        #expect(model.openError == "git fetch exited with status 128: network down")
        // Equivalent edits name the same request, so the error stays.
        model.pullRequest.input = "#61 "
        #expect(model.openError == "git fetch exited with status 128: network down")
        model.pullRequest.input = "https://github.com/acme/widgets/pull/61"
        model.pullRequest.input = "https://github.com/acme/widgets/pull/61/files"
        #expect(model.openError == "git fetch exited with status 128: network down")

        await client.fail(.fetchPullRequest, with: nil)
        model.pullRequest.input = "#62"
        model.pullRequest.resolveNow()
        #expect(await eventually { await model.pullRequest.churn == .ready(summary) })
        #expect(model.openError == nil)
        // Naming the failed pull request again doesn't bring the old error back.
        model.pullRequest.input = ""
        model.pullRequest.input = "#61"
        #expect(model.openError == nil)
    }

    @Test func closingWhileAPullRequestResolvesOpensNothing() async {
        let client = await client()
        await client.hold(.fetchPullRequest)
        let opener = Opener()
        let model = await pullRequestModel(client, opener: opener)

        let submission = Task { await model.submit() }
        #expect(await held(client, .fetchPullRequest))
        model.close()
        #expect(await submission.value == false)
        await client.release(.fetchPullRequest)
        #expect(await eventually { await model.pullRequest.readTask == nil })
        #expect(opener.opened.isEmpty)
        #expect(await client.pinPullRequestCalls.isEmpty)
    }

    @Test func aPullRequestCountsFailureStillSubmitsTheResolvedRange() async {
        let client = await client()
        await client.fail(churn: true)
        let opener = Opener()
        let model = await pullRequestModel(client, opener: opener)

        model.pullRequest.resolveNow()
        #expect(await eventually { await model.churn(.forward) == .failed("git diff exited with status 128: gone") })
        #expect(model.canCompare(.forward))
        #expect(await model.submit())
        let revisions = RevisionPair(baseSHA: objectID("pr-base"), targetSHA: objectID("pr-head"))
        #expect(opener.opened.map(\.revisions) == [revisions])
    }

    // MARK: Choosing

    @Test(
        arguments: [
            (nil, nil, false), ("main", nil, false), (nil, "feature", false), ("main", "main", false),
            ("main", "alias", false), ("main", "feature", true),
        ] as [(String?, String?, Bool)])
    func canCompareNeedsTwoDifferentCommits(base: String?, target: String?, expected: Bool) {
        let refs = [main, feature, alias]
        let model = model(StubRepoClient(files: []))
        if let base, let ref = refs.first(where: { $0.name == base }) { model.select(ref, for: .base) }
        if let target, let ref = refs.first(where: { $0.name == target }) { model.select(ref, for: .target) }
        #expect(model.canCompare(.forward) == expected)
    }

    @Test func swapExchangesTheSides() {
        let model = model(StubRepoClient(files: []))
        #expect(!model.canSwap)

        model.select(main, for: .base)
        model.swap()
        #expect(model.base == nil && model.target == main)
        #expect(model.churn(.forward) == .hidden)

        model.select(feature, for: .base)
        model.swap()
        #expect(model.base == main && model.target == feature)
        #expect(model.churn(.forward) == .pending)

        model.select(main, for: .target)
        #expect(!model.canSwap)
    }

    @Test func filteringKeepsTheSortOrderAndEachColumnExplainsWhyItIsEmpty() async {
        let client = StubRepoClient(files: [])
        let tag = ref("v1-main", .tag, hoursAgo: 0)
        let remote = ref("origin/main", .remote, hoursAgo: 0)
        await client.set(refs: [tag, remote, feature, main, other])
        let model = model(client)
        #expect(model.emptyText(.base) == nil)

        await model.load()
        #expect(model.rows(.base) == [main, feature, other, remote, tag])
        model.baseQuery = "MAIN"
        #expect(model.rows(.base) == [main, remote, tag])
        #expect(model.rows(.target).count == 5)
        model.targetQuery = "zzz"
        #expect(model.emptyText(.target) == "No matches")
        #expect(model.emptyText(.base) == nil)

        model.moveSelection(.base, by: -1)
        #expect(model.base == main)
        model.moveSelection(.base, by: 1)
        #expect(model.base == remote)
        model.moveSelection(.base, by: 5)
        #expect(model.base == tag)

        await client.set(refs: [])
        await model.load()
        #expect(model.emptyText(.base) == "No branches or tags")
        await client.fail(refs: true)
        await model.load()
        let failure = "Couldn't read branches and tags: git for-each-ref exited with status 128: gone"
        #expect(model.emptyText(.base) == failure && model.emptyText(.target) == failure)
    }

    @Test func loadingSelectsByNamePreferringTheLocalBranch() async {
        let client = StubRepoClient(files: [])
        let tag = ref("feature", .tag, sha: "feature-tag", hoursAgo: 0)
        await client.set(refs: [tag, feature, main])
        let model = model(client)

        await model.load(selecting: "main", "feature")
        #expect(model.base == main && model.target == feature)
    }

    // MARK: Prefill

    @Test(
        arguments: [
            // origin/HEAD names a branch that also exists locally.
            (
                [ref("trunk"), ref("origin/trunk", .remote), ref("main")], "refs/remotes/origin/trunk",
                "refs/heads/trunk"
            ),
            // No local copy, so the remote branch itself; `main` would be the wrong answer.
            ([ref("origin/trunk", .remote), ref("main")], "refs/remotes/origin/trunk", "refs/remotes/origin/trunk"),
            // A `/` in the name stays part of the name.
            (
                [ref("release/2026"), ref("origin/release/2026", .remote), ref("main")],
                "refs/remotes/origin/release/2026", "refs/heads/release/2026"
            ),
            // A tag named like the remote branch is not the branch.
            ([ref("origin/trunk", .tag), ref("trunk"), ref("main")], "refs/remotes/origin/trunk", "refs/heads/trunk"),
            ([ref("master"), ref("main")], nil, "refs/heads/main"),
            ([ref("master"), ref("feature")], nil, "refs/heads/master"),
            // A hint that names nothing present falls back the same way.
            ([ref("main"), ref("feature")], "refs/remotes/origin/gone", "refs/heads/main"),
            ([ref("feature")], nil, nil),
        ] as [([GitRef], String?, String?)])
    func defaultBaseFollowsOriginHeadThenTheUsualNames(refs: [GitRef], hint: String?, expected: String?) {
        let base = CompareWindowModel.defaultBase(in: refs, originDefaultBranchRef: hint, currentBranch: "feature")
        #expect(base?.fullName == expected)
    }

    @Test func defaultBaseIsNilWhenItIsTheCurrentBranch() {
        let refs = [ref("main"), ref("origin/main", .remote)]
        let base = CompareWindowModel.defaultBase(
            in: refs, originDefaultBranchRef: "refs/remotes/origin/main", currentBranch: "main")
        #expect(base == nil)
    }

    @Test func loadingPrefillsTheCurrentBranchAgainstTheDefaultBranch() async {
        let client = StubRepoClient(files: [])
        await client.set(refs: [main, feature, ref("trunk", hoursAgo: 3), ref("origin/trunk", .remote)])
        await client.set(originDefaultBranchRef: "refs/remotes/origin/trunk")
        let model = model(client, currentBranch: "feature")

        await model.load()
        #expect(model.refList == .loaded)
        #expect(model.target == feature)
        #expect(model.base?.fullName == "refs/heads/trunk")
    }

    @Test func aFailingDefaultBranchReadStillPrefillsFromMain() async {
        let client = StubRepoClient(files: [])
        await client.set(refs: [main, feature])
        await client.fail(originDefaultBranchRef: true)
        let model = model(client, currentBranch: "feature")

        await model.load()
        #expect(model.target == feature && model.base == main)
    }

    @Test func closingWhileTheRefsLoadPrefillsNothing() async {
        let client = await client()
        await client.set(refs: [main, feature])
        await client.hold(.refs)
        let model = model(client, currentBranch: "feature")

        let loading = Task { await model.load() }
        #expect(await held(client, .refs))
        model.close()
        await client.release(.refs)
        await loading.value
        #expect(model.base == nil && model.target == nil)
        #expect(model.churn(.forward) == .hidden)
    }

    @Test func aDetachedHeadPrefillsNothing() async {
        let client = StubRepoClient(files: [])
        await client.set(refs: [main, feature])
        let model = model(client, currentBranch: nil)

        await model.load()
        #expect(model.refList == .loaded)
        #expect(model.base == nil && model.target == nil)
    }

    @Test func prefillDoesNotWaitForTheRemotesAndTheUsersChoiceSurvivesThem() async throws {
        let client = StubRepoClient(files: [])
        await client.set(refs: [main, feature, other])
        await client.hold(.remotes)
        let model = model(client, currentBranch: "feature")

        let loading = Task { await model.load() }
        #expect(await held(client, .remotes))
        #expect(await eventually { await model.refList == .loaded })
        #expect(model.base == main && model.target == feature)

        model.select(other, for: .target)
        await client.release(.remotes)
        await loading.value
        #expect(model.base == main && model.target == other)
    }

    @Test func loadingByNameLeavesTheUnnamedSidesEmptyDespiteAPrefillableBranch() async {
        let client = StubRepoClient(files: [])
        await client.set(refs: [main, feature])
        let model = model(client, currentBranch: "feature")

        await model.load(selecting: nil, nil)
        #expect(model.base == nil && model.target == nil)
        await model.load(selecting: "main", nil)
        #expect(model.base == main && model.target == nil)
    }

    // MARK: Wording

    @Test func rowsNameTheCheckedOutBranchAndCountsReadAloud() {
        let model = model(StubRepoClient(files: []))
        #expect(model.subtitle(for: main) == "Today 11:00 · checked out")
        #expect(model.subtitle(for: ref("main", .remote)) == "Today 11:00")
        #expect(model.subtitle(for: feature) == "Today 10:00")

        let english = Locale(identifier: "en_US")
        #expect(
            CompareWindowModel.churnAccessibilityLabel(summary, locale: english)
                == "15 files changed, 411 additions, 110 deletions")
        let single = IncomingChangeSummary(fileCount: 1, addedLineCount: 1, deletedLineCount: 1)
        #expect(
            CompareWindowModel.churnAccessibilityLabel(single, locale: english)
                == "1 file changed, 1 addition, 1 deletion")
    }
}
