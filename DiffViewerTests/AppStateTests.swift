import Foundation
import Testing
@testable import DiffViewer

/// A repository whose status call can be held open and released in any order.
actor StubRepoClient: RepoClient {
    private var files: [ChangedFile]
    private var holds = false
    private var fails = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var statusCalls = 0

    init(files: [ChangedFile]) { self.files = files }

    func set(files: [ChangedFile]) { self.files = files }
    func hold(_ on: Bool) { holds = on }
    func fail(_ on: Bool) { fails = on }
    var heldCount: Int { held.count }

    func status() async throws -> [ChangedFile] {
        statusCalls += 1
        let snapshot = files
        if holds {
            await withCheckedContinuation { held.append($0) }
        }
        if fails { throw ProcessError.failed(command: "git status", status: 128, stderr: "gone") }
        return snapshot
    }

    func releaseFirst() { if !held.isEmpty { held.removeFirst().resume() } }
    func releaseLast() { if !held.isEmpty { held.removeLast().resume() } }

    func indexContents(of path: String) async throws -> Data? { Data("old \(path)".utf8) }
    func headContents(of path: String) async throws -> Data? { Data("head \(path)".utf8) }
    func worktreeContents(of path: String) async -> Data? { Data("new \(path)".utf8) }
}

/// Holds `openRepository` calls for chosen URLs until released.
actor OpenGate {
    private var heldURLs: Set<URL> = []
    private var waiting: [URL: CheckedContinuation<Void, Never>] = [:]
    private var failing: Set<URL> = []

    func hold(_ url: URL) { heldURLs.insert(url) }
    func fail(_ url: URL) { failing.insert(url) }
    var waitingURLs: Set<URL> { Set(waiting.keys) }

    func pass(_ url: URL) async throws {
        if heldURLs.contains(url) {
            await withCheckedContinuation { waiting[url] = $0 }
        }
        if failing.contains(url) { throw ProcessError.failed(command: "git rev-parse", status: 128, stderr: "not a repo") }
    }

    func release(_ url: URL) { waiting.removeValue(forKey: url)?.resume() }
}

@MainActor
final class NoopWatcher: RepoWatching {
    private(set) var stopped = false
    func stop() { stopped = true }
}

/// Stub repositories by URL, plus the watchers `AppState` asked for.
@MainActor
final class RepoRegistry {
    var clients: [URL: StubRepoClient] = [:]
    var watchers: [URL: NoopWatcher] = [:]
    var watcherCallbacks: [URL: @MainActor () -> Void] = [:]
}

@MainActor
final class Harness {
    let defaults: UserDefaults
    let suite = "DiffViewerTests.\(UUID().uuidString)"
    let gate = OpenGate()
    let runner = RunnerProbe()
    let registry = RepoRegistry()
    let state: AppState

    var clients: [URL: StubRepoClient] { registry.clients }
    var watchers: [URL: NoopWatcher] { registry.watchers }
    var watcherCallbacks: [URL: @MainActor () -> Void] { registry.watcherCallbacks }

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let gate = gate
        let runner = runner
        let registry = registry
        let cache = DifftCache(runner: { old, new, fileName, qos in
            try await runner.run(old: old, new: new, fileName: fileName, qualityOfService: qos)
        })
        state = AppState(
            defaults: defaults,
            openRepository: { url in
                try await gate.pass(url)
                guard let client = await registry.clients[url] else { throw ProcessError.failed(command: "test", status: 1, stderr: "no stub") }
                return (url, client)
            },
            watchRepository: { root, onChange in
                let watcher = NoopWatcher()
                registry.watchers[root] = watcher
                registry.watcherCallbacks[root] = onChange
                return watcher
            },
            cache: cache
        )
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    func repo(_ name: String, files: [ChangedFile]) -> URL {
        let url = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        registry.clients[url] = StubRepoClient(files: files)
        return url
    }
}

@MainActor
struct AppStateTests {
    let filesA = [changedFile("a1.swift"), changedFile("a2.swift", area: .staged)]
    let filesB = [changedFile("b1.swift")]

    @Test func supersededOpenInstallsNothing() async {
        let h = Harness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        await h.gate.hold(a)
        let openA = Task { await h.state.openRepo(at: a) }
        #expect(await eventually { await h.gate.waitingURLs.contains(a) })
        #expect(h.state.isLoading)

        await h.state.openRepo(at: b)
        #expect(h.state.repoRoot == b)
        #expect(h.state.files == filesB)
        #expect(!h.state.isLoading)

        await h.gate.release(a)
        await openA.value
        #expect(h.state.repoRoot == b)
        #expect(h.state.files == filesB)
        #expect(h.watchers[a] == nil, "a superseded open must not install its watcher")
        #expect(h.watchers[b] != nil)
        #expect(h.state.prefetcher.acceptedFileIDs == filesB.map(\.id))
        #expect(!h.state.isLoading)
        #expect(h.state.recentRepos.first == b)
        #expect(!h.state.recentRepos.contains(a))
    }

    @Test func supersededOpenErrorIsNotPublished() async {
        let h = Harness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        await h.gate.hold(a)
        await h.gate.fail(a)
        let openA = Task { await h.state.openRepo(at: a) }
        #expect(await eventually { await h.gate.waitingURLs.contains(a) })
        await h.state.openRepo(at: b)

        await h.gate.release(a)
        await openA.value
        #expect(h.state.errorMessage == nil)
        #expect(h.state.repoRoot == b)
        #expect(!h.state.isLoading)
    }

    @Test func openErrorIsPublishedWhenStillLatest() async {
        let h = Harness()
        let a = h.repo("A", files: filesA)
        await h.gate.fail(a)
        await h.state.openRepo(at: a)
        #expect(h.state.errorMessage?.contains("Not a git repository") == true)
        #expect(h.state.repoRoot == nil)
        #expect(!h.state.isLoading)
    }

    @Test func refreshFromAReplacedSessionIsDiscarded() async {
        let h = Harness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        await h.state.openRepo(at: a)
        let sessionA = h.state.session!
        let clientA = h.clients[a]!
        await clientA.hold(true)
        // What the watcher callback does, awaited so the test knows when it finished.
        let stale = Task { await h.state.refresh(session: sessionA) }
        #expect(await eventually { await clientA.heldCount == 1 })

        await h.state.openRepo(at: b)
        #expect(h.watchers[a]?.stopped == true)
        await clientA.releaseFirst()
        await stale.value
        #expect(h.state.repoRoot == b)
        #expect(h.state.files == filesB)
        #expect(h.state.prefetcher.acceptedFileIDs == filesB.map(\.id))
    }

    @Test func staleRefreshErrorIsNotPublished() async {
        let h = Harness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        await h.state.openRepo(at: a)
        let sessionA = h.state.session!
        let clientA = h.clients[a]!
        await clientA.hold(true)
        let stale = Task { await h.state.refresh(session: sessionA) }
        #expect(await eventually { await clientA.heldCount == 1 })

        await h.state.openRepo(at: b)
        await clientA.fail(true)
        await clientA.releaseFirst()
        await stale.value
        #expect(h.state.errorMessage == nil)
        #expect(h.state.files == filesB)
    }

    @Test func watcherCallbackAfterReplacementReadsNothing() async {
        let h = Harness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        await h.state.openRepo(at: a)
        let callbackA = h.watcherCallbacks[a]!
        let clientA = h.clients[a]!
        let before = await clientA.statusCalls

        await h.state.openRepo(at: b)
        callbackA()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await clientA.statusCalls == before, "a replaced session's watcher must not spawn git status")
        #expect(h.state.files == filesB)
    }

    @Test func olderRefreshCannotOverwriteNewerOne() async {
        let h = Harness()
        let a = h.repo("A", files: filesA)
        await h.state.openRepo(at: a)
        let client = h.clients[a]!
        await client.hold(true)

        let second = [changedFile("second.swift")]
        let third = [changedFile("third.swift")]
        await client.set(files: second)
        let refresh1 = Task { await h.state.refresh() }
        #expect(await eventually { await client.heldCount == 1 })
        await client.set(files: third)
        let refresh2 = Task { await h.state.refresh() }
        #expect(await eventually { await client.heldCount == 2 })

        await client.releaseLast()
        await refresh2.value
        #expect(h.state.files == third)
        await client.releaseFirst()
        await refresh1.value
        #expect(h.state.files == third, "the older status response must not win")
    }

    @Test func watcherCallbackRefreshesItsOwnSession() async {
        let h = Harness()
        let a = h.repo("A", files: filesA)
        await h.state.openRepo(at: a)
        let updated = [changedFile("changed.swift")]
        await h.clients[a]!.set(files: updated)
        h.watcherCallbacks[a]!()
        #expect(await eventually { await h.state.files == updated })
    }

    @Test func selectedFileIsExcludedFromPrefetch() async {
        let h = Harness()
        let a = h.repo("A", files: filesA)
        await h.state.openRepo(at: a)
        #expect(h.state.prefetcher.acceptedFileIDs == filesA.map(\.id))
        h.state.selectedFileID = filesA[0].id
        await h.state.refresh()
        #expect(h.state.prefetcher.acceptedFileIDs == [filesA[1].id])
    }
}
