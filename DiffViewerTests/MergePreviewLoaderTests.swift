import Testing

@testable import DiffViewer

/// The keys one consumer was told had finished, in order.
@MainActor
private final class Deliveries {
    private(set) var keys: [MergePreviewKey] = []

    func record(_ key: MergePreviewKey) {
        keys.append(key)
    }
}

@MainActor
struct MergePreviewLoaderTests {
    private let client = StubRepoClient(files: [])

    private func key(_ source: String) -> MergePreviewKey {
        MergePreviewKey(headSha: "head", sourceTipSha: source)
    }

    private func register(_ loader: MergePreviewLoader, _ log: Deliveries) -> MergePreviewLoader.ConsumerToken {
        loader.registerConsumer { log.record($0) }
    }

    /// Waits until every call has returned and been handled.
    private func settled(_ loader: MergePreviewLoader) async -> Bool {
        await eventually { await loader.runningCount == 0 }
    }

    @Test func concurrentRequestsCoalesceAndALaterOneHitsTheCache() async {
        let a = key("a")
        await client.set(mergePreview: .clean(commits: 2), for: a)
        await client.hold(.mergePreview)
        let loader = MergePreviewLoader(client: client)
        let (picker, sheet) = (Deliveries(), Deliveries())
        let pickerToken = register(loader, picker)
        let sheetToken = register(loader, sheet)
        loader.setRequestedKeys([a], for: pickerToken)
        loader.setRequestedKeys([a], for: pickerToken)
        loader.setRequestedKeys([a], for: sheetToken)
        #expect(await eventually { await client.heldCount(.mergePreview) == 1 })
        await client.release(.mergePreview)
        #expect(await settled(loader))
        #expect(picker.keys == [a])
        #expect(sheet.keys == [a])

        loader.setRequestedKeys([], for: pickerToken)
        loader.setRequestedKeys([a], for: pickerToken)
        #expect(loader.cachedPreview(for: a) == .clean(commits: 2))
        #expect(loader.runningCount == 0)
        #expect(await client.mergePreviewCalls == [a])
    }

    @Test func theCacheEvictsItsLeastRecentlyUsedEntry() async {
        let loader = MergePreviewLoader(client: client, capacity: 2)
        let token = register(loader, Deliveries())
        for source in ["a", "b"] {
            loader.setRequestedKeys([key(source)], for: token)
            #expect(await settled(loader))
        }
        _ = loader.cachedPreview(for: key("a"))
        loader.setRequestedKeys([key("c")], for: token)
        #expect(await settled(loader))
        #expect(loader.cachedPreview(for: key("a")) != nil)
        #expect(loader.cachedPreview(for: key("b")) == nil)
        #expect(loader.cachedPreview(for: key("c")) != nil)
    }

    @Test func noMoreThanTwoCallsRunAtOnce() async {
        await client.hold(.mergePreview)
        let loader = MergePreviewLoader(client: client)
        let log = Deliveries()
        let keys = Set(["a", "b", "c", "d", "e"].map(key))
        loader.setRequestedKeys(keys, for: register(loader, log))
        #expect(await eventually { await client.heldCount(.mergePreview) == 2 })
        #expect(await client.mergePreviewCalls.count == 2)

        await client.hold(.mergePreview, false)
        await client.release(.mergePreview)
        #expect(await settled(loader))
        #expect(Set(log.keys) == keys)
        #expect(await client.mostRunningMergePreviews == MergePreviewLoader.maximumConcurrent)
    }

    /// The running calls keep their slots, so a newcomer waits for one; the queued key
    /// nobody wants any more never runs.
    @Test func anUnregisteredConsumersCallsFinishButItsQueueIsDropped() async {
        await client.hold(.mergePreview)
        let loader = MergePreviewLoader(client: client)
        let gone = Deliveries()
        let goneToken = register(loader, gone)
        loader.setRequestedKeys([key("a"), key("b"), key("c")], for: goneToken)
        #expect(await eventually { await client.heldCount(.mergePreview) == 2 })
        let started = await client.mergePreviewCalls
        loader.unregisterConsumer(goneToken)

        let next = Deliveries()
        loader.setRequestedKeys([key("d")], for: register(loader, next))
        #expect(loader.runningCount == 2)
        await client.releaseFirst(.mergePreview)
        #expect(await eventually { await client.mergePreviewCalls.count == 3 })
        await client.hold(.mergePreview, false)
        await client.release(.mergePreview)
        #expect(await settled(loader))
        #expect(await client.mergePreviewCalls == started + [key("d")])
        #expect(gone.keys.isEmpty)
        #expect(next.keys == [key("d")])
        #expect(started.allSatisfy { loader.cachedPreview(for: $0) != nil })
    }

    @Test func aReopenedPickerJoinsTheCallItsPredecessorStarted() async {
        let a = key("a")
        await client.hold(.mergePreview)
        let loader = MergePreviewLoader(client: client)
        let closed = Deliveries()
        let closedToken = register(loader, closed)
        loader.setRequestedKeys([a], for: closedToken)
        #expect(await eventually { await client.heldCount(.mergePreview) == 1 })
        loader.unregisterConsumer(closedToken)

        let reopened = Deliveries()
        loader.setRequestedKeys([a], for: register(loader, reopened))
        await client.release(.mergePreview)
        #expect(await settled(loader))
        #expect(await client.mergePreviewCalls == [a])
        #expect(closed.keys.isEmpty)
        #expect(reopened.keys == [a])
        #expect(loader.cachedPreview(for: a) == .alreadyMerged)
    }

    /// The sheet opened from the picker reuses a finished result and joins a running one.
    @Test func aSecondConsumerReusesCachedAndRunningCalls() async {
        let (done, running) = (key("done"), key("running"))
        let loader = MergePreviewLoader(client: client)
        let pickerToken = register(loader, Deliveries())
        loader.setRequestedKeys([done], for: pickerToken)
        #expect(await settled(loader))

        await client.hold(.mergePreview)
        loader.setRequestedKeys([running], for: pickerToken)
        #expect(await eventually { await client.heldCount(.mergePreview) == 1 })
        let sheet = Deliveries()
        loader.setRequestedKeys([done, running], for: register(loader, sheet))
        #expect(loader.cachedPreview(for: done) == .alreadyMerged)
        await client.release(.mergePreview)
        #expect(await settled(loader))
        #expect(await client.mergePreviewCalls == [done, running])
        #expect(sheet.keys == [running])
    }

    /// A failure is remembered per consumer: the same consumer isn't asked again until it
    /// retries, and a new consumer starts clean.
    @Test func aFailureIsRetriedOnRequestOrByANewConsumer() async {
        let a = key("a")
        await client.fail(mergePreview: true, for: a)
        let loader = MergePreviewLoader(client: client)
        let log = Deliveries()
        let token = register(loader, log)
        loader.setRequestedKeys([a], for: token)
        #expect(await settled(loader))
        loader.setRequestedKeys([a], for: token)
        #expect(loader.runningCount == 0, "a reconfigured cell doesn't ask again")
        #expect(log.keys == [a])
        #expect(loader.cachedPreview(for: a) == nil)

        await client.fail(mergePreview: false, for: a)
        loader.retry(a, for: token)
        #expect(await settled(loader))
        #expect(log.keys == [a, a])
        #expect(loader.cachedPreview(for: a) == .alreadyMerged)

        let b = key("b")
        await client.fail(mergePreview: true, for: b)
        loader.setRequestedKeys([b], for: token)
        #expect(await settled(loader))
        await client.fail(mergePreview: false, for: b)
        let fresh = Deliveries()
        loader.setRequestedKeys([b], for: register(loader, fresh))
        #expect(await settled(loader))
        #expect(fresh.keys == [b])
        #expect(await client.mergePreviewCalls == [a, a, b, b])
    }

    /// Another consumer's success reaches one whose own call failed, from the cache.
    @Test func aFailedConsumerSeesAnotherConsumersSuccess() async {
        let a = key("a")
        await client.fail(mergePreview: true, for: a)
        let loader = MergePreviewLoader(client: client)
        let failedToken = register(loader, Deliveries())
        loader.setRequestedKeys([a], for: failedToken)
        #expect(await settled(loader))
        loader.setRequestedKeys([], for: failedToken)

        await client.fail(mergePreview: false, for: a)
        loader.retry(a, for: register(loader, Deliveries()))
        #expect(await settled(loader))
        loader.setRequestedKeys([a], for: failedToken)
        #expect(loader.cachedPreview(for: a) == .alreadyMerged)
        #expect(loader.runningCount == 0)
        #expect(await client.mergePreviewCalls == [a, a])
    }

    /// A call running at invalidation is neither cached nor reported, and no token, old
    /// or new, starts another.
    @Test func anInvalidatedLoaderDoesNothing() async {
        let a = key("a")
        await client.hold(.mergePreview)
        let loader = MergePreviewLoader(client: client)
        let before = Deliveries()
        let beforeToken = register(loader, before)
        loader.setRequestedKeys([a], for: beforeToken)
        #expect(await eventually { await client.heldCount(.mergePreview) == 1 })
        loader.invalidate()
        await client.release(.mergePreview)
        #expect(await settled(loader))
        #expect(loader.cachedPreview(for: a) == nil)

        await client.hold(.mergePreview, false)
        let after = Deliveries()
        let afterToken = register(loader, after)
        loader.setRequestedKeys([key("b")], for: afterToken)
        loader.retry(key("c"), for: beforeToken)
        #expect(loader.runningCount == 0)
        #expect(await client.mergePreviewCalls == [a])
        #expect(before.keys.isEmpty)
        #expect(after.keys.isEmpty)
    }
}

struct MergePreviewTextTests {
    @Test func previewsArePluralisedAndConflictsWarn() {
        let cases: [(MergePreview, BranchRowLabel)] = [
            (.clean(commits: 1), BranchRowLabel(text: "1 commit", style: .secondary)),
            (.clean(commits: 3), BranchRowLabel(text: "3 commits", style: .secondary)),
            (.alreadyMerged, BranchRowLabel(text: "Already merged", style: .secondary)),
            (.conflicts(commits: 2, paths: ["a"]), BranchRowLabel(text: "Conflict in 1 file", style: .warning)),
            (.conflicts(commits: 2, paths: ["a", "b"]), BranchRowLabel(text: "Conflict in 2 files", style: .warning)),
            (.conflicts(commits: 2, paths: []), BranchRowLabel(text: "Conflicts predicted", style: .warning)),
        ]
        for (preview, label) in cases {
            #expect(MergePreviewText.label(for: preview) == label)
        }
    }
}
