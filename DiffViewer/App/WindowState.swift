// swiftlint:disable file_length
// The scope, history, commit and branch-switch extensions stay in this file so their
// state can remain `private(set)`; the length is the cost of that.

import AppKit
import Observation
import SwiftUI

/// Everything one window holds for its repository: the session, the changed-file
/// list, the selection, the diff loader, and change navigation.
///
/// A window adopts a repository once and keeps it until it closes. App-wide concerns
/// (preferences, the caches, prefetching) are injected or driven from outside.
@MainActor
@Observable
final class WindowState {
    typealias WatcherCallback = @MainActor (Set<RepoChange>) -> Void
    typealias WatcherFactory = @MainActor (RepositoryRoot, @escaping WatcherCallback) -> (any RepoWatching)?

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

    /// On screen, per AppKit's occlusion state. A hidden window stops its watcher and
    /// starts no diff or highlight work. Showing restarts watching and schedules a
    /// rescan; stale or changed content reloads.
    var isVisible = true {
        didSet {
            guard isVisible != oldValue, !isClosed else { return }
            if isVisible {
                guard let session else { return }
                let watcherGeneration = startWatcher(session: session)
                Task {
                    await repositoryChanged(session: session, watcherGeneration: watcherGeneration, changes: [.rescan])
                }
            } else {
                if let session { stopWatcher(session: session) }
                if diffLoader.cancelActiveWork() { diffStale = true }
            }
        }
    }

    /// A diff load was skipped or cancelled while hidden and must run on becoming visible.
    private(set) var diffStale = false
    /// What the running or last changeset load was asked to show; nil while a file is shown.
    private var changesetRequest: ChangesetRequest?

    /// What the sidebar is showing: the working tree, or one previous commit.
    private(set) var scope: DiffScope = .workingTree
    /// The selected commit's display details, kept whether or not it is still in the
    /// loaded page: a branch switch or a page reset can drop it from `history`, and the
    /// picker still has to label and tick the thing the user chose.
    private(set) var selectedCommit: CommitSummary?
    private(set) var history = CommitHistory()
    /// Where HEAD points, or nil until the first read returns: nil shows no branch, not a wrong one.
    private(set) var headState: HeadState?
    /// The local branches the picker lists, read with `headState` on the same ticket.
    private(set) var branches: [LocalBranch] = []
    /// How the last paired HEAD + branch read went, so the picker can tell unread from empty.
    private(set) var branchReadStatus: BranchReadStatus = .unread
    /// The branch names the picker's menu lists, in the order they were read.
    var localBranches: [String] { branches.map(\.name) }
    /// The list's entry for the branch HEAD is on, or nil when HEAD is detached, unread, or
    /// the branch is missing from the list.
    var currentBranch: LocalBranch? { branches.first { $0.name == currentBranchName } }
    /// True while a branch switch is queued, running, or refreshing repository state.
    private(set) var isSwitchingBranch = false
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
    /// The last working-tree read threw and nothing has replaced its list since: an
    /// empty `files` then means unread, not clean.
    private(set) var listReadFailed = false
    /// The rows to select again once the new list arrives. Held here rather than after the
    /// scope task's own `refresh`, which may be superseded by a watcher refresh that
    /// publishes the files instead.
    private var pendingReselections: [PendingSelection] = []
    /// Set when a window or a scope is about to show its first list, and consumed by
    /// whichever refresh publishes one, for the same reason as `pendingReselect`.
    private var pendingAllChanges = false

    /// The commit-message draft; the reader's own edits bump its revision, applied
    /// defaults do not.
    ///
    /// The setter is the reader's path (the editor, tests), so it bumps `commitDraftRevision`.
    /// A real change while the model is writing means the reader has taken over: generation
    /// is cancelled and what it streamed stays. The equality check ignores SwiftUI's
    /// `TextEditor` writing an unchanged value back.
    /// A defaults read writes `storedCommitMessage` directly, the way `applySelection`
    /// bypasses the `selection` setter, so automatic text never counts as an edit.
    var commitMessage: String {
        get { storedCommitMessage }
        set {
            if isGeneratingCommitMessage, newValue != storedCommitMessage { cancelCommitMessageGeneration() }
            storedCommitMessage = newValue
            commitDraftRevision += 1
        }
    }
    private var storedCommitMessage = ""
    /// Bumped by every reader write to `commitMessage`, so a commit can tell whether the
    /// draft was edited while git ran. Same idea as `selectionRevision`.
    private(set) var commitDraftRevision = 0
    /// git's suggestion (merge, squash, template) and whether a merge is in progress.
    private(set) var commitDefaults = CommitDefaults.none
    /// Last automatically applied message, used to preserve edited drafts.
    private var lastAppliedDefaultMessage: String?
    /// A commit is queued or running.
    private(set) var isCommitting = false
    /// The commit sheet is up. Drives the presentation the way `errorMessage` drives the alert.
    var isCommitSheetPresented = false
    /// The commit picker popover is up. Also cleared by SwiftUI when a click outside closes it.
    var isCommitPickerPresented = false
    /// The branch picker popover is up, on the same terms as the commit picker's flag.
    var isBranchPickerPresented = false
    /// A commit message is being written by the model.
    private(set) var isGeneratingCommitMessage = false
    /// Why the last generation stopped, for the sheet's caption. Cleared when another
    /// starts and when one is cancelled.
    private(set) var commitGenerationError: String?

    /// How many commits a page holds, and how many `Load More` adds.
    static let commitPageSize = 50

    /// Called after every refresh that publishes `files`, whether or not the list changed.
    /// `inputsChanged` is whether the id set or any file's fingerprint moved since the
    /// previous list.
    @ObservationIgnored var onRefreshPublished: (@MainActor (WindowState, RefreshCause, _ inputsChanged: Bool) -> Void)?

    /// Index into the current document's change blocks, for next/previous navigation, and
    /// the row the panes should bring into view. Written by `applySelection`, which resets
    /// both when the pane's content changes, and by `WindowState+Navigation`. Nothing else
    /// should write them; they are `var` only because that extension is in another file.
    var currentChangeIndex: Int?
    var scrollTarget: ScrollTarget?

    private let watchRepository: WatcherFactory
    private var initialRefresh: Task<Void, Never>?
    /// Writes the commit message the sheet's Generate button asks for.
    private let commitMessageGenerator: any CommitMessageGenerator

    init(
        preferences: Preferences, cache: DifftCache, resultCache: DiffResultCache = DiffResultCache(),
        commitMessageGenerator: any CommitMessageGenerator = FoundationModelsCommitMessageGenerator(),
        watchRepository: @escaping WatcherFactory
    ) {
        self.preferences = preferences
        self.commitMessageGenerator = commitMessageGenerator
        self.watchRepository = watchRepository
        diffLoader = DiffLoader(cache: cache, resultCache: resultCache)
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
        // A window adopted hidden gets its watcher when shown.
        if isVisible { startWatcher(session: session) }
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
        if let session { cancelLineStats(session: session) }
        session?.commitDefaultsGeneration += 1
        session?.commitDefaultsTask?.cancel()
        session?.commitGenerationTask?.cancel()
        isGeneratingCommitMessage = false
        isCommitSheetPresented = false
        isCommitPickerPresented = false
        isBranchPickerPresented = false
        session?.historySerial += 1
        session?.historyTask?.cancel()
        session?.headStateCheckSerial += 1
        if let session { stopWatcher(session: session) }
        diffLoader.cancelActiveWork()
        isLoading = false
    }

    /// Starts a watcher for `session` and returns the generation its callbacks must match.
    @discardableResult
    private func startWatcher(session: RepoSession) -> Int {
        session.watcherGeneration += 1
        let watcherGeneration = session.watcherGeneration
        let watcher = watchRepository(session.root) { [weak self, weak session] changes in
            guard let self, let session else { return }
            Task {
                await self.repositoryChanged(session: session, watcherGeneration: watcherGeneration, changes: changes)
            }
        }
        // A fresh watcher keeps the template the last defaults read found.
        if case let .configured(path) = session.templateDependency {
            watcher?.setDependencies([path])
        }
        session.watcher = watcher
        return watcherGeneration
    }

    /// Invalidates callbacks, stops watching, and clears pending changes.
    private func stopWatcher(session: RepoSession) {
        session.watcherGeneration += 1
        session.watcher?.stop()
        session.watcher = nil
        session.watcherRefreshPending = nil
    }

    // MARK: - Refreshing

    func refresh() async {
        guard let session else { return }
        // ⌘R re-reads everything, including a commit's files: the user asked.
        await refresh(session: session, cause: .manual)
        refreshHistory(session: session)
        await refreshHeadState(session: session)
    }

    /// Something under `.git` or in the working tree changed, per the watcher of
    /// `watcherGeneration`. One refresh runs at a time; ticks during it merge into one
    /// follow-up carrying their watcher's generation. A hidden window has no watcher,
    /// so showing delivers one `[.rescan]`.
    private func repositoryChanged(session: RepoSession, watcherGeneration: Int, changes: Set<RepoChange>) async {
        guard session === self.session, !isClosed, watcherGeneration == session.watcherGeneration else { return }
        if session.watcherRefreshRunning {
            // Merge with a pending tick of the same generation; a pending tick from a
            // stopped watcher is replaced, its work covered by the rescan that follows a restart.
            if var pending = session.watcherRefreshPending, pending.generation == watcherGeneration {
                pending.changes.formUnion(changes)
                session.watcherRefreshPending = pending
            } else {
                session.watcherRefreshPending = (watcherGeneration, changes)
            }
            return
        }
        session.watcherRefreshRunning = true
        defer { session.watcherRefreshRunning = false }
        await runWatcherRefresh(session: session, watcherGeneration: watcherGeneration, changes: changes)
        // The follow-up runs on the pending tick's own generation, so a rescan delivered
        // by a restart while this refresh ran is not lost, and a tick from a watcher
        // stopped meanwhile is dropped.
        while let pending = session.watcherRefreshPending, session === self.session, !isClosed,
            pending.generation == session.watcherGeneration
        {
            session.watcherRefreshPending = nil
            await runWatcherRefresh(session: session, watcherGeneration: pending.generation, changes: pending.changes)
        }
        session.watcherRefreshPending = nil
    }

    /// Routes `changes` to the reads they can invalidate. In commit scope only repository
    /// metadata is refreshed: a commit's contents cannot change, and re-reading them on
    /// every keystroke in another editor would redo alignment and highlighting for nothing.
    private func runWatcherRefresh(session: RepoSession, watcherGeneration: Int, changes: Set<RepoChange>) async {
        if changes.contains(.configuration) || changes.contains(.rescan) {
            session.configurationRevision += 1
            // The configuration may have gained a template; until the read below says,
            // a worktree write has to be assumed to touch it.
            session.templateDependency = .unknown
        }
        let work = RefreshRouting.work(for: changes, scope: scope, template: session.templateDependency)
        // Before the first suspension, so the read's generation is settled the moment
        // the tick is accepted.
        if work.commitDefaults { startCommitDefaultsRead(session: session) }
        if work.status { await refresh(session: session, cause: .watcher, watcherGeneration: watcherGeneration) }
        guard session === self.session, !isClosed, watcherGeneration == session.watcherGeneration else { return }
        // A load skipped while hidden is still owed when the refresh could not decide
        // about it: commit scope reads no status, and a failed read publishes nothing.
        if diffStale { reloadDiff() }
        guard work.repositoryMetadata else { return }
        await reloadHistoryIfHeadMoved(session: session)
        await refreshHeadState(session: session)
    }

    /// Reloads the file list for `session`. The result is published only if the
    /// session is still current, the window is open, and no newer refresh of it has
    /// started since.
    ///
    /// Line stats are decoration and arrive separately: the list is published as soon
    /// as `status()` returns, carrying the counts still valid for each file, and a
    /// numstat read updates `files` in place when `session.lineStats` says one is needed.
    /// A failed numstat leaves its files unknown and never fails the refresh, which is
    /// driven by `status()` alone.
    func refresh(session: RepoSession, cause: RefreshCause, watcherGeneration: Int? = nil) async {
        // A watcher callback queued before its window closed: skip the read.
        guard session === self.session, !isClosed else { return }
        session.refreshSerial += 1
        let serial = session.refreshSerial
        // Started before the first suspension so the read's generation is settled the
        // moment the refresh is accepted. Independent of `status()` succeeding: the
        // defaults have their own inputs.
        if scope == .workingTree, cause.readsCommitDefaults {
            startCommitDefaultsRead(session: session)
        }
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
        // A watcher refresh whose watcher was stopped publishes nothing; the rescan that
        // follows a restart reads again.
        if let watcherGeneration, watcherGeneration != session.watcherGeneration { return }
        // The scope changed while this read was in flight; its files belong to a list
        // nobody is showing any more.
        guard scope == self.scope else { return }

        isLoadingScope = false
        switch outcome {
        case let .success(newFiles):
            listReadFailed = false
            // Taken before anything is applied: a restoration describes the list this
            // refresh is about to replace, and only this refresh can grant it.
            let pending = pendingReselections
            pendingReselections = []
            let wantsAllChanges = pendingAllChanges
            pendingAllChanges = false
            // Taken before `files` is replaced, so it describes the pane on screen.
            let keyBefore = detailIdentity
            let before = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let newByID = Dictionary(newFiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let selectionBeforeWasEmpty = storedSelection.isEmpty
            let inputsChanged =
                Set(before.keys) != Set(newByID.keys)
                || newFiles.contains {
                    DiffInputFingerprint.mayHaveChanged(before[$0.id]?.fingerprint, $0.fingerprint)
                }
            // Counts are carried over from the last finished read, never from the list
            // on screen: a cancelled read must not leave one version's counts on another's
            // content. Assigned only when something differs, so an equal tick observes nothing.
            let desired = LineStatsRequest(
                scope: scope, hideWhitespace: ignoreWhitespace,
                configurationRevision: session.configurationRevision,
                inputs: newByID.mapValues { FileInputIdentity($0.fingerprint) })
            let lastOutcome = session.lineStats.lastOutcome
            let published = newFiles.map { $0.with(lineStats: lastOutcome?.validStats(for: $0, in: desired)) }
            if published != files { files = published }
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
            // A watcher tick reloads only when what is shown may differ from the list
            // published before it: the rows moved, a shown file's inputs moved, a load is
            // owed, or the last one failed. Failed loads stay eligible for retry, but a
            // retry never cancels a replacement already in flight for the same inputs, or
            // every equal tick would restart it. A settings change reloaded the diff before
            // it started this refresh, so it reloads again only when the rows or a shown
            // file's inputs moved meanwhile — an edit that lands between that load's read
            // and this status would otherwise stay hidden behind its own new fingerprint.
            // Every other cause re-reads content that may have changed on disk.
            let identityMoved = detailIdentity != keyBefore
            let shownInputsChanged = detailIdentity.ids.contains { id in
                DiffInputFingerprint.mayHaveChanged(before[id]?.fingerprint, newByID[id]?.fingerprint)
            }
            let reload: Bool
            switch cause {
            case .watcher:
                let lastLoadFailed =
                    !diffLoader.hasActiveWork && (diffLoader.errorMessage != nil || changesetHasFailedSection)
                reload = identityMoved || shownInputsChanged || diffStale || lastLoadFailed
            case .settings:
                reload = identityMoved || shownInputsChanged
            default:
                reload = true
            }
            if reload { reloadDiff() }
            onRefreshPublished?(self, cause, inputsChanged)
            switch session.lineStats.decide(desired: desired, cause: cause) {
            case let .reuseLastOutcome(cancelActive):
                // The counts were carried over above; the superseded read has nothing to add.
                if cancelActive { session.statsTask?.cancel() }
            case .keepActive:
                break
            case let .start(token, cancelActive):
                if cancelActive { session.statsTask?.cancel() }
                session.statsTask = Task { [weak self] in
                    await self?.attachLineStats(to: newFiles, request: desired, token: token, session: session)
                }
            }
        case let .failure(error):
            if case let .commit(ref) = scope {
                // The commit itself could not be read — garbage-collected after a rebase,
                // or the repository is damaged. An empty sidebar under its name would be a
                // lie, so drop back to the working tree.
                await fallBackToWorkingTree(session: session, from: ref, error: error)
            } else {
                listReadFailed = true
                errorMessage = error.localizedDescription
                errorRaisedByRefresh = true
            }
        }
    }

    /// True when the changeset on screen has a section its load could not produce.
    private var changesetHasFailedSection: Bool {
        guard case let .changeset(document)? = diffLoader.content else { return false }
        return document.sections.contains { if case .failed = $0.outcome { return true } else { return false } }
    }

    /// Runs numstat for the request's areas and counts untracked files, then stamps the
    /// counts onto the current `files` by id. Accepted only from the active read: a
    /// superseded token records nothing, whatever refresh is newest by then. Not a
    /// publish: the list itself did not change.
    private func attachLineStats(
        to newFiles: [ChangedFile], request: LineStatsRequest, token: Int, session: RepoSession
    ) async {
        let client = session.client
        let ignoreWhitespace = request.hideWhitespace
        // The working tree's two areas are independent processes and stay concurrent;
        // a commit scope has a single area.
        let numstat = await withTaskGroup(of: (ChangedFile.Area, [NumstatEntry]?).self) { group in
            for area in request.scope.areas {
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
        var results: [ChangedFile.ID: LineStatsResult] = [:]
        for file in joined {
            results[file.id] =
                switch file.kind {
                case .unmerged: .unavailable
                case .untracked: file.lineStats.map { .available($0) } ?? .failed
                default:
                    numstat[file.area] == nil
                        ? .failed : .available(file.lineStats ?? .counted(added: 0, deleted: 0))
                }
        }
        let outcome = LineStatsOutcome(request: request, results: results)
        guard !Task.isCancelled, session === self.session, !isClosed, session.lineStats.record(outcome, token: token)
        else { return }
        files = files.map { file in results[file.id].map { file.with(lineStats: $0.lineStats) } ?? file }
    }

    /// Stops the active line-stats read, for a window or a scope that no longer wants it.
    private func cancelLineStats(session: RepoSession) {
        session.statsTask?.cancel()
        session.statsTask = nil
        _ = session.lineStats.invalidateActive()
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
            loadChangeset(sidebarRows)
        case .files:
            loadChangeset(selectedFiles)
        case .file, .nothing:
            // `selectedFile` is nil for `.nothing`, and for a file that has left the list;
            // either way the loader is told to show nothing, which also cancels its work.
            changesetRequest = nil
            diffLoader.load(file: selectedFile, client: session?.client, hideWhitespace: preferences.hideWhitespace)
        }
    }

    /// Loads `files` as one changeset. A reload of the view already on screen keeps its
    /// document until the replacement is whole; a new view starts from empty.
    private func loadChangeset(_ files: [ChangedFile]) {
        let request = ChangesetRequest(identity: detailIdentity)
        diffLoader.load(
            changeset: files, client: session?.client, hideWhitespace: preferences.hideWhitespace,
            foldOptions: preferences.foldOptions, preserveCurrentContent: request.isReload(of: changesetRequest))
        changesetRequest = request
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

    /// The picker's choice: a commit is looked up in `selectableCommits`, and an unknown
    /// ref is ignored.
    func select(scope newScope: DiffScope) {
        switch newScope {
        case .workingTree:
            selectWorkingTree()
        case let .commit(ref):
            guard let commit = selectableCommits.first(where: { $0.ref == ref }) else { return }
            select(commit: commit)
        }
    }

    /// The loaded page, plus the selected commit when it is not in it: a branch switch or
    /// a page reset can drop it, and the picker still has to tick what is on screen.
    var selectableCommits: [CommitSummary] {
        let page = history.commits
        guard let selected = selectedCommit, !page.contains(where: { $0.ref == selected.ref }) else { return page }
        return [selected] + page
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
        cancelLineStats(session: session)

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

    /// The picker's Retry: the same `commitLimit`, so a failed Load More never grows the request.
    func retryHistoryLoad() {
        guard let session, !isClosed, !isLoadingHistory, historyErrorMessage != nil else { return }
        // Read HEAD again: the last good history may belong to another branch.
        startHistoryLoad(session: session, source: .currentHead)
    }

    /// Reloads the commit list only when HEAD has moved since the page was read. One
    /// `rev-parse` per watcher tick, instead of a full log on every edit to the tree.
    private func reloadHistoryIfHeadMoved(session: RepoSession) async {
        // Reached after awaits too: a window closed meanwhile must start no process.
        guard session === self.session, !isClosed else { return }
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

    /// Re-reads where HEAD points and the local branch list, on its own serial so a
    /// commit-list load cannot cancel it or be cancelled.
    private func refreshHeadState(session: RepoSession) async {
        // A watcher callback queued before its window closed: skip the read.
        guard session === self.session, !isClosed else { return }
        session.headStateCheckSerial += 1
        let ticket = session.headStateCheckSerial
        // A failure leaves the last known pair on show: the next tick reads again, and
        // stale beats blank. Nothing is published until both reads are in, so the picker
        // never sees a HEAD the branch list has not caught up with.
        let state: HeadState
        let list: [LocalBranch]
        do {
            state = try await session.client.headState()
            // A superseded or closed request stops here rather than starting a second
            // git process for an answer nobody will publish.
            guard session === self.session, !isClosed, ticket == session.headStateCheckSerial else { return }
            list = try await session.client.localBranches()
        } catch {
            guard session === self.session, !isClosed, ticket == session.headStateCheckSerial else { return }
            branchReadStatus = .failed
            return
        }
        guard session === self.session, !isClosed, ticket == session.headStateCheckSerial else { return }
        headState = state
        branches = list
        branchReadStatus = .loaded
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
    /// Whether the commit editor can open, regardless of the draft: an open window in
    /// working-tree scope, no commit or branch switch queued or running, both pickers
    /// down, no conflict rows, something to commit (staged files, or a merge whose tree may
    /// equal HEAD).
    var canOpenCommitSheet: Bool {
        guard session != nil, !isClosed, scope == .workingTree, !isCommitting, !isSwitchingBranch,
            !isCommitPickerPresented, !isBranchPickerPresented
        else { return false }
        guard !files.contains(where: { $0.kind == .unmerged }) else { return false }
        return files.contains(where: { $0.area == .staged }) || commitDefaults.isMerging
    }

    /// `canOpenCommitSheet`, plus a non-blank message that is not a commit.template left
    /// exactly as applied, and no generation still running: a half-written message must
    /// not be committed.
    var canCommit: Bool {
        guard canOpenCommitSheet, !isGeneratingCommitMessage else { return false }
        guard !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !commitNeedsTemplateEdit
    }

    /// True when the draft exactly matches the configured template. Commit refuses it and
    /// the editor says why. An exact string comparison, not git's cleanup-aware check;
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

    /// `commit()` for a message confirmed in the sheet. Checked before the first
    /// suspension, so a defaults read that replaced an untouched suggestion while the sheet
    /// was closing cannot slip a message the reader never saw into the commit. Returns
    /// whether the draft still matched; the caller shows the changed text instead.
    func commit(confirming message: String) async -> Bool {
        guard commitMessage == message else { return false }
        await commit()
        return true
    }

    private func runCommit(message: String, revision: Int, session: RepoSession) async {
        guard session === self.session, !isClosed else { return }
        var failure: (any Error)?
        do { try await session.client.commit(message: message) } catch { failure = error }
        guard session === self.session, !isClosed else { return }
        // Whatever the reader typed while git ran, a cleared draft included, is theirs and
        // survives both outcomes. Only an unedited draft is settled here.
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

    /// Starts a defaults read for the refresh being accepted. Its own generation, not the
    /// refresh serial: a `.settings` refresh leaves a running read alone, and a read that
    /// outlives a newer one publishes nothing.
    private func startCommitDefaultsRead(session: RepoSession) {
        session.commitDefaultsGeneration += 1
        let generation = session.commitDefaultsGeneration
        session.commitDefaultsTask?.cancel()
        session.commitDefaultsTask = Task { [weak self] in
            await self?.loadCommitDefaults(session: session, generation: generation)
        }
    }

    /// Reads the suggestion and applies it while its generation is still current and the
    /// sidebar still shows the working tree. A thrown read applies nothing, so the draft
    /// keeps its last good state, but it does forget whether a template is configured.
    private func loadCommitDefaults(session: RepoSession, generation: Int) async {
        // Cancelled before it ran: skip the subprocess, not just the publish.
        guard !Task.isCancelled else { return }
        func isCurrent() -> Bool {
            !Task.isCancelled && session === self.session && !isClosed
                && generation == session.commitDefaultsGeneration && scope == .workingTree
        }
        let new: CommitDefaults
        do {
            new = try await session.client.commitDefaults()
        } catch {
            // Behind `isCurrent()` too, so an obsolete failure never overwrites a newer result.
            guard isCurrent() else { return }
            session.templateDependency = .unknown
            return
        }
        guard isCurrent() else { return }
        session.templateDependency = new.templateDependency
        if case let .configured(path) = new.templateDependency {
            session.watcher?.setDependencies([path])
        } else {
            session.watcher?.setDependencies([])
        }
        applyCommitDefaults(new)
    }

    /// The draft is untouched when it still equals what was last applied (or is empty and
    /// nothing was). Untouched → replaced by the new suggestion (nil empties it) and
    /// remembered; touched → left alone. A merge abort empties the draft, a cherry-pick
    /// fills it, and a half-written message survives every watcher tick.
    private func applyCommitDefaults(_ new: CommitDefaults) {
        commitDefaults = new
        guard storedCommitMessage == (lastAppliedDefaultMessage ?? "") else { return }
        let text = new.suggestion?.text
        storedCommitMessage = text ?? ""  // not the setter: this is not an edit
        lastAppliedDefaultMessage = text
    }

    // MARK: Generating the message

    /// Nil when the model can write a message; otherwise the one-line reason the button
    /// shows instead.
    var commitGenerationUnavailableReason: String? { commitMessageGenerator.unavailableReason }

    /// What the sheet's Generate button needs: a commit that could be made, no generation
    /// already running, and a model to run it.
    var canGenerateCommitMessage: Bool {
        canOpenCommitSheet && !isGeneratingCommitMessage && commitGenerationUnavailableReason == nil
    }

    /// Writes a message for the staged changes into the draft, a growing piece at a time.
    /// A second call while one is running does nothing.
    func generateCommitMessage() {
        guard canGenerateCommitMessage, let session else { return }
        isGeneratingCommitMessage = true  // before the first suspension: the admission guard
        commitGenerationError = nil
        session.commitGenerationTask = Task { [weak self] in
            await self?.runCommitMessageGeneration(session: session)
        }
    }

    /// Stops the generation in flight. Whatever it has written by then stays in the draft:
    /// it is text the reader has seen, and theirs to finish or clear.
    func cancelCommitMessageGeneration() {
        session?.commitGenerationTask?.cancel()
        session?.commitGenerationTask = nil
        isGeneratingCommitMessage = false
        commitGenerationError = nil
    }

    /// Streamed text bypasses the setter, whose cancel-on-edit would stop the run writing
    /// it. It still counts as the reader's: the revision moves and the last applied
    /// suggestion is forgotten, so a later defaults read leaves the draft alone even if the
    /// model reproduced that suggestion word for word.
    private func applyGeneratedText(_ text: String) {
        storedCommitMessage = text
        lastAppliedDefaultMessage = nil
        commitDraftRevision += 1
    }

    /// Reads the staged patch, then streams the model's answer into the draft.
    private func runCommitMessageGeneration(session: RepoSession) async {
        // A cancelled run was already settled by whoever cancelled it, and a newer run may
        // be up by now; only a run that ends on its own turns the flag off.
        defer { if !Task.isCancelled { isGeneratingCommitMessage = false } }
        func isCurrent() -> Bool { session === self.session && !isClosed && !Task.isCancelled }
        do {
            let patchWithStat = try await session.client.stagedPatch()
            guard isCurrent() else { return }
            // A merge whose tree already equals HEAD stages nothing: the sheet opens for
            // it, but there is no patch to describe.
            guard CommitMessagePrompt.hasPatch(patchWithStat) else {
                commitGenerationError = "No staged changes to summarize"
                return
            }
            let request = CommitMessagePrompt.Request(
                patchWithStat: patchWithStat, recentSubjects: history.commits.map(\.subject))
            for try await text in commitMessageGenerator.generate(request) {
                guard isCurrent() else { return }
                applyGeneratedText(text)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent() else { return }
            commitGenerationError = error.localizedDescription
        }
    }
}

// MARK: - Switching branches

/// Checking out another local branch from the title bar. Same file as the class so
/// `isSwitchingBranch` stays `private(set)`.
extension WindowState {
    /// Switches the working tree to `branch` on the write chain; a second call while one
    /// is queued or running does nothing, and so does choosing the branch already checked
    /// out. The scope is kept: a selected commit stays selected.
    func switchBranch(to branch: String) async {
        guard let session, !isClosed, !isSwitchingBranch, headState != .named(branch) else { return }
        isSwitchingBranch = true  // before the first suspension: the admission guard
        defer { isSwitchingBranch = false }
        await enqueueWrite(session: session) { [weak self] in
            await self?.runBranchSwitch(to: branch, session: session)
        }
    }

    private func runBranchSwitch(to branch: String, session: RepoSession) async {
        guard session === self.session, !isClosed else { return }
        var failure: (any Error)?
        do { try await session.client.switchBranch(to: branch) } catch { failure = error }
        guard session === self.session, !isClosed else { return }
        // Refresh after either outcome: a failed post-checkout hook can leave HEAD changed,
        // and the watcher ignores this process's own events. A commit's files and diff
        // cannot have changed, so commit scope skips the re-read.
        if scope == .workingTree {
            // A switch replaces the working tree wholesale, so the old list must not
            // outlive it even when the re-read fails: cleared first, the way a scope
            // change is, and the defaults with it so a stale merge suggestion cannot
            // enable Commit. The refresh reloads both.
            //
            // Restore selected paths that remain in the refreshed list; otherwise select
            // All changes. Old row positions are ignored because the branch may have
            // changed. Recorded after the setter below, which drops any pending restoration.
            let candidates: [PendingSelection] = files.compactMap { file in
                guard selection.contains(.file(file.id)) else { return nil }
                return PendingSelection(path: file.path, area: file.area, row: nil)
            }
            selection = []
            if !candidates.isEmpty { restoreSelectionAfterNextRefresh(candidates) }
            pendingAllChanges = true
            cancelLineStats(session: session)
            files = []
            isLoadingScope = true
            applyCommitDefaults(.none)
            await refresh(session: session, cause: .branchSwitch)
        }
        guard session === self.session, !isClosed else { return }
        // Reloads history only when HEAD moved or a previous read failed, and resets the
        // page when it did; two branches at one commit keep their list.
        await reloadHistoryIfHeadMoved(session: session)
        await refreshHeadState(session: session)
        guard session === self.session, !isClosed, let failure else { return }
        // After the refresh, so the news survives it.
        errorMessage = failure.localizedDescription
    }
}
