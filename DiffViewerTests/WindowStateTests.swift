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
    private var holdsNumstat = false
    private var heldNumstat: [CheckedContinuation<Void, Never>] = []
    /// The `ignoreWhitespace` argument of the most recent numstat call.
    private(set) var lastIgnoreWhitespace: Bool?
    private(set) var numstatCalls = 0
    /// Worktree contents by path, overriding the default "new \(path)" body.
    private var worktree: [String: Data?] = [:]
    /// Object sizes by spec; an unlisted spec is one git has no object for.
    private var objectSizesBySpec: [String: Int64] = [:]
    private var failsObjectSizes = false
    private var truncatesObjectSizes = false
    /// Every `objectSizes` batch asked for, in order.
    private(set) var objectSizesCalls: [[String]] = []
    private var head: String? = String(repeating: "a", count: 40)
    private var stubbedHeadState: HeadState = .named("main")
    private var failsHeadState = false
    private(set) var headStateCalls = 0
    private var stubbedLocalBranches: [String] = ["main"]
    private var failsLocalBranches = false
    private var holdsLocalBranches = false
    private var heldLocalBranches: [CheckedContinuation<Void, Never>] = []
    private(set) var localBranchesCalls = 0
    /// Every branch a switch was asked for, in order, whether or not it succeeded.
    private(set) var switchBranchCalls: [String] = []
    private var failsSwitchBranch = false
    private var holdsSwitchBranch = false
    private var heldSwitchBranch: [CheckedContinuation<Void, Never>] = []
    /// What HEAD becomes once a switch runs, even one that then fails: a post-checkout
    /// hook fails after git has already moved HEAD. Nil leaves the state alone.
    private var headStateAfterSwitch: HeadState?
    private var headAfterSwitch: String??
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
    /// Suspends `numstat` after it records the call, so a read can be in flight while the
    /// test drives something else.
    func holdNumstat(_ on: Bool) { holdsNumstat = on }
    var heldNumstatCount: Int { heldNumstat.count }
    func releaseNumstat() {
        let waiting = heldNumstat
        heldNumstat = []
        for continuation in waiting { continuation.resume() }
    }
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
    /// The size `objectSizes` answers for `spec`; nil is what git says for a missing object.
    func set(objectSize size: Int64?, for spec: String) { objectSizesBySpec[spec] = size }
    /// Makes `objectSizes` throw, after recording the call.
    func fail(objectSizes on: Bool) { failsObjectSizes = on }
    /// Makes `objectSizes` answer one entry short, after recording the call.
    func truncate(objectSizes on: Bool) { truncatesObjectSizes = on }

    func objectSizes(of specs: [String]) async throws -> [Int64?] {
        objectSizesCalls.append(specs)
        if failsObjectSizes {
            throw ProcessError.failed(command: "git cat-file", status: 128, stderr: "gone")
        }
        let sizes = specs.map { objectSizesBySpec[$0] }
        return truncatesObjectSizes ? Array(sizes.dropLast()) : sizes
    }

    func numstat(area: ChangedFile.Area, ignoreWhitespace: Bool) async throws -> [NumstatEntry] {
        numstatCalls += 1
        lastIgnoreWhitespace = ignoreWhitespace
        if holdsNumstat {
            await withCheckedContinuation { heldNumstat.append($0) }
        }
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

    // MARK: Branches

    func set(localBranches names: [String]) { stubbedLocalBranches = names }
    func fail(localBranches on: Bool) { failsLocalBranches = on }
    /// Suspends `localBranches` after it records the call.
    func holdLocalBranches(_ on: Bool) { holdsLocalBranches = on }
    var heldLocalBranchesCount: Int { heldLocalBranches.count }
    func releaseLocalBranches() {
        let waiting = heldLocalBranches
        heldLocalBranches = []
        for continuation in waiting { continuation.resume() }
    }
    /// Releases the newest held branches read, so completion order can be chosen.
    func releaseLastLocalBranches() { if !heldLocalBranches.isEmpty { heldLocalBranches.removeLast().resume() } }

    /// Makes `switchBranch` throw, after recording the call and moving HEAD.
    func fail(switchBranch on: Bool) { failsSwitchBranch = on }
    /// Suspends `switchBranch` after it records the call.
    func holdSwitchBranch(_ on: Bool) { holdsSwitchBranch = on }
    var heldSwitchBranchCount: Int { heldSwitchBranch.count }
    func releaseSwitchBranch() {
        let waiting = heldSwitchBranch
        heldSwitchBranch = []
        for continuation in waiting { continuation.resume() }
    }
    /// The head state a switch leaves behind, applied whether or not the switch fails.
    func set(headStateAfterSwitch state: HeadState?) { headStateAfterSwitch = state }
    /// The head sha a switch leaves behind, applied whether or not the switch fails.
    func set(headAfterSwitch sha: String?) { headAfterSwitch = .some(sha) }

    func localBranches() async throws -> [String] {
        localBranchesCalls += 1
        // Snapshot before suspending, the way `status()` does: a held read reports what
        // the repository looked like when it was asked.
        let snapshot = stubbedLocalBranches
        if holdsLocalBranches {
            await withCheckedContinuation { heldLocalBranches.append($0) }
        }
        if failsLocalBranches {
            throw ProcessError.failed(command: "git for-each-ref", status: 128, stderr: "gone")
        }
        return snapshot
    }

    func switchBranch(to branch: String) async throws {
        switchBranchCalls.append(branch)
        if holdsSwitchBranch {
            await withCheckedContinuation { heldSwitchBranch.append($0) }
        }
        // HEAD moves before the failure check: a post-checkout hook fails after git has
        // already switched, and that is the case a caller has to refresh through.
        if let headStateAfterSwitch { stubbedHeadState = headStateAfterSwitch }
        if let headAfterSwitch { head = headAfterSwitch }
        if failsSwitchBranch {
            throw ProcessError.failed(command: "git switch", status: 1, stderr: "post-checkout hook failed")
        }
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
    /// Every dependency set handed over, in order.
    private(set) var dependencies: [Set<String>] = []
    func setDependencies(_ paths: Set<String>) { dependencies.append(paths) }
    func stop() { stopped = true }
}

@MainActor
final class Harness {
    let defaults: UserDefaults
    let suite = "DiffViewerTests.\(UUID().uuidString)"
    let runner = RunnerProbe()
    let preferences: Preferences
    /// The latest watcher started for each root.
    private(set) var watchers: [RepositoryRoot: NoopWatcher] = [:]
    /// How many watchers were started for each root.
    private(set) var watcherStarts: [RepositoryRoot: Int] = [:]
    /// A tick carrying an explicit set of changes, from the latest watcher.
    private(set) var watcherChangeCallbacks: [RepositoryRoot: @MainActor (Set<RepoChange>) -> Void] = [:]
    /// The callback of the watcher the latest one replaced, for ticks from a stopped watcher.
    private(set) var previousWatcherCallbacks: [RepositoryRoot: @MainActor (Set<RepoChange>) -> Void] = [:]
    /// A plain tick, as an edit and a stage produce: `[.worktree, .index]`.
    private(set) var watcherCallbacks: [RepositoryRoot: @MainActor () -> Void] = [:]
    /// Every `onRefreshPublished` call, in order.
    private(set) var published: [(files: [ChangedFile], cause: RefreshCause, inputsChanged: Bool)] = []

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
                self?.watcherStarts[root, default: 0] += 1
                self?.previousWatcherCallbacks[root] = self?.watcherChangeCallbacks[root]
                self?.watcherChangeCallbacks[root] = onChange
                self?.watcherCallbacks[root] = { onChange([.worktree, .index]) }
                return watcher
            })
        state.onRefreshPublished = { [weak self] state, cause, inputsChanged in
            self?.published.append((state.files, cause, inputsChanged))
        }
        return state
    }

    /// Delivers a watcher tick for `root` carrying `changes`.
    func tick(_ root: RepositoryRoot, _ changes: Set<RepoChange>) {
        watcherChangeCallbacks[root]!(changes)
    }

    /// Waits for the line-stats read in flight, if any, so later counter assertions are
    /// about what the test itself asked for.
    func settleStats(_ state: WindowState) async {
        await state.session?.statsTask?.value
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
        let before = h.published.count
        state.isVisible = true
        // Showing re-reads status once; an equal list has nothing to reload.
        #expect(await eventually { await h.published.count > before })
        #expect(h.published.last?.cause == .watcher)
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

        // The owed load rides on the rescan refresh that showing delivers.
        state.isVisible = true
        #expect(await eventually { await h.published.count == 3 })
        #expect(h.published.last?.cause == .watcher)
        #expect(await eventually { await !state.diffStale })
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

    // MARK: Changeset reloads

    /// The changeset the loader is publishing, or nil when it is showing anything else.
    private func changesetDocument(_ state: WindowState) -> ChangesetDocument? {
        guard case let .changeset(document)? = state.diffLoader.content else { return nil }
        return document
    }

    /// Waits for a changeset load other than `previous` to finish publishing, and returns it.
    private func replacementChangeset(_ state: WindowState, after previous: UUID?) async -> ChangesetDocument? {
        #expect(await eventually { await self.changesetDocument(state)?.loadID != previous })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        return changesetDocument(state)
    }

    @Test func anEditWhileAllChangesIsShownKeepsTheDocumentOnScreen() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let shown = changesetDocument(state)?.loadID
        #expect(shown != nil)

        await repo.client.hold(worktree: ["a1.swift"])
        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        h.watcherCallbacks[repo.root]!()
        #expect(await eventually { await repo.client.waitingWorktreePaths.contains("a1.swift") })
        #expect(changesetDocument(state)?.loadID == shown, "the document on screen stays while the edit reloads")
        #expect(state.diffLoader.isLoading)

        await repo.client.release(worktree: "a1.swift")
        let replacement = await replacementChangeset(state, after: shown)
        #expect(replacement?.sections.map(\.file.path) == ["a1.swift", "a2.swift"])
    }

    @Test func aWhitespaceToggleKeepsAllChangesOnScreen() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let shown = changesetDocument(state)?.loadID
        #expect(shown != nil)

        await repo.client.hold(worktree: ["a1.swift"])
        h.preferences.hideWhitespace.toggle()
        state.diffSettingsChanged()
        #expect(await eventually { await repo.client.waitingWorktreePaths.contains("a1.swift") })
        #expect(changesetDocument(state)?.loadID == shown, "the document on screen stays while the toggle reloads")
        #expect(state.diffLoader.isLoading)

        await repo.client.release(worktree: "a1.swift")
        let replacement = await replacementChangeset(state, after: shown)
        #expect(replacement?.sections.map(\.file.path) == ["a1.swift", "a2.swift"])
    }

    /// A new selection is a new view and starts from empty; once it is on screen, a
    /// reload of the same files keeps it, like All changes.
    @Test func selectingFilesAfterAllChangesStartsFromEmpty() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        #expect(changesetDocument(state) != nil)

        await repo.client.hold(worktree: ["a1.swift"])
        state.selection = [.file(filesA[0].id), .file(filesA[1].id)]
        #expect(state.diffLoader.content == nil, "the All-changes document is not kept for another selection")

        await repo.client.release(worktree: "a1.swift")
        let selected = await replacementChangeset(state, after: nil)
        #expect(selected?.sections.map(\.file.path) == ["a1.swift", "a2.swift"])

        await repo.client.hold(worktree: ["a1.swift"])
        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        h.watcherCallbacks[repo.root]!()
        #expect(await eventually { await repo.client.waitingWorktreePaths.contains("a1.swift") })
        #expect(changesetDocument(state)?.loadID == selected?.loadID, "the same files reload in place")
        #expect(state.diffLoader.isLoading)

        await repo.client.release(worktree: "a1.swift")
        let replacement = await replacementChangeset(state, after: selected?.loadID)
        #expect(replacement?.sections.map(\.file.path) == ["a1.swift", "a2.swift"])
    }

    /// The reload that showing a window delivers, through its rescan, is a reload of the
    /// same view too.
    @Test func showingAHiddenAllChangesReloadKeepsTheDocument() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let shown = changesetDocument(state)?.loadID
        #expect(shown != nil)

        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        state.isVisible = false
        await repo.client.hold(worktree: ["a1.swift"])
        state.isVisible = true
        #expect(await eventually { await repo.client.waitingWorktreePaths.contains("a1.swift") })
        #expect(changesetDocument(state)?.loadID == shown, "the document stays while the rescan reloads")
        #expect(state.diffLoader.isLoading)

        await repo.client.release(worktree: "a1.swift")
        let replacement = await replacementChangeset(state, after: shown)
        #expect(replacement?.sections.map(\.file.path) == ["a1.swift", "a2.swift"])
    }

    // MARK: Line stats

    @Test func publishedFilesCarryLineStats() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: filesA)
        await repo.client.set(
            numstat: [NumstatEntry(path: "a1.swift", stats: .counted(added: 12, deleted: 4))], area: .unstaged)
        await repo.client.set(numstat: [NumstatEntry(path: "a2.swift", stats: .binary(nil))], area: .staged)
        let before = h.published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count > before })
        #expect(h.published.last?.files.map(\.id) == filesA.map(\.id))

        // Stats follow the publish; the list itself does not change again.
        #expect(
            await eventually {
                await state.files.first { $0.path == "a1.swift" }?.lineStats == .counted(added: 12, deleted: 4)
            })
        #expect(state.files.first { $0.path == "a2.swift" }?.lineStats == .binary(nil))
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

    // MARK: Quiet refreshes

    /// Flips when the observed property is assigned. `withObservationTracking` fires its
    /// closure on the assigning thread, which for `files` is the main actor.
    private final class ChangeFlag: @unchecked Sendable {
        var raised = false
    }

    private func counted(_ file: ChangedFile, _ added: Int, _ deleted: Int) -> NumstatEntry {
        NumstatEntry(path: file.path, stats: .counted(added: added, deleted: deleted))
    }

    /// Adopts `files` with counts for both areas and waits for them to land.
    private func adoptCounted(_ h: Harness, _ state: WindowState, files: [ChangedFile]) async -> (
        root: RepositoryRoot, client: StubRepoClient
    ) {
        let repo = h.repo("A", files: files)
        await repo.client.set(numstat: files.filter { $0.area == .unstaged }.map { counted($0, 3, 1) }, area: .unstaged)
        await repo.client.set(numstat: files.filter { $0.area == .staged }.map { counted($0, 5, 2) }, area: .staged)
        let before = h.published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count > before })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        await h.settleStats(state)
        #expect(state.files.allSatisfy { $0.lineStats != nil })
        return repo
    }

    private func stats(of path: String, in state: WindowState) -> LineStats? {
        state.files.first { $0.path == path }?.lineStats
    }

    private func tick(_ h: Harness, _ repo: RepositoryRoot, waitingFor client: StubRepoClient) async {
        let status = await client.statusCalls
        let before = h.published.count
        h.watcherCallbacks[repo]!()
        #expect(await eventually { await client.statusCalls == status + 1 })
        #expect(await eventually { await h.published.count > before })
    }

    @Test func equalTickPublishesWithoutReloadingRecountingOrReassigning() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptCounted(h, state, files: filesA)
        let reads = await repo.client.contentReads
        let numstats = await repo.client.numstatCalls
        let flag = ChangeFlag()
        withObservationTracking {
            _ = state.files
        } onChange: {
            flag.raised = true
        }

        await tick(h, repo.root, waitingFor: repo.client)
        #expect(h.published.last?.cause == .watcher)
        #expect(h.published.last?.inputsChanged == false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == reads, "nothing shown changed, so nothing is re-read")
        #expect(await repo.client.numstatCalls == numstats, "the last counts still answer the same inputs")
        #expect(!flag.raised, "an equal list is not reassigned")
        #expect(state.files.allSatisfy { $0.lineStats != nil })
    }

    @Test func changedSelectedFileReloadsTheDiff() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads

        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(h.published.last?.inputsChanged == true)
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
    }

    @Test func anyChangedFileReloadsAllChanges() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        #expect(state.detailSelection == .allChanges)
        let reads = await repo.client.contentReads

        await repo.client.set(files: [filesA[0], filesA[1].restaged()])
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(await eventually { await repo.client.contentReads > reads })
    }

    @Test func changedUnselectedFileRecountsWithoutReloading() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptCounted(h, state, files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads
        await repo.client.holdNumstat(true)

        await repo.client.set(files: [filesA[0], filesA[1].restaged()])
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(stats(of: "a2.swift", in: state) == nil, "moved inputs drop the old counts until new ones arrive")
        #expect(stats(of: "a1.swift", in: state) == .counted(added: 3, deleted: 1), "unmoved inputs keep theirs")
        #expect(await eventually { await repo.client.heldNumstatCount == 2 })
        #expect(await repo.client.contentReads == reads, "the shown file did not change")

        await repo.client.releaseNumstat()
        #expect(await eventually { await self.stats(of: "a2.swift", in: state) == .counted(added: 5, deleted: 2) })
    }

    @Test func failedLoadRetriesOnAnEqualTick() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        await repo.client.fail(worktree: ["a1.swift"])
        await state.refresh()
        #expect(await eventually { await state.diffLoader.errorMessage != nil })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })

        await repo.client.fail(worktree: [])
        let reads = await repo.client.contentReads
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
        #expect(await eventually { await state.diffLoader.errorMessage == nil })
    }

    @Test func interruptedCountsPublishNilAndRunOnce() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptCounted(h, state, files: filesA)
        await repo.client.holdNumstat(true)

        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(stats(of: "a1.swift", in: state) == nil)
        #expect(await eventually { await repo.client.heldNumstatCount == 2 })
        let numstats = await repo.client.numstatCalls

        await tick(h, repo.root, waitingFor: repo.client)
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(await repo.client.numstatCalls == numstats, "an equal request keeps the read already running")
        #expect(stats(of: "a1.swift", in: state) == nil)

        await repo.client.releaseNumstat()
        #expect(await eventually { await self.stats(of: "a1.swift", in: state) == .counted(added: 3, deleted: 1) })
    }

    @Test func revertedEditKeepsTheEarlierCountsWhenTheSupersededReadFinishes() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptCounted(h, state, files: filesA)
        // A: the counts on screen. B: the edit, whose read would report something else.
        await repo.client.set(numstat: [counted(filesA[0], 99, 0)], area: .unstaged)
        await repo.client.holdNumstat(true)
        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(stats(of: "a1.swift", in: state) == nil)
        #expect(await eventually { await repo.client.heldNumstatCount == 2 })

        // Back to A: the last finished read answers again, and B's is superseded.
        await repo.client.set(files: filesA)
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(stats(of: "a1.swift", in: state) == .counted(added: 3, deleted: 1))
        await repo.client.releaseNumstat()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(stats(of: "a1.swift", in: state) == .counted(added: 3, deleted: 1), "B's counts never land on A")
    }

    @Test func failedCountsAreReusedByTicksAndRetriedByManualRefresh() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: filesA)
        await repo.client.fail(numstat: true)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count == 1 })
        await h.settleStats(state)
        #expect(state.files.allSatisfy { $0.lineStats == nil })
        let numstats = await repo.client.numstatCalls

        await tick(h, repo.root, waitingFor: repo.client)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.numstatCalls == numstats, "a tick does not retry a failure")

        await repo.client.fail(numstat: false)
        await repo.client.set(numstat: [counted(filesA[0], 3, 1)], area: .unstaged)
        await repo.client.set(numstat: [counted(filesA[1], 5, 2)], area: .staged)
        await state.refresh()
        #expect(await eventually { await self.stats(of: "a1.swift", in: state) == .counted(added: 3, deleted: 1) })
        #expect(await eventually { await self.stats(of: "a2.swift", in: state) == .counted(added: 5, deleted: 2) })
    }

    @Test func binaryFilesKeepTheirLabelAcrossAnEqualTick() async {
        let h = Harness()
        let state = h.makeState()
        let tracked = changedFile("img.png")
        let untracked = changedFile("new.png", kind: .untracked)
        let repo = h.repo("A", files: [tracked, untracked])
        await repo.client.set(numstat: [NumstatEntry(path: "img.png", stats: .binary(nil))], area: .unstaged)
        await repo.client.set(numstat: [], area: .staged)
        await repo.client.set(worktree: Data([0x89, 0x50, 0x4E, 0x47, 0, 1]), for: "new.png")
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count == 1 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        await h.settleStats(state)
        let untrackedSizes = LineStats.binary(BinarySizes(oldByteCount: nil, newByteCount: 6))
        #expect(stats(of: "img.png", in: state) == .binary(nil))
        #expect(stats(of: "new.png", in: state) == untrackedSizes)
        let numstats = await repo.client.numstatCalls

        await tick(h, repo.root, waitingFor: repo.client)
        #expect(stats(of: "img.png", in: state) == .binary(nil))
        #expect(stats(of: "new.png", in: state) == untrackedSizes)
        #expect(await repo.client.numstatCalls == numstats)
    }

    /// The "binary" fallback: git classified the file but its sizes could not be read, so
    /// the label stays rather than dropping to a retryable failure.
    @Test func aFailedSizeLookupKeepsTheBinaryLabel() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: [changedFile("img.png")])
        await repo.client.set(numstat: [NumstatEntry(path: "img.png", stats: .binary(nil))], area: .unstaged)
        await repo.client.set(numstat: [], area: .staged)
        await repo.client.fail(objectSizes: true)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count == 1 })
        await h.settleStats(state)

        #expect(await repo.client.objectSizesCalls.count == 1)
        #expect(stats(of: "img.png", in: state) == .binary(nil))
        #expect(state.session?.lineStats.lastOutcome?.results["unstaged:img.png"] == .available(.binary(nil)))
    }

    @Test func whitespaceToggleStartsANewCount() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptCounted(h, state, files: filesA)
        let numstats = await repo.client.numstatCalls

        let toggled = !h.preferences.hideWhitespace
        h.preferences.hideWhitespace = toggled
        state.diffSettingsChanged()
        #expect(await eventually { await repo.client.numstatCalls == numstats + 2 })
        #expect(await eventually { await repo.client.lastIgnoreWhitespace == toggled })
    }

    private func hasFailedSection(_ state: WindowState) -> Bool {
        guard case let .changeset(document)? = state.diffLoader.content else { return false }
        return document.sections.contains { if case .failed = $0.outcome { return true } else { return false } }
    }

    @Test func failedSectionRetriesOnceAcrossEqualTicks() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: filesA)
        await repo.client.fail(worktree: ["a1.swift"])
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count == 1 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        #expect(hasFailedSection(state))

        await repo.client.fail(worktree: [])
        await repo.client.holdReads(true)
        let reads = await repo.client.contentReads
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(await eventually { await repo.client.heldReadCount == 1 }, "the replacement starts")
        #expect(await eventually { await repo.client.contentReads == reads + 4 })

        await tick(h, repo.root, waitingFor: repo.client)
        await tick(h, repo.root, waitingFor: repo.client)
        #expect(await repo.client.contentReads == reads + 4, "a replacement in flight is not restarted")

        await repo.client.releaseReads()
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        #expect(!hasFailedSection(state))
        #expect(await repo.client.contentReads == reads + 4)
    }

    private func merging(_ text: String) -> CommitDefaults {
        CommitDefaults(suggestion: .init(text: text, source: .merge), isMerging: true)
    }

    @Test func settingsRefreshLeavesTheDefaultsReadAlone() async throws {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: filesA)
        let expected = merging("Merge branch 'feature'")
        await repo.client.set(commitDefaults: expected)
        await repo.client.holdCommitDefaults(true)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await repo.client.heldCommitDefaultsCount == 1 })
        let task = try #require(state.session?.commitDefaultsTask)
        let generation = state.session?.commitDefaultsGeneration
        let before = h.published.count

        state.diffSettingsChanged()
        #expect(await eventually { await h.published.count > before })
        #expect(h.published.last?.cause == .settings)
        #expect(await repo.client.commitDefaultsCalls == 1, "a settings change has no bearing on the suggestion")
        #expect(state.session?.commitDefaultsGeneration == generation)

        await repo.client.releaseCommitDefaults()
        await task.value
        #expect(state.commitDefaults == expected)
    }

    @Test func olderDefaultsReadIsDiscardedWhileTheNewerRefreshIsStillReading() async throws {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: filesA)
        let older = merging("Merge branch 'older'")
        let newer = merging("Merge branch 'newer'")
        await repo.client.set(commitDefaults: older)
        await repo.client.holdCommitDefaults(true)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await repo.client.heldCommitDefaultsCount == 1 })
        let old = try #require(state.session?.commitDefaultsTask)

        // The newer refresh is accepted, and its defaults read starts, before its status returns.
        await repo.client.set(commitDefaults: newer)
        await repo.client.hold(true)
        let refresh = Task { await state.refresh() }
        #expect(await eventually { await repo.client.heldCount == 1 })
        #expect(await eventually { await repo.client.heldCommitDefaultsCount == 2 })

        await repo.client.releaseFirstCommitDefaults()
        await old.value
        #expect(state.commitDefaults == .none, "the older read finished and applied nothing")

        await repo.client.releaseFirst()
        await refresh.value
        await repo.client.releaseCommitDefaults()
        let current = try #require(state.session?.commitDefaultsTask)
        await current.value
        #expect(state.commitDefaults == newer)
    }

    @Test func manualRefreshReloadsEqualFiles() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads

        await state.refresh()
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
    }

    @Test func ticksDuringASlowStatusCollapseIntoOneFollowUp() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let status = await repo.client.statusCalls
        await repo.client.hold(true)
        h.watcherCallbacks[repo.root]!()
        #expect(await eventually { await repo.client.heldCount == 1 })
        h.watcherCallbacks[repo.root]!()
        h.watcherCallbacks[repo.root]!()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == status + 1, "ticks queue behind the running refresh")

        await repo.client.releaseFirst()
        #expect(await eventually { await repo.client.heldCount == 1 }, "one follow-up for both ticks")
        await repo.client.hold(false)
        await repo.client.releaseFirst()
        #expect(await eventually { await repo.client.statusCalls == status + 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == status + 2)
    }

    /// An edit that lands between the settings load's read and its status would leave
    /// the old content behind a fingerprint every later tick judges unchanged.
    @Test func settingsRefreshReloadsAShownFileThatChangedUnderTheLoad() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads

        // The stub snapshots its list when status is called, so the edit is in place before
        // the refresh starts; the held status still returns after the load's reads.
        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        await repo.client.hold(true)
        state.diffSettingsChanged()
        #expect(await eventually { await repo.client.contentReads == reads + 2 }, "the settings load read the file")
        #expect(await eventually { await repo.client.heldCount == 1 })
        await repo.client.hold(false)
        await repo.client.releaseFirst()
        #expect(await eventually { await h.published.last?.cause == .settings })
        #expect(await eventually { await repo.client.contentReads == reads + 4 }, "the edit is read again")

        let after = await repo.client.contentReads
        await tick(h, repo.root, waitingFor: repo.client)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == after, "the tick has nothing new to load")
    }

    // MARK: Hiding and showing

    @Test func hidingStopsTheWatcherAndShowingStartsANewOne() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        #expect(h.watcherStarts[repo.root] == 1)
        let first = h.watchers[repo.root]
        let status = await repo.client.statusCalls
        let reads = await repo.client.contentReads
        let before = h.published.count

        state.isVisible = false
        #expect(first?.stopped == true)
        #expect(state.session?.watcher == nil)

        state.isVisible = true
        #expect(h.watcherStarts[repo.root] == 2)
        #expect(h.watchers[repo.root] !== first)
        #expect(h.watchers[repo.root]?.stopped == false)
        #expect(await eventually { await h.published.count > before })
        #expect(h.published.last?.cause == .watcher)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == status + 1, "one rescan")
        #expect(await repo.client.contentReads == reads, "nothing changed: the diff on show is kept")
    }

    @Test func showingReloadsAStaleDiffOnce() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads
        let status = await repo.client.statusCalls

        state.isVisible = false
        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        state.isVisible = true
        #expect(await eventually { await repo.client.statusCalls == status + 1 })
        #expect(await eventually { await state.files.first?.fingerprint == self.filesA[0].edited().fingerprint })
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        #expect(!state.diffStale)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == status + 1, "one status read")
        #expect(await repo.client.contentReads == reads + 2, "one load")
    }

    /// A hidden window watches nothing: a running refresh and the tick queued behind it
    /// go with the watcher, and the rescan on showing finds the edit they carried.
    @Test func staleStatusAcrossHideAndShow() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads
        let status = await repo.client.statusCalls
        let before = h.published.count
        let tick = h.watcherCallbacks[repo.root]!

        await repo.client.hold(true)
        tick()
        #expect(await eventually { await repo.client.heldCount == 1 })
        await repo.client.set(files: [filesA[0].edited(), filesA[1]])
        tick()
        state.isVisible = false
        await repo.client.hold(false)
        await repo.client.releaseFirst()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.published.count == before, "the outlived read publishes nothing")
        #expect(await repo.client.statusCalls == status + 1, "the queued follow-up is dropped")
        #expect(state.files.first?.fingerprint == filesA[0].fingerprint)
        #expect(!state.diffStale, "nothing was published, so no reload is owed")
        #expect(await repo.client.contentReads == reads)

        // The stopped watcher's callback reads nothing.
        tick()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == status + 1)

        state.isVisible = true
        #expect(await eventually { await repo.client.statusCalls == status + 2 })
        #expect(await eventually { await state.files.first?.fingerprint == self.filesA[0].edited().fingerprint })
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == status + 2)
        #expect(await repo.client.contentReads == reads + 2, "exactly one load")
    }

    @Test func aTickFromAStoppedWatcherIsIgnored() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let before = h.published.count
        state.isVisible = false
        state.isVisible = true
        #expect(await eventually { await h.published.count > before })
        try? await Task.sleep(for: .milliseconds(50))
        let status = await repo.client.statusCalls

        h.previousWatcherCallbacks[repo.root]!([.worktree])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == status, "the replaced watcher's ticks are dropped")

        h.watcherChangeCallbacks[repo.root]!([.worktree])
        #expect(await eventually { await repo.client.statusCalls == status + 1 }, "the new watcher's are not")
    }

    @Test func showingInCommitScopeReadsMetadataAndReloadsTheStaleDiff() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptInCommitScope(h, state)
        let file = state.files[0]

        state.isVisible = false
        state.selection = [.file(file.id)]
        #expect(state.diffStale)
        let before = await Reads(repo.client)

        state.isVisible = true
        // A commit's files cannot change, so no status read; the owed load runs once.
        #expect(await eventually { await self.hasContent(state, for: file) })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        let expected = before.plus(head: 1, headState: 1, content: 2)
        #expect(await eventually { await Reads(repo.client) == expected })
        #expect(!state.diffStale)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await Reads(repo.client) == expected)
    }

    @Test func adoptingHiddenStartsTheWatcherOnShow() async {
        let h = Harness()
        let state = h.makeState()
        state.isVisible = false
        let repo = h.repo("A", files: filesA)
        let before = h.published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count > before })
        #expect(h.watcherStarts[repo.root, default: 0] == 0)
        #expect(state.session?.watcher == nil)

        state.isVisible = true
        #expect(h.watcherStarts[repo.root] == 1)
        #expect(state.session?.watcher != nil)
    }

    @Test func aRescanDeliveredDuringARunningRefreshIsNotLost() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        let status = await repo.client.statusCalls

        await repo.client.hold(true)
        h.watcherCallbacks[repo.root]!()
        #expect(await eventually { await repo.client.heldCount == 1 })
        state.isVisible = false
        state.isVisible = true
        // The rescan finds the old watcher's refresh still running and queues behind it.
        #expect(await eventually { await state.session?.watcherRefreshPending != nil })
        #expect(await repo.client.statusCalls == status + 1)

        await repo.client.hold(false)
        await repo.client.releaseFirst()
        #expect(await eventually { await repo.client.statusCalls == status + 2 }, "the rescan runs as the follow-up")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == status + 2)
    }

    /// A status read that outlives its watcher publishes nothing: its snapshot predates
    /// the hide, and the rescan queued behind it reads again.
    @Test func aStatusReadOutlivedByItsWatcherPublishesNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads
        let status = await repo.client.statusCalls
        let before = h.published.count

        // The selected file is gone in the snapshot the held read will return.
        await repo.client.set(files: [filesA[1]])
        await repo.client.hold(true)
        h.watcherCallbacks[repo.root]!()
        #expect(await eventually { await repo.client.heldCount == 1 })
        state.isVisible = false
        state.isVisible = true
        #expect(await eventually { await state.session?.watcherRefreshPending != nil })
        // It is back by the time the rescan reads.
        await repo.client.set(files: filesA)
        // The stale read returns; the rescan's read is held next.
        await repo.client.releaseFirst()
        #expect(await eventually { await repo.client.heldCount == 1 })
        await repo.client.releaseFirst()

        #expect(await eventually { await repo.client.statusCalls == status + 2 })
        #expect(await eventually { await h.published.count == before + 1 }, "the stale response published nothing")
        #expect(state.selection == [.file(filesA[0].id)], "the selection survives the file's brief absence")
        #expect(state.files == filesA)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.published.count == before + 1)
        #expect(await repo.client.contentReads == reads, "the shown file's fingerprint is unchanged: no reload")
    }

    /// The load owed from hiding does not depend on the status read on show succeeding.
    @Test func aFailedStatusOnShowStillLoadsTheOwedDiff() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: filesA)
        await select(filesA[0], in: state)
        let reads = await repo.client.contentReads

        // A reload of the same file, held at the worktree read.
        await repo.client.holdReads(true)
        state.diffSettingsChanged()
        #expect(await eventually { await repo.client.heldReadCount == 1 })
        state.isVisible = false
        #expect(state.diffStale)
        await repo.client.holdReads(false)
        await repo.client.releaseReads()

        await repo.client.fail(true)
        state.isVisible = true
        #expect(await eventually { await state.errorMessage != nil }, "the status failure is kept")
        // The cancelled reload's two reads were counted before the hold; the owed load adds two.
        #expect(await eventually { await repo.client.contentReads == reads + 4 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        #expect(!state.diffStale)
        #expect(hasContent(state, for: filesA[0]))
        #expect(state.files == filesA, "the old list is retained")
    }

    /// Status cannot say what HEAD holds for a conflict, so the fingerprint is unknown and
    /// every tick reloads: the price of never showing a stale conflict.
    @Test func unmergedFileRevalidatesOnEveryTick() async {
        let h = Harness()
        let state = h.makeState()
        let conflict = changedFile("c.swift", kind: .unmerged)
        let repo = await h.adopt(state, "A", files: [conflict])
        await select(conflict, in: state)
        let reads = await repo.client.contentReads

        await tick(h, repo.root, waitingFor: repo.client)
        #expect(h.published.last?.inputsChanged == true)
        #expect(await eventually { await repo.client.contentReads == reads + 2 })
    }

    // MARK: Routed ticks

    /// Adopts `files` with counts and waits for every read the adoption starts, so the
    /// counters below move only for the tick under test.
    private func adoptSettled(_ h: Harness, _ state: WindowState, files: [ChangedFile]) async -> (
        root: RepositoryRoot, client: StubRepoClient
    ) {
        let repo = await adoptCounted(h, state, files: files)
        await state.session?.historyTask?.value
        await state.session?.commitDefaultsTask?.value
        #expect(await eventually { await state.localBranches == ["main"] })
        return repo
    }

    /// Every read a tick can route to, taken at one moment.
    private struct Reads: Equatable {
        var status, head, headState, defaults, numstat, content: Int

        init(_ client: StubRepoClient) async {
            status = await client.statusCalls
            head = await client.headCalls
            headState = await client.headStateCalls
            defaults = await client.commitDefaultsCalls
            numstat = await client.numstatCalls
            content = await client.contentReads
        }

        /// The same counters after the given reads.
        func plus(status: Int = 0, head: Int = 0, headState: Int = 0, defaults: Int = 0, content: Int = 0) -> Reads {
            var reads = self
            reads.status += status
            reads.head += head
            reads.headState += headState
            reads.defaults += defaults
            reads.content += content
            return reads
        }
    }

    /// Sends `changes` and waits for the status read and publish it must produce.
    private func tick(
        _ h: Harness, _ repo: RepositoryRoot, _ changes: Set<RepoChange>, waitingFor client: StubRepoClient
    ) async {
        let status = await client.statusCalls
        let before = h.published.count
        h.tick(repo, changes)
        #expect(await eventually { await client.statusCalls == status + 1 })
        #expect(await eventually { await h.published.count > before })
    }

    @Test func anIndexTickCostsOneStatusRead() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        let before = await Reads(repo.client)

        await tick(h, repo.root, [.index], waitingFor: repo.client)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await Reads(repo.client) == before.plus(status: 1))
    }

    @Test func aRefsTickReadsMetadataAndDefaultsWithoutReloading() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        let before = await Reads(repo.client)

        await tick(h, repo.root, [.refs], waitingFor: repo.client)
        let expected = before.plus(status: 1, head: 1, headState: 1, defaults: 1)
        #expect(await eventually { await Reads(repo.client) == expected })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await Reads(repo.client) == expected, "equal inputs: no diff, no recount")
    }

    /// A soft reset writes only `.git/HEAD` and the ref, yet what is staged changes.
    @Test func aSoftResetShowsItsStagedFiles() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        #expect(state.detailSelection == .allChanges)
        let reads = await repo.client.contentReads

        let unstaged = filesA + [changedFile("reset.swift", area: .staged)]
        await repo.client.set(files: unstaged)
        await tick(h, repo.root, [.refs], waitingFor: repo.client)
        #expect(state.files.map(\.id) == unstaged.map(\.id))
        #expect(await eventually { await repo.client.contentReads > reads }, "All changes reloads")
    }

    /// `info/exclude` decides what is untracked, so the list and the counts follow it.
    @Test func anExcludeEditUpdatesTheListAndRecounts() async {
        let h = Harness()
        let state = h.makeState()
        let untracked = changedFile("scratch.txt", kind: .untracked)
        let repo = await adoptSettled(h, state, files: filesA + [untracked])
        let numstats = await repo.client.numstatCalls

        await repo.client.set(files: filesA)
        await tick(h, repo.root, [.configuration], waitingFor: repo.client)
        #expect(state.files.map(\.id) == filesA.map(\.id))
        #expect(await eventually { await repo.client.numstatCalls > numstats })
    }

    /// Attributes can reclassify an unchanged file as binary, so a configuration change
    /// recounts everything and shows nothing stale meanwhile.
    @Test func aConfigurationTickDropsCarriedOverCountsAndRecounts() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        let revision = state.session?.configurationRevision
        await repo.client.holdNumstat(true)

        await tick(h, repo.root, [.configuration], waitingFor: repo.client)
        #expect(state.session?.configurationRevision == revision.map { $0 + 1 })
        #expect(state.files.allSatisfy { $0.lineStats == nil }, "the old counts answer another configuration")
        #expect(await eventually { await repo.client.heldNumstatCount == 2 })

        await repo.client.releaseNumstat()
        #expect(await eventually { await state.files.allSatisfy { $0.lineStats != nil } })
    }

    @Test func aWorktreeTickLeavesAHeldDefaultsReadAloneWhenNoTemplateIsConfigured() async throws {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        // Spelled out: `.none` against an optional would mean nil.
        #expect(state.session?.templateDependency == CommitDefaults.TemplateDependency.none)
        let expected = merging("Merge branch 'feature'")
        await repo.client.set(commitDefaults: expected)
        await repo.client.holdCommitDefaults(true)
        await state.refresh()
        #expect(await eventually { await repo.client.heldCommitDefaultsCount == 1 })
        let task = try #require(state.session?.commitDefaultsTask)
        let defaults = await repo.client.commitDefaultsCalls

        await tick(h, repo.root, [.worktree], waitingFor: repo.client)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.commitDefaultsCalls == defaults, "no template: the worktree cannot change it")

        await repo.client.releaseCommitDefaults()
        await task.value
        #expect(state.commitDefaults == expected, "the held read was not superseded")
    }

    /// A configured template may live in the worktree, so an edit there can change the suggestion.
    @Test func aWorktreeTickRereadsDefaultsWhileATemplateIsConfigured() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: filesA)
        await repo.client.set(
            commitDefaults: CommitDefaults(suggestion: nil, isMerging: false, templateDependency: configured))
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count == 1 })
        await state.session?.commitDefaultsTask?.value
        #expect(state.session?.templateDependency == configured)

        let filled = CommitDefaults(
            suggestion: .init(text: "Subject: ", source: .template), isMerging: false, templateDependency: configured)
        await repo.client.set(commitDefaults: filled)
        await tick(h, repo.root, [.worktree], waitingFor: repo.client)
        #expect(await eventually { await state.commitDefaults == filled })
    }

    /// A configuration change may have enabled a template. Until the read it starts says
    /// so, a worktree tick must not trust the old "none": a template edit made while that
    /// read is pending would otherwise publish a suggestion that is already stale.
    @Test func aConfigurationTickForgetsTheTemplateDependencyUntilItsReadLands() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        #expect(state.session?.templateDependency == CommitDefaults.TemplateDependency.none)

        let templateA = templated("A")
        let templateB = templated("B")
        // The read the configuration tick starts sees template A and is held there.
        await repo.client.set(commitDefaults: templateA)
        await repo.client.holdCommitDefaults(true)
        await tick(h, repo.root, [.configuration], waitingFor: repo.client)
        #expect(await eventually { await repo.client.heldCommitDefaultsCount == 1 })
        #expect(state.session?.templateDependency == .unknown)

        // The template is edited to B while A's read is pending; the worktree tick must read again.
        await repo.client.set(commitDefaults: templateB)
        await tick(h, repo.root, [.worktree], waitingFor: repo.client)
        #expect(await eventually { await repo.client.heldCommitDefaultsCount == 2 })

        await repo.client.releaseFirstCommitDefaults()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(state.commitDefaults == .none, "A's read is stale and applies nothing")
        await repo.client.holdCommitDefaults(false)
        await repo.client.releaseCommitDefaults()
        #expect(await eventually { await state.commitDefaults == templateB })
        #expect(state.session?.templateDependency == configured)
    }

    /// A template in the worktree, as the routed-tick tests configure it.
    private let configured = CommitDefaults.TemplateDependency.configured(path: "/tmp/A/.gitmessage")

    private func templated(_ text: String) -> CommitDefaults {
        CommitDefaults(
            suggestion: .init(text: text, source: .template), isMerging: false, templateDependency: configured)
    }

    /// The watcher learns the template's path from each read, so an edit to a template kept
    /// under `.git` is not dropped with that directory's noise.
    @Test func aDefaultsReadHandsTheTemplatePathToTheWatcher() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: filesA)
        let path = "/tmp/A/.git/commit-template"
        await repo.client.set(
            commitDefaults: CommitDefaults(
                suggestion: nil, isMerging: false, templateDependency: .configured(path: path)))
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count == 1 })
        await state.session?.commitDefaultsTask?.value
        #expect(h.watchers[repo.root]?.dependencies.last == [path])

        await repo.client.set(commitDefaults: .none)
        await state.refresh()
        await state.session?.commitDefaultsTask?.value
        #expect(h.watchers[repo.root]?.dependencies.last == [], "unset: nothing left to depend on")
    }

    /// A read that threw cannot say whether a template is configured, so the next
    /// worktree tick reads again rather than assuming there is none.
    @Test func aFailedDefaultsReadIsRetriedByAWorktreeTick() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: filesA)
        await repo.client.fail(commitDefaults: true)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count == 1 })
        await state.session?.commitDefaultsTask?.value
        #expect(state.session?.templateDependency == .unknown)

        let expected = merging("Merge branch 'feature'")
        await repo.client.fail(commitDefaults: false)
        await repo.client.set(commitDefaults: expected)
        await tick(h, repo.root, [.worktree], waitingFor: repo.client)
        #expect(await eventually { await state.commitDefaults == expected })
    }

    @Test func ticksWithDifferentChangesMergeIntoOneFollowUp() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptSettled(h, state, files: filesA)
        let before = await Reads(repo.client)
        await repo.client.hold(true)
        h.tick(repo.root, [.index])
        #expect(await eventually { await repo.client.heldCount == 1 })
        h.tick(repo.root, [.index])
        h.tick(repo.root, [.refs])
        await repo.client.hold(false)
        await repo.client.releaseFirst()

        #expect(await eventually { await repo.client.statusCalls == before.status + 2 }, "one follow-up")
        #expect(await eventually { await repo.client.headStateCalls == before.headState + 1 }, "carrying `.refs`")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.statusCalls == before.status + 2)
        #expect(await repo.client.headStateCalls == before.headState + 1)
    }

    /// Selects `commit` and waits for its files, so a tick arrives in commit scope.
    private func adoptInCommitScope(_ h: Harness, _ state: WindowState) async -> (
        root: RepositoryRoot, client: StubRepoClient
    ) {
        let commit = commitSummary("c1")
        let repo = h.repo("A", files: filesA)
        await repo.client.set(head: commit.ref.sha)
        await repo.client.set(commits: [commit])
        await repo.client.set(
            files: [ChangedFile(path: "one.swift", originalPath: nil, kind: .modified, area: .commit(commit.ref))],
            forCommit: commit.ref.sha)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await !state.history.commits.isEmpty })
        state.select(commit: commit)
        #expect(await eventually { await state.files.count == 1 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        #expect(await eventually { await state.localBranches == ["main"] })
        return repo
    }

    @Test func aWorktreeTickDoesNothingInCommitScope() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptInCommitScope(h, state)
        let before = await Reads(repo.client)

        h.tick(repo.root, [.worktree])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await Reads(repo.client) == before)
    }

    @Test func aRefsTickChecksHeadWithoutStatusInCommitScope() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptInCommitScope(h, state)
        let before = await Reads(repo.client)

        h.tick(repo.root, [.refs])
        let expected = before.plus(head: 1, headState: 1)
        #expect(await eventually { await Reads(repo.client) == expected })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await Reads(repo.client) == expected, "no status read, no defaults read")
    }
}
