import Foundation
import Testing

@testable import DiffViewer

@MainActor
struct MergeSheetModelTests {
    private let target = MergeTarget(
        sourceName: "side", sourceRef: "refs/heads/side", sourceTipSha: objectID("side"),
        destinationBranch: "main", destinationTipSha: objectID("main"))
    private let english = Locale(identifier: "en_US")
    private let summaryA = IncomingChangeSummary(fileCount: 1, addedLineCount: 2, deletedLineCount: 3)
    private let summaryB = IncomingChangeSummary(fileCount: 4, addedLineCount: 5, deletedLineCount: 6)

    private func client(preview: MergePreview? = nil) async -> StubRepoClient {
        let client = StubRepoClient(files: [])
        if let preview { await client.set(mergePreview: preview, for: target.previewKey) }
        return client
    }

    private func model(_ client: StubRepoClient, locale: Locale? = nil) -> MergeSheetModel {
        let target = target
        return MergeSheetModel(
            target: target, previews: MergePreviewLoader(client: client), locale: locale ?? english,
            loadIncomingChanges: {
                try? await client.incomingChanges(headSha: target.destinationTipSha, sourceTipSha: target.sourceTipSha)
            })
    }

    // MARK: Presentation

    @Test(arguments: [(0, CommitMarks.none), (1, .dots(1)), (5, .dots(5)), (6, .capsule)])
    func commitMarksFollowTheCount(count: Int, marks: CommitMarks) {
        #expect(CommitMarks.forCount(count) == marks)
    }

    @Test func anUnknownCountHasNoCommitsTextAndAGenericLabel() {
        let model = model(StubRepoClient(files: []))
        #expect(model.commitsText == nil)
        #expect(model.accessibilityLabel == "Merge side into main")
    }

    @Test(arguments: [
        (1, "1 commit", "1 file"), (48, "48 commits", "48 files"), (1234, "1,234 commits", "1,234 files"),
    ])
    func countsAreSingularOrPluralAndGrouped(count: Int, commits: String, files: String) {
        #expect(MergeSheetModel.commitsText(count, locale: english) == commits)
        #expect(MergeSheetModel.filesText(count, locale: english) == files)
    }

    @Test(arguments: [
        (0, "Conflicts Predicted", "Conflicts are predicted."),
        (1, "1 File with Conflicts", "Conflicts are predicted in 1 file."),
        (23, "23 Files with Conflicts", "Conflicts are predicted in 23 files."),
    ])
    func conflictWordingFollowsTheFileCount(count: Int, title: String, notePrefix: String) {
        #expect(MergeSheetModel.conflictTitle(fileCount: count, locale: english) == title)
        #expect(
            MergeSheetModel.conflictNote(fileCount: count, locale: english)
                == notePrefix + " If the merge stops, resolve them in your editor, then stage and commit here.")
    }

    @Test func lineCountsUseTheLocaleAndATrueMinus() {
        #expect(MergeSheetModel.addedText(3906, locale: english) == "+3,906")
        #expect(MergeSheetModel.deletedText(2118, locale: english) == "\u{2212}2,118")
        #expect(MergeSheetModel.deletedText(2118, locale: Locale(identifier: "de_DE")) == "\u{2212}2.118")
    }

    @Test func aLoadedMergeIsDescribedFromThePreviewAndTheSummary() async throws {
        let files = [MergeConflict(path: "a.swift", kind: .contents), MergeConflict(path: "b.swift", kind: .addAdd)]
        let client = await client(preview: .conflicts(commits: 3, files: files))
        await client.set(
            incomingChanges: IncomingChangeSummary(fileCount: 12, addedLineCount: 3906, deletedLineCount: 2118))
        let model = model(client)

        model.start()
        let task = try #require(model.summaryTask)
        await task.value
        #expect(await eventually { await model.previewStatus != .loading })

        #expect(model.commitsText == "3 commits")
        #expect(model.commitMarks == .dots(3))
        #expect(model.accessibilityLabel == "side, with 3 commits, merges into main")
        #expect(model.statusTitle == "2 Files with Conflicts")
        #expect(model.conflicts == files)
        #expect(model.primaryTitle == "Merge Anyway")
        #expect(model.statistics == .ready(files: "12 files", added: "+3,906", deleted: "\u{2212}2,118"))
        model.stop()
    }

    @Test func conflictsWithoutNamedFilesStillWarnAndOfferMergeAnyway() async throws {
        let model = model(await client(preview: .conflicts(commits: 2, files: [])))

        model.start()

        #expect(await eventually { await model.previewStatus != .loading })
        #expect(model.statusTitle == "Conflicts Predicted")
        #expect(model.primaryTitle == "Merge Anyway")
        #expect(model.conflictNote?.hasPrefix("Conflicts are predicted. If the merge stops") == true)
        model.stop()
    }

    // MARK: Lifecycle

    @Test func repeatedStartsAskOncePerKind() async throws {
        let client = await client(preview: .clean(commits: 1))
        await client.set(incomingChanges: summaryA)
        let model = model(client)

        model.start()
        let task = try #require(model.summaryTask)
        model.start()
        await task.value
        #expect(await eventually { await model.previewStatus != .loading })

        #expect(model.incomingChangesStatus == .ready(summaryA))
        #expect(await client.mergePreviewCalls == [target.previewKey])
        #expect(await client.incomingChangesCalls == [target.previewKey])
        model.stop()
    }

    @Test func aSummaryFinishingAfterStopIsIgnored() async throws {
        let client = await client(preview: .clean(commits: 1))
        await client.hold(.incomingChanges)
        let model = model(client)

        model.start()
        #expect(await eventually { await client.heldCount(.incomingChanges) == 1 })
        let task = try #require(model.summaryTask)
        model.stop()
        await client.release(.incomingChanges)
        await task.value

        #expect(model.incomingChangesStatus == .loading)
    }

    @Test func aFailedSummaryIsUnavailable() async throws {
        let client = await client(preview: .clean(commits: 1))
        await client.fail(incomingChanges: true)
        let model = model(client)

        model.start()
        let task = try #require(model.summaryTask)
        await task.value

        #expect(model.incomingChangesStatus == .unavailable)
        #expect(model.statistics == .hidden)
        model.stop()
    }

    @Test func aFailedPredictionIsNotRetriedAfterStopAndStart() async throws {
        let client = await client()
        await client.fail(mergePreview: true, for: target.previewKey)
        let model = model(client)

        model.start()
        #expect(await eventually { await model.previewStatus == .unavailable })
        model.stop()
        model.start()

        #expect(model.previewStatus == .unavailable)
        #expect(await client.mergePreviewCalls.count == 1)
        model.stop()
    }

    /// The first request is stale after a restart, so its late answer must not overwrite the new one.
    @Test func anUnfinishedSummaryResumesAfterStopAndStart() async throws {
        let client = await client(preview: .clean(commits: 1))
        await client.hold(.incomingChanges)
        let model = model(client)

        model.start()
        #expect(await eventually { await client.heldCount(.incomingChanges) == 1 })
        let oldTask = try #require(model.summaryTask)
        model.stop()
        model.start()
        #expect(await eventually { await client.heldCount(.incomingChanges) == 2 })
        let newTask = try #require(model.summaryTask)

        await client.set(incomingChanges: summaryB)
        await client.releaseLast(.incomingChanges)
        await newTask.value
        #expect(model.incomingChangesStatus == .ready(summaryB))

        await client.set(incomingChanges: summaryA)
        await client.releaseFirst(.incomingChanges)
        await oldTask.value
        #expect(model.incomingChangesStatus == .ready(summaryB))
        model.stop()
    }

    @Test func anUnfinishedPredictionResumesAfterStopAndStart() async throws {
        let client = await client(preview: .clean(commits: 2))
        await client.hold(.mergePreview)
        let model = model(client)

        model.start()
        #expect(await eventually { await client.heldCount(.mergePreview) == 1 })
        model.stop()
        model.start()
        await client.release(.mergePreview)

        #expect(await eventually { await model.previewStatus == .ready(.clean(commits: 2)) })
        #expect(await client.mergePreviewCalls.count == 1)
        model.stop()
    }

    @Test func aCachedAlreadyMergedPreviewSkipsTheSummary() async throws {
        let client = await client(preview: .alreadyMerged)
        let loader = MergePreviewLoader(client: client)
        let warm = MergeSheetModel(target: target, previews: loader, loadIncomingChanges: { nil })
        warm.start()
        #expect(await eventually { await warm.previewStatus == .ready(.alreadyMerged) })
        warm.stop()

        let target = target
        let model = MergeSheetModel(
            target: target, previews: loader,
            loadIncomingChanges: {
                try? await client.incomingChanges(headSha: target.destinationTipSha, sourceTipSha: target.sourceTipSha)
            })
        model.start()

        #expect(model.isAlreadyMerged)
        #expect(model.statistics == .hidden)
        #expect(model.summaryTask == nil)
        #expect(await client.incomingChangesCalls.isEmpty)
        model.stop()
    }

    // MARK: Independence

    @Test func theSummaryDoesNotHoldBackMerging() async throws {
        let client = await client(preview: .clean(commits: 1))
        await client.hold(.incomingChanges)
        let model = model(client)

        model.start()

        #expect(await eventually { await model.previewStatus == .ready(.clean(commits: 1)) })
        #expect(model.canMerge)
        #expect(model.statistics == .pending)
        model.stop()
        await client.release(.incomingChanges)
    }

    @Test func anAlreadyMergedPreviewHidesStatisticsThatAlreadyArrived() async throws {
        let client = await client(preview: .alreadyMerged)
        await client.set(incomingChanges: summaryA)
        await client.hold(.mergePreview)
        let model = model(client)

        model.start()
        let task = try #require(model.summaryTask)
        await task.value
        #expect(model.statistics != .hidden)

        await client.release(.mergePreview)
        #expect(await eventually { await model.isAlreadyMerged })
        #expect(model.statistics == .hidden)
        model.stop()
    }

    // MARK: Availability

    enum Situation {
        case loading, clean, conflicted, alreadyMerged, failed, noLoader
    }

    @Test(arguments: [
        (Situation.loading, false), (.clean, true), (.conflicted, true), (.alreadyMerged, false),
        (.failed, true), (.noLoader, true),
    ])
    func mergingIsAllowedOnceThePredictionIsKnownAndThereIsSomethingToMerge(situation: Situation, allowed: Bool)
        async throws
    {
        let client = await client()
        let model: MergeSheetModel
        switch situation {
        case .loading:
            await client.hold(.mergePreview)
            model = self.model(client)
        case .clean:
            await client.set(mergePreview: .clean(commits: 1), for: target.previewKey)
            model = self.model(client)
        case .conflicted:
            await client.set(mergePreview: .conflicts(commits: 1, files: []), for: target.previewKey)
            model = self.model(client)
        case .alreadyMerged:
            await client.set(mergePreview: .alreadyMerged, for: target.previewKey)
            model = self.model(client)
        case .failed:
            await client.fail(mergePreview: true, for: target.previewKey)
            model = self.model(client)
        case .noLoader:
            model = MergeSheetModel(target: target, previews: nil, loadIncomingChanges: { nil })
        }

        model.start()
        if situation == .loading {
            #expect(await eventually { await client.heldCount(.mergePreview) == 1 })
        } else {
            #expect(await eventually { await model.previewStatus != .loading })
        }

        #expect(model.canMerge == allowed)
        model.stop()
        await client.release(.mergePreview)
    }
}
