import Testing

@testable import DiffViewer

@MainActor
struct MergeSheetModelTests {
    @Test func moreCommitsPrefersThePreviewsTotal() {
        #expect(MergeSheetModel.moreCommitsText(listed: 3, total: 3) == nil)
        #expect(MergeSheetModel.moreCommitsText(listed: 21, total: 35) == "and 15 more")
        #expect(MergeSheetModel.moreCommitsText(listed: 21, total: nil) == "and more")
        #expect(MergeSheetModel.moreCommitsText(listed: 20, total: nil) == nil)
    }

    @Test func conflictTextListsFivePathsThenCountsTheRest() {
        #expect(MergeSheetModel.conflictText(paths: []) == "Merging will conflict.")
        #expect(MergeSheetModel.conflictText(paths: ["a"]) == "Merging will conflict in 1 file: a")
        #expect(
            MergeSheetModel.conflictText(paths: ["a", "b", "c", "d", "e", "f", "g"])
                == "Merging will conflict in 7 files: a, b, c, d, e and 2 more")
    }

    private let target = MergeTarget(
        sourceName: "side", sourceRef: "refs/heads/side", sourceTipSha: objectID("side"),
        destinationBranch: "main", destinationTipSha: objectID("main"))

    /// Records the limits `loadCommits` was asked for, and can park the answer until released.
    @MainActor
    private final class CommitLoads {
        private(set) var limits: [Int] = []
        /// Loads that have returned their answer, held or not.
        private(set) var finished = 0
        var holds = false
        private var waiter: CheckedContinuation<Void, Never>?

        func load(limit: Int, answer: [CommitSummary]) async -> [CommitSummary]? {
            limits.append(limit)
            if holds { await withCheckedContinuation { waiter = $0 } }
            finished += 1
            return answer
        }

        func release() {
            waiter?.resume()
            waiter = nil
        }
    }

    private func model(
        _ client: StubRepoClient, loads: CommitLoads = CommitLoads(), commits: [CommitSummary] = []
    ) -> MergeSheetModel {
        MergeSheetModel(
            target: target, previews: MergePreviewLoader(client: client),
            loadCommits: { await loads.load(limit: $0, answer: commits) })
    }

    /// The model answers from the shared cache and the commit list, and stops asking on `stop()`.
    @Test func startLoadsThePreviewAndTheCommitsOnce() async throws {
        let client = StubRepoClient(files: [])
        await client.set(mergePreview: .conflicts(commits: 2, paths: ["a.swift"]), for: target.previewKey)
        let loads = CommitLoads()
        let model = model(client, loads: loads, commits: [commitSummary("c1"), commitSummary("c2")])

        model.start()
        model.start()

        #expect(await eventually { await model.previewStatus != .loading })
        #expect(await eventually { await model.commits != nil })
        #expect(model.previewStatus == .ready(.conflicts(commits: 2, paths: ["a.swift"])))
        #expect(model.conflictText == "Merging will conflict in 1 file: a.swift")
        #expect(model.moreCommitsText == nil)
        #expect(model.canMerge)
        #expect(await client.mergePreviewCalls == [target.previewKey])
        #expect(loads.limits == [MergeSheetModel.commitRequestLimit])
        model.stop()
    }

    @Test func mergeWaitsForThePredictionAndNeedsSomethingToMerge() async throws {
        let client = StubRepoClient(files: [])
        await client.set(mergePreview: .clean(commits: 1), for: target.previewKey)
        await client.hold(.mergePreview)
        let model = model(client)

        model.start()
        #expect(await eventually { await client.heldCount(.mergePreview) == 1 })
        #expect(model.previewStatus == .loading)
        #expect(!model.canMerge)

        await client.release(.mergePreview)
        #expect(await eventually { await model.previewStatus == .ready(.clean(commits: 1)) })
        #expect(model.canMerge)

        model.stop()
    }

    @Test func withoutALoaderThereIsNothingToWaitFor() {
        let model = MergeSheetModel(target: target, previews: nil, loadCommits: { _ in nil })
        model.start()
        #expect(model.previewStatus == .unavailable)
        #expect(model.canMerge)
    }

    @Test func aFailedPredictionStillAllowsTheMerge() async throws {
        let client = StubRepoClient(files: [])
        await client.fail(mergePreview: true, for: target.previewKey)
        let model = model(client)

        model.start()

        #expect(await eventually { await model.previewStatus != .loading })
        #expect(model.previewStatus == .unavailable)
        #expect(model.canMerge)
        model.stop()
    }

    @Test func anAlreadyMergedBranchCannotBeMerged() async throws {
        let client = StubRepoClient(files: [])
        await client.set(mergePreview: .alreadyMerged, for: target.previewKey)
        let model = model(client)

        model.start()

        #expect(await eventually { await model.previewStatus == .ready(.alreadyMerged) })
        #expect(model.isAlreadyMerged)
        #expect(!model.canMerge)
        model.stop()
    }

    /// The cache already knows there is nothing to bring in, so the list is not asked for.
    @Test func aCachedAlreadyMergedPreviewSkipsTheCommitList() async throws {
        let client = StubRepoClient(files: [])
        await client.set(mergePreview: .alreadyMerged, for: target.previewKey)
        let loader = MergePreviewLoader(client: client)
        let warm = MergeSheetModel(target: target, previews: loader, loadCommits: { _ in nil })
        warm.start()
        #expect(await eventually { await warm.previewStatus == .ready(.alreadyMerged) })
        warm.stop()

        let loads = CommitLoads()
        let model = MergeSheetModel(
            target: target, previews: loader, loadCommits: { await loads.load(limit: $0, answer: []) })
        model.start()

        #expect(model.isAlreadyMerged)
        #expect(model.commits?.isEmpty == true)
        #expect(!model.isLoadingCommits)
        #expect(loads.limits.isEmpty)
        model.stop()
    }

    @Test func aCommitListFinishingAfterStopIsIgnored() async throws {
        let client = StubRepoClient(files: [])
        let loads = CommitLoads()
        loads.holds = true
        let model = model(client, loads: loads, commits: [commitSummary("c1")])

        model.start()
        #expect(await eventually { await loads.limits.count == 1 })
        let task = model.commitsTask
        model.stop()
        loads.release()
        await task?.value

        #expect(model.commits == nil)
        #expect(model.isLoadingCommits)
    }
}
