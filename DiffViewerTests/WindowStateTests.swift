import Foundation
import Testing
@testable import DiffViewer

/// A repository whose status call and worktree reads can be held open and released.
actor StubRepoClient: RepoClient {
    private var files: [ChangedFile]
    private var holds = false
    private var fails = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var statusCalls = 0
    private var holdsReads = false
    private var heldReads: [CheckedContinuation<Void, Never>] = []
    /// Content reads of any kind since creation.
    private(set) var contentReads = 0

    init(files: [ChangedFile]) { self.files = files }

    func set(files: [ChangedFile]) { self.files = files }
    var currentFiles: [ChangedFile] { files }
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

    func holdReads(_ on: Bool) { holdsReads = on }
    var heldReadCount: Int { heldReads.count }
    func releaseReads() {
        let waiting = heldReads
        heldReads = []
        waiting.forEach { $0.resume() }
    }

    func indexContents(of path: String) async throws -> Data? {
        contentReads += 1
        return Data("old \(path)".utf8)
    }

    func headContents(of path: String) async throws -> Data? {
        contentReads += 1
        return Data("head \(path)".utf8)
    }

    func worktreeContents(of path: String) async -> Data? {
        contentReads += 1
        if holdsReads {
            await withCheckedContinuation { heldReads.append($0) }
        }
        return Data("new \(path)".utf8)
    }
}

@MainActor
final class NoopWatcher: RepoWatching {
    private(set) var stopped = false
    func stop() { stopped = true }
}

@MainActor
final class Harness {
    let defaults: UserDefaults
    let suite = "DiffViewerTests.\(UUID().uuidString)"
    let runner = RunnerProbe()
    let preferences: Preferences
    private(set) var watchers: [RepositoryRoot: NoopWatcher] = [:]
    private(set) var watcherCallbacks: [RepositoryRoot: @MainActor () -> Void] = [:]
    /// Every `onRefreshPublished` call, in order.
    private(set) var published: [(files: [ChangedFile], cause: RefreshCause)] = []

    init() {
        defaults = UserDefaults(suiteName: suite)!
        preferences = Preferences(defaults: defaults)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    func makeState() -> WindowState {
        let runner = runner
        let cache = DifftCache(runner: { old, new, fileName, qos in
            try await runner.run(old: old, new: new, fileName: fileName, qualityOfService: qos)
        })
        let state = WindowState(preferences: preferences, cache: cache, watchRepository: { [weak self] root, onChange in
            let watcher = NoopWatcher()
            self?.watchers[root] = watcher
            self?.watcherCallbacks[root] = onChange
            return watcher
        })
        state.onRefreshPublished = { [weak self] state, cause in
            self?.published.append((state.files, cause))
        }
        return state
    }

    func repo(_ name: String, files: [ChangedFile]) -> (root: RepositoryRoot, client: StubRepoClient) {
        (RepositoryRoot(path: "/tmp/\(name)"), StubRepoClient(files: files))
    }

    /// Adopts and waits for the initial refresh to publish.
    @discardableResult
    func adopt(_ state: WindowState, _ name: String, files: [ChangedFile]) async -> (root: RepositoryRoot, client: StubRepoClient) {
        let repo = repo(name, files: files)
        let before = published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await self.published.count > before })
        return repo
    }
}

@MainActor
struct WindowStateTests {
    let filesA = [changedFile("a1.swift"), changedFile("a2.swift", area: .staged)]
    let filesB = [changedFile("b1.swift")]

    // MARK: Adoption

    @Test func adoptInstallsSessionWatcherAndRefreshes() async {
        let h = Harness()
        let state = h.makeState()
        #expect(state.isEmpty)
        let repo = await h.adopt(state, "A", files: filesA)
        #expect(state.repositoryRoot == repo.root)
        #expect(!state.isEmpty)
        #expect(state.files == filesA)
        #expect(h.watchers[repo.root] != nil)
        #expect(h.published.last?.cause == .initial)
        #expect(await eventually { await !state.isLoading })
    }

    @Test func secondAdoptIsRejected() async {
        let h = Harness()
        let state = h.makeState()
        let a = await h.adopt(state, "A", files: filesA)
        let b = h.repo("B", files: filesB)
        #expect(!state.adopt(root: b.root, client: b.client))
        #expect(state.repositoryRoot == a.root)
        #expect(state.files == filesA)
        #expect(h.watchers[b.root] == nil)
        #expect(await b.client.statusCalls == 0)
    }

    // MARK: Refreshing

    @Test func olderRefreshCannotOverwriteNewerOne() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let client = repo.client
        await client.hold(true)

        let second = [changedFile("second.swift")]
        let third = [changedFile("third.swift")]
        await client.set(files: second)
        let refresh1 = Task { await state.refresh() }
        #expect(await eventually { await client.heldCount == 1 })
        await client.set(files: third)
        let refresh2 = Task { await state.refresh() }
        #expect(await eventually { await client.heldCount == 2 })

        await client.releaseLast()
        await refresh2.value
        #expect(state.files == third)
        await client.releaseFirst()
        await refresh1.value
        #expect(state.files == third, "the older status response must not win")
    }

    @Test func refreshReportsItsCauseEvenWhenUnchanged() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await state.refresh()
        #expect(h.published.count == 2)
        #expect(h.published.last?.cause == .manual)
        #expect(h.published.last?.files == filesA)

        let updated = [changedFile("changed.swift")]
        await repo.client.set(files: updated)
        h.watcherCallbacks[repo.root]!()
        #expect(await eventually { await h.published.count == 3 })
        #expect(h.published.last?.cause == .watcher)
        #expect(state.files == updated)
    }

    @Test func refreshErrorIsPublishedAndKeepsFiles() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await repo.client.fail(true)
        await state.refresh()
        #expect(state.errorMessage != nil)
        #expect(state.files == filesA)
        #expect(h.published.count == 1)
    }

    @Test func filesToWarmExcludesSelection() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: filesA)
        #expect(state.filesToWarm == filesA)
        state.selectedFileID = filesA[0].id
        #expect(state.filesToWarm == [filesA[1]])
    }

    // MARK: Closing

    @Test func closeStopsWatcherAndIsIdempotent() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        state.close()
        #expect(state.isClosed)
        #expect(h.watchers[repo.root]?.stopped == true)
        state.close()
        #expect(state.isClosed)
    }

    @Test func refreshCompletingAfterCloseIsDiscarded() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let client = repo.client
        await client.hold(true)
        await client.set(files: filesB)
        let stale = Task { await state.refresh() }
        #expect(await eventually { await client.heldCount == 1 })

        state.close()
        await client.releaseFirst()
        await stale.value
        #expect(state.files == filesA)
        #expect(h.published.count == 1, "a closed window must not publish")
        #expect(state.errorMessage == nil)
    }

    @Test func watcherCallbackAfterCloseReadsNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let before = await repo.client.statusCalls
        state.close()
        h.watcherCallbacks[repo.root]!()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == before)
    }

    @Test func adoptAfterCloseIsRejected() async {
        let h = Harness()
        let state = h.makeState()
        state.close()
        let repo = h.repo("A", files: filesA)
        #expect(!state.adopt(root: repo.root, client: repo.client))
        #expect(state.isEmpty)
        #expect(h.watchers[repo.root] == nil)
    }

    // MARK: Visibility

    private func hasContent(_ state: WindowState, for file: ChangedFile? = nil) -> Bool {
        guard state.diffLoader.content != nil else { return false }
        return file.map { state.diffLoader.contentFileID == $0.id } ?? true
    }

    /// Selects `file` and waits for its diff to be published.
    private func select(_ file: ChangedFile, in state: WindowState) async {
        state.selectedFileID = file.id
        #expect(await eventually { await self.hasContent(state, for: file) })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
    }

    private func documentID(_ state: WindowState) -> UUID? {
        if case let .text(document)? = state.diffLoader.content { return document.id }
        return nil
    }

    @Test func hidingCancelsReplacementLoadAndKeepsPublishedDiff() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let published = documentID(state)
        #expect(published != nil)

        // A reload of the same file, held at the worktree read.
        await repo.client.holdReads(true)
        state.diffSettingsChanged()
        #expect(await eventually { await repo.client.heldReadCount == 1 })
        #expect(state.diffLoader.isLoading)

        state.isVisible = false
        #expect(state.diffStale)
        #expect(!state.diffLoader.hasActiveWork)
        await repo.client.releaseReads()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(documentID(state) == published, "the cancelled replacement must not publish")
        #expect(!state.diffLoader.isHighlighting)
        #expect(hasContent(state), "the published diff stays for the switch back")
    }

    @Test func hidingACompletedDiffDoesNotMarkStale() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads

        state.isVisible = false
        #expect(!state.diffStale)
        state.isVisible = true
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == reads, "a current diff is reused, not reloaded")
        #expect(!state.diffLoader.hasActiveWork)
    }

    @Test func hiddenSelectionChangeAndRefreshStartNoLoad() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        state.isVisible = false
        let reads = await repo.client.contentReads

        state.selectedFileID = filesA[0].id
        #expect(state.diffStale)
        await state.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == reads)
        #expect(!hasContent(state))
        #expect(h.published.count == 2, "hidden refreshes still publish their file list")

        state.isVisible = true
        #expect(!state.diffStale)
        #expect(await eventually { await self.hasContent(state) })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        #expect(await repo.client.contentReads == reads + 2, "one load: index plus worktree")
    }

    @Test func diffSettingsChangeReloadsWhenVisibleAndMarksStaleWhenHidden() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads

        h.preferences.hideWhitespace.toggle()
        state.diffSettingsChanged()
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })

        state.isVisible = false
        state.diffSettingsChanged()
        #expect(state.diffStale)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == reads + 2)
    }
}
