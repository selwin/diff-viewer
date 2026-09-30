import Foundation
import Testing

@testable import DiffViewer

/// A window and the repository behind it.
typealias Window = (h: Harness, state: WindowState, client: StubRepoClient, root: RepositoryRoot)

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

    /// What `WindowState` reads as the current time; tests move it to expire cooldowns.
    var clock = Date(timeIntervalSince1970: 1_789_300_000)

    func makeState(commitMessageGenerator: any CommitMessageGenerator = StubCommitMessageGenerator()) -> WindowState {
        let state = WindowState(
            preferences: preferences, cache: probeCache(runner), commitMessageGenerator: commitMessageGenerator,
            now: { [weak self] in self?.clock ?? Date() },
            watchRepository: { [weak self] root, onChange in
                let watcher = NoopWatcher()
                self?.watchers[root] = watcher
                self?.watcherStarts[root, default: 0] += 1
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

    /// Adopts and waits for the initial refresh to publish. `configure` stubs the client
    /// before adoption starts reading it.
    @discardableResult
    func adopt(
        _ state: WindowState, _ name: String, files: [ChangedFile],
        configure: (StubRepoClient) async -> Void = { _ in }
    ) async -> (root: RepositoryRoot, client: StubRepoClient) {
        let repo = repo(name, files: files)
        await configure(repo.client)
        let before = published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await self.published.count > before })
        // The first list lands on All changes, which reads every file. Waiting for that
        // load to settle keeps later read counts about what the test itself asked for.
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        return repo
    }

    /// Adopts a repository whose HEAD is the first of `commits`, which changed
    /// `commitFiles`, and waits for the file list to publish. The caller waits for the
    /// history itself, as each needs something different from it.
    func adoptWithHistory(
        _ state: WindowState, files: [ChangedFile], commits: [CommitSummary], commitFiles: [ChangedFile] = []
    ) async -> StubRepoClient {
        let repo = repo("A", files: files)
        await repo.client.set(head: commits.first?.ref.sha)
        await repo.client.set(commits: commits)
        if let first = commits.first { await repo.client.set(files: commitFiles, forCommit: first.ref.sha) }
        let before = published.count
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await self.published.count > before })
        return repo.client
    }
}

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
        return DifftFile(
            language: "Swift", path: fileName, status: "changed", chunks: [[DifftFile.LinePair(lhs: line, rhs: line)]])
    }

    /// Releases held launches in the order they arrived.
    func release(_ count: Int = .max) {
        for _ in 0..<min(count, held.count) {
            held.removeFirst().resume()
        }
    }
}
