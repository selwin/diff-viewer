import AppKit
import Foundation

/// Routes every "open a repository" request to a window, tracks which window is key
/// and which are visible, owns the app-wide prefetcher, and fans preference changes
/// out to windows. Not observable: no view reads it.
///
/// Windows are the unit: one repository per window. A populated window never swaps
/// its repository; an open lands in the originating window only when that window is
/// empty, otherwise a new window is created for it. Opening a repository that is
/// already open focuses its window.
@MainActor
final class WindowCoordinator {
    typealias Discoverer = @Sendable (URL) async throws -> RepositoryDiscovery.Result

    enum Phase: Sendable { case restoring, running }

    /// Whether an open counts as the user opening something (and so touches recency).
    enum OpenPurpose: Sendable { case user, restoration }

    enum OpenOrigin: Hashable, Sendable {
        /// Cmd+O, Open Recent, or drop in a specific window.
        case window(WindowID)
        /// Finder, the Dock, or restoration: no window asked.
        case app
    }

    struct OpenRequest: Sendable {
        let url: URL
        let origin: OpenOrigin
        var purpose: OpenPurpose = .user
        /// The saved root this request restores, if any; what `settle` refers to.
        var restoreEntry: RepositoryRoot? = nil
    }

    /// A window has been asked for but has not registered its state yet.
    struct PendingWindowOpen {
        let root: RepositoryRoot
        let client: any RepoClient
        /// Upgraded to `.user` if a user request joins a restoration create.
        var purpose: OpenPurpose
        let restoreEntry: RepositoryRoot?
        /// Known once the window's accessor attaches, before its state registers.
        var windowID: WindowID?
    }

    /// The presentation the coordinator needs but does not own.
    struct Hooks {
        var createWindow: @MainActor (RepositoryRoot) -> Void
        var focusWindow: @MainActor (WindowID) -> Void
        var presentError: @MainActor (String) -> Void
    }

    let preferences: Preferences
    private let prefetcher: any Prefetching
    private let discover: Discoverer
    private let hooks: Hooks

    private(set) var phase: Phase = .restoring
    /// Every live window, populated or empty.
    private(set) var windows: [WindowID: WindowState] = [:]
    /// Populated windows only.
    private(set) var rootIndex: [RepositoryRoot: WindowID] = [:]
    /// Presentation requested, not yet registered.
    private(set) var pendingCreates: [RepositoryRoot: PendingWindowOpen] = [:]
    /// Windows that closed before their state registered; a late `.task` must not register them.
    private var closedBeforeRegistration: Set<WindowID> = []
    /// Accepted opens in order: the single representation of opening order.
    private(set) var openOrder: [RepositoryRoot] = []
    /// The key window, nil while the app is inactive. May name a window that has not registered yet.
    private(set) var keyWindowID: WindowID?
    /// The root of the last populated window that was key.
    private(set) var lastActiveRepositoryRoot: RepositoryRoot?

    /// Occlusion state by window, kept for windows that have not registered yet.
    private var visibility: [WindowID: Bool] = [:]
    /// Writes a window's scene value once it adopts a repository.
    private var sceneRootSetters: [WindowID: @MainActor (RepositoryRoot?) -> Void] = [:]
    /// Finder and Dock opens received before the first window registered.
    private var queuedAppURLs: [URL] = []
    private var hasRegisteredOnce = false

    init(
        preferences: Preferences,
        prefetcher: any Prefetching,
        discover: @escaping Discoverer = RepositoryDiscovery.discover,
        hooks: Hooks
    ) {
        self.preferences = preferences
        self.prefetcher = prefetcher
        self.discover = discover
        self.hooks = hooks
        preferences.onDiffSettingsChange = { [weak self] in
            guard let self else { return }
            for window in windows.values { window.diffSettingsChanged() }
        }
    }

    var keyWindowState: WindowState? {
        keyWindowID.flatMap { windows[$0] }
    }

    // MARK: - Opening

    /// Runs the folder chooser for `origin` and opens the result.
    func presentOpenPanel(from origin: OpenOrigin) {
        guard let url = RepositoryDiscovery.chooseFolder() else { return }
        Task { await open(OpenRequest(url: url, origin: origin)) }
    }

    /// A URL from Finder or the Dock. Queued until the first window has registered.
    func openFromApp(_ url: URL) {
        guard phase == .running else {
            queuedAppURLs.append(url)
            return
        }
        Task { await open(OpenRequest(url: url, origin: .app)) }
    }

    /// The only `await` is discovery; everything after it is synchronous, so the
    /// routing decision and its bookkeeping cannot interleave with another open.
    func open(_ request: OpenRequest) async {
        let entry = request.restoreEntry
        let discovered: RepositoryDiscovery.Result
        do {
            discovered = try await discover(request.url)
        } catch {
            if originIsGone(request.origin) {
                settle(entry)
            } else {
                if request.purpose == .user {
                    hooks.presentError("Not a git repository: \(request.url.path)\n\(error.localizedDescription)")
                }
                settleFailed(entry)
            }
            return
        }
        let (root, client) = discovered
        if let entry, entry != root {
            // The saved path now lies inside another repository: stale, not migrated.
            settleFailed(entry)
            return
        }
        if originIsGone(request.origin) {
            settle(entry)
            return
        }
        if let id = rootIndex[root] {
            hooks.focusWindow(id)
            if request.purpose == .user { preferences.noteOpened(root) }
            settle(entry)
            return
        }
        // Join the pending operation; it settles itself on registration or close.
        if pendingCreates[root] != nil {
            if request.purpose == .user { pendingCreates[root]?.purpose = .user }
            return
        }

        let originID = resolveOrigin(request.origin)
        if let originID, let window = windows[originID], window.isEmpty {
            if window.adopt(root: root, client: client) {
                accept(root)
                attach(originID, root: root, purpose: request.purpose)
                settle(entry)
            } else {
                settleFailed(entry)
            }
            return
        }
        // A new window joins the origin's group, so bring the origin forward first.
        if let originID { hooks.focusWindow(originID) }
        pendingCreates[root] = PendingWindowOpen(root: root, client: client, purpose: request.purpose, restoreEntry: entry, windowID: nil)
        accept(root)
        hooks.createWindow(root)
    }

    private func originIsGone(_ origin: OpenOrigin) -> Bool {
        if case let .window(id) = origin { return windows[id] == nil }
        return false
    }

    /// App-originated requests land in the key window if it is empty, otherwise
    /// alongside it. With no key window the last active repository's window stands
    /// in, then the first opened one; with no windows at all they create one.
    private func resolveOrigin(_ origin: OpenOrigin) -> WindowID? {
        switch origin {
        case let .window(id):
            return id
        case .app:
            if let id = keyWindowID, windows[id] != nil { return id }
            if let id = lastActiveRepositoryRoot.flatMap({ rootIndex[$0] }) { return id }
            if let id = openOrder.first.flatMap({ rootIndex[$0] }) { return id }
            return windows.keys.first
        }
    }

    /// The only place that appends to `openOrder`.
    private func accept(_ root: RepositoryRoot) {
        openOrder.append(root)
    }

    /// Binds a populated window to its root. Runs once per adoption, whether the
    /// window adopted directly or on registration of a pending create.
    private func attach(_ id: WindowID, root: RepositoryRoot, purpose: OpenPurpose) {
        rootIndex[root] = id
        sceneRootSetters[id]?(root)
        if purpose == .user { preferences.noteOpened(root) }
        // No key event will come for a window that is already key.
        if keyWindowID == id {
            lastActiveRepositoryRoot = root
            prefetch(for: id)
        }
    }

    // MARK: - Window lifecycle

    /// The window's accessor found its `NSWindow`; runs before the state registers.
    func windowDidAttach(_ id: WindowID, sceneRoot: RepositoryRoot?) {
        if let sceneRoot, pendingCreates[sceneRoot] != nil {
            pendingCreates[sceneRoot]?.windowID = id
        }
    }

    /// Registers a window's state. Idempotent by id; refused for a window that
    /// already closed. A `sceneRoot` naming a pending create adopts that repository
    /// without a second discovery.
    func register(_ state: WindowState, sceneRoot: RepositoryRoot?, setSceneRoot: @escaping @MainActor (RepositoryRoot?) -> Void = { _ in }) {
        guard !closedBeforeRegistration.contains(state.id), windows[state.id] == nil else { return }
        windows[state.id] = state
        sceneRootSetters[state.id] = setSceneRoot
        state.onRefreshPublished = { [weak self] state, _ in
            self?.refreshPublished(state)
        }
        // Reconcile with notifications that arrived before registration.
        if let visible = visibility[state.id] { state.isVisible = visible }
        state.isKey = keyWindowID == state.id

        if let sceneRoot, let pending = pendingCreates.removeValue(forKey: sceneRoot) {
            if state.adopt(root: pending.root, client: pending.client) {
                attach(state.id, root: pending.root, purpose: pending.purpose)
                settle(pending.restoreEntry)
            } else {
                openOrder.removeAll { $0 == pending.root }
                settleFailed(pending.restoreEntry)
            }
        } else if sceneRoot != nil {
            // A scene value nobody asked for (restoration is disabled): stay empty.
            setSceneRoot(nil)
        }

        if !hasRegisteredOnce {
            hasRegisteredOnce = true
            restoreIfNeeded(initialWindow: state.id)
        }
    }

    /// The `NSWindow` is closing. A registered window is removed; a window that was
    /// created for a pending open but never registered releases its reservation.
    func windowWillClose(_ id: WindowID, sceneRoot: RepositoryRoot?) {
        if windows[id] != nil {
            remove(id)
            return
        }
        if keyWindowID == id { windowDidResignKey(id) }
        visibility[id] = nil
        closedBeforeRegistration.insert(id)
        let match = pendingCreates.first { $0.key == sceneRoot || $0.value.windowID == id }
        guard let (root, pending) = match else { return }
        pendingCreates[root] = nil
        openOrder.removeAll { $0 == root }
        settleFailed(pending.restoreEntry)
    }

    func remove(_ id: WindowID) {
        guard let state = windows[id] else { return }
        if keyWindowID == id {
            deactivate(id)
            keyWindowID = nil
        }
        windows[id] = nil
        state.close()
        if let root = state.repositoryRoot {
            if rootIndex[root] == id { rootIndex[root] = nil }
            openOrder.removeAll { $0 == root }
        }
        sceneRootSetters[id] = nil
        visibility[id] = nil
    }

    // MARK: - Key and visibility

    func windowDidBecomeKey(_ id: WindowID) {
        guard keyWindowID != id else { return }
        if let previous = keyWindowID { deactivate(previous) }
        keyWindowID = id
        guard let window = windows[id] else { return }
        window.isKey = true
        if let root = window.repositoryRoot {
            lastActiveRepositoryRoot = root
            prefetch(for: id)
        }
    }

    func windowDidResignKey(_ id: WindowID) {
        guard keyWindowID == id else { return }
        deactivate(id)
        keyWindowID = nil
    }

    func windowOcclusionChanged(_ id: WindowID, visible: Bool) {
        visibility[id] = visible
        windows[id]?.isVisible = visible
    }

    /// Cancels the queued prefetch, which only ever belongs to the key window.
    private func deactivate(_ id: WindowID) {
        prefetcher.cancel()
        windows[id]?.isKey = false
    }

    private func prefetch(for id: WindowID) {
        guard let window = windows[id], let client = window.session?.client else { return }
        prefetcher.prefetch(files: window.filesToWarm, client: client)
    }

    private func refreshPublished(_ state: WindowState) {
        if state.id == keyWindowID { prefetch(for: state.id) }
    }

    // MARK: - Restoration

    /// Runs once, on the first registration. Until session restoration lands this
    /// reopens the most recent repository into the initial window, unless Finder
    /// already asked for something.
    private func restoreIfNeeded(initialWindow id: WindowID) {
        phase = .running
        let queued = queuedAppURLs
        queuedAppURLs = []
        if !queued.isEmpty {
            for url in queued {
                Task { await open(OpenRequest(url: url, origin: .window(id))) }
            }
            return
        }
        if let last = preferences.recentRepositoryRoots.first {
            Task { await open(OpenRequest(url: last.url, origin: .window(id), purpose: .restoration)) }
        }
    }

    private func settle(_ entry: RepositoryRoot?) {}

    private func settleFailed(_ entry: RepositoryRoot?) {}

    // MARK: - Presentation defaults

    static func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not open repository"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
