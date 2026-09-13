import Foundation
import Testing

@testable import DiffViewer

/// Stand-in for git reads: records which files were asked for, can hold loads open,
/// and can make particular files binary, identical, or failing.
actor LoaderProbe {
    struct Call: Equatable {
        let fileID: ChangedFile.ID
        let client: String
    }

    private(set) var calls: [Call] = []
    private(set) var inFlight = 0
    private(set) var peakInFlight = 0
    private var holds = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var binary: Set<String> = []
    private var identical: Set<String> = []
    private var failing: Set<String> = []

    func hold(_ on: Bool) { holds = on }
    func markBinary(_ path: String) { binary.insert(path) }
    func markIdentical(_ path: String) { identical.insert(path) }
    func markFailing(_ path: String) { failing.insert(path) }

    func load(_ file: ChangedFile, client: any RepoClient) async throws -> DiffEngine.Sources {
        calls.append(Call(fileID: file.id, client: (client as? TaggedClient)?.tag ?? "?"))
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        if holds {
            await withCheckedContinuation { held.append($0) }
        }
        inFlight -= 1
        if failing.contains(file.path) { throw ProcessError.failed(command: "git", status: 128, stderr: "nope") }
        if binary.contains(file.path) {
            return DiffEngine.Sources(old: Data([0, 1]), new: Data([0, 2]), fileName: file.fileName)
        }
        let old = Data(file.path.utf8)
        let new = identical.contains(file.path) ? old : old + Data("!".utf8)
        return DiffEngine.Sources(old: old, new: new, fileName: file.fileName)
    }

    func release() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }
}

/// A client the prefetcher passes through to the loader, identifiable by tag.
struct TaggedClient: RepoClient {
    var tag = "A"

    func status() async throws -> [ChangedFile] { [] }
    func indexContents(of path: String) async throws -> Data? { nil }
    func headContents(of path: String) async throws -> Data? { nil }
    func worktreeContents(of path: String) async -> Data? { nil }
}

@MainActor
private func makePrefetcher(runner: RunnerProbe, loader: LoaderProbe, limits: DifftCache.Limits = DifftCache.Limits())
    -> (DiffPrefetcher, DifftCache)
{
    let cache = DifftCache(
        runner: { old, new, fileName, qos in
            try await runner.run(old: old, new: new, fileName: fileName, qualityOfService: qos)
        },
        limits: limits
    )
    return (
        DiffPrefetcher(cache: cache, loadSources: { file, client in try await loader.load(file, client: client) }),
        cache
    )
}

private func files(_ count: Int, prefix: String = "f") -> [ChangedFile] {
    (0..<count).map { changedFile("\(prefix)\($0).swift") }
}

@MainActor
struct DiffPrefetcherTests {
    @Test func dequeuesInListOrderAndWarmsEveryFile() async {
        let runner = RunnerProbe()
        let loader = LoaderProbe()
        let (prefetcher, cache) = makePrefetcher(runner: runner, loader: loader)
        let list = files(20)
        prefetcher.prefetch(files: list, client: TaggedClient())
        #expect(await eventually { await prefetcher.isIdle })
        #expect(prefetcher.dequeuedFileIDs == list.map(\.id))
        #expect(await runner.launches.count == 20)
        #expect(await runner.launches.allSatisfy { $0.qualityOfService == .utility })

        // The point of warming: a later foreground request for the same sources is a hit.
        let sources = try? await loader.load(list[7], client: TaggedClient())
        let result = await cache.result(
            old: sources!.old, new: sources!.new, fileName: sources!.fileName, priority: .foreground)
        #expect(result != nil)
        #expect(await runner.launches.count == 20)
        #expect(await cache.stats.hits == 1)
    }

    @Test func skipsBinaryAndIdenticalSources() async {
        let runner = RunnerProbe()
        let loader = LoaderProbe()
        await loader.markBinary("f2.swift")
        await loader.markIdentical("f3.swift")
        let (prefetcher, _) = makePrefetcher(runner: runner, loader: loader)
        prefetcher.prefetch(files: files(5), client: TaggedClient())
        #expect(await eventually { await prefetcher.isIdle })
        #expect(await loader.calls.count == 5)
        #expect(
            await Set(runner.fileNames) == ["f0.swift", "f1.swift", "f4.swift"],
            "completion order is not asserted; dequeue order is")
    }

    @Test func sourceLoadsAreBoundedByTheWorkerCount() async {
        let runner = RunnerProbe()
        let loader = LoaderProbe()
        await loader.hold(true)
        let (prefetcher, _) = makePrefetcher(runner: runner, loader: loader)
        prefetcher.prefetch(files: files(10), client: TaggedClient())
        #expect(await eventually { await loader.inFlight == 3 })
        #expect(await loader.calls.count == 3)
        await loader.hold(false)
        await loader.release()
        #expect(await eventually { await prefetcher.isIdle })
        #expect(await loader.peakInFlight == 3)
        #expect(await runner.launches.count == 10)
    }

    @Test func cancelStopsDequeuingButFinishesLoadsInProgress() async {
        let runner = RunnerProbe()
        let loader = LoaderProbe()
        await loader.hold(true)
        let (prefetcher, _) = makePrefetcher(runner: runner, loader: loader)
        prefetcher.prefetch(files: files(10), client: TaggedClient())
        #expect(await eventually { await loader.inFlight == 3 })
        prefetcher.cancel()
        await loader.hold(false)
        await loader.release()
        #expect(await eventually { await prefetcher.isIdle })
        #expect(prefetcher.dequeuedFileIDs.count == 3)
        #expect(await loader.calls.count == 3)
        #expect(await runner.launches.count == 3, "in-progress files still reach the cache")
    }

    @Test func onlyTheFirstHundredFilesAreScheduled() async {
        let runner = RunnerProbe()
        let loader = LoaderProbe()
        let (prefetcher, _) = makePrefetcher(runner: runner, loader: loader)
        let list = files(150)
        prefetcher.prefetch(files: list, client: TaggedClient())
        #expect(await eventually { await prefetcher.isIdle })
        #expect(prefetcher.dequeuedFileIDs == list.prefix(100).map(\.id))
        #expect(await runner.launches.count == 100)
    }

    @Test func loaderErrorSkipsThatFileOnly() async {
        let runner = RunnerProbe()
        let loader = LoaderProbe()
        await loader.markFailing("f2.swift")
        let (prefetcher, _) = makePrefetcher(runner: runner, loader: loader)
        prefetcher.prefetch(files: files(20), client: TaggedClient())
        #expect(await eventually { await prefetcher.isIdle })
        #expect(await runner.launches.count == 19)
        #expect(await runner.fileNames.contains("f2.swift") == false)
    }

    @Test func replacementsKeepBothBoundsAndDequeueTheLatestList() async {
        let runner = RunnerProbe()
        let loader = LoaderProbe()
        await runner.hold(true)
        let (prefetcher, _) = makePrefetcher(runner: runner, loader: loader)
        var lists: [[ChangedFile]] = []
        for round in 0..<5 {
            let list = files(10, prefix: "r\(round)-")
            lists.append(list)
            prefetcher.prefetch(files: list, client: TaggedClient(tag: "r\(round)"))
            #expect(await eventually { await runner.launches.count == 3 })
            #expect(await loader.peakInFlight <= 3)
            #expect(await runner.peakInFlight <= 3)
        }
        #expect(await loader.calls.count == 3, "workers blocked in the cache take nothing new")

        // Drain: released runs get held again, so release until the pool goes idle.
        for _ in 0..<200 where !prefetcher.isIdle {
            await runner.release()
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(prefetcher.isIdle)
        #expect(await loader.peakInFlight <= 3)
        #expect(await runner.peakInFlight <= 3)
        #expect(prefetcher.dequeuedFileIDs == lists[4].map(\.id))
        #expect(await runner.launches.count == 13, "three from the first list, then the whole last list")
        let calls = await loader.calls
        #expect(
            calls.prefix(3).map(\.client) == ["r0", "r0", "r0"],
            "jobs in progress keep the client they were dequeued with")
        #expect(
            calls.dropFirst(3).map(\.client) == Array(repeating: "r4", count: 10),
            "newly dequeued jobs use the replacement client")
    }
}
