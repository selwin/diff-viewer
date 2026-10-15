import Foundation
import Testing

@testable import DiffViewer

/// Resolves each request only when the test finishes it, so a read can be held mid-flight.
@MainActor
private final class GatedResolver {
    private(set) var requests: [String] = []
    /// What each request's `isCurrent()` said once it was finished.
    private(set) var wasCurrent: [Bool] = []
    private var waiting: [CheckedContinuation<Result<CommitRange, ComparisonFailure>, Never>] = []

    func resolve(_ request: String, isCurrent: @MainActor () -> Bool) async throws -> CommitRange {
        requests.append(request)
        let result = await withCheckedContinuation { waiting.append($0) }
        wasCurrent.append(isCurrent())
        return try result.get()
    }

    /// Finishes the oldest request still waiting.
    func finish(_ result: Result<CommitRange, ComparisonFailure>) {
        waiting.removeFirst().resume(returning: result)
    }
}

@MainActor
struct ComparisonPreviewTests {
    private let summary = IncomingChangeSummary(fileCount: 3, addedLineCount: 20, deletedLineCount: 5)
    private let range = CommitRange(
        baseName: "main", targetName: "a", mergeBaseSHA: objectID("base"), targetSHA: objectID("a"))

    private func preview(
        _ resolver: GatedResolver, clock: ManualClock = ManualClock(), failingChurn: Bool = false
    ) async -> ComparisonPreview<String> {
        let client = StubRepoClient(files: [])
        await client.set(churn: summary)
        await client.fail(churn: failingChurn)
        return ComparisonPreview(
            client: client, clock: clock, debounce: .milliseconds(500), spinnerDelay: .milliseconds(800)
        ) { request, isCurrent in
            try await resolver.resolve(request, isCurrent: isCurrent)
        }
    }

    @Test func customDelaysAreMeasuredFromTheRequestChange() async {
        let resolver = GatedResolver()
        let clock = ManualClock()
        let preview = await preview(resolver, clock: clock)

        preview.setRequest("a")
        #expect(await eventually { clock.sleeperCount == 2 })
        clock.advance(by: .milliseconds(499))
        #expect(clock.sleeperCount == 2)
        #expect(preview.resolution == .idle)
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await preview.resolution == .resolving })
        clock.advance(by: .milliseconds(299))
        #expect(preview.churn == .pending)
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await preview.churn == .comparing })

        resolver.finish(.success(range))
        #expect(await eventually { await preview.churn == .ready(summary) })
        #expect(preview.resolution == .resolved(range))
    }

    @Test(arguments: [true, false])
    func aSupersededRequestPublishesNothing(succeeds: Bool) async throws {
        let resolver = GatedResolver()
        let preview = await preview(resolver)

        preview.setRequest("a")
        preview.resolveNow()
        #expect(await eventually { await resolver.requests == ["a"] })
        #expect(preview.resolution == .resolving)
        let read = try #require(preview.readTask)
        preview.setRequest("b")
        #expect(preview.resolution == .idle && preview.churn == .pending)

        resolver.finish(succeeds ? .success(range) : .failure(ComparisonFailure("a failed")))
        await read.value
        #expect(resolver.wasCurrent == [false])
        #expect(preview.resolution == .idle && preview.churn == .pending)
    }

    @Test func anEqualRequestStartsNoNewRead() async {
        let resolver = GatedResolver()
        let clock = ManualClock()
        let preview = await preview(resolver, clock: clock)

        preview.setRequest("a")
        #expect(await eventually { clock.sleeperCount == 2 })
        clock.advance(by: .milliseconds(300))
        // Restarting the debounce here would leave nothing resolving at 500 ms.
        preview.setRequest("a")
        clock.advance(by: .milliseconds(200))
        #expect(await eventually { await preview.resolution == .resolving })

        resolver.finish(.success(range))
        #expect(await eventually { await preview.resolution == .resolved(range) })
        preview.setRequest("a")
        preview.resolveNow()
        #expect(await preview.resolvedRange() == .range(range))
        #expect(resolver.requests == ["a"])
    }

    @Test func aResolverFailureIsPublishedAndRetried() async throws {
        let resolver = GatedResolver()
        let preview = await preview(resolver)

        preview.setRequest("a")
        let first = Task { await preview.resolvedRange() }
        #expect(await eventually { await resolver.requests == ["a"] })
        let read = try #require(preview.readTask)
        resolver.finish(.failure(ComparisonFailure("nope")))
        #expect(await first.value == .failed("nope"))
        await read.value
        #expect(preview.resolution == .failed("nope"))
        #expect(preview.churn == .failed("nope"))

        let retry = Task { await preview.resolvedRange() }
        #expect(await eventually { await resolver.requests == ["a", "a"] })
        resolver.finish(.success(range))
        #expect(await retry.value == .range(range))
    }

    @Test func aChurnFailureKeepsTheResolvedRange() async {
        let resolver = GatedResolver()
        let preview = await preview(resolver, failingChurn: true)
        let message = ProcessError.failed(command: "git diff", status: 128, stderr: "gone").localizedDescription

        preview.setRequest("a")
        preview.resolveNow()
        #expect(await eventually { await resolver.requests == ["a"] })
        resolver.finish(.success(range))
        #expect(await eventually { await preview.churn == .failed(message) })

        #expect(preview.resolution == .resolved(range))
        #expect(await preview.resolvedRange() == .range(range))
        #expect(resolver.requests == ["a"])
    }

    @Test(arguments: ["b", nil] as [String?])
    func changingOrClearingTheRequestResumesAWaiterWithNil(next: String?) async {
        let resolver = GatedResolver()
        let preview = await preview(resolver)

        preview.setRequest("a")
        let waiter = Task { await preview.resolvedRange() }
        #expect(await eventually { await resolver.requests == ["a"] })
        preview.setRequest(next)

        #expect(await waiter.value == nil)
        resolver.finish(.success(range))
    }

    @Test func aClosedPreviewIgnoresNewRequests() async {
        let resolver = GatedResolver()
        let clock = ManualClock()
        let preview = await preview(resolver, clock: clock)

        preview.close()
        preview.setRequest("a")
        #expect(preview.churn == .hidden)
        #expect(preview.resolution == .idle)
        #expect(preview.debounceTask == nil)
        #expect(clock.sleeperCount == 0)

        clock.advance(by: .seconds(1))
        #expect(preview.churn == .hidden)
        #expect(preview.readTask == nil)
        #expect(resolver.requests.isEmpty)
    }
}
