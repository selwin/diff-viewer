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
    /// Worktree paths whose read suspends until the test releases them.
    private var heldPaths: Set<String> = []
    private var pathWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Worktree paths whose read throws rather than returning contents.
    private var failingWorktreePaths: Set<String> = []
    /// Content reads of any kind since creation.
    private(set) var contentReads = 0
    /// Every path read, in order, whichever side it was read from.
    private(set) var readPaths: [String] = []
    /// Content reads running at once, and the most there have ever been.
    private(set) var inFlightReads = 0
    private(set) var peakInFlightReads = 0
    private var numstatEntries: [ChangedFile.Area: [NumstatEntry]] = [:]
    private var failsNumstat = false
    /// The `ignoreWhitespace` argument of the most recent numstat call.
    private(set) var lastIgnoreWhitespace: Bool?
    private(set) var numstatCalls = 0
    /// Worktree contents by path, overriding the default "new \(path)" body.
    private var worktree: [String: Data?] = [:]
    private var head: String? = String(repeating: "a", count: 40)
    private var stubbedHeadState: HeadState = .named("main")
    private var failsHeadState = false
    private(set) var headStateCalls = 0
    private var commits: [CommitSummary] = []
    /// Files each commit changed, by sha.
    private var commitFiles: [String: [ChangedFile]] = [:]
    private var failsHistory = false
    private var failsCommitFiles = false
    private var holdsCommitFiles = false
    private var heldCommitFiles: [CheckedContinuation<Void, Never>] = []
    private var holdsHead = false
    private var heldHead: [CheckedContinuation<Void, Never>] = []
    private var holdsHistory = false
    private var heldHistory: [CheckedContinuation<Void, Never>] = []
    private(set) var headCalls = 0
    private(set) var historyCalls = 0
    private(set) var lastHistoryRevision: String?
    private(set) var lastHistoryLimit: Int?
    private(set) var commitFileCalls = 0
    /// Every `(path, revision)` pair `contents(of:at:)` was asked for, in order.
    private(set) var contentRevisions: [(path: String, revision: String)] = []
    /// Every git write asked for, in order: one entry per call, holding the whole batch.
    private(set) var performed: [(action: GitFileAction, paths: [String])] = []
    /// Every trash call, in order: one entry per call, holding the whole batch.
    private(set) var trashed: [[String]] = []
    private var failsActions = false
    private var holdsActions = false
    private var heldActions: [CheckedContinuation<Void, Never>] = []
    /// What the repository becomes once a write succeeds, standing in for git's own
    /// effect on it. Nil leaves `files` alone.
    private var filesAfterWrite: [ChangedFile]?
    /// Every message a commit was asked for, in order, whether or not it succeeded.
    private(set) var commitMessages: [String] = []
    private var stubbedDefaults = CommitDefaults.none
    private var failsCommit = false
    private var failsCommitDefaults = false
    private var holdsCommitDefaults = false
    private var heldCommitDefaults: [CheckedContinuation<Void, Never>] = []
    private(set) var commitDefaultsCalls = 0

    init(files: [ChangedFile]) { self.files = files }

    func set(files: [ChangedFile]) { self.files = files }
    /// The list `status()` reports from the moment a `perform` or `trash` completes, so
    /// a test says what the write did to the repository instead of pre-seeding a status
    /// read that the write's own validation would see too early.
    func set(filesAfterWrite list: [ChangedFile]?) { filesAfterWrite = list }
    var currentFiles: [ChangedFile] { files }
    func hold(_ on: Bool) { holds = on }
    func fail(_ on: Bool) { fails = on }
    var heldCount: Int { held.count }

    func set(numstat entries: [NumstatEntry], area: ChangedFile.Area) { numstatEntries[area] = entries }
    func fail(numstat on: Bool) { failsNumstat = on }
    /// Makes both `perform` and `trash` throw, after recording the call.
    func fail(actions on: Bool) { failsActions = on }
    /// Suspends `perform` and `trash` after they record the call, so a second write can
    /// be queued behind one that is still running.
    func holdActions(_ on: Bool) { holdsActions = on }
    var heldActionCount: Int { heldActions.count }
    func releaseActions() {
        let waiting = heldActions
        heldActions = []
        for continuation in waiting { continuation.resume() }
    }
    func set(worktree data: Data?, for path: String) { worktree[path] = .some(data) }

    func numstat(area: ChangedFile.Area, ignoreWhitespace: Bool) async throws -> [NumstatEntry] {
        numstatCalls += 1
        lastIgnoreWhitespace = ignoreWhitespace
        // An area no test configured is unknown, not empty: the joiner treats an empty
        // list as "git saw no churn" and would stamp every file with +0 −0.
        guard !failsNumstat, let entries = numstatEntries[area] else {
            throw ProcessError.failed(command: "git diff --numstat", status: 128, stderr: "gone")
        }
        return entries
    }

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
        for continuation in waiting { continuation.resume() }
    }

    // MARK: Per-path worktree reads

    /// Suspends the worktree read of each path until it is released, so one file's diff
    /// can be held open while the others finish.
    func hold(worktree paths: Set<String>) { heldPaths.formUnion(paths) }
    /// The paths whose reads are suspended right now.
    var waitingWorktreePaths: Set<String> { Set(pathWaiters.keys) }
    func release(worktree path: String) {
        heldPaths.remove(path)
        for continuation in pathWaiters.removeValue(forKey: path) ?? [] { continuation.resume() }
    }
    func releaseAllWorktreeHolds() {
        heldPaths.removeAll()
        let waiting = pathWaiters
        pathWaiters = [:]
        for continuation in waiting.values.flatMap({ $0 }) { continuation.resume() }
    }
    /// Paths whose worktree read throws: a file that is there but cannot be read.
    func fail(worktree paths: Set<String>) { failingWorktreePaths = paths }

    private func beginRead(_ path: String) {
        contentReads += 1
        readPaths.append(path)
        inFlightReads += 1
        peakInFlightReads = max(peakInFlightReads, inFlightReads)
    }

    private func endRead() { inFlightReads -= 1 }

    // MARK: History and commits

    func set(head sha: String?) { head = sha }
    func set(headState state: HeadState) { stubbedHeadState = state }
    func fail(headState on: Bool) { failsHeadState = on }
    func set(commits list: [CommitSummary]) { commits = list }
    func set(files list: [ChangedFile], forCommit sha: String) { commitFiles[sha] = list }
    func fail(history on: Bool) { failsHistory = on }
    func fail(commitFiles on: Bool) { failsCommitFiles = on }
    func holdCommitFiles(_ on: Bool) { holdsCommitFiles = on }
    var heldCommitFileCount: Int { heldCommitFiles.count }
    func releaseCommitFiles() {
        let waiting = heldCommitFiles
        heldCommitFiles = []
        for continuation in waiting { continuation.resume() }
    }

    func holdHead(_ on: Bool) { holdsHead = on }
    var heldHeadCount: Int { heldHead.count }
    func releaseHead() {
        let waiting = heldHead
        heldHead = []
        for continuation in waiting { continuation.resume() }
    }
    /// Releases the oldest held HEAD read, so completion order can be chosen.
    func releaseFirstHead() { if !heldHead.isEmpty { heldHead.removeFirst().resume() } }

    func holdHistory(_ on: Bool) { holdsHistory = on }
    var heldHistoryCount: Int { heldHistory.count }
    func releaseHistory() {
        let waiting = heldHistory
        heldHistory = []
        for continuation in waiting { continuation.resume() }
    }

    func headSha() async throws -> String? {
        headCalls += 1
        // Snapshot before suspending, the way `status()` does: a held read must report
        // the revision it was asked about, not whatever HEAD became while it waited.
        let snapshot = head
        if holdsHead {
            await withCheckedContinuation { heldHead.append($0) }
        }
        if failsHistory { throw ProcessError.failed(command: "git rev-parse", status: 128, stderr: "gone") }
        return snapshot
    }

    func headState() async throws -> HeadState {
        headStateCalls += 1
        if failsHeadState { throw ProcessError.failed(command: "git symbolic-ref", status: 128, stderr: "gone") }
        return stubbedHeadState
    }

    func recentCommits(startingAt revision: String, limit: Int) async throws -> [CommitSummary] {
        historyCalls += 1
        lastHistoryRevision = revision
        lastHistoryLimit = limit
        let snapshot = commits
        if holdsHistory {
            await withCheckedContinuation { heldHistory.append($0) }
        }
        if failsHistory { throw ProcessError.failed(command: "git log", status: 128, stderr: "gone") }
        return Array(snapshot.prefix(limit))
    }

    func changedFiles(in commit: CommitRef) async throws -> [ChangedFile] {
        commitFileCalls += 1
        if holdsCommitFiles {
            await withCheckedContinuation { heldCommitFiles.append($0) }
        }
        if failsCommitFiles {
            throw ProcessError.failed(command: "git diff-tree", status: 128, stderr: "bad object")
        }
        return commitFiles[commit.sha] ?? []
    }

    func contents(of path: String, at revision: String) async throws -> Data {
        beginRead(path)
        defer { endRead() }
        contentRevisions.append((path, revision))
        return Data("\(revision):\(path)".utf8)
    }

    func indexContents(of path: String) async throws -> Data? {
        beginRead(path)
        defer { endRead() }
        return Data("old \(path)".utf8)
    }

    func headContents(of path: String) async throws -> Data? {
        beginRead(path)
        defer { endRead() }
        return Data("head \(path)".utf8)
    }

    func worktreeContents(of path: String) async throws -> Data? {
        beginRead(path)
        defer { endRead() }
        if holdsReads {
            await withCheckedContinuation { heldReads.append($0) }
        }
        if heldPaths.contains(path) {
            await withCheckedContinuation { pathWaiters[path, default: []].append($0) }
        }
        if failingWorktreePaths.contains(path) {
            throw ProcessError.failed(command: "read \(path)", status: 1, stderr: "permission denied")
        }
        if let override = worktree[path] { return override }
        return Data("new \(path)".utf8)
    }

    func perform(_ action: GitFileAction, on paths: [String]) async throws {
        performed.append((action, paths))
        if holdsActions {
            await withCheckedContinuation { heldActions.append($0) }
        }
        if failsActions { throw ProcessError.failed(command: "git add", status: 128, stderr: "index.lock exists") }
        if let filesAfterWrite { files = filesAfterWrite }
    }

    func trash(_ paths: [String]) async throws {
        trashed.append(paths)
        if holdsActions {
            await withCheckedContinuation { heldActions.append($0) }
        }
        if failsActions {
            throw ProcessError.failed(command: "trash", status: 1, stderr: "could not move to Trash")
        }
        if let filesAfterWrite { files = filesAfterWrite }
    }

    // MARK: Commits

    func set(commitDefaults defaults: CommitDefaults) { stubbedDefaults = defaults }
    func fail(commitDefaults on: Bool) { failsCommitDefaults = on }
    /// Makes `commit` throw, after recording the message.
    func fail(commit on: Bool) { failsCommit = on }
    /// Suspends `commitDefaults` after it records the call, so the read can still be in
    /// flight while the test drives something else.
    func holdCommitDefaults(_ on: Bool) { holdsCommitDefaults = on }
    var heldCommitDefaultsCount: Int { heldCommitDefaults.count }
    func releaseCommitDefaults() {
        let waiting = heldCommitDefaults
        heldCommitDefaults = []
        for continuation in waiting { continuation.resume() }
    }
    /// Releases the oldest held defaults read, so completion order can be chosen.
    func releaseFirstCommitDefaults() { if !heldCommitDefaults.isEmpty { heldCommitDefaults.removeFirst().resume() } }

    func commitDefaults() async throws -> CommitDefaults {
        commitDefaultsCalls += 1
        // Snapshot before suspending, the way `status()` does: a held read reports what
        // the repository looked like when it was asked.
        let snapshot = stubbedDefaults
        if holdsCommitDefaults {
            await withCheckedContinuation { heldCommitDefaults.append($0) }
        }
        if failsCommitDefaults {
            throw ProcessError.failed(command: "git rev-parse", status: 128, stderr: "gone")
        }
        return snapshot
    }

    /// Held and released with the other writes, so a commit can be queued behind a stage.
    func commit(message: String) async throws {
        commitMessages.append(message)
        if holdsActions {
            await withCheckedContinuation { heldActions.append($0) }
        }
        if failsCommit {
            throw ProcessError.failed(command: "git commit", status: 1, stderr: "pre-commit hook failed")
        }
        if let filesAfterWrite { files = filesAfterWrite }
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
        let state = WindowState(
            preferences: preferences, cache: cache,
            watchRepository: { [weak self] root, onChange in
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
    func adopt(_ state: WindowState, _ name: String, files: [ChangedFile]) async -> (
        root: RepositoryRoot, client: StubRepoClient
    ) {
        let repo = repo(name, files: files)
        let before = published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await self.published.count > before })
        // The first list lands on All changes, which reads every file. Waiting for that
        // load to settle keeps later read counts about what the test itself asked for.
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
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
        // All changes is reading every file itself, so there is nothing to warm.
        #expect(state.filesToWarm.isEmpty)
        state.selection = [.file(filesA[0].id)]
        #expect(state.filesToWarm == [filesA[1]])
        state.selection = []
        #expect(state.filesToWarm == filesA)
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
        state.selection = [.file(file.id)]
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

        state.selection = [.file(filesA[0].id)]
        #expect(state.diffStale)
        await state.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == reads)
        // The changeset from adoption is still on show; what did not happen is the load
        // for the file just selected.
        #expect(!hasContent(state, for: filesA[0]))
        #expect(h.published.count == 2, "hidden refreshes still publish their file list")

        state.isVisible = true
        #expect(!state.diffStale)
        #expect(await eventually { await self.hasContent(state, for: self.filesA[0]) })
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
        // The reload now rides on a settings refresh, so staleness lands asynchronously.
        #expect(await eventually { await state.diffStale })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == reads + 2)
    }

    // MARK: Line stats

    @Test func publishedFilesCarryLineStats() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: filesA)
        await repo.client.set(
            numstat: [NumstatEntry(path: "a1.swift", stats: .counted(added: 12, deleted: 4))], area: .unstaged)
        await repo.client.set(numstat: [NumstatEntry(path: "a2.swift", stats: .binary)], area: .staged)
        let before = h.published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count > before })
        #expect(h.published.last?.files.map(\.id) == filesA.map(\.id))

        // Stats follow the publish; the list itself does not change again.
        #expect(
            await eventually {
                await state.files.first { $0.path == "a1.swift" }?.lineStats == .counted(added: 12, deleted: 4)
            })
        #expect(state.files.first { $0.path == "a2.swift" }?.lineStats == .binary)
        #expect(state.files.map(\.id) == filesA.map(\.id))
        #expect(h.published.count == before + 1)
    }

    @Test func failingNumstatStillPublishesFilesWithoutStats() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: filesA)
        await repo.client.fail(numstat: true)
        let before = h.published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count > before })

        #expect(state.files.map(\.id) == filesA.map(\.id))
        #expect(state.files.allSatisfy { $0.lineStats == nil })
        #expect(state.errorMessage == nil, "stats are decoration and must not fail the refresh")
    }

    @Test func whitespaceChangeRefreshesStatsWithTheNewSetting() async {
        let h = Harness()
        h.preferences.hideWhitespace = true
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        #expect(await repo.client.lastIgnoreWhitespace == true)

        let before = h.published.count
        h.preferences.hideWhitespace = false
        state.diffSettingsChanged()
        #expect(await eventually { await h.published.count > before })
        #expect(h.published.last?.cause == .settings)
        #expect(await eventually { await repo.client.lastIgnoreWhitespace == false })
    }

    @Test func whitespaceChangeReloadsDiffEvenWhenStatusFails() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads

        await repo.client.fail(true)
        h.preferences.hideWhitespace.toggle()
        state.diffSettingsChanged()
        #expect(
            await eventually { await repo.client.contentReads == reads + 2 },
            "the diff reloads without waiting for status")
        #expect(await eventually { await state.errorMessage != nil })
        #expect(state.files.map(\.id) == filesA.map(\.id))
    }

    @Test func closingDuringUntrackedReadsAttachesNothing() async {
        let h = Harness()
        let state = h.makeState()
        let fresh = changedFile("fresh.txt", kind: .untracked)
        let repo = h.repo("A", files: [fresh])
        await repo.client.holdReads(true)
        let before = h.published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count > before })
        #expect(
            await eventually { await repo.client.heldReadCount >= 1 },
            "the untracked count starts after the publish")

        state.close()
        await repo.client.releaseReads()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(state.files.first?.lineStats == nil)
    }

    @Test func settingsRefreshWhileHiddenMarksStaleAndLoadsNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads
        state.isVisible = false
        #expect(!state.diffStale)
        let before = h.published.count

        state.diffSettingsChanged()
        #expect(await eventually { await h.published.count > before })
        #expect(h.published.last?.cause == .settings)
        #expect(state.diffStale)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == reads, "a hidden window loads no diff")
    }
}
