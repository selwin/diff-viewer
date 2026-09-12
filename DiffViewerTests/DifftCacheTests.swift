import Foundation
import Testing
@testable import DiffViewer

/// Stand-in for the difft process: records launches in submission order, can hold
/// launches open until released, and can fail on demand.
actor RunnerProbe {
    struct Launch: Equatable {
        let fileName: String
        let qualityOfService: QualityOfService
    }

    private(set) var launches: [Launch] = []
    private(set) var inFlight = 0
    private(set) var peakInFlight = 0
    private var holds = false
    private var fails = false
    private var changesPerLine = 1
    private var held: [CheckedContinuation<Void, Never>] = []

    var fileNames: [String] { launches.map(\.fileName) }

    func hold(_ on: Bool) { holds = on }
    func fail(_ on: Bool) { fails = on }
    func changes(perLine count: Int) { changesPerLine = count }

    func run(old: Data, new: Data, fileName: String, qualityOfService: QualityOfService) async throws -> DifftFile {
        launches.append(Launch(fileName: fileName, qualityOfService: qualityOfService))
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        if holds {
            await withCheckedContinuation { held.append($0) }
        }
        inFlight -= 1
        if fails { throw ProcessError.failed(command: "difft", status: 1, stderr: "boom") }
        let changes = (0..<changesPerLine).map {
            DifftFile.Change(start: $0 * 2, end: $0 * 2 + 1, content: "x", highlight: "normal")
        }
        let line = DifftFile.Line(lineNumber: 0, changes: changes)
        return DifftFile(language: "Swift", path: fileName, status: "changed", chunks: [[DifftFile.LinePair(lhs: line, rhs: line)]])
    }

    /// Releases held launches in the order they arrived.
    func release(_ count: Int = .max) {
        for _ in 0..<min(count, held.count) {
            held.removeFirst().resume()
        }
    }
}

/// Controllable monotonic clock for failure expiry.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var offset: Duration = .zero

    func now() -> ContinuousClock.Instant { lock.withLock { base + offset } }
    func advance(_ duration: Duration) { lock.withLock { offset += duration } }
}

private func makeCache(_ probe: RunnerProbe, limits: DifftCache.Limits = DifftCache.Limits(), clock: TestClock = TestClock()) -> DifftCache {
    DifftCache(
        runner: { old, new, fileName, qualityOfService in
            try await probe.run(old: old, new: new, fileName: fileName, qualityOfService: qualityOfService)
        },
        limits: limits,
        now: { clock.now() }
    )
}

/// Requests a diff whose content is derived from `name`, so distinct names are distinct keys.
private func request(_ cache: DifftCache, _ name: String, _ priority: DifftCache.Priority = .foreground, fileName: String = "a.swift") async -> DifftResult? {
    await cache.result(old: Data(name.utf8), new: Data("\(name)!".utf8), fileName: fileName, priority: priority)
}

/// Polls `condition` for up to two seconds.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

struct DifftCacheTests {
    @Test func sameInputsRunOnce() async {
        let probe = RunnerProbe()
        let cache = makeCache(probe)
        let first = await request(cache, "a")
        let second = await request(cache, "a")
        #expect(first?.language == "Swift")
        #expect(second?.hints.pairs.count == 1)
        #expect(await probe.launches.count == 1)
        #expect(await cache.stats.hits == 1)
    }

    @Test func differentInputsRunSeparately() async {
        let probe = RunnerProbe()
        let cache = makeCache(probe)
        _ = await request(cache, "a")
        _ = await request(cache, "b")
        _ = await request(cache, "a", fileName: "a.py")
        _ = await cache.result(old: Data("a".utf8), new: Data("a!".utf8), fileName: "a.swift", priority: .foreground)
        #expect(await probe.launches.count == 3)
    }

    @Test func keyDependsOnSideBoundaries() {
        let ab = DifftCache.key(old: Data("ab".utf8), new: Data("c".utf8), fileName: "f")
        let a_bc = DifftCache.key(old: Data("a".utf8), new: Data("bc".utf8), fileName: "f")
        #expect(ab != a_bc)
        #expect(ab == DifftCache.key(old: Data("ab".utf8), new: Data("c".utf8), fileName: "f"))
    }

    @Test func concurrentRequestsCoalesce() async {
        let probe = RunnerProbe()
        let cache = makeCache(probe)
        await probe.hold(true)
        let tasks = (0..<5).map { _ in Task { await request(cache, "a", .background) } }
        #expect(await eventually { await cache.stats.inFlightJoins == 4 }, "all callers must reach the cache while the run is held")
        #expect(await probe.launches.count == 1)
        await probe.release()
        for task in tasks { #expect(await task.value != nil) }
    }

    @Test func evictionPressureDoesNotDuplicateRunningTask() async {
        let probe = RunnerProbe()
        var limits = DifftCache.Limits()
        limits.entries = 1
        let cache = makeCache(probe, limits: limits)
        await probe.hold(true)
        let running = Task { await request(cache, "a", .background) }
        #expect(await eventually { await probe.launches.count == 1 })
        await probe.hold(false)
        _ = await request(cache, "b")
        _ = await request(cache, "c")
        #expect(await cache.stats.evictions == 1)

        let again = Task { await request(cache, "a") }
        #expect(await eventually { await cache.stats.inFlightJoins == 1 })
        #expect(await probe.fileNames == ["a.swift", "a.swift", "a.swift"])
        #expect(await probe.launches.count == 3, "second request for a running key must not launch")
        await probe.release()
        #expect(await running.value != nil)
        #expect(await again.value != nil)
    }

    @Test func entryBoundEvictsOldestCompletedResult() async {
        let probe = RunnerProbe()
        var limits = DifftCache.Limits()
        limits.entries = 2
        let cache = makeCache(probe, limits: limits)
        _ = await request(cache, "a")
        _ = await request(cache, "b")
        _ = await request(cache, "c")
        _ = await request(cache, "b")
        #expect(await probe.launches.count == 3)
        _ = await request(cache, "a")
        #expect(await probe.launches.count == 4)
        #expect(await cache.stats.evictions == 2)
    }

    @Test func byteBudgetEvictsOldestCompletedResults() async {
        let probe = RunnerProbe()
        await probe.changes(perLine: 10)
        var limits = DifftCache.Limits()
        limits.bytes = 1000
        let cache = makeCache(probe, limits: limits)
        let result = await request(cache, "a")
        #expect(result?.cost == 405)
        _ = await request(cache, "b")
        _ = await request(cache, "c")
        #expect(await cache.stats.evictions == 1)
        _ = await request(cache, "b")
        _ = await request(cache, "c")
        #expect(await probe.launches.count == 3)
        _ = await request(cache, "a")
        #expect(await probe.launches.count == 4)
    }

    @Test func oversizedResultIsReturnedButNotStored() async {
        let probe = RunnerProbe()
        await probe.changes(perLine: 10)
        var limits = DifftCache.Limits()
        limits.maxResultCost = 100
        let cache = makeCache(probe, limits: limits)
        #expect(await request(cache, "a") != nil)
        #expect(await request(cache, "a") != nil)
        #expect(await probe.launches.count == 2)
    }

    @Test func failureIsRememberedUntilExpiry() async {
        let probe = RunnerProbe()
        let clock = TestClock()
        let cache = makeCache(probe, clock: clock)
        await probe.fail(true)
        #expect(await request(cache, "a") == nil)
        #expect(await request(cache, "a") == nil)
        #expect(await probe.launches.count == 1)
        #expect(await cache.stats.failures == 1)

        clock.advance(.seconds(31))
        await probe.fail(false)
        #expect(await request(cache, "a") != nil)
        #expect(await probe.launches.count == 2)
    }

    @Test func expiredFailuresArePrunedWithoutRerequestingThem() async {
        let probe = RunnerProbe()
        let clock = TestClock()
        let cache = makeCache(probe, clock: clock)
        await probe.fail(true)
        for index in 0..<20 { _ = await request(cache, "stale-\(index)") }
        #expect(await cache.rememberedFailureCount == 20)

        clock.advance(.seconds(31))
        _ = await request(cache, "fresh")
        #expect(await cache.rememberedFailureCount == 1)
        #expect(await probe.launches.count == 21)
    }

    @Test func failureTableIsBounded() async {
        let probe = RunnerProbe()
        var limits = DifftCache.Limits()
        limits.failures = 5
        let cache = makeCache(probe, limits: limits)
        await probe.fail(true)
        for index in 0..<8 { _ = await request(cache, "f-\(index)") }
        #expect(await cache.rememberedFailureCount == 5)
        #expect(await request(cache, "f-7") == nil)
        #expect(await probe.launches.count == 8, "newest failures stay remembered")
        _ = await request(cache, "f-0")
        #expect(await probe.launches.count == 9, "oldest failure was dropped and retried")
    }

    @Test func backgroundLimitAdmitsInSubmissionOrder() async {
        let probe = RunnerProbe()
        let cache = makeCache(probe)
        await probe.hold(true)
        var tasks: [Task<DifftResult?, Never>] = []
        for name in ["a", "b", "c", "d", "e", "f"] {
            tasks.append(Task { await request(cache, name, .background, fileName: "\(name).swift") })
            let expected = tasks.count
            #expect(await eventually { await cache.stats.misses == expected })
        }
        #expect(await eventually { await cache.stats.backgroundQueueWaits == 3 })
        #expect(await probe.fileNames == ["a.swift", "b.swift", "c.swift"])
        #expect(await probe.peakInFlight == 3)
        #expect(await probe.launches.allSatisfy { $0.qualityOfService == .utility })

        await probe.release(1)
        #expect(await eventually { await probe.launches.count == 4 })
        #expect(await probe.fileNames.last == "d.swift")
        #expect(await probe.peakInFlight == 3)

        await probe.release()
        #expect(await eventually { await probe.launches.count == 6 })
        await probe.release()
        for task in tasks { #expect(await task.value != nil) }
    }

    @Test func foregroundStartsImmediatelyPastTheBackgroundLimit() async {
        let probe = RunnerProbe()
        let cache = makeCache(probe)
        await probe.hold(true)
        let background = ["a", "b", "c"].map { name in Task { await request(cache, name, .background, fileName: "\(name).swift") } }
        #expect(await eventually { await probe.launches.count == 3 })

        let foreground = Task { await request(cache, "x", .foreground, fileName: "x.swift") }
        #expect(await eventually { await probe.launches.count == 4 })
        #expect(await probe.launches.last == RunnerProbe.Launch(fileName: "x.swift", qualityOfService: .userInitiated))
        #expect(await probe.peakInFlight == 4)

        await probe.release()
        for task in background { #expect(await task.value != nil) }
        #expect(await foreground.value != nil)
    }

    @Test func foregroundRequestPromotesAWaitingKey() async {
        let probe = RunnerProbe()
        var limits = DifftCache.Limits()
        limits.backgroundProcesses = 1
        let cache = makeCache(probe, limits: limits)
        await probe.hold(true)
        let a = Task { await request(cache, "a", .background, fileName: "a.swift") }
        #expect(await eventually { await probe.launches.count == 1 })
        let b = Task { await request(cache, "b", .background, fileName: "b.swift") }
        let c = Task { await request(cache, "c", .background, fileName: "c.swift") }
        #expect(await eventually { await cache.stats.backgroundQueueWaits == 2 })

        let promoted = Task { await request(cache, "c", .foreground, fileName: "c.swift") }
        #expect(await eventually { await probe.launches.count == 2 })
        #expect(await probe.launches.last == RunnerProbe.Launch(fileName: "c.swift", qualityOfService: .userInitiated))
        #expect(await cache.stats.promotions == 1)

        await probe.release(2)
        #expect(await eventually { await probe.launches.count == 3 })
        #expect(await probe.fileNames.last == "b.swift")
        await probe.release()
        for task in [a, b, c, promoted] { #expect(await task.value != nil) }
        #expect(await probe.launches.count == 3)
    }
}
