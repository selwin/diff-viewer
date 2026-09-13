import AppKit
import Observation
import SwiftUI

/// Identifies one window for the lifetime of the app.
struct WindowID: Hashable, Sendable {
    private let uuid = UUID()
}

/// An opened repository: its root, client, and watcher. Refreshes are bound to the
/// session they started in, so a result for a repository that has since been replaced
/// is discarded.
@MainActor
final class RepoSession {
    let root: RepositoryRoot
    let client: any RepoClient
    var watcher: (any RepoWatching)?
    /// Incremented per refresh; only the latest may publish.
    var refreshSerial = 0
    /// The line-stats work of the latest refresh; cancelled when a newer one starts.
    var statsTask: Task<Void, Never>?

    init(root: RepositoryRoot, client: any RepoClient) {
        self.root = root
        self.client = client
    }
}

/// Why a refresh ran. Reported with every published file list.
enum RefreshCause: Sendable {
    /// The first status read after `adopt`.
    case initial
    /// Cmd+R or the toolbar button.
    case manual
    /// The repository watcher fired.
    case watcher
    /// A setting that changes diff content (Hide Whitespace) changed.
    case settings
}

/// Everything one window holds for its repository: the session, the changed-file
/// list, the selection, the diff loader, and change navigation.
///
/// A window adopts a repository once and keeps it until it closes. App-wide concerns
/// (preferences, the difft cache, prefetching) are injected or driven from outside.
@MainActor
@Observable
final class WindowState {
    typealias WatcherFactory = @MainActor (RepositoryRoot, @escaping @MainActor () -> Void) -> (any RepoWatching)?

    let id = WindowID()
    let preferences: Preferences
    let diffLoader: DiffLoader

    private(set) var session: RepoSession?
    var repositoryRoot: RepositoryRoot? { session?.root }
    var isEmpty: Bool { session == nil }
    private(set) var files: [ChangedFile] = []
    private(set) var isLoading = false
    private(set) var isClosed = false
    var errorMessage: String?
    var selectedFileID: ChangedFile.ID? {
        didSet {
            if selectedFileID != oldValue {
                currentChangeIndex = nil
                scrollTarget = nil
                reloadDiff()
            }
        }
    }

    /// Keyboard focus. Informational for the view; nothing in the model branches on it.
    var isKey = false

    /// On screen, per AppKit's occlusion state. A hidden window starts no diff or
    /// highlight work; what it skipped is reloaded when it becomes visible again.
    var isVisible = true {
        didSet {
            guard isVisible != oldValue, !isClosed else { return }
            if isVisible {
                if diffStale { reloadDiff() }
            } else if diffLoader.cancelActiveWork() {
                diffStale = true
            }
        }
    }

    /// A diff load was skipped or cancelled while hidden and must run on becoming visible.
    private(set) var diffStale = false

    /// Called after every refresh that publishes `files`, whether or not the list changed.
    @ObservationIgnored var onRefreshPublished: (@MainActor (WindowState, RefreshCause) -> Void)?

    /// Index into the current document's change blocks, for next/previous navigation.
    private(set) var currentChangeIndex: Int?
    private(set) var scrollTarget: ScrollTarget?

    private let watchRepository: WatcherFactory
    private var initialRefresh: Task<Void, Never>?

    init(preferences: Preferences, cache: DifftCache, watchRepository: @escaping WatcherFactory) {
        self.preferences = preferences
        self.watchRepository = watchRepository
        diffLoader = DiffLoader(cache: cache)
    }

    var selectedFile: ChangedFile? {
        files.first { $0.id == selectedFileID }
    }

    var unstagedFiles: [ChangedFile] { files.filter { $0.area == .unstaged } }
    var stagedFiles: [ChangedFile] { files.filter { $0.area == .staged } }

    /// Files worth warming in the difft cache: everything but the selection, which
    /// is the loader's job at foreground priority.
    var filesToWarm: [ChangedFile] {
        (unstagedFiles + stagedFiles).filter { $0.id != selectedFileID }
    }

    var repoName: String { repositoryRoot?.name ?? "DiffViewer" }

    /// The window and tab title. The repository name, extended with parent folders by
    /// the coordinator when another open repository has the same name.
    var title = "DiffViewer"

    /// The window subtitle: the selected file's path, or nothing.
    var subtitle: String { selectedFile?.path ?? "" }

    // MARK: - Lifecycle

    /// Installs `root` as this window's repository and starts its first refresh.
    /// One-time: returns `false` and changes nothing if the window is already
    /// populated or closed.
    @discardableResult
    func adopt(root: RepositoryRoot, client: any RepoClient) -> Bool {
        guard session == nil, !isClosed else { return false }
        let session = RepoSession(root: root, client: client)
        session.watcher = watchRepository(root) { [weak self, weak session] in
            guard let self, let session else { return }
            Task { await self.refresh(session: session, cause: .watcher) }
        }
        self.session = session
        title = root.name
        selectedFileID = nil
        errorMessage = nil
        isLoading = true
        initialRefresh = Task { [weak self] in
            await self?.refresh(session: session, cause: .initial)
            self?.isLoading = false
        }
        return true
    }

    /// Ends this window's work for good: no refresh in flight can publish, no diff
    /// or highlight can complete, and the watcher is stopped. Idempotent.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        initialRefresh?.cancel()
        session?.refreshSerial += 1
        session?.statsTask?.cancel()
        session?.watcher?.stop()
        session?.watcher = nil
        diffLoader.cancelActiveWork()
        isLoading = false
    }

    // MARK: - Refreshing

    func refresh() async {
        guard let session else { return }
        await refresh(session: session, cause: .manual)
    }

    /// Reloads the file list for `session`. The result is published only if the
    /// session is still current, the window is open, and no newer refresh of it has
    /// started since.
    ///
    /// Line stats are decoration and arrive separately: the list is published as soon
    /// as `status()` returns, carrying the counts already known for each file, and a
    /// follow-up task runs numstat and the untracked line counts and updates `files`
    /// in place. A newer refresh cancels that task; a failed numstat leaves its area
    /// unknown and never fails the refresh, which is driven by `status()` alone.
    func refresh(session: RepoSession, cause: RefreshCause) async {
        // A watcher callback queued before its window closed: skip the read.
        guard session === self.session, !isClosed else { return }
        session.refreshSerial += 1
        let serial = session.refreshSerial
        session.statsTask?.cancel()
        let ignoreWhitespace = preferences.hideWhitespace
        let client = session.client

        let outcome: Result<[ChangedFile], Error>
        do {
            outcome = .success(try await client.status())
        } catch {
            outcome = .failure(error)
        }
        guard session === self.session, !isClosed, serial == session.refreshSerial else { return }

        switch outcome {
        case let .success(newFiles):
            let known = Dictionary(files.map { ($0.id, $0.lineStats) }, uniquingKeysWith: { first, _ in first })
            files = newFiles.map { $0.with(lineStats: known[$0.id] ?? nil) }
            if let selectedFileID, !newFiles.contains(where: { $0.id == selectedFileID }) {
                self.selectedFileID = nil
            }
            errorMessage = nil
            // A settings change reloaded the diff before starting its refresh.
            if cause != .settings { reloadDiff() }
            onRefreshPublished?(self, cause)
            session.statsTask = Task { [weak self] in
                await self?.attachLineStats(to: newFiles, session: session, serial: serial, ignoreWhitespace: ignoreWhitespace)
            }
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    /// Runs numstat for both areas and counts untracked files, then replaces `files`
    /// with the same list carrying the fresh stats, if this refresh still owns the
    /// window. Not a publish: the list itself did not change.
    private func attachLineStats(to newFiles: [ChangedFile], session: RepoSession, serial: Int, ignoreWhitespace: Bool) async {
        let client = session.client
        async let unstaged = client.numstat(area: .unstaged, ignoreWhitespace: ignoreWhitespace)
        async let staged = client.numstat(area: .staged, ignoreWhitespace: ignoreWhitespace)
        // A failed numstat leaves its area out, which the joiner reports as unknown.
        var numstat: [ChangedFile.Area: [NumstatEntry]] = [:]
        numstat[.unstaged] = try? await unstaged
        numstat[.staged] = try? await staged
        guard !Task.isCancelled else { return }
        let joined = await LineStatsJoiner.attach(numstat: numstat, to: newFiles, client: client)
        guard !Task.isCancelled, session === self.session, !isClosed, serial == session.refreshSerial else { return }
        files = joined
    }

    // MARK: - Diff

    /// A setting that changes diff content changed. The diff reloads at once (or is
    /// marked stale while hidden); the line counts depend on Hide Whitespace too, so
    /// a refresh follows to recompute them.
    func diffSettingsChanged() {
        reloadDiff()
        guard let session else { return }
        Task { await refresh(session: session, cause: .settings) }
    }

    /// Loads the selected file's diff when visible; when hidden, records that a load
    /// is owed so nothing runs for a window nobody can see.
    private func reloadDiff() {
        guard !isClosed else { return }
        guard isVisible else {
            diffStale = true
            return
        }
        diffStale = false
        diffLoader.load(file: selectedFile, client: session?.client, hideWhitespace: preferences.hideWhitespace)
    }

    // MARK: - Change navigation

    var changeBlockCount: Int {
        if case let .text(document)? = diffLoader.content { return document.changeBlocks.count }
        return 0
    }

    func nextChange() {
        jump(to: ChangeNavigator.next(after: ChangeNavigator.clamp(currentChangeIndex, count: changeBlockCount), count: changeBlockCount))
    }

    func previousChange() {
        jump(to: ChangeNavigator.previous(before: ChangeNavigator.clamp(currentChangeIndex, count: changeBlockCount), count: changeBlockCount))
    }

    private func jump(to index: Int?) {
        guard let index, case let .text(document)? = diffLoader.content else { return }
        currentChangeIndex = index
        scrollTarget = ScrollTarget(row: document.changeBlocks[index].lowerBound)
    }
}
