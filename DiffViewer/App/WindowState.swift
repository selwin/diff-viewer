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
    let root: URL
    let client: any RepoClient
    var watcher: (any RepoWatching)?
    /// Incremented per refresh; only the latest may publish.
    var refreshSerial = 0

    init(root: URL, client: any RepoClient) {
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
}

/// Everything one window holds for its repository: the session, the changed-file
/// list, the selection, the diff loader, and change navigation.
///
/// A window adopts a repository once and keeps it until it closes. App-wide concerns
/// (preferences, the difft cache, prefetching) are injected or driven from outside.
@MainActor
@Observable
final class WindowState {
    typealias WatcherFactory = @MainActor (URL, @escaping @MainActor () -> Void) -> (any RepoWatching)?

    let id = WindowID()
    let preferences: Preferences
    let diffLoader: DiffLoader

    private(set) var session: RepoSession?
    var repositoryRoot: URL? { session?.root }
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

    var repoName: String { repositoryRoot?.lastPathComponent ?? "DiffViewer" }

    // MARK: - Lifecycle

    /// Installs `root` as this window's repository and starts its first refresh.
    /// One-time: returns `false` and changes nothing if the window is already
    /// populated or closed.
    @discardableResult
    func adopt(root: URL, client: any RepoClient) -> Bool {
        guard session == nil, !isClosed else { return false }
        let session = RepoSession(root: root, client: client)
        session.watcher = watchRepository(root) { [weak self, weak session] in
            guard let self, let session else { return }
            Task { await self.refresh(session: session, cause: .watcher) }
        }
        self.session = session
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
    func refresh(session: RepoSession, cause: RefreshCause) async {
        // A watcher callback queued before its window closed: skip the read.
        guard session === self.session, !isClosed else { return }
        session.refreshSerial += 1
        let serial = session.refreshSerial
        let outcome: Result<[ChangedFile], Error>
        do {
            outcome = .success(try await session.client.status())
        } catch {
            outcome = .failure(error)
        }
        guard session === self.session, !isClosed, serial == session.refreshSerial else { return }

        switch outcome {
        case let .success(newFiles):
            files = newFiles
            if let selectedFileID, !newFiles.contains(where: { $0.id == selectedFileID }) {
                self.selectedFileID = nil
            }
            errorMessage = nil
            reloadDiff()
            onRefreshPublished?(self, cause)
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Diff

    /// A setting that changes diff content changed.
    func diffSettingsChanged() {
        reloadDiff()
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
