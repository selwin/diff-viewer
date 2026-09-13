import AppKit
import Observation
import SwiftUI

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
                // Someone chose a file; whatever the last scope change meant to restore
                // is now out of date.
                if selectedFileID != nil { pendingReselect = nil }
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

    /// What the sidebar is showing: the working tree, or one previous commit.
    private(set) var scope: DiffScope = .workingTree
    /// The selected commit's display details, kept whether or not it is still in the
    /// loaded page: a branch switch or a page reset can drop it from `history`, and the
    /// picker still has to label and tick the thing the user chose.
    private(set) var selectedCommit: CommitSummary?
    private(set) var history = CommitHistory()
    private(set) var commitLimit = Self.commitPageSize
    private(set) var isLoadingHistory = false
    private(set) var historyErrorMessage: String?
    /// The read a history load is serving, so an identical repeat can be skipped instead
    /// of cancelling and restarting a `git log` that would produce the same answer.
    /// `ProcessRunner` does not kill the subprocess it cancels, so restarts accumulate.
    private var historyRequestInFlight: HistoryRequest?
    /// True from a scope change until that scope's file list arrives, so an unfinished
    /// read is not drawn as a commit that changed nothing.
    private(set) var isLoadingScope = false
    /// The file to select again once the new scope's list arrives. Held here rather than
    /// after the scope task's own `refresh`, which may be superseded by a watcher refresh
    /// that publishes the files instead.
    private var pendingReselect: PendingSelection?

    /// A path to find again in a new scope, and the area it came from.
    struct PendingSelection: Equatable, Sendable {
        let path: String
        let area: ChangedFile.Area
    }

    /// How many commits a page holds, and how many `Load More` adds.
    static let commitPageSize = 50

    /// What the picker shows in place of a commit list.
    enum HistoryPlaceholder {
        case loading
        case empty
        case failed
    }

    /// Nil when there are commits to list.
    var historyPlaceholder: HistoryPlaceholder? {
        guard history.commits.isEmpty else { return nil }
        if isLoadingHistory { return .loading }
        return historyErrorMessage == nil ? .empty : .failed
    }

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
    /// The selected commit's files. Empty in working-tree scope.
    var commitFiles: [ChangedFile] { files.filter(\.area.isCommit) }

    /// Files worth warming in the difft cache: everything in the current scope but the
    /// selection, which is the loader's job at foreground priority.
    var filesToWarm: [ChangedFile] {
        // Unstaged first, as before: that is the list a reader works down. The working
        // tree can fill both of its lists at once; a commit fills only the third.
        (unstagedFiles + stagedFiles + commitFiles).filter { $0.id != selectedFileID }
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
            Task { await self.repositoryChanged(session: session) }
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
        refreshHistory(session: session)
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
        session?.historySerial += 1
        session?.historyTask?.cancel()
        session?.watcher?.stop()
        session?.watcher = nil
        diffLoader.cancelActiveWork()
        isLoading = false
    }

    // MARK: - Refreshing

    func refresh() async {
        guard let session else { return }
        // ⌘R re-reads everything, including a commit's files: the user asked.
        await refresh(session: session, cause: .manual)
        refreshHistory(session: session)
    }

    /// Something under `.git` or in the working tree changed.
    ///
    /// A commit's contents cannot change, so in commit scope this must not re-read the
    /// file list, republish it, or reload the diff — doing so on every keystroke in
    /// another editor would re-read historical blobs and re-run alignment and
    /// highlighting for a view that cannot have changed. Only the commit list can go
    /// stale, and only when HEAD moves.
    private func repositoryChanged(session: RepoSession) async {
        guard session === self.session, !isClosed else { return }
        if case .workingTree = scope {
            await refresh(session: session, cause: .watcher)
        }
        guard session === self.session, !isClosed else { return }
        await reloadHistoryIfHeadMoved(session: session)
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

        let scope = self.scope
        let outcome: Result<[ChangedFile], Error>
        do {
            switch scope {
            case .workingTree:
                outcome = .success(try await client.status())
            case let .commit(ref):
                outcome = .success(try await client.changedFiles(in: ref))
            }
        } catch {
            outcome = .failure(error)
        }
        guard session === self.session, !isClosed, serial == session.refreshSerial else { return }
        // The scope changed while this read was in flight; its files belong to a list
        // nobody is showing any more.
        guard scope == self.scope else { return }

        isLoadingScope = false
        switch outcome {
        case let .success(newFiles):
            // Taken before the list is published: clearing a selection that vanished
            // runs the observer above, which would discard the restoration first.
            let pending = pendingReselect
            pendingReselect = nil
            let selectionBefore = selectedFileID
            // Only the files whose counts are known, so the lookup below is a plain
            // optional rather than a nested one.
            let known = Dictionary(
                files.compactMap { file in file.lineStats.map { (file.id, $0) } },
                uniquingKeysWith: { first, _ in first })
            files = newFiles.map { $0.with(lineStats: known[$0.id]) }
            if let selectedFileID, !newFiles.contains(where: { $0.id == selectedFileID }) {
                self.selectedFileID = nil
            }
            if let pending { reselect(pending) }
            errorMessage = nil
            // A settings change reloaded the diff before starting its refresh, and any
            // change to the selection above already reloaded it through the observer.
            if cause != .settings, selectedFileID == selectionBefore { reloadDiff() }
            onRefreshPublished?(self, cause)
            session.statsTask = Task { [weak self] in
                await self?.attachLineStats(
                    to: newFiles, session: session, scope: scope, serial: serial,
                    ignoreWhitespace: ignoreWhitespace)
            }
        case let .failure(error):
            if case let .commit(ref) = scope {
                // The commit itself could not be read — garbage-collected after a rebase,
                // or the repository is damaged. An empty sidebar under its name would be a
                // lie, so drop back to the working tree.
                await fallBackToWorkingTree(session: session, from: ref, error: error)
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Runs numstat for the scope's areas and counts untracked files, then replaces
    /// `files` with the same list carrying the fresh stats, if this refresh still owns
    /// the window. Not a publish: the list itself did not change.
    private func attachLineStats(
        to newFiles: [ChangedFile], session: RepoSession, scope: DiffScope, serial: Int, ignoreWhitespace: Bool
    ) async {
        let client = session.client
        // The working tree's two areas are independent processes and stay concurrent;
        // a commit scope has a single area.
        let numstat = await withTaskGroup(of: (ChangedFile.Area, [NumstatEntry]?).self) { group in
            for area in scope.areas {
                group.addTask {
                    let entries = try? await client.numstat(area: area, ignoreWhitespace: ignoreWhitespace)
                    return (area, entries)
                }
            }
            // A failed numstat leaves its area out, which the joiner reports as unknown.
            var rows: [ChangedFile.Area: [NumstatEntry]] = [:]
            for await (area, entries) in group where entries != nil {
                rows[area] = entries
            }
            return rows
        }
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
        jump(
            to: ChangeNavigator.next(
                after: ChangeNavigator.clamp(currentChangeIndex, count: changeBlockCount), count: changeBlockCount))
    }

    func previousChange() {
        jump(
            to: ChangeNavigator.previous(
                before: ChangeNavigator.clamp(currentChangeIndex, count: changeBlockCount), count: changeBlockCount))
    }

    private func jump(to index: Int?) {
        guard let index, case let .text(document)? = diffLoader.content else { return }
        currentChangeIndex = index
        scrollTarget = ScrollTarget(row: document.changeBlocks[index].lowerBound)
    }
}

/// Choosing what the sidebar shows, and reading the branch history the picker lists.
///
/// An extension rather than more of the class body, which is long enough already; it
/// stays in this file because the state it writes is `private(set)`. History loading
/// runs on its own generation counter, so reloading the commit list can never
/// invalidate an in-flight scope change.
extension WindowState {
    /// Where a history read gets its revision. Separating the two removes the
    /// combination a single "resolve HEAD?" flag allowed, where a caller could ask to
    /// resolve HEAD *and* name a revision.
    private enum HistorySource {
        /// Read HEAD first. Adoption and ⌘R, where the revision is not known yet.
        case currentHead
        /// A revision the caller already resolved, so the commits and the revision they
        /// describe come from one reading of HEAD rather than two.
        case revision(String?)
    }

    // MARK: - Scope

    /// Shows the working tree again.
    func selectWorkingTree() {
        select(scope: .workingTree, commit: nil)
    }

    /// Shows what `commit` changed against its first parent.
    func select(commit: CommitSummary) {
        select(scope: .commit(commit.ref), commit: commit)
    }

    private func select(scope newScope: DiffScope, commit: CommitSummary?) {
        guard let session, !isClosed, newScope != scope else { return }
        session.scopeSerial += 1

        // Remember what was selected before anything is cleared. Clearing `files` does
        // not run `selectedFileID`'s observer, so the previous scope's diff load has to
        // be stopped by hand; assigning nil does that through `reloadDiff`, and it must
        // happen before the target is recorded or the observer would discard it.
        let previous = selectedFile.map { PendingSelection(path: $0.path, area: $0.area) }
        selectedFileID = nil
        pendingReselect = previous
        session.statsTask?.cancel()

        scope = newScope
        selectedCommit = commit
        files = []
        isLoadingScope = true
        Task { [weak self] in
            await self?.refresh(session: session, cause: .scope)
        }
    }

    /// Puts the selection back on the same path in the new scope. A path can appear in
    /// two areas at once, so the old area wins, then unstaged, then staged.
    ///
    /// Called by whichever refresh publishes the new scope's files, which is not always
    /// the one the scope change started: a watcher refresh can overtake it.
    func reselect(_ previous: PendingSelection) {
        guard !isClosed, selectedFileID == nil else { return }
        let matches = files.filter { $0.path == previous.path }
        let match =
            matches.first { $0.area == previous.area }
            ?? matches.first { $0.area == .unstaged }
            ?? matches.first
        selectedFileID = match?.id
    }

    /// Returns to the working tree after a commit could not be read.
    ///
    /// The message is assigned after the refresh, not before: a successful refresh
    /// clears `errorMessage`, so setting it first would wipe the only explanation the
    /// user gets for the sidebar changing under them. The scope generation is checked
    /// after the await too — by then the user may have picked another commit, and an
    /// alert about the old one would be both wrong and obstructive.
    func fallBackToWorkingTree(session: RepoSession, from ref: CommitRef, error: Error) async {
        session.scopeSerial += 1
        let serial = session.scopeSerial
        scope = .workingTree
        selectedCommit = nil
        selectedFileID = nil
        pendingReselect = nil
        files = []
        isLoadingScope = true
        await refresh(session: session, cause: .scope)
        guard session === self.session, !isClosed, serial == session.scopeSerial else { return }
        errorMessage = "Couldn't read commit \(ref.shortSha): \(error.localizedDescription)"
    }

    // MARK: - History

    /// Resolves HEAD and loads its history: adoption and ⌘R.
    func refreshHistory(session: RepoSession) {
        startHistoryLoad(session: session, source: .currentHead)
    }

    /// Reads another page of commits. Ignored while a page is already loading:
    /// `ProcessRunner` does not kill a subprocess when its task is cancelled, so
    /// repeated clicks would otherwise pile up ever-larger `git log` reads whose output
    /// is thrown away.
    func loadMoreCommits() {
        guard let session, !isClosed, !isLoadingHistory, history.hasMore else { return }
        commitLimit += Self.commitPageSize
        // Page against the revision already on show, so a checkout mid-scroll cannot
        // splice two branches' commits into one list.
        startHistoryLoad(session: session, source: .revision(history.revision))
    }

    /// Reloads the commit list only when HEAD has moved since the page was read. One
    /// `rev-parse` per watcher tick, instead of a full log on every edit to the tree.
    func reloadHistoryIfHeadMoved(session: RepoSession) async {
        // The generation is read before the await and checked after it. Without that,
        // two overlapping checks can resolve different revisions, and the slower one —
        // holding the older answer — would start the last load and leave the picker
        // showing a branch the repository has already left.
        let serialBefore = session.historySerial
        // `try?` would flatten a thrown error and an unborn HEAD into the same nil, and
        // checking out an unborn branch has to clear the list rather than leave the old
        // one up. A failure here is transient by assumption; the next tick tries again.
        let head: String?
        do {
            head = try await session.client.headSha()
        } catch {
            return
        }
        guard session === self.session, !isClosed, serialBefore == session.historySerial else { return }

        let headMoved = head != history.revision
        // Retry a failed read too, or one bad moment would leave the picker empty until
        // HEAD happened to move.
        guard headMoved || historyErrorMessage != nil else { return }
        // A different HEAD is a different branch or a new commit: start from page one.
        if headMoved { commitLimit = Self.commitPageSize }
        // Several ticks can arrive while one `git log` is still running; restarting it
        // for the answer it is already fetching only burns processes.
        guard historyRequestInFlight != HistoryRequest(revision: head, limit: commitLimit) else { return }
        startHistoryLoad(session: session, source: .revision(head))
    }

    private func startHistoryLoad(session: RepoSession, source: HistorySource) {
        session.historySerial += 1
        let serial = session.historySerial
        session.historyTask?.cancel()
        isLoadingHistory = true
        historyErrorMessage = nil
        let limit = commitLimit
        historyRequestInFlight =
            if case let .revision(revision) = source { HistoryRequest(revision: revision, limit: limit) } else { nil }
        session.historyTask = Task { [weak self] in
            await self?.loadHistory(session: session, serial: serial, source: source, limit: limit)
        }
    }

    private func loadHistory(session: RepoSession, serial: Int, source: HistorySource, limit: Int) async {
        func isCurrent() -> Bool {
            session === self.session && !isClosed && serial == session.historySerial && !Task.isCancelled
        }

        do {
            let revision: String?
            switch source {
            case .currentHead:
                revision = try await session.client.headSha()
                guard isCurrent() else { return }
                historyRequestInFlight = HistoryRequest(revision: revision, limit: limit)
            case let .revision(value):
                revision = value
            }

            guard let revision else {
                // An unborn HEAD: a real, settled answer, not a failure.
                guard isCurrent() else { return }
                history = CommitHistory()
                finishHistoryLoad()
                return
            }
            // One extra tells us whether another page exists without a second query.
            let page = try await session.client.recentCommits(startingAt: revision, limit: limit + 1)
            guard isCurrent() else { return }
            history = CommitHistory(
                revision: revision, commits: Array(page.prefix(limit)), hasMore: page.count > limit)
            finishHistoryLoad()
        } catch {
            guard isCurrent() else { return }
            historyErrorMessage = error.localizedDescription
            finishHistoryLoad()
        }
    }

    private func finishHistoryLoad() {
        isLoadingHistory = false
        historyRequestInFlight = nil
    }
}
