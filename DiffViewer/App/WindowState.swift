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
    let find = FindState()

    private(set) var session: RepoSession?
    private(set) var files: [ChangedFile] = []
    private(set) var isLoading = false
    private(set) var isClosed = false
    var errorMessage: String? {
        didSet {
            errorRaisedByRefresh = false
            errorIsCommitFailure = false
        }
    }
    /// True only while `errorMessage` holds a refresh's own error; a later successful
    /// refresh clears just that. Every assignment above clears it, so only the refresh
    /// failure branch, which sets it afterwards, can turn it on.
    private var errorRaisedByRefresh = false
    /// True while `errorMessage` holds a failed commit's output, so the alert can lead with
    /// the failing line. Cleared the same way; only a failed commit sets it afterwards.
    private(set) var errorIsCommitFailure = false
    /// Bumped by every user write to `selection`, so a file action can tell whether the
    /// reader changed it while git ran. Writable only here; the action extension reads it.
    private(set) var selectionRevision = 0
    private var storedSelection: Set<DiffSelection> = []

    /// The rows highlighted in the sidebar: All changes alone, any number of files, or nothing.
    ///
    /// The setter is the user's path — the List binding, a scope change, the debug hooks,
    /// tests — so it records the intent and drops whatever a file action meant to restore,
    /// which the reader has now overruled. A refresh puts the selection back by another
    /// route, `applySelection`, which does neither.
    var selection: Set<DiffSelection> {
        get { storedSelection }
        set {
            selectionRevision += 1
            pendingReselection = nil
            let normalized = Self.withoutAllChangesBesideFiles(newValue)
            if applySelection(normalized, from: detailIdentity) { reloadDiff() }
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
        find.contentUnavailable()
        return true
    }

    /// Keyboard focus. Informational for the view; nothing in the model branches on it.
    var isKey = false

    /// On screen, per AppKit's occlusion state. A hidden window starts no diff or
    /// highlight work, and its watcher only keeps `workingTreeChurn` current for the tab
    /// bar, refreshing the file list only in working-tree scope, where the churn comes from
    /// it. Showing restarts watching and schedules a rescan; stale or changed content reloads.
    var isVisible = true {
        didSet {
            guard isVisible != oldValue, !isClosed else { return }
            if isVisible {
                guard let session else { return }
                stopWatcher(session: session)
                let watcherGeneration = startWatcher(session: session)
                Task {
                    await repositoryChanged(session: session, watcherGeneration: watcherGeneration, changes: [.rescan])
                }
            } else {
                if let session {
                    // A new generation drops the visible watcher's refreshes still in flight.
                    stopWatcher(session: session)
                    startWatcher(session: session)
                }
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
    /// Every remote-tracking branch, tracked or not, published with `branches`.
    private(set) var remoteBranches: [RemoteBranch] = []
    /// How the last paired HEAD + branch read went, so the picker can tell unread from empty.
    private(set) var branchReadStatus: BranchReadStatus = .unread
    /// The branch names the picker's menu lists, in the order they were read.
    var localBranches: [String] { branches.map(\.name) }
    /// The list's entry for the branch HEAD is on, or nil when HEAD is detached, unread, or
    /// the branch is missing from the list.
    var currentBranch: LocalBranch? { branches.first { $0.name == currentBranchName } }
    /// True while a branch switch is queued, running, or refreshing repository state.
    private(set) var isSwitchingBranch = false
    private(set) var isLoadingHistory = false
    private(set) var historyErrorMessage: String?
    /// The read a history load is serving, so an identical repeat can be skipped instead
    /// of cancelling and restarting a `git log` that would produce the same answer.
    /// `ProcessRunner` does not kill the subprocess it cancels, so restarts accumulate.
    private var historyRequestInFlight: HistoryRequest?
    /// The read behind `historyErrorMessage`, so a retry can repeat a failed next page.
    /// Nil when the failure came before a revision was known.
    private var failedHistoryRequest: HistoryRequest?
    /// The commits on HEAD's branch that its remote-tracking upstream lacks, published with
    /// the branch read. Empty whenever that cannot be said.
    private(set) var unpushedCommitShas: Set<String> = []
    /// The working tree's changed files and line churn, or nil while unread or after a
    /// failed read. Kept current by every watcher tick, in any scope and while hidden.
    private(set) var workingTreeChurn: RepositoryChurn?
    /// True from a scope change until that scope's file list arrives, so an unfinished
    /// read is not drawn as a commit that changed nothing.
    private(set) var isLoadingScope = false
    /// The last working-tree read threw and nothing has replaced its list since: an
    /// empty `files` then means unread, not clean.
    private(set) var listReadFailed = false
    /// What to select once the new list arrives. Held here rather than after the write's
    /// or the branch switch's own `refresh`, which may be superseded by a watcher refresh
    /// that publishes the files instead.
    private var pendingReselection: PendingReselection?
    /// Armed on adoption, on a scope change, and by every empty list a refresh publishes;
    /// consumed by the refresh that publishes a list with rows. Held here for the same
    /// reason as `pendingReselection`.
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
    /// The latest text the model streamed into the draft, so pressing Generate again does
    /// not hand the model its own output as the reader's note.
    private var lastGeneratedMessage: String?
    /// A commit is queued or running.
    private(set) var isCommitting = false
    /// The commit sheet is up. Drives the presentation the way `errorMessage` drives the alert.
    var isCommitSheetPresented = false
    /// A destructive file action is waiting on its confirmation. A second trigger meanwhile
    /// does nothing, and the Changes menu greys out rather than queue another question.
    var isConfirmingFileAction = false
    /// The commit picker popover is up. Also cleared by SwiftUI when a click outside closes it.
    var isCommitPickerPresented = false
    /// The New Branch sheet is up. Like the pickers and the commit sheet, it opens only
    /// while none of them is.
    var isNewBranchSheetPresented = false
    /// The branch picker popover is up, on the same terms as the commit picker's flag.
    /// Opening it starts the automatic fetch behind its counts.
    var isBranchPickerPresented = false {
        didSet {
            guard isBranchPickerPresented, !oldValue else { return }
            Task { @MainActor [weak self] in await self?.fetchForBranchPicker() }
        }
    }
    /// Where the fetch round is: it drives the header's spinner and holds a pull while the
    /// remotes are listed.
    private(set) var fetchStatus: FetchStatus = .idle
    /// The remotes the running round fetches. They stay here until the round's branch read
    /// publishes, so nothing acts on counts from before the round.
    private(set) var fetchingRemotes: Set<String> = []
    /// The repository's remotes, as the last fetch round listed them.
    private(set) var remotes: [String] = []
    /// Branch name to its configured upstream remote. Unlike `upstream`, it includes
    /// branches whose upstream the fetch mapping doesn't cover.
    private(set) var configuredUpstreamRemotes: [String: String] = [:]
    /// How each remote fared in the last finished fetch round, or nil before the first.
    private(set) var lastFetchRound: FetchRound?
    /// The remote-tracking refs fetch rounds brought in, cleared by a successful switch.
    private(set) var newRemoteBranches: Set<String> = []
    /// The pull or push queued or running, and its branch, or nil when neither is.
    private(set) var activeSync: ActiveSync?
    /// A commit message is being written by the model.
    private(set) var isGeneratingCommitMessage = false
    /// Why the last generation stopped, for the sheet's caption. Cleared when another
    /// starts and when one is cancelled.
    private(set) var commitGenerationError: String?

    /// How many commits each history read asks for.
    nonisolated static let commitPageSize = 50

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
    /// The clock the fetch cooldown and the picker's fetch times are measured against;
    /// injected so tests can move it.
    let now: @MainActor () -> Date

    init(
        preferences: Preferences, cache: DifftCache, resultCache: DiffResultCache = DiffResultCache(),
        commitMessageGenerator: any CommitMessageGenerator = FoundationModelsCommitMessageGenerator(),
        now: @escaping @MainActor () -> Date = Date.init,
        watchRepository: @escaping WatcherFactory
    ) {
        self.preferences = preferences
        self.commitMessageGenerator = commitMessageGenerator
        self.now = now
        self.watchRepository = watchRepository
        diffLoader = DiffLoader(cache: cache, resultCache: resultCache)
        diffLoader.onPresentationChange = { [weak self] in
            guard let self, !isFindAvailable else { return }
            find.contentUnavailable()
        }
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
        startWatcher(session: session)
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
        isNewBranchSheetPresented = false
        session?.historySerial += 1
        session?.historyTask?.cancel()
        session?.headStateCheckSerial += 1
        if let session {
            // No further read will publish, so anyone waiting for one is let go.
            resumeBranchReadWaiters(session: session)
            stopWatcher(session: session)
        }
        diffLoader.cancelActiveWork()
        find.contentUnavailable()
        isLoading = false
    }

    /// Whether `session` still belongs to this window and the window is open. A task may
    /// still need its own cancellation or ticket check.
    func isLive(_ session: RepoSession) -> Bool {
        session === self.session && !isClosed
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
    /// follow-up carrying their watcher's generation. A hidden window's ticks only keep
    /// the churn current, so showing delivers one `[.rescan]`.
    private func repositoryChanged(session: RepoSession, watcherGeneration: Int, changes: Set<RepoChange>) async {
        guard isLive(session), watcherGeneration == session.watcherGeneration else { return }
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
        while let pending = session.watcherRefreshPending, isLive(session),
            pending.generation == session.watcherGeneration
        {
            session.watcherRefreshPending = nil
            await runWatcherRefresh(session: session, watcherGeneration: pending.generation, changes: pending.changes)
        }
        session.watcherRefreshPending = nil
    }

    /// Routes `changes` to the reads they can invalidate. In commit scope only repository
    /// metadata and the working-tree churn are refreshed: a commit's contents cannot
    /// change, and re-reading them on every keystroke in another editor would redo
    /// alignment and highlighting for nothing.
    private func runWatcherRefresh(session: RepoSession, watcherGeneration: Int, changes: Set<RepoChange>) async {
        // Before the hidden path too: `.gitattributes` can change line counts of files
        // whose fingerprints did not move, and only a new revision stops their reuse.
        if changes.contains(.configuration) || changes.contains(.rescan) {
            session.configurationRevision += 1
            // The configuration may have gained a template; until the read below says,
            // a worktree write has to be assumed to touch it.
            session.templateDependency = .unknown
        }
        // Hidden, only the tab bar's churn is wanted: the working tree's list and line
        // counts supply it, and the rescan on show redoes the rest.
        guard isVisible else {
            if scope == .workingTree {
                await refresh(session: session, cause: .watcher, watcherGeneration: watcherGeneration)
            } else {
                await refreshWorkingTreeChurn(session: session)
            }
            return
        }
        let work = RefreshRouting.work(for: changes, scope: scope, template: session.templateDependency)
        // Before the first suspension, so the read's generation is settled the moment
        // the tick is accepted.
        if work.commitDefaults { startCommitDefaultsRead(session: session) }
        if work.status {
            await refresh(session: session, cause: .watcher, watcherGeneration: watcherGeneration)
        } else if scope != .workingTree {
            // Any change can move the working tree, and the tab bar shows its churn.
            await refreshWorkingTreeChurn(session: session)
        }
        guard isLive(session), watcherGeneration == session.watcherGeneration else { return }
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
        guard isLive(session) else { return }
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
        // Outranks every churn read started before it, so none can land while this list's
        // counts are still coming; the churn itself is published later on a ticket of its own.
        if scope == .workingTree { takeWorkingTreeChurnTicket(session: session) }
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
        guard isLive(session), serial == session.refreshSerial else { return }
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
            let pending = pendingReselection
            pendingReselection = nil
            let wantsAllChanges = pendingAllChanges
            // An empty list is not a first list: it keeps the flag armed, so a repository
            // with no changes lands on All changes when its first change arrives.
            pendingAllChanges = newFiles.isEmpty
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
            let surviving = SidebarReselection.surviving(storedSelection, before: before, in: newFiles)
            applySelection(
                SidebarReselection.selection(for: pending, surviving: surviving, in: sidebarRows),
                from: keyBefore)
            // All changes is the default after a first list or an empty one. A selection a
            // refresh emptied because its files vanished from a list that still has rows stays
            // empty, which is what the restoration rule and the detail area both read.
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
                // Otherwise the churn waits for `attachLineStats`, so the tab never shows
                // a list whose lines are still being counted.
                if scope == .workingTree { publishListChurn(RepositoryChurn(published), session: session) }
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
                publishListChurn(nil, session: session)
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
            diffLoader.load(
                file: selectedFile, client: session?.client, repository: session?.root,
                hideWhitespace: preferences.hideWhitespace)
        }
    }

    /// Loads `files` as one changeset. A reload of the view already on screen keeps its
    /// document until the replacement is whole; a new view starts from empty.
    private func loadChangeset(_ files: [ChangedFile]) {
        let request = ChangesetRequest(identity: detailIdentity)
        diffLoader.load(
            changeset: files, client: session?.client, repository: session?.root,
            hideWhitespace: preferences.hideWhitespace,
            foldOptions: preferences.foldOptions, preserveCurrentContent: request.isReload(of: changesetRequest))
        changesetRequest = request
    }
}

// MARK: - Line stats

/// Reading the per-file line counts the sidebar shows beside each file.
extension WindowState {
    /// Runs numstat for the request's areas and counts untracked files, then stamps the
    /// counts onto the current `files` by id. Accepted only from the active read: a
    /// superseded token records nothing, whatever refresh is newest by then. Not a
    /// publish: the list itself did not change.
    private func attachLineStats(
        to newFiles: [ChangedFile], request: LineStatsRequest, token: Int, session: RepoSession
    ) async {
        let (joined, numstat) = await Self.joinLineStats(
            to: newFiles, areas: request.scope.areas, ignoreWhitespace: request.hideWhitespace,
            client: session.client)
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
        guard !Task.isCancelled, isLive(session), session.lineStats.record(outcome, token: token)
        else { return }
        files = files.map { file in results[file.id].map { file.with(lineStats: $0.lineStats) } ?? file }
        // The working tree's churn is published once its counts are in. A failed list read
        // since then keeps its nil: these counts belong to the list it could not replace.
        if request.scope == .workingTree, scope == .workingTree, !listReadFailed {
            publishListChurn(RepositoryChurn(files), session: session)
        }
    }

    /// Numstat for each of `areas`, joined onto `files` with untracked files counted.
    /// Returns the rows too, so a caller can tell a failed area from one without churn.
    private static func joinLineStats(
        to files: [ChangedFile], areas: [ChangedFile.Area], ignoreWhitespace: Bool, client: any RepoClient
    ) async -> (joined: [ChangedFile], numstat: [ChangedFile.Area: [NumstatEntry]]) {
        // The working tree's two areas are independent processes and stay concurrent;
        // a commit scope has a single area.
        let numstat = await withTaskGroup(of: (ChangedFile.Area, [NumstatEntry]?).self) { group in
            for area in areas {
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
        guard !Task.isCancelled else { return (files, numstat) }
        return (await LineStatsJoiner.attach(numstat: numstat, to: files, client: client), numstat)
    }

    /// Stops the active line-stats read, for a window or a scope that no longer wants it.
    private func cancelLineStats(session: RepoSession) {
        session.statsTask?.cancel()
        session.statsTask = nil
        _ = session.lineStats.invalidateActive()
    }
}

// MARK: - Working Tree churn

/// Keeping `workingTreeChurn` current for the tab bar and the commit picker's Working Tree
/// row. In working-tree scope it is the sidebar list's own total; in commit scope a
/// separate read of status and numstat supplies it.
extension WindowState {
    /// Reads the working tree's status and line counts for its churn alone. Publishes
    /// only while its session is current, the window is open and its ticket is the newest,
    /// so a late read never overwrites a newer churn. A failed status read leaves no churn
    /// rather than an old one; a failed numstat only leaves those lines out.
    private func refreshWorkingTreeChurn(session: RepoSession) async {
        guard isLive(session) else { return }
        let ticket = takeWorkingTreeChurnTicket(session: session)
        guard let status = try? await session.client.status() else {
            guard isLive(session) else { return }
            publishWorkingTreeChurn(nil, ticket: ticket, session: session)
            return
        }
        // Already outranked: skip the numstat nobody will publish.
        guard isLive(session), ticket == session.workingTreeChurnSerial else { return }
        // A clean tree has no lines to count.
        guard !status.isEmpty else {
            publishWorkingTreeChurn(RepositoryChurn(status), ticket: ticket, session: session)
            return
        }
        let (joined, _) = await Self.joinLineStats(
            to: status, areas: DiffScope.workingTree.areas, ignoreWhitespace: preferences.hideWhitespace,
            client: session.client)
        guard isLive(session) else { return }
        publishWorkingTreeChurn(RepositoryChurn(joined), ticket: ticket, session: session)
    }

    @discardableResult
    private func takeWorkingTreeChurnTicket(session: RepoSession) -> Int {
        session.workingTreeChurnSerial += 1
        return session.workingTreeChurnSerial
    }

    /// Sets the churn only for the newest ticket.
    private func publishWorkingTreeChurn(_ churn: RepositoryChurn?, ticket: Int, session: RepoSession) {
        guard ticket == session.workingTreeChurnSerial else { return }
        session.workingTreeChurnPublishedSerial = ticket
        if churn != workingTreeChurn { workingTreeChurn = churn }
    }

    /// Publishes the churn of the sidebar's working-tree list. Its ticket is taken now,
    /// not when the read started: churn reads only start in commit scope, so any still in
    /// flight is older than this list, and a line-count read kept across refreshes must
    /// not be outranked by the refresh that kept it.
    private func publishListChurn(_ churn: RepositoryChurn?, session: RepoSession) {
        publishWorkingTreeChurn(churn, ticket: takeWorkingTreeChurnTicket(session: session), session: session)
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
        /// Read HEAD first. Adoption, ⌘R and Retry, where the revision is not known yet.
        /// `retrying` is the failed read a Retry repeats if HEAD has not moved.
        case currentHead(retrying: HistoryRequest?)
        /// A read whose revision the caller already resolved, so the commits and the
        /// revision they describe come from one reading of HEAD rather than two.
        case request(HistoryRequest)
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
        // Leaving the working tree drops its unfinished status and line-count reads, so a
        // churn still waiting on either needs a read of its own.
        let churnOwed =
            scope == .workingTree
            && (workingTreeChurn == nil || session.workingTreeChurnPublishedSerial != session.workingTreeChurnSerial)

        // Nothing is remembered to restore: the new scope's list lands on All changes, a
        // better answer than hunting for the same paths in a different set of files.
        resetListForReload(session: session)
        scope = newScope
        selectedCommit = commit
        Task { [weak self] in
            await self?.refresh(session: session, cause: .scope)
        }
        if churnOwed {
            Task { [weak self] in await self?.refreshWorkingTreeChurn(session: session) }
        }
    }

    /// Asks the next refresh that publishes a file list to select according to
    /// `reselection`. The rules themselves are `SidebarReselection`.
    ///
    /// Exists because `pendingReselection` is private to the class body and the
    /// file-action extension lives in another file. Deliberately narrow: it records a
    /// wish, and whichever refresh publishes the new list decides whether it can still be
    /// granted — not always the refresh that recorded it, since a watcher refresh can
    /// overtake a branch switch or a file action.
    func restoreSelectionAfterNextRefresh(_ reselection: PendingReselection) {
        pendingReselection = reselection
    }

    /// Clears the current list and its line stats. The next refresh lands on All changes
    /// unless a reselection is registered after this call.
    private func resetListForReload(session: RepoSession) {
        selection = []
        pendingAllChanges = true
        cancelLineStats(session: session)
        files = []
        isLoadingScope = true
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
        resetListForReload(session: session)
        await refresh(session: session, cause: .scope)
        guard isLive(session), serial == session.scopeSerial else { return }
        errorMessage = "Couldn't read commit \(ref.shortSha): \(error.localizedDescription)"
    }

    // MARK: - History

    /// Resolves HEAD and loads its history: adoption and ⌘R.
    private func refreshHistory(session: RepoSession) {
        startHistoryLoad(session: session, source: .currentHead(retrying: nil))
    }

    /// Reads the next page and appends it. Ignored while a page is already loading:
    /// `ProcessRunner` does not kill a subprocess when its task is cancelled, so
    /// repeated clicks would otherwise pile up `git log` reads whose output is thrown away.
    func loadMoreCommits() {
        guard let session, !isClosed, !isLoadingHistory, history.hasMore, let revision = history.revision
        else { return }
        // Page against the revision already on show, so a checkout mid-scroll cannot
        // splice two branches' commits into one list, and the skip stays stable.
        let request = HistoryRequest(revision: revision, skip: history.commits.count, limit: Self.commitPageSize)
        startHistoryLoad(session: session, source: .request(request))
    }

    /// The picker's Retry.
    func retryHistoryLoad() {
        guard let session, !isClosed, !isLoadingHistory, historyErrorMessage != nil else { return }
        // Read HEAD again: the last good history may belong to another branch.
        startHistoryLoad(session: session, source: .currentHead(retrying: failedHistoryRequest))
    }

    /// What to read for `head`: page one, or `failed` again.
    ///
    /// A failed next page is repeated only while HEAD still names the revision on show.
    /// Once HEAD has moved, the read restarts at page one and replaces the list, so an old
    /// revision's page is never appended after a branch change.
    private func historyRequest(head: String?, retrying failed: HistoryRequest?) -> HistoryRequest {
        if let failed, failed.skip > 0, failed.revision == head, head == history.revision { return failed }
        return HistoryRequest(revision: head, skip: 0, limit: Self.commitPageSize)
    }

    /// Reloads the commit list only when HEAD has moved since the page was read. One
    /// `rev-parse` per watcher tick, instead of a full log on every edit to the tree.
    private func reloadHistoryIfHeadMoved(session: RepoSession) async {
        // Reached after awaits too: a window closed meanwhile must start no process.
        guard isLive(session) else { return }
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
        guard isLive(session), ticket == session.headCheckSerial else { return }

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
        // A different HEAD is a different branch or a new commit: page one.
        let request = historyRequest(head: head, retrying: failedHistoryRequest)
        // Several ticks can arrive while one `git log` is still running; restarting it
        // for the answer it is already fetching only burns processes.
        guard historyRequestInFlight != request else { return }
        startHistoryLoad(session: session, source: .request(request))
    }

    /// Re-reads where HEAD points and the local and remote branch lists, on its own serial
    /// so a commit-list load cannot cancel it or be cancelled.
    ///
    /// Returns whether this read published anything: a failure that publishes `.failed`
    /// counts, a superseded or closed one does not. The fetch waits on that, so a read of
    /// its own lands before it reports the counts as caught up.
    ///
    /// `round` is stored once this read holds the newest ticket: only this read or a newer
    /// one can publish after that point, so the round is never paired with branches read
    /// before its fetches ended.
    @discardableResult
    private func refreshHeadState(session: RepoSession, finishing round: PendingFetchRound? = nil) async -> Bool {
        // A watcher callback queued before its window closed: skip the read.
        guard isLive(session) else { return false }
        session.headStateCheckSerial += 1
        let ticket = session.headStateCheckSerial
        if let round { session.pendingFetchRound = round }
        // A failure leaves the last known pair on show: the next tick reads again, and
        // stale beats blank. Nothing is published until every read is in, so the picker
        // never sees a HEAD the branch lists have not caught up with. Not pushed is the
        // exception: a stale mark could outlive a push, so a failure clears it.
        let state: HeadState
        let list: [LocalBranch]
        let remoteList: [RemoteBranch]
        do {
            state = try await session.client.headState()
            // A superseded or closed request stops here rather than starting another
            // git process for an answer nobody will publish.
            guard isCurrentHeadStateRead(session: session, ticket: ticket) else { return false }
            list = try await session.client.localBranches()
            guard isCurrentHeadStateRead(session: session, ticket: ticket) else { return false }
            remoteList = try await session.client.remoteBranches()
        } catch {
            guard isCurrentHeadStateRead(session: session, ticket: ticket) else { return false }
            branchReadStatus = .failed
            if !unpushedCommitShas.isEmpty { unpushedCommitShas = [] }
            publishPendingFetchRound(session: session)
            publishedBranchRead(session: session)
            return true
        }
        guard isCurrentHeadStateRead(session: session, ticket: ticket) else { return false }
        guard let unpushed = await readUnpushedCommits(session: session, ticket: ticket, head: state, branches: list)
        else { return false }
        headState = state
        branches = list
        remoteBranches = remoteList
        if unpushed != unpushedCommitShas { unpushedCommitShas = unpushed }
        branchReadStatus = .loaded
        publishPendingFetchRound(session: session)
        publishedBranchRead(session: session)
        return true
    }

    /// Whether a branch read holding `ticket` is still the newest one for a live session.
    private func isCurrentHeadStateRead(session: RepoSession, ticket: Int) -> Bool {
        isLive(session) && ticket == session.headStateCheckSerial
    }

    /// The commits HEAD's branch has not pushed, read on the branch read's ticket. Nil
    /// when that ticket was superseded or the window closed; empty whenever it cannot be
    /// said, a failed read included, so no other branch's commits stay marked.
    private func readUnpushedCommits(
        session: RepoSession, ticket: Int, head: HeadState, branches: [LocalBranch]
    ) async -> Set<String>? {
        // Being ahead of a local branch says nothing about the remote, so only an upstream
        // under `refs/remotes/` counts.
        guard case let .named(name) = head, let branch = branches.first(where: { $0.name == name }),
            let upstream = branch.upstream, upstream.localRef.hasPrefix("refs/remotes/"),
            case let .counts(ahead, _) = upstream.tracking, ahead > 0
        else { return [] }
        do {
            // Resolved on every read, since the upstream ref can move without the branch.
            let upstreamTip = try await session.client.commitSha(of: upstream.localRef)
            guard isCurrentHeadStateRead(session: session, ticket: ticket) else { return nil }
            guard let upstreamTip else { return [] }
            let key = UnpushedCommits.Key(branch: name, tip: branch.tipSha, upstreamTip: upstreamTip)
            if let cached = session.unpushedCommits, cached.key == key { return cached.shas }
            let shas = try await session.client.unpushedCommits(tip: branch.tipSha, upstreamTip: upstreamTip)
            // Cached even when superseded: the answer is keyed by commit ids and stays true.
            session.unpushedCommits = UnpushedCommits(key: key, shas: shas)
            return isCurrentHeadStateRead(session: session, ticket: ticket) ? shas : nil
        } catch {
            return isCurrentHeadStateRead(session: session, ticket: ticket) ? [] : nil
        }
    }

    /// Records a published branch read and wakes whoever was waiting for one.
    private func publishedBranchRead(session: RepoSession) {
        session.branchReadGeneration += 1
        resumeBranchReadWaiters(session: session)
    }

    /// Resumes and clears pending branch-read waiters.
    private func resumeBranchReadWaiters(session: RepoSession) {
        let waiting = session.branchReadWaiters
        session.branchReadWaiters = []
        for continuation in waiting { continuation.resume() }
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
        failedHistoryRequest = nil
        historyRequestInFlight = if case let .request(request) = source { request } else { nil }
        session.historyTask = Task { [weak self] in
            await self?.loadHistory(session: session, serial: serial, source: source)
        }
    }

    private func loadHistory(session: RepoSession, serial: Int, source: HistorySource) async {
        func isCurrent() -> Bool {
            isLive(session) && serial == session.historySerial && !Task.isCancelled
        }

        let request: HistoryRequest
        switch source {
        case let .currentHead(retrying):
            let head: String?
            do {
                head = try await session.client.headSha()
            } catch {
                guard isCurrent() else { return }
                // The read being retried is still the one left to do.
                failHistoryLoad(error, request: retrying)
                return
            }
            guard isCurrent() else { return }
            request = historyRequest(head: head, retrying: retrying)
            historyRequestInFlight = request
        case let .request(value):
            request = value
        }

        guard let revision = request.revision else {
            // An unborn HEAD: a real, settled answer, not a failure.
            guard isCurrent() else { return }
            history = CommitHistory()
            finishHistoryLoad()
            return
        }
        do {
            // One extra tells us whether another page exists without a second query.
            let page = try await session.client.recentCommits(
                startingAt: revision, skip: request.skip, limit: request.limit + 1)
            guard isCurrent() else { return }
            // A next page is only ever asked of the revision on show, and any other load
            // supersedes it, so the list it extends is the one it was read against.
            let earlier = request.skip == 0 ? [] : history.commits
            history = CommitHistory(
                revision: revision, commits: earlier + page.prefix(request.limit), hasMore: page.count > request.limit)
            finishHistoryLoad()
        } catch {
            guard isCurrent() else { return }
            failHistoryLoad(error, request: request)
        }
    }

    private func failHistoryLoad(_ error: Error, request: HistoryRequest?) {
        historyErrorMessage = error.localizedDescription
        failedHistoryRequest = request
        finishHistoryLoad()
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
    /// working-tree scope, no commit or branch switch queued or running, both pickers and
    /// the New Branch sheet down, no conflict rows, something to commit (staged files, or a
    /// merge whose tree may equal HEAD).
    var canOpenCommitSheet: Bool {
        guard session != nil, !isClosed, scope == .workingTree, !isCommitting, !isSwitchingBranch,
            !isOtherOverlayPresented(besides: .commitSheet)
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
        guard isLive(session) else { return }
        var failure: (any Error)?
        do { try await session.client.commit(message: message) } catch { failure = error }
        guard isLive(session) else { return }
        // Whatever the reader typed while git ran, a cleared draft included, is theirs and
        // survives both outcomes. Only an unedited draft is settled here.
        if commitDraftRevision == revision {
            if failure == nil {
                storedCommitMessage = ""
                lastGeneratedMessage = nil
            } else {
                // A defaults read that landed while git ran may have replaced or emptied
                // the draft. Put the submitted message back, and count it as the reader's
                // own from now on so no later refresh can take it away. It is still no
                // note for Generate if the model wrote it: `lastGeneratedMessage` stays.
                storedCommitMessage = message
            }
            lastAppliedDefaultMessage = nil
        }
        // Refresh either way: a failing hook may have rewritten files, and the watcher
        // ignores this process's own writes.
        await refresh(session: session, cause: .commit)
        // `refresh` returns quietly for a closed window; the history load below would
        // not, and would leave `isLoadingHistory` stuck on.
        guard isLive(session) else { return }
        // History and HEAD reload because a commit moves both and nothing else on this
        // path would notice.
        refreshHistory(session: session)
        await refreshHeadState(session: session)
        guard isLive(session), let failure else { return }
        // After the refresh, so the news survives it.
        errorMessage = failure.localizedDescription
        errorIsCommitFailure = true
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
            !Task.isCancelled && isLive(session)
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
        // Read now: streaming replaces the draft.
        let note = draftNote
        let branch = currentBranchName
        session.commitGenerationTask = Task { [weak self] in
            await self?.runCommitMessageGeneration(note: note, branch: branch, session: session)
        }
    }

    /// The draft, when it is the reader's own words: not blank, not git's untouched
    /// suggestion, and not the model's last answer left as it was.
    private var draftNote: String? {
        let draft = storedCommitMessage
        guard draft != lastAppliedDefaultMessage, draft != lastGeneratedMessage else { return nil }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        lastGeneratedMessage = text
        lastAppliedDefaultMessage = nil
        commitDraftRevision += 1
    }

    /// Reads the staged patch, then streams the model's answer into the draft.
    private func runCommitMessageGeneration(note: String?, branch: String?, session: RepoSession) async {
        // A cancelled run was already settled by whoever cancelled it, and a newer run may
        // be up by now; only a run that ends on its own turns the flag off.
        defer { if !Task.isCancelled { isGeneratingCommitMessage = false } }
        func isCurrent() -> Bool { isLive(session) && !Task.isCancelled }
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
                patchWithStat: patchWithStat, recentSubjects: history.commits.map(\.subject),
                draftNote: note, branch: branch)
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

/// Checking out another local branch, a remote one as a new tracking branch, or a new
/// branch made at HEAD, from the title bar. Same file as the class so `isSwitchingBranch` stays `private(set)`.
extension WindowState {
    /// Switches the working tree to `branch` on the write chain; a second call while one
    /// is queued or running does nothing, and so does choosing the branch already checked
    /// out or the one being deleted. The scope is kept: a selected commit stays selected.
    func switchBranch(to branch: String) async {
        guard let session, !isClosed, !isSwitchingBranch, headState != .named(branch),
            activeSync != ActiveSync(branch: branch, operation: .delete)
        else { return }
        await startBranchSwitch(session: session) { client in
            try await client.switchBranch(to: branch)
        }
    }

    /// Runs `checkout` on the write chain, holding `isSwitchingBranch` until it and its
    /// re-reads finish. The flag is set before the first suspension: callers guard on it.
    private func startBranchSwitch(
        session: RepoSession, checkout: @escaping (any RepoClient) async throws -> Void
    ) async {
        isSwitchingBranch = true
        defer { isSwitchingBranch = false }
        // A run in flight would pair the old branch name with the new branch's patch.
        cancelCommitMessageGeneration()
        await enqueueWrite(session: session) { [weak self] in
            await self?.runBranchSwitch(session: session, checkout: checkout)
        }
    }

    /// `checkout` is the git call that moves HEAD; everything after it is shared.
    private func runBranchSwitch(session: RepoSession, checkout: (any RepoClient) async throws -> Void) async {
        guard isLive(session) else { return }
        let headBefore = headState
        var failure: (any Error)?
        do { try await checkout(session.client) } catch { failure = error }
        guard isLive(session) else { return }
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
            // changed. Recorded after `resetListForReload`, which drops any pending restoration.
            let candidates: [PendingSelection] = files.compactMap { file in
                guard selection.contains(.file(file.id)) else { return nil }
                return PendingSelection(path: file.path, area: file.area, row: nil)
            }
            resetListForReload(session: session)
            if !candidates.isEmpty { restoreSelectionAfterNextRefresh(.paths(candidates)) }
            applyCommitDefaults(.none)
            await refresh(session: session, cause: .branchSwitch)
        } else {
            // The commit on show is unchanged, but the working tree the tab counts is not.
            await refreshWorkingTreeChurn(session: session)
        }
        guard isLive(session) else { return }
        // Reloads history only when HEAD moved or a previous read failed, and resets the
        // page when it did; two branches at one commit keep their list.
        await reloadHistoryIfHeadMoved(session: session)
        await refreshHeadState(session: session)
        guard isLive(session) else { return }
        // A failed post-checkout hook can still have moved HEAD, and a successful checkout
        // whose re-read failed still did. A failed checkout whose re-read also failed may
        // have moved HEAD unseen; dropping the flags beats leaving stale ones.
        if failure == nil || headState != headBefore || branchReadStatus == .failed { newRemoteBranches = [] }
        guard let failure else { return }
        // After the refresh, so the news survives it.
        errorMessage = failure.localizedDescription
    }

    /// Creates `name` at HEAD and switches to it, on the same terms as `switchBranch(to:)`.
    /// The sheet has already checked the name; git still has the final say.
    func createBranch(named name: String) async {
        guard let session, !isClosed, !isSwitchingBranch else { return }
        await startBranchSwitch(session: session) { client in
            try await client.createBranch(name)
        }
    }

    /// Creates a local branch tracking `branch` and switches to it, on the same terms as
    /// `switchBranch(to:)`. A local branch of the same name is reported rather than
    /// switched to or renamed around: it may track something else entirely.
    func checkoutRemoteBranch(_ branch: RemoteBranch) async {
        guard let session, !isClosed, !isSwitchingBranch else { return }
        // Git would refuse too; this says why in words. One created since the last read
        // still reaches git, whose refusal is reported the same way.
        guard !branches.contains(where: { $0.name == branch.name }) else {
            errorMessage = branch.localNameCollisionMessage
            return
        }
        await startBranchSwitch(session: session) { client in
            try await client.checkoutTracking(branch: branch.name, trackingRef: branch.ref)
        }
    }
}

// MARK: - Remote sync

/// Updating the remote-tracking refs the branch picker's counts are read from. Same file
/// as the class so the fetch state stays `private(set)`.
extension WindowState {
    /// How long a successful fetch of a remote stands for. Reopening the picker inside it
    /// shows the last fetch instead of running another.
    static let fetchCooldown: TimeInterval = 60

    /// What asked for a fetch round.
    private enum FetchRoundKind {
        /// Opening the picker: skips remotes inside their cooldown, and stops if the picker
        /// closes before git fetch starts.
        case opening
        /// Fetch or ⌘R: every remote, however recently fetched.
        case manual
    }

    /// Opening the branch picker refreshes the remote-tracking refs its counts are read
    /// from: a round over every remote outside its cooldown.
    ///
    /// Runs on its own task rather than the write chain: a fetch updates the refs the
    /// remote's configured mappings name, independently of the worktree and index writes
    /// that chain serializes. A failure is header news, never `errorMessage`.
    func fetchForBranchPicker() async {
        await fetchRound(.opening)
    }

    /// The picker's Fetch: a round over every remote, cooldown or not.
    func fetchAllRemotes() async {
        await fetchRound(.manual)
    }

    /// Runs a round, or waits for the one already running: one round per session. A manual
    /// request still gets every remote fetched: it upgrades a round that hasn't applied the
    /// cooldown yet, and queues one follow-up behind a round whose cooldown skipped a remote.
    private func fetchRound(_ kind: FetchRoundKind) async {
        guard let session, !isClosed else { return }
        if let running = session.activeFetchRound {
            if kind == .manual {
                switch session.fetchRoundSkippedRemotes {
                case nil: session.fetchRoundUpgradedToManual = true
                case true?: return await manualRound(after: running, session: session)
                case false?: break
                }
            }
            await running.value
            return
        }
        // Re-checked here because the flag may already be false again by the time the
        // presentation's task runs.
        guard kind == .manual || isBranchPickerPresented else { return }
        // A pull or push is about to move the same counts; let it publish them.
        guard activeSync == nil else { return }
        fetchStatus = .discovering
        session.fetchRoundUpgradedToManual = false
        session.fetchRoundSkippedRemotes = nil
        let round = Task { await self.runFetchRound(kind, session: session) }
        // Before the first suspension, so every later caller joins this round.
        session.activeFetchRound = round
        await round.value
    }

    /// Waits for `running` to finish, then runs a manual round, sharing the one already
    /// queued if there is one.
    private func manualRound(after running: Task<Void, Never>, session: RepoSession) async {
        if let queued = session.followUpManualRound { return await queued.value }
        let followUp = Task {
            await running.value
            // Released before the round starts, so a request that finds a round skipping
            // remotes then can't wait on this task from inside it.
            session.followUpManualRound = nil
            await self.fetchRound(.manual)
        }
        session.followUpManualRound = followUp
        await followUp.value
    }

    /// Lists the remotes, fetches them all at once, then re-reads the branches once and
    /// publishes the result with them.
    ///
    /// An opening round checks the picker is still up at every step before git fetch
    /// starts, so a dismissal stops it before it costs anything. Once the fetches run only
    /// the session is checked: a dismissal still records the outcome and refreshes the
    /// counts, while a closed window publishes nothing.
    private func runFetchRound(_ kind: FetchRoundKind, session: RepoSession) async {
        func isWanted() -> Bool {
            isLive(session)
                && (kind == .manual || session.fetchRoundUpgradedToManual || isBranchPickerPresented)
        }

        let remotes: [String]
        do {
            remotes = try await session.client.remoteNames()
        } catch {
            guard isWanted() else { return abandonFetchRound(session: session) }
            let round = FetchRound(discoveryError: error.localizedDescription)
            let pending = PendingFetchRound(round: round, before: nil, fetched: [])
            await awaitBranchRead(session: session, finishing: pending)
            return
        }
        // A failed read keeps the previous value; the fetch doesn't depend on it.
        let configured = try? await session.client.configuredUpstreamRemotes()
        guard isWanted() else { return abandonFetchRound(session: session) }
        self.remotes = remotes
        if let configured { configuredUpstreamRemotes = configured }
        // A push admitted during discovery is about to move the same counts; let it
        // publish them.
        guard activeSync == nil else { return abandonFetchRound(session: session) }

        // Decided here: a manual request that joins later gets a follow-up round if this
        // one skipped anything.
        let usesCooldown = kind == .opening && !session.fetchRoundUpgradedToManual
        var outcomes: [String: FetchRound.Outcome] = [:]
        var wanted: [String] = []
        for remote in remotes {
            if usesCooldown, let at = session.lastSuccessfulFetchAtByRemote[remote],
                now().timeIntervalSince(at) < Self.fetchCooldown
            {
                outcomes[remote] = .fetched(at: at)
            } else {
                wanted.append(remote)
            }
        }
        session.fetchRoundSkippedRemotes = !outcomes.isEmpty
        fetchingRemotes = Set(wanted)
        fetchStatus = .fetching

        // Read fresh rather than taken from the published list, which another git process
        // may have changed since: a branch that was already there must not show as new.
        var before: Set<String>?
        if !wanted.isEmpty, let list = try? await session.client.remoteBranches() {
            before = Set(list.map(\.ref))
        }
        guard isWanted() else { return abandonFetchRound(session: session) }

        // All started before the first is awaited, so they run in parallel.
        let fetches = wanted.map { remote in (remote, Task { await self.fetch(remote: remote, session: session) }) }
        var fetched: Set<String> = []
        for (remote, task) in fetches {
            switch await task.value {
            case let .success(at):
                outcomes[remote] = .fetched(at: at)
                fetched.insert(remote)
            case let .failure(error):
                outcomes[remote] = .failed(message: error.localizedDescription)
            }
        }
        // Re-read even after a failure, since a fetch can update refs before it fails.
        let pending = PendingFetchRound(round: FetchRound(outcomes: outcomes), before: before, fetched: fetched)
        await awaitBranchRead(session: session, finishing: pending)
    }

    /// Runs git fetch alone. Only a success starts a cooldown: a failure stays retryable.
    private func fetch(remote: String, session: RepoSession) async -> Result<Date, any Error> {
        do {
            try await session.client.fetch(remote: remote)
        } catch {
            return .failure(error)
        }
        let at = now()
        session.lastSuccessfulFetchAtByRemote[remote] = at
        return .success(at)
    }

    /// Releases a round that stopped before git fetch, publishing nothing.
    private func abandonFetchRound(session: RepoSession) {
        guard isLive(session) else { return }
        fetchingRemotes = []
        fetchStatus = .idle
        session.activeFetchRound = nil
    }

    /// Publishes a finished round in the same turn as the branch read that follows it. A
    /// failed read keeps the last New flags, but the outcomes still show and the remotes
    /// are released, so the sync buttons never stay disabled.
    private func publishPendingFetchRound(session: RepoSession) {
        guard let pending = session.pendingFetchRound else { return }
        session.pendingFetchRound = nil
        if branchReadStatus == .loaded {
            newRemoteBranches = NewRemoteBranches.update(
                previous: newRemoteBranches, before: pending.before, after: remoteBranches, fetched: pending.fetched)
        }
        lastFetchRound = pending.round
        fetchingRemotes = []
        fetchStatus = .idle
        session.activeFetchRound = nil
    }

    /// Starts a branch read and waits for a publication. A read superseded here waits for
    /// its replacement instead of retrying: the newest read publishes unless the window
    /// closes, which wakes the waiters too. A `round` is published by whichever read that is.
    private func awaitBranchRead(session: RepoSession, finishing round: PendingFetchRound? = nil) async {
        let before = session.branchReadGeneration
        if await refreshHeadState(session: session, finishing: round) { return }
        guard isLive(session), session.branchReadGeneration == before else { return }
        await withCheckedContinuation { session.branchReadWaiters.append($0) }
    }
}

// MARK: - Pull and push

/// Moving commits between a local branch and its upstream, from the branch picker's rows.
/// Same file as the class so `activeSync` stays `private(set)`.
extension WindowState {
    /// Brings `branch` up to date with its upstream without switching to it: `git pull`
    /// when it is checked out, otherwise a fast-forward of its ref.
    func pull(branch: String) async {
        await sync(.pull, branch: branch)
    }

    /// Sends `branch` to its upstream, fast-forward only.
    func push(branch: String) async {
        await sync(.push, branch: branch)
    }

    /// Pushes `branch`, which tracks nothing, to the same name on `remote` and makes that
    /// its upstream. Admitted on the same terms as a pull or push, and on the same chain.
    func publish(branch: String, to remote: String) async {
        guard let session, !isClosed, activeSync == nil, !isSwitchingBranch, branchReadStatus == .loaded,
            !SyncPolicy.isFetching(remote: remote, fetchStatus: fetchStatus, fetchingRemotes: fetchingRemotes)
        else { return }
        let request = PublishRequest(branch: branch, remote: remote)
        guard
            SyncPolicy.canPublish(
                request, branches: branches, remotes: remotes, configuredRemote: configuredUpstreamRemotes[branch])
        else { return }
        // Before the first suspension: the admission guard.
        activeSync = ActiveSync(branch: branch, operation: .publish)
        await enqueueWrite(session: session) { [weak self] in
            await self?.runPublish(request, session: session)
        }
    }

    /// Admits one operation at a time, and only one the counts on screen allow. Runs on
    /// the write chain, which serializes sync operations with the local writes, so
    /// revalidation and execution both see the branch state the reader acted on.
    ///
    /// A pull is refused while a fetch may still move its counts. A fetch can only take a
    /// push away, so a push waits for the round fetching its remote instead and `runSync`
    /// re-checks.
    private func sync(_ operation: SyncOperation, branch: String) async {
        guard let session, !isClosed, activeSync == nil, !isSwitchingBranch else { return }
        var isCurrent = headState == .named(branch)
        guard
            let target = SyncPolicy.target(branch: branch, readStatus: branchReadStatus, branches: branches),
            SyncPolicy.allows(operation, on: target, isCurrent: isCurrent),
            operation != .pull
                || !SyncPolicy.isFetching(
                    remote: target.destination.remote, fetchStatus: fetchStatus, fetchingRemotes: fetchingRemotes)
        else { return }
        // Before the first suspension: the admission guard. It also stops the picker
        // starting a fetch while the operation waits or runs.
        activeSync = ActiveSync(branch: branch, operation: operation)
        var requested = target.destination
        if operation == .push, fetchingRemotes.contains(target.destination.remote),
            let round = session.activeFetchRound
        {
            // Off the write chain, so a slow fetch doesn't hold up local writes. The round
            // ends once its branch read has published.
            await round.value
            guard isLive(session) else {
                activeSync = nil
                return
            }
            isCurrent = headState == .named(branch)
            guard
                let refreshed = SyncPolicy.target(branch: branch, readStatus: branchReadStatus, branches: branches),
                SyncPolicy.allows(operation, on: refreshed, isCurrent: isCurrent)
            else {
                activeSync = nil
                return
            }
            requested = refreshed.destination
        }
        await enqueueWrite(session: session) { [weak self] in
            await self?.runSync(operation, requested: requested, wasCurrent: isCurrent, session: session)
        }
    }

    /// Revalidates against the repository, runs git, and re-reads what the operation could
    /// have changed. The reservation is released on every exit, so a skipped operation
    /// leaves the buttons live again.
    private func runSync(
        _ operation: SyncOperation, requested: SyncDestination, wasCurrent: Bool, session: RepoSession
    ) async {
        defer { activeSync = nil }
        guard isLive(session) else { return }

        // The write ahead of this one may have moved HEAD or retargeted the upstream, so
        // the destination is read from the repository rather than from what the picker
        // showed. Read directly: a published read would be news for the picker before this
        // has decided whether it is acting at all.
        guard let read = await readHeadAndBranches(session: session) else { return }

        // Checked-out status decides between `git pull` and a fast-forward, so HEAD moving
        // onto or off the branch counts as a change too.
        let isCurrent = read.state == .named(requested.branch)
        let fresh = SyncPolicy.target(branch: requested.branch, readStatus: .loaded, branches: read.branches)
        guard let fresh, fresh.destination == requested, isCurrent == wasCurrent else {
            // Somewhere else entirely now: say so, because the reader asked for this.
            // Every re-read here waits for a published one: the buttons stay in their
            // running state until the counts they will be drawn from have landed.
            await awaitBranchRead(session: session)
            guard isLive(session) else { return }
            errorMessage = operation.changedBeforeStartMessage
            return
        }
        // The same destination with nothing left to do — someone else pulled, or the
        // counts were stale. The refreshed row says so; an alert would only repeat it.
        guard SyncPolicy.allows(operation, on: fresh, isCurrent: isCurrent) else {
            await awaitBranchRead(session: session)
            return
        }

        var failure: (any Error)?
        do {
            switch operation {
            case .pull where isCurrent:
                try await session.client.pull()
            case .pull:
                try await session.client.fastForward(
                    branch: requested.branch, remote: requested.remote, remoteRef: requested.remoteRef,
                    localRef: requested.localRef)
            case .push:
                try await session.client.push(
                    branch: requested.branch, to: requested.remote, remoteRef: requested.remoteRef)
            case .publish, .delete:
                // `allows` refuses both above; they run through `runPublish` and `runDelete`.
                return
            }
        } catch { failure = error }
        guard isLive(session) else { return }

        if operation == .pull, isCurrent {
            // Either outcome re-reads: a failed pull can leave conflicts, a merge in
            // progress, or an autostash put back. A commit's files cannot have changed,
            // so commit scope re-reads only the churn, as a branch switch does.
            if scope == .workingTree {
                await refresh(session: session, cause: .pull)
            } else {
                await refreshWorkingTreeChurn(session: session)
            }
            guard isLive(session) else { return }
            await reloadHistoryIfHeadMoved(session: session)
            guard isLive(session) else { return }
        }
        // A push, or a fast-forward of a branch that isn't checked out, changes no file
        // and no commit on screen: only the counts move.
        await awaitBranchRead(session: session)
        guard isLive(session), let failure else { return }
        // After the refresh, so the news survives it.
        errorMessage = failure.localizedDescription
    }

    /// HEAD and the local branches, read directly for a write revalidating its target.
    /// Nil when the session went stale or a read failed; a failure is reported.
    private func readHeadAndBranches(session: RepoSession) async -> (state: HeadState, branches: [LocalBranch])? {
        let state: HeadState
        let branches: [LocalBranch]
        do {
            state = try await session.client.headState()
            guard isLive(session) else { return nil }
            branches = try await session.client.localBranches()
        } catch {
            guard isLive(session) else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
        guard isLive(session) else { return nil }
        return (state, branches)
    }

    /// Revalidates against the repository, publishes, and re-reads the branches and the
    /// configured upstreams, which the publish writes. The reservation is released on
    /// every exit.
    private func runPublish(_ request: PublishRequest, session: RepoSession) async {
        defer { activeSync = nil }
        guard isLive(session) else { return }

        // Read directly, as `runSync` does: the branch may have gained an upstream, or its
        // remote gone, while this waited its turn.
        let list: [LocalBranch]
        let remotes: [String]
        let configured: [String: String]
        do {
            list = try await session.client.localBranches()
            guard isLive(session) else { return }
            remotes = try await session.client.remoteNames()
            guard isLive(session) else { return }
            configured = try await session.client.configuredUpstreamRemotes()
        } catch {
            guard isLive(session) else { return }
            errorMessage = error.localizedDescription
            return
        }
        guard isLive(session) else { return }

        let configuredRemote = configured[request.branch]
        guard
            SyncPolicy.canPublish(request, branches: list, remotes: remotes, configuredRemote: configuredRemote)
        else {
            // Stored after the branch read, so the row never pairs new config with old branches.
            await awaitBranchRead(session: session)
            guard isLive(session) else { return }
            self.remotes = remotes
            configuredUpstreamRemotes = configured
            if let branch = list.first(where: { $0.name == request.branch }),
                let hidden = SyncPolicy.hiddenUpstreamRemote(of: branch, configuredRemote: configuredRemote)
            {
                errorMessage = "\(request.branch) tracks \(hidden), but fetch settings don't fetch it"
            } else {
                errorMessage = SyncOperation.publish.changedBeforeStartMessage
            }
            return
        }

        var failure: (any Error)?
        do { try await session.client.publish(branch: request.branch, to: request.remote) } catch { failure = error }
        guard isLive(session) else { return }

        // Re-read after either outcome, as after a push. A failed config read keeps the
        // previous value, as the picker's own read does.
        let fresh = try? await session.client.configuredUpstreamRemotes()
        guard isLive(session) else { return }
        await awaitBranchRead(session: session)
        guard isLive(session) else { return }
        if let fresh {
            configuredUpstreamRemotes = fresh
        } else if failure == nil {
            // A successful publish wrote this config. Under a narrow fetch mapping the branch
            // reads back as tracking nothing, and without it the row would offer Publish again.
            configuredUpstreamRemotes[request.branch] = request.remote
        }
        guard let failure else { return }
        // After the refresh, so the news survives it.
        errorMessage = failure.localizedDescription
    }
}

// MARK: - Deleting gone branches

/// Deleting a branch whose upstream is gone, from its row. Same file as the class so
/// `activeSync` stays `private(set)`.
extension WindowState {
    /// Deletes `branch` as the reader confirmed it: admitted only while its row offers
    /// Delete, on the write chain, and one operation at a time with pull and push. A fetch
    /// of its remote may bring the remote branch back, so the delete waits it out.
    func deleteBranch(_ branch: LocalBranch) async {
        guard let session, !isClosed, activeSync == nil, !isSwitchingBranch, branchReadStatus == .loaded,
            Self.isDeletable(branch, in: branches, headState: headState), let upstream = branch.upstream,
            !SyncPolicy.isFetching(remote: upstream.remote, fetchStatus: fetchStatus, fetchingRemotes: fetchingRemotes)
        else { return }
        // Before the first suspension: the admission guard.
        activeSync = ActiveSync(branch: branch.name, operation: .delete)
        await enqueueWrite(session: session) { [weak self] in
            await self?.runDelete(branch, session: session)
        }
    }

    /// `list` still holds the branch as it was confirmed, same tip and same upstream, and
    /// it may be deleted. A branch recreated under the name elsewhere is another branch.
    private static func isDeletable(_ branch: LocalBranch, in list: [LocalBranch], headState: HeadState?) -> Bool {
        guard let found = list.first(where: { $0.name == branch.name }) else { return false }
        return found.tipSha == branch.tipSha && found.upstream == branch.upstream
            && SyncPolicy.canDelete(found, isCurrent: headState == .named(branch.name))
    }

    /// Revalidates against the repository, deletes, and re-reads the branches. The
    /// reservation is released on every exit.
    private func runDelete(_ branch: LocalBranch, session: RepoSession) async {
        defer { activeSync = nil }
        guard isLive(session) else { return }

        // Read directly, as `runSync` does: the branch may have moved, been checked out or
        // been recreated while this waited its turn.
        guard let read = await readHeadAndBranches(session: session) else { return }

        guard Self.isDeletable(branch, in: read.branches, headState: read.state) else {
            await awaitBranchRead(session: session)
            guard isLive(session) else { return }
            // Already gone is what the reader asked for; anything else is news.
            if read.branches.contains(where: { $0.name == branch.name }) {
                errorMessage = SyncOperation.delete.changedBeforeStartMessage
            }
            return
        }

        var failure: (any Error)?
        do { try await session.client.deleteBranch(branch.name) } catch { failure = error }
        guard isLive(session) else { return }
        await awaitBranchRead(session: session)
        guard isLive(session) else { return }
        guard let failure else {
            // Git removed the branch's config with it.
            configuredUpstreamRemotes[branch.name] = nil
            return
        }
        // After the refresh, so the news survives it.
        errorMessage = failure.localizedDescription
    }
}
