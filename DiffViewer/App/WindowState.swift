// swiftlint:disable file_length
// The scope, history and commit extensions stay in this file so their state can remain
// `private(set)`; the length is the cost of that.

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
    private(set) var files: [ChangedFile] = []
    private(set) var isLoading = false
    private(set) var isClosed = false
    var errorMessage: String? {
        didSet { errorRaisedByRefresh = false }
    }
    /// True only while `errorMessage` holds a refresh's own error; a later successful
    /// refresh clears just that. Every assignment above clears it, so only the refresh
    /// failure branch, which sets it afterwards, can turn it on.
    private var errorRaisedByRefresh = false
    /// Bumped by every user write to `selection`, so a file action can tell whether the
    /// reader changed it while git ran. Writable only here; the action extension reads it.
    private(set) var selectionRevision = 0
    private var storedSelection: Set<DiffSelection> = []

    /// The rows highlighted in the sidebar: All changes, any number of files, or nothing.
    ///
    /// The setter is the user's path — the List binding, a scope change, the debug hooks,
    /// tests — so it records the intent and drops whatever a file action meant to restore,
    /// which the reader has now overruled. A refresh puts the selection back by another
    /// route, `applySelection`, which does neither.
    var selection: Set<DiffSelection> {
        get { storedSelection }
        set {
            selectionRevision += 1
            pendingReselections = []
            if applySelection(newValue, from: detailIdentity) { reloadDiff() }
        }
    }

    /// The one place the stored selection changes. Resets change navigation when the
    /// identity moved away from `keyBefore` and reports whether it did; never reloads, so
    /// that a refresh can apply a selection and then decide about the reload once, at the end.
    ///
    /// The caller supplies `keyBefore` because a refresh replaces `files` first: read here,
    /// the "before" identity would already describe the new list.
    @discardableResult
    private func applySelection(_ new: Set<DiffSelection>, from keyBefore: DetailIdentity) -> Bool {
        storedSelection = new
        guard detailIdentity != keyBefore else { return false }
        currentChangeIndex = nil
        scrollTarget = nil
        return true
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
    /// Where HEAD points, or nil until the first read returns: nil shows no subtitle, not a wrong one.
    private(set) var headState: HeadState?
    private(set) var commitLimit = WindowState.commitPageSize
    private(set) var isLoadingHistory = false
    private(set) var historyErrorMessage: String?
    /// The read a history load is serving, so an identical repeat can be skipped instead
    /// of cancelling and restarting a `git log` that would produce the same answer.
    /// `ProcessRunner` does not kill the subprocess it cancels, so restarts accumulate.
    private var historyRequestInFlight: HistoryRequest?
    /// True from a scope change until that scope's file list arrives, so an unfinished
    /// read is not drawn as a commit that changed nothing.
    private(set) var isLoadingScope = false
    /// The rows to select again once the new list arrives. Held here rather than after the
    /// scope task's own `refresh`, which may be superseded by a watcher refresh that
    /// publishes the files instead.
    private var pendingReselections: [PendingSelection] = []
    /// Set when a window or a scope is about to show its first list, and consumed by
    /// whichever refresh publishes one, for the same reason as `pendingReselect`.
    private var pendingAllChanges = false

    /// The commit message being written, bound to the commit box.
    ///
    /// The setter is the reader's path (the box, tests), so it bumps `commitDraftRevision`.
    /// A defaults read writes `storedCommitMessage` directly, the way `applySelection`
    /// bypasses the `selection` setter, so automatic text never counts as an edit.
    var commitMessage: String {
        get { storedCommitMessage }
        set {
            storedCommitMessage = newValue
            commitDraftRevision += 1
        }
    }
    private var storedCommitMessage = ""
    /// Bumped by every reader write to `commitMessage`, so a commit can tell whether the box
    /// was edited while git ran. Same idea as `selectionRevision`.
    private(set) var commitDraftRevision = 0
    /// git's suggestion (merge, squash, template) and whether a merge is in progress.
    private(set) var commitDefaults = CommitDefaults.none
    /// Last automatically applied message, used to preserve edited drafts.
    private var lastAppliedDefaultMessage: String?
    /// A commit is queued or running.
    private(set) var isCommitting = false

    /// How many commits a page holds, and how many `Load More` adds.
    static let commitPageSize = 50

    /// Called after every refresh that publishes `files`, whether or not the list changed.
    @ObservationIgnored var onRefreshPublished: (@MainActor (WindowState, RefreshCause) -> Void)?

    /// Index into the current document's change blocks, for next/previous navigation, and
    /// the row the panes should bring into view. Written by `applySelection`, which resets
    /// both when the pane's content changes, and by `WindowState+Navigation`. Nothing else
    /// should write them; they are `var` only because that extension is in another file.
    var currentChangeIndex: Int?
    var scrollTarget: ScrollTarget?

    private let watchRepository: WatcherFactory
    private var initialRefresh: Task<Void, Never>?

    init(preferences: Preferences, cache: DifftCache, watchRepository: @escaping WatcherFactory) {
        self.preferences = preferences
        self.watchRepository = watchRepository
        diffLoader = DiffLoader(cache: cache)
    }

    /// The window and tab title. The repository name, extended with parent folders by
    /// the coordinator when another open repository has the same name.
    var title = "DiffViewer"

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
        selection = []
        pendingAllChanges = true
        errorMessage = nil
        isLoading = true
        initialRefresh = Task { [weak self] in
            await self?.refresh(session: session, cause: .initial)
            self?.isLoading = false
        }
        refreshHistory(session: session)
        Task { [weak self] in await self?.refreshHeadState(session: session) }
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
        session?.commitDefaultsTask?.cancel()
        session?.historySerial += 1
        session?.historyTask?.cancel()
        session?.headStateCheckSerial += 1
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
        await refreshHeadState(session: session)
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
        // Also in commit scope: a checkout under a selected commit still changes the branch.
        await refreshHeadState(session: session)
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
        session.commitDefaultsTask?.cancel()
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
            // Taken before anything is applied: a restoration describes the list this
            // refresh is about to replace, and only this refresh can grant it.
            let pending = pendingReselections
            pendingReselections = []
            let wantsAllChanges = pendingAllChanges
            pendingAllChanges = false
            // Taken before `files` is replaced, so it describes the pane on screen.
            let keyBefore = detailIdentity
            let selectionBeforeWasEmpty = storedSelection.isEmpty
            // Only the files whose counts are known, so the lookup below is a plain
            // optional rather than a nested one.
            let known = Dictionary(
                files.compactMap { file in file.lineStats.map { (file.id, $0) } },
                uniquingKeysWith: { first, _ in first })
            files = newFiles.map { $0.with(lineStats: known[$0.id]) }
            // One set for the whole selection rather than a scan of the list per row:
            // All changes is not a file and always survives.
            let liveIDs = Set(newFiles.map(\.id))
            let surviving = storedSelection.filter { $0.fileID.map(liveIDs.contains) ?? true }
            applySelection(
                SidebarReselection.selection(after: pending, surviving: surviving, in: sidebarRows),
                from: keyBefore)
            // Only the first list for a window or a scope lands on All changes: a
            // selection a *later* refresh emptied because its files vanished stays empty,
            // which is what the restoration rule and the detail area both read.
            // `selectionBeforeWasEmpty` guards a choice made while this read was in flight.
            if wantsAllChanges, storedSelection.isEmpty, selectionBeforeWasEmpty {
                applySelection([.allChanges], from: keyBefore)
            }
            // A refresh clears the error a refresh raised, and only that one: an action's
            // failure is news the reader has not seen yet and outlives a status read.
            if errorRaisedByRefresh { errorMessage = nil }
            // The refresh alone decides, because applying a selection above never reloads.
            // A settings change reloaded the diff before it started this refresh, so it
            // reloads a second time only when the identity actually moved; every other
            // cause re-reads content that may have changed on disk.
            if detailIdentity != keyBefore || cause != .settings {
                reloadDiff()
            }
            onRefreshPublished?(self, cause)
            session.statsTask = Task { [weak self] in
                await self?.attachLineStats(
                    to: newFiles, session: session, scope: scope, serial: serial,
                    ignoreWhitespace: ignoreWhitespace)
            }
            if scope == .workingTree {
                session.commitDefaultsTask = Task { [weak self] in
                    await self?.loadCommitDefaults(session: session, serial: serial)
                }
            }
        case let .failure(error):
            if case let .commit(ref) = scope {
                // The commit itself could not be read — garbage-collected after a rebase,
                // or the repository is damaged. An empty sidebar under its name would be a
                // lie, so drop back to the working tree.
                await fallBackToWorkingTree(session: session, from: ref, error: error)
            } else {
                errorMessage = error.localizedDescription
                errorRaisedByRefresh = true
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

    /// Loads the selection's diff when visible; when hidden, records that a load
    /// is owed so nothing runs for a window nobody can see.
    private func reloadDiff() {
        guard !isClosed else { return }
        guard isVisible else {
            diffStale = true
            return
        }
        diffStale = false
        switch detailSelection {
        case .allChanges:
            diffLoader.load(
                changeset: sidebarRows, client: session?.client, hideWhitespace: preferences.hideWhitespace,
                foldOptions: preferences.foldOptions)
        case .files:
            diffLoader.load(
                changeset: selectedFiles, client: session?.client, hideWhitespace: preferences.hideWhitespace,
                foldOptions: preferences.foldOptions)
        case .file, .nothing:
            // `selectedFile` is nil for `.nothing`, and for a file that has left the list;
            // either way the loader is told to show nothing, which also cancels its work.
            diffLoader.load(file: selectedFile, client: session?.client, hideWhitespace: preferences.hideWhitespace)
        }
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

        // Clearing `files` does not touch the selection, so the previous scope's diff load
        // has to be stopped by hand; emptying the selection does that through `reloadDiff`.
        // Nothing is remembered to restore: the new scope's list lands on All changes, a
        // better answer than hunting for the same paths in a different set of files, and
        // the setter drops a pending restoration, which belongs to the list being left.
        selection = []
        pendingAllChanges = true
        session.statsTask?.cancel()

        scope = newScope
        selectedCommit = commit
        files = []
        isLoadingScope = true
        Task { [weak self] in
            await self?.refresh(session: session, cause: .scope)
        }
    }

    /// Asks the next refresh that publishes a file list to put the selection back on
    /// `selections`. The rule itself is `SidebarReselection`.
    ///
    /// Exists because `pendingReselections` is private to the class body and the
    /// file-action extension lives in another file. Deliberately narrow: it records a
    /// wish, and whichever refresh publishes the new list decides whether it can still be
    /// granted — not always the refresh that recorded it, since a watcher refresh can
    /// overtake a scope change or a file action.
    func restoreSelectionAfterNextRefresh(_ selections: [PendingSelection]) {
        pendingReselections = selections
    }

    /// Returns to the working tree after a commit could not be read.
    ///
    /// The message is assigned after the refresh, not before: a successful refresh clears
    /// whatever error a refresh raised, so setting it first could wipe the only
    /// explanation the user gets for the sidebar changing under them. Assigned afterwards
    /// it stands until the reader dismisses it. The scope generation is checked
    /// after the await too — by then the user may have picked another commit, and an
    /// alert about the old one would be both wrong and obstructive.
    private func fallBackToWorkingTree(session: RepoSession, from ref: CommitRef, error: Error) async {
        session.scopeSerial += 1
        let serial = session.scopeSerial
        scope = .workingTree
        selectedCommit = nil
        selection = []
        pendingAllChanges = true
        files = []
        isLoadingScope = true
        await refresh(session: session, cause: .scope)
        guard session === self.session, !isClosed, serial == session.scopeSerial else { return }
        errorMessage = "Couldn't read commit \(ref.shortSha): \(error.localizedDescription)"
    }

    // MARK: - History

    /// Resolves HEAD and loads its history: adoption and ⌘R.
    private func refreshHistory(session: RepoSession) {
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
    private func reloadHistoryIfHeadMoved(session: RepoSession) async {
        // Each check takes its own ticket, so the newest one wins whatever order they
        // finish in. Sharing the history generation let completion order decide instead:
        // whichever check resolved first started a load, and a check holding a fresher
        // HEAD was discarded behind it.
        session.headCheckSerial += 1
        let ticket = session.headCheckSerial
        // `try?` would flatten a thrown error and an unborn HEAD into the same nil, and
        // checking out an unborn branch has to clear the list rather than leave the old
        // one up. A failure here is transient by assumption; the next tick tries again.
        let head: String?
        do {
            head = try await session.client.headSha()
        } catch {
            return
        }
        guard session === self.session, !isClosed, ticket == session.headCheckSerial else { return }

        let displayed = history.revision
        // Where the picker is heading, which is not always what it shows.
        let loading = historyRequestInFlight?.revision

        // Checked out elsewhere and back again while a load was running: comparing only
        // against what is displayed would find nothing to do and let that load land,
        // publishing another branch's commits over the right ones.
        if head == displayed, let loading, loading != head {
            cancelHistoryLoad(session: session)
            return
        }
        // Retry a failed read too, or one bad moment would leave the picker empty until
        // HEAD happened to move.
        guard head != displayed || historyErrorMessage != nil else { return }
        // A different HEAD is a different branch or a new commit: start from page one.
        if head != displayed { commitLimit = Self.commitPageSize }
        // Several ticks can arrive while one `git log` is still running; restarting it
        // for the answer it is already fetching only burns processes.
        guard historyRequestInFlight != HistoryRequest(revision: head, limit: commitLimit) else { return }
        startHistoryLoad(session: session, source: .revision(head))
    }

    /// Re-reads where HEAD points, on its own serial so a commit-list load cannot cancel it or be cancelled.
    private func refreshHeadState(session: RepoSession) async {
        // A watcher callback queued before its window closed: skip the read.
        guard session === self.session, !isClosed else { return }
        session.headStateCheckSerial += 1
        let ticket = session.headStateCheckSerial
        // A failure leaves the last known branch on show: the next tick reads again, and stale beats blank.
        let state: HeadState
        do {
            state = try await session.client.headState()
        } catch {
            return
        }
        guard session === self.session, !isClosed, ticket == session.headStateCheckSerial else { return }
        headState = state
    }

    /// Drops a history read whose answer is no longer wanted, and settles the state its
    /// completion would have cleared.
    private func cancelHistoryLoad(session: RepoSession) {
        session.historySerial += 1
        session.historyTask?.cancel()
        historyRequestInFlight = nil
        isLoadingHistory = false
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

// MARK: - Commit

/// Recording the index as a commit and keeping the draft in step with git's own
/// suggestion. Same file as the class so the commit state stays `private(set)`.
extension WindowState {
    /// An open window in working-tree scope, no commit queued or running, no conflict
    /// rows, something to commit (staged files, or a merge whose tree may equal HEAD), a
    /// non-blank message that is not a commit.template left exactly as applied.
    var canCommit: Bool {
        guard session != nil, !isClosed, scope == .workingTree, !isCommitting else { return false }
        guard !files.contains(where: { $0.kind == .unmerged }) else { return false }
        guard files.contains(where: { $0.area == .staged }) || commitDefaults.isMerging else { return false }
        guard !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !commitNeedsTemplateEdit
    }

    /// Whether the draft exactly matches the current template suggestion. Commit refuses
    /// it and the box says why. An exact string comparison, not git's cleanup-aware check;
    /// a safeguard against committing boilerplate.
    var commitNeedsTemplateEdit: Bool {
        guard let suggestion = commitDefaults.suggestion, suggestion.source == .template else { return false }
        return commitMessage == suggestion.text
    }

    /// Starts one commit; a second call while one is queued or running does nothing, so a
    /// burst of ⌘↩ presses records one commit.
    func commit() async {
        guard canCommit, let session else { return }
        isCommitting = true  // before the first suspension: the admission guard
        defer { isCommitting = false }
        let message = commitMessage
        let revision = commitDraftRevision
        await enqueueWrite(session: session) { [weak self] in
            await self?.runCommit(message: message, revision: revision, session: session)
        }
    }

    private func runCommit(message: String, revision: Int, session: RepoSession) async {
        guard session === self.session, !isClosed else { return }
        var failure: (any Error)?
        do { try await session.client.commit(message: message) } catch { failure = error }
        guard session === self.session, !isClosed else { return }
        // Whatever the reader typed while git ran, a cleared box included, is theirs and
        // survives both outcomes. Only an unedited box is settled here.
        if commitDraftRevision == revision {
            if failure == nil {
                storedCommitMessage = ""
            } else {
                // A defaults read that landed while git ran may have replaced or emptied
                // the draft. Put the submitted message back, and count it as the reader's
                // own from now on so no later refresh can take it away.
                storedCommitMessage = message
            }
            lastAppliedDefaultMessage = nil
        }
        // Refresh either way: a failing hook may have rewritten files, and the watcher
        // ignores this process's own writes.
        await refresh(session: session, cause: .commit)
        // `refresh` returns quietly for a closed window; the history load below would
        // not, and would leave `isLoadingHistory` stuck on.
        guard session === self.session, !isClosed else { return }
        // History and HEAD reload because a commit moves both and nothing else on this
        // path would notice.
        refreshHistory(session: session)
        await refreshHeadState(session: session)
        guard session === self.session, !isClosed, let failure else { return }
        // After the refresh, so the news survives it.
        errorMessage = failure.localizedDescription
    }

    /// Reads the suggestion for the list a refresh just published. Applies only while that
    /// refresh is still the newest and the sidebar still shows the working tree; a thrown
    /// read applies nothing, so the box keeps its last good state.
    private func loadCommitDefaults(session: RepoSession, serial: Int) async {
        // Cancelled before it ran: skip the subprocess, not just the publish.
        guard !Task.isCancelled else { return }
        let new: CommitDefaults
        do { new = try await session.client.commitDefaults() } catch { return }
        guard !Task.isCancelled, session === self.session, !isClosed, serial == session.refreshSerial,
            scope == .workingTree
        else { return }
        applyCommitDefaults(new)
    }

    /// The draft is untouched when it still equals what was last applied (or is empty and
    /// nothing was). Untouched → replaced by the new suggestion (nil empties it) and
    /// remembered; touched → left alone. A merge abort empties the box, a cherry-pick
    /// fills it, and a half-written message survives every watcher tick.
    private func applyCommitDefaults(_ new: CommitDefaults) {
        commitDefaults = new
        guard storedCommitMessage == (lastAppliedDefaultMessage ?? "") else { return }
        let text = new.suggestion?.text
        storedCommitMessage = text ?? ""  // not the setter: this is not an edit
        lastAppliedDefaultMessage = text
    }
}
