import AppKit
import Foundation

/// Routes every "open a repository" request to a window, tracks which window is key
/// and which are visible, owns the app-wide prefetcher, fans preference changes out to
/// windows, and persists the set of open repositories across launches. Not
/// observable: no view reads it.
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

    let preferences: Preferences
    private let prefetcher: any Prefetching
    private let discover: Discoverer
    private let hooks: Hooks
    private let defaults: UserDefaults

    private(set) var phase: Phase = .restoring
    /// Set by `applicationWillTerminate`; after it, nothing rewrites the session.
    private(set) var isTerminating = false
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
    /// Finder and Dock opens received while restoring; opened once the batch settles.
    /// URLs the app was launched with arrive here before launch finishes.
    private var queuedAppURLs: [URL] = []
    private var launchFinished = false

    /// The saved session, read before any view exists. `restoreList` is the saved
    /// order; the other sets track how each entry was accounted for during startup.
    private(set) var restoreList: [RepositoryRoot] = []
    private(set) var restoreActive: RepositoryRoot?
    /// The path each saved entry was persisted under, unresolved. `RepositoryRoot`
    /// resolves symlinks, so a saved path that became a symlink to another repository
    /// takes on that repository's identity before it is even opened; the raw path is
    /// what discovery is asked for, what a quit mid-restore writes back, and what the
    /// stale check inspects.
    private var savedPaths: [RepositoryRoot: String] = [:]
    private var savedActivePath: String?
    private var restoreOutstanding: Set<RepositoryRoot> = []
    private var restoreFailed: Set<RepositoryRoot> = []
    /// Saved roots whose window the user closed during startup.
    private var restoreClosed: Set<RepositoryRoot> = []
    private var restoreStarted = false

    init(
        preferences: Preferences,
        prefetcher: any Prefetching,
        defaults: UserDefaults = .standard,
        discover: @escaping Discoverer = RepositoryDiscovery.discover,
        hooks: Hooks
    ) {
        self.preferences = preferences
        self.prefetcher = prefetcher
        self.defaults = defaults
        self.discover = discover
        self.hooks = hooks
        for path in defaults.stringArray(forKey: SessionKeys.openRoots) ?? [] {
            let root = RepositoryRoot(path: path)
            restoreList.append(root)
            if savedPaths[root] == nil { savedPaths[root] = path }
        }
        savedActivePath = defaults.string(forKey: SessionKeys.lastActive)
        restoreActive = savedActivePath.map { RepositoryRoot(path: $0) }
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

    /// A URL from Finder or the Dock. Queued while the saved session is restoring;
    /// URLs the app was launched with replace the saved session for this launch.
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
        if let entry, isStale(entry, discovered: root) {
            // The saved path now lies inside another repository, or is a symlink to
            // one: stale, not migrated.
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
        if let pending = pendingCreates[root] {
            if request.purpose == .user { pendingCreates[root]?.purpose = .user }
            if let entry {
                if pending.restoreEntry == nil {
                    // A user started this create; the pending window now restores `entry`.
                    pendingCreates[root]?.restoreEntry = entry
                } else if pending.restoreEntry != entry {
                    settle(entry)
                }
            }
            return
        }

        let originID = resolveOrigin(request.origin)
        if request.canAdoptEmptyOrigin, let originID, let window = windows[originID], window.isEmpty {
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
        pendingCreates[root] = PendingWindowOpen(
            root: root, client: client, purpose: request.purpose, restoreEntry: entry, windowID: nil)
        accept(root)
        hooks.createWindow(root)
    }

    /// A saved entry is stale when its path no longer discovers the repository it
    /// was persisted for: the discovered root differs (the path now lies inside
    /// another repository), or the persisted path has itself become a symlink.
    /// Persisted paths are canonical, so a symlink there means the filesystem changed
    /// under the session and the link's target is not what the user had open.
    private func isStale(_ entry: RepositoryRoot, discovered root: RepositoryRoot) -> Bool {
        if root != entry { return true }
        guard let path = savedPaths[entry] else { return false }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
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

    /// The only place that adds to `openOrder`. While restoring, a saved root takes
    /// its saved position, ahead of anything the user opened meanwhile, so the
    /// restored order never depends on which discovery finished first; everything
    /// else appends.
    private func accept(_ root: RepositoryRoot) {
        if phase == .restoring, let saved = restoreList.firstIndex(of: root) {
            let insertAt =
                openOrder.firstIndex { candidate in
                    guard let other = restoreList.firstIndex(of: candidate) else { return true }
                    return other > saved
                } ?? openOrder.endIndex
            openOrder.insert(root, at: insertAt)
        } else {
            openOrder.append(root)
        }
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
        updateTitles()
        persist()
    }

    /// Recomputes every populated window's title so repositories with the same name
    /// stay distinguishable. Called after every attach and removal.
    private func updateTitles() {
        for (root, title) in WindowTitles.assign(Array(rootIndex.keys)) {
            windows[rootIndex[root]!]?.title = title
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
    /// already closed and for a state that is closed. A `sceneRoot` naming a pending
    /// create adopts that repository without a second discovery.
    func register(
        _ state: WindowState, sceneRoot: RepositoryRoot?,
        setSceneRoot: @escaping @MainActor (RepositoryRoot?) -> Void = { _ in }
    ) {
        guard !closedBeforeRegistration.contains(state.id), !state.isClosed, windows[state.id] == nil else { return }
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

        restoreIfNeeded()
    }

    /// AppKit has finished launching. URLs the app was launched with have been
    /// delivered by now, so whether this launch restores the saved session or shows
    /// what was opened can be decided.
    func applicationDidFinishLaunching() {
        launchFinished = true
        restoreIfNeeded()
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
        if let entry = pending.restoreEntry { restoreClosed.insert(entry) }
        settleFailed(pending.restoreEntry)
        persist()
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
            if phase == .restoring, restoreList.contains(root) { restoreClosed.insert(root) }
        }
        sceneRootSetters[id] = nil
        visibility[id] = nil
        updateTitles()
        persist()
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
            persist()
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

    // MARK: - Session persistence

    /// Writes the live session. Nothing is written while restoring (the saved
    /// session is the truth until the batch settles) or after termination began.
    private func persist() {
        guard phase == .running, !isTerminating else { return }
        writeSession(openOrder, active: lastActiveRepositoryRoot)
    }

    private func writeSession(_ roots: [RepositoryRoot], active: RepositoryRoot?) {
        writeSession(paths: roots.map(\.path), activePath: active?.path)
    }

    private func writeSession(paths: [String], activePath: String?) {
        defaults.set(paths, forKey: SessionKeys.openRoots)
        if let activePath {
            defaults.set(activePath, forKey: SessionKeys.lastActive)
        } else {
            defaults.removeObject(forKey: SessionKeys.lastActive)
        }
    }

    /// Writes the one snapshot a quit leaves behind. While running that is the live
    /// session. While still restoring it is the saved list minus what failed and what
    /// the user closed, with the saved active root, so quitting mid-restore never
    /// replaces the session with the subset that happened to have registered. Window
    /// closes AppKit performs afterwards do not persist.
    func applicationWillTerminate() {
        guard !isTerminating else { return }
        isTerminating = true
        switch phase {
        case .running:
            writeSession(openOrder, active: lastActiveRepositoryRoot)
        case .restoring:
            let kept = restoreList.filter { !restoreFailed.contains($0) && !restoreClosed.contains($0) }
            writeSession(paths: kept.map { savedPaths[$0] ?? $0.path }, activePath: savedActivePath)
        }
    }

    // MARK: - Restoration

    /// Runs once, as soon as a window has registered and launch has finished. The
    /// empty window that exists then (the launch window) is the adoption target for
    /// the first saved repository whether or not it is key yet. URLs the app was
    /// launched with replace the saved set for this launch: they open into that
    /// window instead, and the saved roots stay only in the recent list.
    private func restoreIfNeeded() {
        guard !restoreStarted, launchFinished, let initial = restorationTargetWindow else { return }
        restoreStarted = true
        let id = initial.id
        let queued = queuedAppURLs
        queuedAppURLs = []
        if !queued.isEmpty {
            restoreList = []
            restoreActive = nil
            phase = .running
            for url in queued {
                Task { await open(OpenRequest(url: url, origin: .window(id))) }
            }
            return
        }
        var seen: Set<RepositoryRoot> = []
        restoreList = restoreList.filter { seen.insert($0).inserted }
        // Every entry is outstanding before any discovery starts, so an early
        // completion cannot settle the batch.
        restoreOutstanding = Set(restoreList)
        guard !restoreList.isEmpty else {
            finishRestorationIfSettled()
            return
        }
        // One at a time, in saved order: windows are presented in the order their
        // opens complete, and the tab strip shows that order.
        let requests = restoreList.enumerated().map { index, root in
            OpenRequest(
                url: URL(fileURLWithPath: savedPaths[root] ?? root.path, isDirectory: true),
                origin: index == 0 ? .window(id) : .app,
                purpose: .restoration,
                restoreEntry: root
            )
        }
        Task {
            for request in requests { await open(request) }
        }
    }

    /// The window restoration adopts into: the key window if it is empty, else any
    /// empty registered window. At launch there is exactly one.
    private var restorationTargetWindow: WindowState? {
        if let key = keyWindowState, key.isEmpty { return key }
        return windows.values.first { $0.isEmpty }
    }

    /// The saved `entry` has been accounted for: adopted, focused, registered, or
    /// its window closed. Discovery never changes which entry is settled.
    private func settle(_ entry: RepositoryRoot?) {
        guard let entry, phase == .restoring else { return }
        restoreOutstanding.remove(entry)
        finishRestorationIfSettled()
    }

    /// The saved `entry` could not be restored (discovery failed, the path now lies
    /// in another repository, or its window closed before registering): dropped.
    private func settleFailed(_ entry: RepositoryRoot?) {
        guard let entry, phase == .restoring else { return }
        restoreFailed.insert(entry)
        restoreOutstanding.remove(entry)
        finishRestorationIfSettled()
    }

    /// Once every saved root is accounted for: focus the saved active window, start
    /// running, write the session once, and open the Finder URLs queued meanwhile.
    private func finishRestorationIfSettled() {
        guard phase == .restoring, restoreStarted, restoreOutstanding.isEmpty else { return }
        if let active = restoreActive, let id = rootIndex[active] {
            lastActiveRepositoryRoot = active
            hooks.focusWindow(id)
            // The batch settles inside the last restored window's registration, and
            // AppKit makes that window key once it finishes presenting it, after this
            // returns. Focus the active window again once that has happened.
            DispatchQueue.main.async { [weak self] in
                guard let self, windows[id] != nil else { return }
                hooks.focusWindow(id)
            }
        }
        phase = .running
        persist()
        let queued = queuedAppURLs
        queuedAppURLs = []
        for url in queued {
            Task { await open(OpenRequest(url: url, origin: .app)) }
        }
    }

    // MARK: - Presentation defaults

    static func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not open repository"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Supporting types

extension WindowCoordinator {
    struct OpenRequest: Sendable {
        let url: URL
        let origin: OpenOrigin
        var purpose: OpenPurpose = .user
        /// The saved root this request restores, if any; what `settle` refers to.
        var restoreEntry: RepositoryRoot?

        /// Restoration opens adopt only the window named as their origin (the initial
        /// window); the rest always create, so saved repositories never race for an
        /// empty window and the restored order does not depend on discovery order.
        var canAdoptEmptyOrigin: Bool {
            purpose == .user || origin != .app
        }
    }

    /// A window has been asked for but has not registered its state yet.
    struct PendingWindowOpen {
        let root: RepositoryRoot
        let client: any RepoClient
        /// Upgraded to `.user` if a user request joins a restoration create.
        var purpose: OpenPurpose
        /// Set when a restoration request joins a create a user started.
        var restoreEntry: RepositoryRoot?
        /// Known once the window's accessor attaches, before its state registers.
        var windowID: WindowID?
    }

    /// The presentation the coordinator needs but does not own.
    struct Hooks {
        var createWindow: @MainActor (RepositoryRoot) -> Void
        var focusWindow: @MainActor (WindowID) -> Void
        var presentError: @MainActor (String) -> Void
    }

    /// Defaults keys for the persisted session.
    enum SessionKeys {
        static let openRoots = "openRepositoryRoots"
        static let lastActive = "lastActiveRepositoryRoot"
    }
}
