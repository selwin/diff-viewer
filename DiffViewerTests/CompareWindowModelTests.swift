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

    /// Every pair from main has a merge base unless a test says otherwise.
    private func client(mergeBases: Bool = true) async -> StubRepoClient {
        let client = StubRepoClient(files: [])
        if mergeBases {
            for target in [feature, other, topic] {
                await client.set(mergeBase: mergeBase, for: main.commitSHA, target.commitSHA)
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

    /// Fires the debounce and waits until its request is queued or running. The debounce
    /// and spinner must both be asleep first, or the advance would land before them.
    private func passDebounce(_ model: CompareWindowModel, _ clock: ManualClock) async throws {
        #expect(await eventually { clock.sleeperCount == 2 })
        let debounce = try #require(model.debounceTask)
        clock.advance(by: CompareWindowModel.debounceDelay)
        await debounce.value
    }

    private func held(_ client: StubRepoClient, _ call: StubCall, calls: Int) async -> Bool {
        await eventually {
            let count = call == .churn ? await client.churnCalls : await client.mergeBaseCalls
            let waiting = await client.heldCount(call)
            return waiting == 1 && count == calls
        }
    }

    // MARK: Churn

    @Test func churnWaitsForTheDebounceThenShowsASpinnerUntilTheCountsArrive() async {
        let client = await client()
        await client.hold(.mergeBase)
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        #expect(model.churn == .hidden)
        model.select(feature, for: .target)
        #expect(model.churn == .pending)
        #expect(await eventually { clock.sleeperCount == 2 })
        clock.advance(by: .milliseconds(149))
        #expect(clock.sleeperCount == 2)
        clock.advance(by: .milliseconds(1))
        #expect(await held(client, .mergeBase, calls: 1))
        clock.advance(by: .milliseconds(149))
        #expect(model.churn == .pending)
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await model.churn == .comparing })

        await client.release(.mergeBase)
        #expect(await eventually { await model.churn == .ready(summary) })
        #expect(model.churnCounts == .init(files: "15 files", added: "+411", deleted: "\u{2212}110"))
    }

    @Test func aReadEndsInNoDifferencesOrAFailure() async throws {
        let client = await client()
        await client.set(churn: IncomingChangeSummary(fileCount: 0, addedLineCount: 0, deletedLineCount: 0))
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await eventually { await model.churn == .noDifferences })

        await client.fail(churn: true)
        model.select(other, for: .target)
        try await passDebounce(model, clock)
        #expect(await eventually { await model.churn == .failed("git diff exited with status 128: gone") })

        model.select(alias, for: .target)
        model.select(feature, for: .base)
        try await passDebounce(model, clock)
        #expect(await eventually { await model.churn == .failed("feature and alias share no history") })
    }

    @Test func theSameRefOrCommitReadsNothing() async {
        let client = await client()
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        model.select(main, for: .target)
        #expect(model.churn == .noDifferences)
        #expect(model.isTargetSameAsBase)
        #expect(model.wellSubtitle(.target) == "Same as base")
        model.select(alias, for: .target)
        #expect(model.churn == .noDifferences)
        #expect(!model.isTargetSameAsBase)
        #expect(model.wellSubtitle(.target) == "Today 07:00")

        #expect(clock.sleeperCount == 0)
        #expect(await client.mergeBaseCalls == 0)
    }

    @Test func aSupersededReadPublishesNeitherItsCountsNorItsFailure() async throws {
        let client = await client()
        await client.hold(.churn)
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await held(client, .churn, calls: 1))
        model.select(other, for: .target)
        try await passDebounce(model, clock)
        await client.releaseFirst(.churn)
        #expect(await held(client, .churn, calls: 2))
        #expect(model.churn == .pending)

        await client.fail(churn: true)
        model.select(topic, for: .target)
        try await passDebounce(model, clock)
        await client.releaseFirst(.churn)
        #expect(await held(client, .churn, calls: 3))
        #expect(model.churn == .pending)

        await client.fail(churn: false)
        await client.release(.churn)
        #expect(await eventually { await model.churn == .ready(summary) })
    }

    @Test func onlyTheLatestQueuedRequestRunsAfterTheOneInFlight() async throws {
        let client = await client()
        let topicBase = objectID("topic-base")
        await client.set(mergeBase: topicBase, for: main.commitSHA, topic.commitSHA)
        await client.hold(.mergeBase)
        let clock = ManualClock()
        let model = model(client, clock: clock)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        try await passDebounce(model, clock)
        #expect(await held(client, .mergeBase, calls: 1))
        model.select(other, for: .target)
        try await passDebounce(model, clock)
        model.select(topic, for: .target)
        try await passDebounce(model, clock)
        #expect(await client.heldCount(.mergeBase) == 1)

        await client.hold(.mergeBase, false)
        await client.release(.mergeBase)
        #expect(await eventually { await model.churn == .ready(summary) })
        let topicRead = RevisionPair(baseSHA: main.commitSHA, targetSHA: topic.commitSHA)
        #expect(await client.mergeBaseRequests.last == topicRead)
        #expect(await client.mergeBaseCalls == 2)
        #expect(await client.churnRequests == [RevisionPair(baseSHA: topicBase, targetSHA: topic.commitSHA)])
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
        #expect(await held(client, .mergeBase, calls: 1))
        model.select(other, for: .target)
        try await passDebounce(model, clock)
        let read = try #require(model.readTask)
        if closes { model.close() } else { model.clear(.target) }

        await client.release(.mergeBase)
        await read.value
        #expect(await client.mergeBaseCalls == 1)
        #expect(await client.churnCalls == 0)
    }

    // MARK: Submitting

    @Test func closingWhileTheMergeBaseResolvesOpensNothingAndReadsNoCounts() async throws {
        let client = await client()
        await client.hold(.mergeBase)
        let opener = Opener()
        let model = model(client, opener: opener)

        model.select(main, for: .base)
        model.select(feature, for: .target)
        let submission = Task { await model.submit() }
        #expect(await held(client, .mergeBase, calls: 1))
        let read = try #require(model.readTask)
        model.close()
        #expect(await submission.value == false)

        await client.release(.mergeBase)
        await read.value
        #expect(await client.churnCalls == 0)
        #expect(opener.opened.isEmpty)
    }

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
        #expect(!model.isOpening && model.canCompare)
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
        #expect(await held(client, .churn, calls: 1))
        #expect(await model.submit())
        #expect(await client.mergeBaseCalls == 1)

        await client.fail(churn: true)
        let failing = self.model(client, opener: opener)
        failing.select(main, for: .base)
        failing.select(other, for: .target)
        await client.hold(.churn, false)
        #expect(await failing.submit())
        #expect(opener.opened.map(\.targetSHA) == [feature.commitSHA, other.commitSHA])
        await client.release(.churn)
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
        #expect(model.canCompare == expected)
    }

    @Test func swapExchangesTheSides() {
        let model = model(StubRepoClient(files: []))
        #expect(!model.canSwap)

        model.select(main, for: .base)
        model.swap()
        #expect(model.base == nil && model.target == main)
        #expect(model.churn == .hidden)

        model.select(feature, for: .base)
        model.swap()
        #expect(model.base == main && model.target == feature)
        #expect(model.churn == .pending)

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
