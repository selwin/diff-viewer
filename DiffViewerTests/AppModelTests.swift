import Foundation
import Testing
@testable import DiffViewer

/// Holds discovery for chosen URLs until released, or fails them.
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

/// Stub repositories by URL, plus the watchers the model asked for.
@MainActor
final class RepoRegistry {
    var clients: [URL: StubRepoClient] = [:]
    var watchers: [URL: NoopWatcher] = [:]
}

@MainActor
final class ModelHarness {
    let defaults: UserDefaults
    let suite = "DiffViewerTests.AppModel.\(UUID().uuidString)"
    let gate = OpenGate()
    let registry = RepoRegistry()
    let model: AppModel

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let gate = gate
        let registry = registry
        let runner = RunnerProbe()
        let cache = DifftCache(runner: { old, new, fileName, qos in
            try await runner.run(old: old, new: new, fileName: fileName, qualityOfService: qos)
        })
        model = AppModel(
            preferences: Preferences(defaults: defaults),
            cache: cache,
            discover: { url in
                try await gate.pass(url)
                guard let client = await registry.clients[url] else { throw ProcessError.failed(command: "test", status: 1, stderr: "no stub") }
                return (url, client)
            },
            watchRepository: { root, _ in
                let watcher = NoopWatcher()
                registry.watchers[root] = watcher
                return watcher
            }
        )
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    var state: WindowState { model.windowState }

    func repo(_ name: String, files: [ChangedFile]) -> URL {
        let url = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        registry.clients[url] = StubRepoClient(files: files)
        return url
    }

    /// Opens and waits for the repository's file list to arrive.
    func openAndSettle(_ url: URL, expecting files: [ChangedFile]) async {
        await model.open(url)
        #expect(await eventually { await self.state.files == files })
    }
}

@MainActor
struct AppModelTests {
    let filesA = [changedFile("a1.swift"), changedFile("a2.swift", area: .staged)]
    let filesB = [changedFile("b1.swift")]

    @Test func supersededOpenInstallsNothing() async {
        let h = ModelHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        await h.gate.hold(a)
        let openA = Task { await h.model.open(a) }
        #expect(await eventually { await h.gate.waitingURLs.contains(a) })

        await h.openAndSettle(b, expecting: filesB)
        await h.gate.release(a)
        await openA.value
        #expect(h.state.repositoryRoot == b)
        #expect(h.state.files == filesB)
        #expect(h.registry.watchers[a] == nil, "a superseded open must not install its watcher")
        #expect(h.registry.watchers[b] != nil)
        #expect(h.model.preferences.recentRepositoryRoots.first == b)
        #expect(!h.model.preferences.recentRepositoryRoots.contains(a))
    }

    @Test func supersededOpenErrorIsNotPublished() async {
        let h = ModelHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        await h.gate.hold(a)
        await h.gate.fail(a)
        let openA = Task { await h.model.open(a) }
        #expect(await eventually { await h.gate.waitingURLs.contains(a) })

        await h.openAndSettle(b, expecting: filesB)
        await h.gate.release(a)
        await openA.value
        #expect(h.state.errorMessage == nil)
        #expect(h.state.repositoryRoot == b)
    }

    @Test func openErrorIsPublishedWhenStillLatest() async {
        let h = ModelHarness()
        let a = h.repo("A", files: filesA)
        await h.gate.fail(a)
        await h.model.open(a)
        #expect(h.state.errorMessage?.contains("Not a git repository") == true)
        #expect(h.state.isEmpty)
    }

    @Test func replacingARepositoryReplacesTheWindowState() async {
        let h = ModelHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        await h.openAndSettle(a, expecting: filesA)
        let stateA = h.state
        await h.openAndSettle(b, expecting: filesB)
        #expect(h.state !== stateA)
        #expect(stateA.isClosed)
        #expect(h.registry.watchers[a]?.stopped == true)
        #expect(h.state.repositoryRoot == b)
    }

    // MARK: Prefetch across a switch

    private var manyFiles: [ChangedFile] { (1...6).map { changedFile("a\($0).swift") } }

    /// Opens A with its worktree reads held, so three prefetch workers sit mid-load.
    private func openAWithStuckWorkers(_ h: ModelHarness) async -> URL {
        let a = h.repo("A", files: manyFiles)
        await h.registry.clients[a]!.holdReads(true)
        await h.openAndSettle(a, expecting: manyFiles)
        #expect(await eventually { await h.model.prefetcher.dequeuedFileIDs.count == DiffPrefetcher.maxConcurrentPrefetchJobs })
        return a
    }

    @Test func switchingCancelsTheOldPrefetchQueue() async {
        let h = ModelHarness()
        let a = await openAWithStuckWorkers(h)
        let b = h.repo("B", files: filesB)
        await h.registry.clients[b]!.hold(true)
        let openB = Task { await h.model.open(b) }
        #expect(await eventually { await h.state.repositoryRoot == b })
        let dequeuedBeforeRelease = h.model.prefetcher.dequeuedFileIDs

        await h.registry.clients[a]!.releaseReads()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.model.prefetcher.dequeuedFileIDs == dequeuedBeforeRelease, "no further A files once B is opening")

        await h.registry.clients[b]!.releaseFirst()
        await openB.value
        #expect(await eventually { await h.model.prefetcher.acceptedFileIDs == self.filesB.map(\.id) })
    }

    @Test func failedRefreshOfTheNewRepositoryDoesNotResumeTheOldQueue() async {
        let h = ModelHarness()
        let a = await openAWithStuckWorkers(h)
        let b = h.repo("B", files: filesB)
        await h.registry.clients[b]!.fail(true)
        await h.model.open(b)
        #expect(await eventually { await h.state.errorMessage != nil })
        let dequeuedBeforeRelease = h.model.prefetcher.dequeuedFileIDs

        await h.registry.clients[a]!.releaseReads()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.model.prefetcher.dequeuedFileIDs == dequeuedBeforeRelease)
        #expect(await eventually { await h.model.prefetcher.isIdle })
    }
}
