import Foundation
import Testing

@testable import DiffViewer

/// Holds discovery for chosen URLs until released, or fails them.
actor OpenGate {
    private var heldURLs: Set<URL> = []
    private var waiting: [URL: CheckedContinuation<Void, Never>] = [:]
    private var failing: Set<URL> = []

    func hold(_ url: URL) { heldURLs.insert(url) }
    func fail(_ url: URL) { failing.insert(url) }
    var waitingURLs: Set<URL> { Set(waiting.keys) }

    func pass(_ url: URL) async throws {
        if heldURLs.contains(url) {
            await withCheckedContinuation { waiting[url] = $0 }
        }
        if failing.contains(url) {
            throw ProcessError.failed(command: "git rev-parse", status: 128, stderr: "not a repo")
        }
    }

    func release(_ url: URL) { waiting.removeValue(forKey: url)?.resume() }
}

/// Stub repositories by URL (several URLs may resolve to one root), the watchers
/// windows asked for, and how often each URL was discovered.
@MainActor
final class RepoRegistry {
    var entries: [URL: (root: RepositoryRoot, client: StubRepoClient)] = [:]
    var lookups: [URL: Int] = [:]
    var watchers: [RepositoryRoot: NoopWatcher] = [:]
    var watcherCallbacks: [RepositoryRoot: @MainActor () -> Void] = [:]

    func lookup(_ url: URL) -> (root: RepositoryRoot, client: StubRepoClient)? {
        lookups[url, default: 0] += 1
        return entries[url]
    }
}

@MainActor
final class RecordingPrefetcher: Prefetching {
    enum Event: Equatable {
        case prefetch([ChangedFile.ID])
        case cancel
    }

    private(set) var events: [Event] = []

    func prefetch(files: [ChangedFile], client: any RepoClient) { events.append(.prefetch(files.map(\.id))) }
    func cancel() { events.append(.cancel) }
}

/// What the coordinator asked the app to present.
@MainActor
final class PresentationLog {
    var created: [RepositoryRoot] = []
    var focused: [WindowID] = []
    var errors: [String] = []
}

@MainActor
final class CoordinatorHarness {
    let defaults: UserDefaults
    private(set) var suite = "DiffViewerTests.Coordinator.\(UUID().uuidString)"
    let gate = OpenGate()
    let registry = RepoRegistry()
    let runner = RunnerProbe()
    let preferences: Preferences
    let prefetcher = RecordingPrefetcher()
    let log = PresentationLog()
    let coordinator: WindowCoordinator
    private let cache: DifftCache
    /// Scene values written by the coordinator, by window.
    private(set) var sceneRoots: [WindowID: RepositoryRoot?] = [:]

    /// `savedRoots` and `savedActive` seed the persisted session the coordinator
    /// reads at init; `suite` reuses another harness's defaults. Launch is reported
    /// as finished up front unless `launchFinished` is false.
    init(
        suite: String? = nil, savedRoots: [RepositoryRoot] = [], savedPaths: [String] = [],
        savedActive: RepositoryRoot? = nil, launchFinished: Bool = true
    ) {
        if let suite { self.suite = suite }
        defaults = UserDefaults(suiteName: self.suite)!
        let paths = savedRoots.map(\.path) + savedPaths
        if !paths.isEmpty {
            defaults.set(paths, forKey: WindowCoordinator.SessionKeys.openRoots)
        }
        if let savedActive {
            defaults.set(savedActive.path, forKey: WindowCoordinator.SessionKeys.lastActive)
        }
        preferences = Preferences(defaults: defaults)
        let runner = runner
        cache = DifftCache(runner: { old, new, fileName, qos in
            try await runner.run(old: old, new: new, fileName: fileName, qualityOfService: qos)
        })
        let gate = gate
        let registry = registry
        let log = log
        coordinator = WindowCoordinator(
            preferences: preferences,
            prefetcher: prefetcher,
            defaults: defaults,
            discover: { url in
                try await gate.pass(url)
                guard let entry = await registry.lookup(url) else {
                    throw ProcessError.failed(command: "test", status: 1, stderr: "no stub")
                }
                return (entry.root, entry.client)
            },
            hooks: WindowCoordinator.Hooks(
                createWindow: { log.created.append($0) },
                focusWindow: { log.focused.append($0) },
                presentError: { log.errors.append($0) }
            )
        )
        if launchFinished { coordinator.applicationDidFinishLaunching() }
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    var recent: [RepositoryRoot] { preferences.recentRepositoryRoots }

    /// The persisted session as the next launch would read it.
    var savedRoots: [RepositoryRoot]? {
        defaults.stringArray(forKey: WindowCoordinator.SessionKeys.openRoots)?.map { RepositoryRoot(path: $0) }
    }

    var savedActive: RepositoryRoot? {
        defaults.string(forKey: WindowCoordinator.SessionKeys.lastActive).map { RepositoryRoot(path: $0) }
    }

    /// The root `repo(name)` will have, for seeding a session before the repo exists.
    nonisolated static func savedRoot(_ name: String) -> RepositoryRoot {
        RepositoryRoot(path: "/tmp/\(name)")
    }

    func repo(_ name: String, files: [ChangedFile] = []) -> URL {
        let url = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        let entry = (RepositoryRoot(url), StubRepoClient(files: files))
        registry.entries[url] = entry
        // Restoration asks for the saved root's own URL.
        registry.entries[entry.0.url] = entry
        return url
    }

    func running() async -> Bool {
        await eventually { await self.coordinator.phase == .running }
    }

    /// A path inside `repo` that discovery resolves to the same root and client.
    func subdirectory(of repo: URL, _ name: String) -> URL {
        let url = repo.appending(path: name, directoryHint: .isDirectory)
        registry.entries[url] = registry.entries[repo]
        return url
    }

    func root(_ url: URL) -> RepositoryRoot { RepositoryRoot(url) }
    func client(_ url: URL) -> StubRepoClient { registry.entries[url]!.client }

    func makeState() -> WindowState {
        WindowState(preferences: preferences, cache: cache) { [weak registry] root, onChange in
            let watcher = NoopWatcher()
            registry?.watchers[root] = watcher
            registry?.watcherCallbacks[root] = onChange
            return watcher
        }
    }

    /// A new empty window that has attached and registered.
    @discardableResult
    func makeWindow() -> WindowState {
        register(makeState(), sceneRoot: nil)
    }

    @discardableResult
    func register(_ state: WindowState, sceneRoot: RepositoryRoot?) -> WindowState {
        coordinator.windowDidAttach(state.id, sceneRoot: sceneRoot)
        coordinator.register(state, sceneRoot: sceneRoot) { [weak self] in self?.sceneRoots[state.id] = $0 }
        return state
    }

    /// Simulates SwiftUI presenting the window the coordinator asked for.
    @discardableResult
    func registerCreated(_ root: RepositoryRoot) -> WindowState {
        register(makeState(), sceneRoot: root)
    }

    func open(_ url: URL, from window: WindowState?, purpose: WindowCoordinator.OpenPurpose = .user) async {
        let origin: WindowCoordinator.OpenOrigin = window.map { .window($0.id) } ?? .app
        await coordinator.open(WindowCoordinator.OpenRequest(url: url, origin: origin, purpose: purpose))
    }

    /// Opens into `window` and waits for its file list.
    func openAndSettle(_ url: URL, into window: WindowState) async {
        await open(url, from: window)
        #expect(window.repositoryRoot == root(url))
        let expected = await client(url).currentFiles
        #expect(await eventually { await window.files == expected })
    }
}

@MainActor
struct WindowCoordinatorTests {
    let filesA = [changedFile("a1.swift"), changedFile("a2.swift", area: .staged)]
    let filesB = [changedFile("b1.swift")]

    // MARK: Routing

    @Test func existingRootIsFocusedNotDuplicated() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let w1 = h.makeWindow()
        let w2 = h.makeWindow()
        await h.openAndSettle(a, into: w1)
        await h.openAndSettle(b, into: w2)
        #expect(h.recent == [h.root(b), h.root(a)])

        await h.open(a, from: w2, purpose: .restoration)
        #expect(h.log.focused == [w1.id])
        #expect(h.log.created.isEmpty)
        #expect(h.recent == [h.root(b), h.root(a)], "restoration never touches recency")

        await h.open(a, from: w2)
        #expect(h.log.focused == [w1.id, w1.id])
        #expect(h.recent == [h.root(a), h.root(b)], "a user open of an open repository moves it to the front")
        #expect(h.coordinator.openOrder == [h.root(a), h.root(b)])
    }

    @Test func emptyOriginAdoptsWithoutCreate() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        await h.openAndSettle(a, into: w1)
        #expect(h.log.created.isEmpty)
        #expect(h.log.focused.isEmpty)
        #expect(h.sceneRoots[w1.id] == h.root(a))
        #expect(h.coordinator.openOrder == [h.root(a)])
        #expect(h.coordinator.rootIndex[h.root(a)] == w1.id)
        #expect(h.recent == [h.root(a)])
    }

    @Test func populatedOriginFocusesThenCreatesAndOrderIsFixedAtReservation() async {
        let h = CoordinatorHarness()
        let x = h.repo("X")
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let w1 = h.makeWindow()
        await h.openAndSettle(x, into: w1)

        await h.open(a, from: w1)
        #expect(h.log.focused == [w1.id])
        #expect(h.log.created == [h.root(a)])
        #expect(h.coordinator.pendingCreates[h.root(a)] != nil)
        await h.open(b, from: w1)
        #expect(h.log.created == [h.root(a), h.root(b)])
        #expect(h.coordinator.openOrder == [h.root(x), h.root(a), h.root(b)])

        let wb = h.registerCreated(h.root(b))
        let wa = h.registerCreated(h.root(a))
        #expect(wb.repositoryRoot == h.root(b))
        #expect(wa.repositoryRoot == h.root(a))
        #expect(
            h.coordinator.openOrder == [h.root(x), h.root(a), h.root(b)],
            "registration order never reorders the session")
        #expect(h.coordinator.pendingCreates.isEmpty)
        #expect(h.sceneRoots[wa.id] == h.root(a))
        #expect(await eventually { await wa.files == self.filesA })
    }

    @Test func appOriginWithNoWindowsCreates() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        await h.open(a, from: nil)
        #expect(h.log.created == [h.root(a)])
        #expect(h.log.focused.isEmpty)
        #expect(h.coordinator.openOrder == [h.root(a)])
        let w = h.registerCreated(h.root(a))
        #expect(w.repositoryRoot == h.root(a))
        #expect(h.recent == [h.root(a)])
    }

    @Test func appOriginLandsInAnEmptyKeyWindow() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        let w2 = h.makeWindow()
        h.coordinator.windowDidBecomeKey(w2.id)
        await h.open(a, from: nil)
        #expect(w2.repositoryRoot == h.root(a))
        #expect(w1.isEmpty)
        #expect(h.log.created.isEmpty)
    }

    @Test func discoveryFailureShowsOneAlertAndChangesNothing() async {
        let h = CoordinatorHarness()
        let bad = URL(fileURLWithPath: "/tmp/not-a-repo", isDirectory: true)
        await h.gate.fail(bad)
        let w1 = h.makeWindow()
        await h.open(bad, from: w1)
        #expect(h.log.errors.count == 1)
        #expect(h.log.errors.first?.contains("Not a git repository") == true)
        #expect(h.log.created.isEmpty)
        #expect(h.log.focused.isEmpty)
        #expect(w1.isEmpty)
        #expect(h.coordinator.openOrder.isEmpty)
        #expect(h.recent.isEmpty)

        await h.open(bad, from: w1, purpose: .restoration)
        #expect(h.log.errors.count == 1, "restoration failures are silent")
    }

    @Test func simultaneousOpensOfTheSameRepositoryAdoptOnceThenFocus() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let sub = h.subdirectory(of: a, "src")
        await h.gate.hold(a)
        await h.gate.hold(sub)
        let w1 = h.makeWindow()
        let first = Task { await h.open(a, from: w1) }
        let second = Task { await h.open(sub, from: w1) }
        #expect(await eventually { await h.gate.waitingURLs == [a, sub] })

        await h.gate.release(sub)
        await second.value
        await h.gate.release(a)
        await first.value
        #expect(w1.repositoryRoot == h.root(a))
        #expect(h.log.created.isEmpty)
        #expect(h.log.focused == [w1.id])
        #expect(h.coordinator.openOrder == [h.root(a)])
        #expect(h.registry.watchers.count == 1)
    }

    @Test func simultaneousOpensOfDifferentRepositoriesAdoptOneAndCreateOne() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        await h.gate.hold(a)
        await h.gate.hold(b)
        let w1 = h.makeWindow()
        let openA = Task { await h.open(a, from: w1) }
        let openB = Task { await h.open(b, from: w1) }
        #expect(await eventually { await h.gate.waitingURLs == [a, b] })

        await h.gate.release(a)
        await openA.value
        await h.gate.release(b)
        await openB.value
        #expect(w1.repositoryRoot == h.root(a))
        #expect(h.log.created == [h.root(b)])
        #expect(h.log.focused == [w1.id])
        #expect(h.coordinator.openOrder == [h.root(a), h.root(b)])
    }

    @Test func openWhileCreateIsPendingJoinsIt() async {
        let h = CoordinatorHarness()
        let x = h.repo("X")
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        await h.openAndSettle(x, into: w1)
        await h.open(a, from: w1)
        await h.open(a, from: w1)
        #expect(h.log.created == [h.root(a)])
        #expect(h.log.focused == [w1.id], "the joining request neither focuses nor creates")
        #expect(h.coordinator.openOrder == [h.root(x), h.root(a)])
        #expect(h.recent == [h.root(x)], "recency waits for the window")
        h.registerCreated(h.root(a))
        #expect(h.recent == [h.root(a), h.root(x)])
    }

    @Test func registerTwiceKeepsOneEntryAndRemoveUnknownIsANoop() async {
        let h = CoordinatorHarness()
        let w1 = h.makeWindow()
        h.register(w1, sceneRoot: nil)
        #expect(h.coordinator.windows.count == 1)
        let stranger = h.makeState()
        h.coordinator.remove(stranger.id)
        #expect(h.coordinator.windows.count == 1)
        #expect(!stranger.isClosed)
    }

    @Test func aClosedStateCannotRegister() async {
        let h = CoordinatorHarness()
        let w1 = h.makeWindow()
        h.coordinator.windowWillClose(w1.id, sceneRoot: nil)
        #expect(w1.isClosed)
        h.register(w1, sceneRoot: nil)
        #expect(h.coordinator.windows.isEmpty, "a window presented again gets a fresh state instead")
    }

    @Test func originClosedWhileDiscoveryIsHeldDropsTheResult() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let bad = URL(fileURLWithPath: "/tmp/bad", isDirectory: true)
        await h.gate.hold(a)
        await h.gate.hold(bad)
        await h.gate.fail(bad)
        let w1 = h.makeWindow()
        let openA = Task { await h.open(a, from: w1) }
        let openBad = Task { await h.open(bad, from: w1) }
        #expect(await eventually { await h.gate.waitingURLs == [a, bad] })

        h.coordinator.remove(w1.id)
        await h.gate.release(a)
        await h.gate.release(bad)
        await openA.value
        await openBad.value
        #expect(w1.isEmpty)
        #expect(w1.isClosed)
        #expect(h.log.created.isEmpty)
        #expect(h.log.errors.isEmpty)
        #expect(h.coordinator.openOrder.isEmpty)
        #expect(h.registry.watchers.isEmpty)
    }

    @Test func registrationWithPendingSceneRootAdoptsWithoutSecondDiscovery() async {
        let h = CoordinatorHarness()
        let x = h.repo("X")
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        await h.openAndSettle(x, into: w1)
        await h.open(a, from: w1)
        #expect(h.registry.lookups[a] == 1)

        // The new window is already key when its state registers.
        let state = h.makeState()
        h.coordinator.windowDidBecomeKey(state.id)
        let before = h.prefetcher.events.count
        h.register(state, sceneRoot: h.root(a))
        #expect(state.repositoryRoot == h.root(a))
        #expect(state.isKey)
        #expect(h.registry.lookups[a] == 1)
        #expect(h.recent.first == h.root(a))
        #expect(h.coordinator.lastActiveRepositoryRoot == h.root(a))
        #expect(await eventually { await h.prefetcher.events.count > before })
        #expect(h.prefetcher.events.last == .prefetch(filesA.map(\.id)))
    }

    @Test func userRequestJoiningARestorationCreateUpgradesRecency() async {
        let h = CoordinatorHarness()
        let x = h.repo("X")
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        await h.openAndSettle(x, into: w1)
        await h.open(a, from: w1, purpose: .restoration)
        await h.open(a, from: w1, purpose: .user)
        #expect(h.log.created == [h.root(a)])
        #expect(h.recent == [h.root(x)])
        h.registerCreated(h.root(a))
        #expect(h.recent == [h.root(a), h.root(x)])
    }

    @Test func appOriginFallsBackToTheLastActiveWindow() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let c = h.repo("C")
        let w1 = h.makeWindow()
        let w2 = h.makeWindow()
        await h.openAndSettle(a, into: w1)
        await h.openAndSettle(b, into: w2)
        h.coordinator.windowDidBecomeKey(w2.id)
        h.coordinator.windowDidResignKey(w2.id)
        await h.open(c, from: nil)
        #expect(h.log.focused == [w2.id], "the new window joins the last active window's group")
        #expect(h.log.created == [h.root(c)])
    }

    @Test func restoredPendingWindowDoesNotTouchRecency() async {
        let h = CoordinatorHarness()
        let x = h.repo("X")
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        await h.openAndSettle(x, into: w1)
        await h.open(a, from: w1, purpose: .restoration)
        let w2 = h.registerCreated(h.root(a))
        #expect(w2.repositoryRoot == h.root(a))
        #expect(h.recent == [h.root(x)])
    }

    @Test func createdWindowClosedBeforeRegistrationIsForgotten() async {
        let h = CoordinatorHarness()
        let x = h.repo("X")
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        await h.openAndSettle(x, into: w1)
        await h.open(a, from: w1)

        let late = h.makeState()
        h.coordinator.windowDidAttach(late.id, sceneRoot: h.root(a))
        h.coordinator.windowWillClose(late.id, sceneRoot: h.root(a))
        #expect(h.coordinator.pendingCreates.isEmpty)
        #expect(h.coordinator.openOrder == [h.root(x)])

        h.coordinator.register(late, sceneRoot: h.root(a))
        #expect(h.coordinator.windows.count == 1)
        #expect(late.isEmpty)
        #expect(h.registry.lookups[a] == 1)
        #expect(h.registry.watchers[h.root(a)] == nil)
    }

    @Test func pendingWindowClosedIsMatchedByRecordedID() async {
        let h = CoordinatorHarness()
        let x = h.repo("X")
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        await h.openAndSettle(x, into: w1)
        await h.open(a, from: w1)
        let late = h.makeState()
        h.coordinator.windowDidAttach(late.id, sceneRoot: h.root(a))
        h.coordinator.windowWillClose(late.id, sceneRoot: nil)
        #expect(h.coordinator.pendingCreates.isEmpty)
        #expect(h.coordinator.openOrder == [h.root(x)])
    }

    @Test func onlyTheOriginOfTwoEmptyWindowsAdopts() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        let w2 = h.makeWindow()
        await h.openAndSettle(a, into: w2)
        #expect(w1.isEmpty)
        #expect(h.log.created.isEmpty)
        #expect(h.sceneRoots[w1.id] == nil)
    }

    @Test func adoptionRejectedByAClosedStateLeavesNothingBehind() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        await h.gate.hold(a)
        let w1 = h.makeWindow()
        let openA = Task { await h.open(a, from: w1) }
        #expect(await eventually { await h.gate.waitingURLs == [a] })
        w1.close()
        await h.gate.release(a)
        await openA.value
        #expect(h.coordinator.openOrder.isEmpty)
        #expect(h.coordinator.pendingCreates.isEmpty)
        #expect(h.coordinator.rootIndex.isEmpty)
        #expect(h.log.created.isEmpty)
        #expect(h.recent.isEmpty)
    }

    // MARK: Key and prefetch

    @Test func adoptingIntoTheKeyWindowStartsPrefetch() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        h.coordinator.windowDidBecomeKey(w1.id)
        #expect(h.coordinator.lastActiveRepositoryRoot == nil)
        await h.openAndSettle(a, into: w1)
        #expect(h.coordinator.lastActiveRepositoryRoot == h.root(a))
        #expect(h.prefetcher.events.contains(.prefetch(filesA.map(\.id))))
    }

    @Test func keyHandoffCancelsThenPrefetchesTheNewKeyWindow() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let w1 = h.makeWindow()
        let w2 = h.makeWindow()
        await h.openAndSettle(a, into: w1)
        await h.openAndSettle(b, into: w2)
        #expect(h.prefetcher.events.isEmpty, "no window is key, so nothing is prefetched")

        h.coordinator.windowDidBecomeKey(w1.id)
        #expect(h.prefetcher.events == [.prefetch(filesA.map(\.id))])
        #expect(h.coordinator.lastActiveRepositoryRoot == h.root(a))
        h.coordinator.windowDidResignKey(w1.id)
        h.coordinator.windowDidBecomeKey(w2.id)
        #expect(h.prefetcher.events == [.prefetch(filesA.map(\.id)), .cancel, .prefetch(filesB.map(\.id))])
        #expect(!w1.isKey)
        #expect(w2.isKey)
        #expect(h.coordinator.lastActiveRepositoryRoot == h.root(b))

        h.coordinator.windowDidResignKey(w1.id)
        #expect(h.prefetcher.events.count == 3, "a late resign for the previous window is ignored")
        #expect(h.coordinator.keyWindowID == w2.id)
        #expect(w2.isKey)

        h.coordinator.windowDidBecomeKey(w2.id)
        #expect(h.prefetcher.events.count == 3, "a duplicate become-key is ignored")

        h.coordinator.windowDidResignKey(w2.id)
        #expect(h.coordinator.keyWindowID == nil)
        #expect(!w1.isKey && !w2.isKey)
        #expect(h.prefetcher.events.last == .cancel)
        #expect(h.coordinator.lastActiveRepositoryRoot == h.root(b), "the last active root survives deactivation")
    }

    @Test func directHandoffWithoutResignDeactivatesThePreviousWindow() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        let w2 = h.makeWindow()
        await h.openAndSettle(a, into: w1)
        h.coordinator.windowDidBecomeKey(w1.id)
        h.coordinator.windowDidBecomeKey(w2.id)
        #expect(!w1.isKey)
        #expect(w2.isKey)
        #expect(h.prefetcher.events == [.prefetch(filesA.map(\.id)), .cancel])
        #expect(
            h.coordinator.lastActiveRepositoryRoot == h.root(a),
            "an empty key window does not change the last active root")
    }

    @Test func registrationReconcilesAWindowThatIsAlreadyKey() async {
        let h = CoordinatorHarness()
        let state = h.makeState()
        h.coordinator.windowDidBecomeKey(state.id)
        h.coordinator.windowOcclusionChanged(state.id, visible: false)
        h.register(state, sceneRoot: nil)
        #expect(state.isKey)
        #expect(!state.isVisible)
        #expect(h.coordinator.keyWindowState === state)
    }

    @Test func removingTheKeyWindowCancelsPrefetch() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        await h.openAndSettle(a, into: w1)
        h.coordinator.windowDidBecomeKey(w1.id)
        h.coordinator.windowWillClose(w1.id, sceneRoot: h.root(a))
        #expect(h.prefetcher.events.last == .cancel)
        #expect(!w1.isKey)
        #expect(h.coordinator.keyWindowID == nil)
        #expect(h.coordinator.windows.isEmpty)
        #expect(h.coordinator.rootIndex.isEmpty)
        #expect(h.coordinator.openOrder.isEmpty)
        #expect(w1.isClosed)
        #expect(h.registry.watchers[h.root(a)]?.stopped == true)
    }

    @Test func backgroundWatcherRefreshUpdatesTheListWithoutPrefetch() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let w1 = h.makeWindow()
        let w2 = h.makeWindow()
        await h.openAndSettle(a, into: w1)
        await h.openAndSettle(b, into: w2)
        h.coordinator.windowDidBecomeKey(w1.id)
        h.coordinator.windowOcclusionChanged(w2.id, visible: false)
        let events = h.prefetcher.events

        let updated = [changedFile("b2.swift")]
        await h.client(b).set(files: updated)
        h.registry.watcherCallbacks[h.root(b)]!()
        #expect(await eventually { await w2.files == updated })
        #expect(h.prefetcher.events == events, "only the key window is prefetched")

        await h.client(a).set(files: updated)
        h.registry.watcherCallbacks[h.root(a)]!()
        #expect(await eventually { await h.prefetcher.events.count == events.count + 1 })
        #expect(h.prefetcher.events.last == .prefetch(updated.map(\.id)))
    }

    @Test func openOrderFollowsOpensAndCloses() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let c = h.repo("C")
        let w1 = h.makeWindow()
        await h.openAndSettle(a, into: w1)
        await h.open(b, from: w1)
        h.coordinator.windowWillClose(w1.id, sceneRoot: h.root(a))
        #expect(h.coordinator.openOrder == [h.root(b)])
        await h.open(c, from: nil)
        #expect(h.log.created == [h.root(b), h.root(c)])
        #expect(h.coordinator.openOrder == [h.root(b), h.root(c)])
        h.registerCreated(h.root(c))
        h.registerCreated(h.root(b))
        #expect(h.coordinator.openOrder == [h.root(b), h.root(c)])
        #expect(h.coordinator.rootIndex.count == 2)
    }

    // MARK: Preferences

    @Test func hideWhitespaceReloadsVisibleWindowsAndMarksHiddenOnesStale() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let w1 = h.makeWindow()
        let w2 = h.makeWindow()
        await h.openAndSettle(a, into: w1)
        await h.openAndSettle(b, into: w2)
        w1.selectedFileID = filesA[0].id
        w2.selectedFileID = filesB[0].id
        #expect(
            await eventually { await MainActor.run { w1.diffLoader.content != nil && w2.diffLoader.content != nil } })
        #expect(
            await eventually { await MainActor.run { !w1.diffLoader.hasActiveWork && !w2.diffLoader.hasActiveWork } })
        h.coordinator.windowOcclusionChanged(w2.id, visible: false)
        let readsA = await h.client(a).contentReads
        let readsB = await h.client(b).contentReads

        h.preferences.hideWhitespace = false
        #expect(await eventually { await h.client(a).contentReads == readsA + 2 })
        #expect(w2.diffStale)
        #expect(await h.client(b).contentReads == readsB)

        h.preferences.hideWhitespace = true
        h.preferences.hideWhitespace = false
        h.preferences.hideWhitespace = true
        #expect(
            await eventually { await MainActor.run { !w1.diffLoader.hasActiveWork && w1.diffLoader.content != nil } })
        #expect(await h.client(a).contentReads >= readsA + 4, "every real toggle reloads the visible window")
        #expect(h.preferences.hideWhitespace)
        #expect(await h.client(b).contentReads == readsB, "the hidden window loads nothing")

        h.coordinator.windowOcclusionChanged(w2.id, visible: true)
        #expect(await eventually { await h.client(b).contentReads == readsB + 2 })
        #expect(!w2.diffStale)
    }

    // MARK: Session and restoration

    @Test func sessionRoundTripsOpenOrderAndActiveRoot() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let w1 = h.makeWindow()
        #expect(await h.running())
        await h.openAndSettle(a, into: w1)
        await h.open(b, from: w1)
        let wb = h.registerCreated(h.root(b))
        h.coordinator.windowDidBecomeKey(wb.id)
        #expect(h.savedRoots == [h.root(a), h.root(b)])
        #expect(h.savedActive == h.root(b))

        let next = CoordinatorHarness(suite: h.suite)
        #expect(next.coordinator.restoreList == [h.root(a), h.root(b)])
        #expect(next.coordinator.restoreActive == h.root(b))
        #expect(next.coordinator.phase == .restoring)
    }

    @Test func noSessionWriteWhileRestoringAndSavedOrderComesFirst() async {
        let saved = [CoordinatorHarness.savedRoot("A"), CoordinatorHarness.savedRoot("B")]
        let h = CoordinatorHarness(savedRoots: saved, savedActive: saved[1])
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let c = h.repo("C")
        await h.gate.hold(a)
        let w1 = h.makeWindow()
        #expect(await eventually { await h.gate.waitingURLs == [a] })
        #expect(h.savedRoots == saved, "the initial empty registration leaves the saved list intact")
        #expect(h.coordinator.phase == .restoring)
        #expect(h.registry.lookups[b] == nil, "saved repositories are discovered one at a time, in order")

        let w2 = h.makeWindow()
        await h.openAndSettle(c, into: w2)
        #expect(h.savedRoots == saved, "nothing is written while restoring")
        #expect(h.recent == [h.root(c)], "a user open during restoration still counts for recency")

        await h.gate.release(a)
        #expect(await eventually { await w1.repositoryRoot == h.root(a) })
        #expect(await eventually { await h.log.created == [h.root(b)] })
        #expect(h.coordinator.phase == .restoring, "B's window has not registered")
        h.registerCreated(h.root(b))
        #expect(h.coordinator.phase == .running)
        #expect(
            h.coordinator.openOrder == [h.root(a), h.root(b), h.root(c)],
            "saved roots keep their order ahead of what was opened meanwhile")
        #expect(h.savedRoots == [h.root(a), h.root(b), h.root(c)])
        #expect(h.recent == [h.root(c)], "restoration never touches recency")
    }

    @Test func restoringOneRepositoryIntoTheInitialWindowSettles() async {
        let h = CoordinatorHarness(savedRoots: [CoordinatorHarness.savedRoot("A")])
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        #expect(await eventually { await w1.repositoryRoot == h.root(a) })
        #expect(await h.running())
        #expect(h.log.created.isEmpty)
        #expect(h.coordinator.openOrder == [h.root(a)])
        #expect(h.savedRoots == [h.root(a)])
        #expect(h.registry.lookups[h.root(a).url] == 1)
    }

    @Test func initialWindowIsTheAdoptionTargetEvenWhenNotKey() async {
        let h = CoordinatorHarness(savedRoots: [CoordinatorHarness.savedRoot("A")])
        let a = h.repo("A", files: filesA)
        await h.gate.hold(a)
        let w1 = h.makeWindow()
        #expect(await eventually { await h.gate.waitingURLs == [a] })
        let w2 = h.makeWindow()
        h.coordinator.windowDidBecomeKey(w2.id)
        await h.gate.release(a)
        #expect(await eventually { await w1.repositoryRoot == h.root(a) })
        #expect(w2.isEmpty)
        #expect(h.log.created.isEmpty)
        #expect(await h.running())
    }

    @Test func restoreWithAMissingPathDropsItAndSettles() async {
        let missing = CoordinatorHarness.savedRoot("gone")
        let h = CoordinatorHarness(savedRoots: [CoordinatorHarness.savedRoot("A"), missing])
        let a = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        #expect(await eventually { await w1.repositoryRoot == h.root(a) })
        #expect(await h.running())
        #expect(h.log.errors.isEmpty, "restoration failures are silent")
        #expect(h.log.created.isEmpty)
        #expect(h.coordinator.openOrder == [h.root(a)])
        #expect(h.savedRoots == [h.root(a)], "the missing path is dropped from the session")
    }

    @Test func windowClosedDuringRestorationStillSettles() async {
        let h = CoordinatorHarness(savedRoots: [CoordinatorHarness.savedRoot("A"), CoordinatorHarness.savedRoot("B")])
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let w1 = h.makeWindow()
        #expect(await eventually { await w1.repositoryRoot == h.root(a) })
        #expect(await eventually { await h.log.created == [h.root(b)] })
        #expect(h.coordinator.phase == .restoring)

        let late = h.makeState()
        h.coordinator.windowDidAttach(late.id, sceneRoot: h.root(b))
        h.coordinator.windowWillClose(late.id, sceneRoot: h.root(b))
        #expect(h.coordinator.phase == .running)
        #expect(h.coordinator.pendingCreates.isEmpty)
        #expect(h.coordinator.openOrder == [h.root(a)])
        #expect(h.savedRoots == [h.root(a)])
    }

    @Test func batchSettlesOnlyWhenEveryRootIsAccountedForRegardlessOfOrder() async {
        let saved = ["A", "B", "C"].map(CoordinatorHarness.savedRoot)
        let h = CoordinatorHarness(savedRoots: saved)
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let c = h.repo("C")
        await h.gate.hold(c)
        let w1 = h.makeWindow()
        #expect(await eventually { await w1.repositoryRoot == h.root(a) })
        #expect(await eventually { await h.log.created == [h.root(b)] })
        #expect(await eventually { await h.gate.waitingURLs == [c] })
        #expect(h.coordinator.phase == .restoring, "B is pending and C is still discovering")

        // C's window registers before B's: registration order is not saved order.
        await h.gate.release(c)
        #expect(await eventually { await h.log.created == [h.root(b), h.root(c)] })
        let wc = h.registerCreated(h.root(c))
        #expect(h.coordinator.phase == .restoring, "B is still pending")
        #expect(h.savedRoots == saved)

        let wb = h.registerCreated(h.root(b))
        #expect(h.coordinator.phase == .running)
        #expect(h.coordinator.openOrder == saved, "the saved order survives out-of-order registration")
        #expect(h.savedRoots == saved)
        #expect(wc.repositoryRoot == h.root(c))
        #expect(wb.repositoryRoot == h.root(b))
        #expect(h.recent.isEmpty)
    }

    @Test func activeRootIsFocusedAfterSettle() async {
        let saved = [CoordinatorHarness.savedRoot("A"), CoordinatorHarness.savedRoot("B")]
        let h = CoordinatorHarness(savedRoots: saved, savedActive: saved[1])
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let w1 = h.makeWindow()
        #expect(await eventually { await w1.repositoryRoot == h.root(a) })
        #expect(await eventually { await h.log.created == [h.root(b)] })
        let wb = h.registerCreated(h.root(b))
        #expect(h.coordinator.phase == .running)
        #expect(h.log.focused.last == wb.id)
        #expect(h.coordinator.lastActiveRepositoryRoot == h.root(b))
        #expect(h.savedActive == h.root(b))
    }

    @Test func duplicateRequestForAPendingRestoredRootKeepsRestorationActive() async {
        let saved = [CoordinatorHarness.savedRoot("A"), CoordinatorHarness.savedRoot("B")]
        let h = CoordinatorHarness(savedRoots: saved)
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let w1 = h.makeWindow()
        #expect(await eventually { await w1.repositoryRoot == h.root(a) })
        #expect(await eventually { await h.log.created == [h.root(b)] })

        await h.open(b, from: w1)
        #expect(h.coordinator.phase == .restoring)
        #expect(h.log.created == [h.root(b)], "the duplicate joins the pending create")
        #expect(h.recent.isEmpty, "recency waits for the window")
        h.registerCreated(h.root(b))
        #expect(h.coordinator.phase == .running)
        #expect(h.recent == [h.root(b)], "the joining user request counts once the window exists")
    }

    @Test func restorationJoiningAUserCreateSettlesWhenThatWindowRegisters() async {
        let saved = [CoordinatorHarness.savedRoot("A"), CoordinatorHarness.savedRoot("B")]
        let h = CoordinatorHarness(savedRoots: saved)
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let c = h.repo("C")
        await h.gate.hold(a)
        let w1 = h.makeWindow()
        #expect(await eventually { await h.gate.waitingURLs == [a] })
        // The user opens C into a second window and B from it, before restoration
        // reaches B: B's window is a pending user create.
        let w2 = h.makeWindow()
        await h.openAndSettle(c, into: w2)
        await h.open(b, from: w2)
        #expect(h.log.created == [h.root(b)])
        #expect(h.coordinator.pendingCreates[h.root(b)]?.restoreEntry == nil)

        await h.gate.release(a)
        #expect(await eventually { await w1.repositoryRoot == h.root(a) })
        #expect(
            await eventually { await h.coordinator.pendingCreates[h.root(b)]?.restoreEntry == h.root(b) },
            "restoration joins the pending create and hands it the saved entry")
        #expect(h.log.created == [h.root(b)], "no second window for B")
        #expect(h.coordinator.phase == .restoring)

        h.registerCreated(h.root(b))
        #expect(h.coordinator.phase == .running)
        #expect(h.coordinator.openOrder == [h.root(a), h.root(b), h.root(c)])
        #expect(h.recent == [h.root(b), h.root(c)], "the user's request keeps its recency")
    }

    @Test func savedPathThatBecameASymlinkToAnotherRepositoryIsDropped() async throws {
        let base = FileManager.default.temporaryDirectory.appending(
            path: "DiffViewerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let bDirectory = base.appending(path: "B", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bDirectory, withIntermediateDirectories: true)
        let bRoot = RepositoryRoot(bDirectory)
        // The session was saved with A's canonical path; A has since become a symlink to B.
        let savedPath = RepositoryRoot(base).path + "/A"
        try FileManager.default.createSymbolicLink(atPath: savedPath, withDestinationPath: bDirectory.path)

        let h = CoordinatorHarness(savedPaths: [savedPath])
        #expect(h.coordinator.restoreList == [bRoot], "the resolved identity already reads as B")
        h.registry.entries[URL(fileURLWithPath: savedPath, isDirectory: true)] = (bRoot, StubRepoClient(files: filesB))
        let w1 = h.makeWindow()
        #expect(await h.running())
        #expect(w1.isEmpty, "B was not what the user had open")
        #expect(h.log.created.isEmpty)
        #expect(h.coordinator.rootIndex[bRoot] == nil)
        #expect(h.savedRoots == [])

        // The same repository saved under its own path restores.
        let h2 = CoordinatorHarness(savedPaths: [bRoot.path])
        h2.registry.entries[bRoot.url] = (bRoot, StubRepoClient(files: filesB))
        let w2 = h2.makeWindow()
        #expect(await eventually { await w2.repositoryRoot == bRoot })
    }

    @Test func terminatingWhileRestoringWritesTheSavedPathsUnchanged() async {
        let a = CoordinatorHarness.savedRoot("A")
        let rawPath = a.path + "/."
        let h = CoordinatorHarness(savedPaths: [rawPath], launchFinished: false)
        _ = h.repo("A", files: filesA)
        h.makeWindow()
        h.coordinator.applicationWillTerminate()
        #expect(
            h.defaults.stringArray(forKey: WindowCoordinator.SessionKeys.openRoots) == [rawPath],
            "the persisted spelling survives a quit before restoration")
    }

    @Test func savedPathResolvingToADifferentRootIsDropped() async {
        let a = CoordinatorHarness.savedRoot("A")
        let stale = RepositoryRoot(path: "/tmp/A/src")
        let h = CoordinatorHarness(savedRoots: [stale])
        _ = h.subdirectory(of: h.repo("A", files: filesA), "src")
        let w1 = h.makeWindow()
        #expect(await h.running())
        #expect(w1.isEmpty, "the saved entry is not migrated to the repository that now contains it")
        #expect(h.log.created.isEmpty)
        #expect(h.coordinator.rootIndex[a] == nil)
        #expect(h.coordinator.openOrder.isEmpty)
        #expect(h.savedRoots == [])
    }

    @Test func savedListWithADuplicateRestoresOneWindow() async {
        let a = CoordinatorHarness.savedRoot("A")
        let h = CoordinatorHarness(savedRoots: [a, a])
        _ = h.repo("A", files: filesA)
        let w1 = h.makeWindow()
        #expect(await eventually { await w1.repositoryRoot == a })
        #expect(await h.running())
        #expect(h.log.created.isEmpty)
        #expect(h.coordinator.openOrder == [a])
        #expect(h.registry.watchers.count == 1)
    }

    @Test func launchByOpenSkipsTheSavedSet() async {
        // The real order: the launch window registers, the launch URL arrives, then
        // launch finishes.
        let h = CoordinatorHarness(savedRoots: [CoordinatorHarness.savedRoot("A")], launchFinished: false)
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let w1 = h.makeWindow()
        #expect(h.coordinator.phase == .restoring, "nothing restores before launch finishes")
        h.coordinator.openFromApp(b)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.registry.lookups[b] == nil, "queued until launch finishes")

        h.coordinator.applicationDidFinishLaunching()
        #expect(h.coordinator.phase == .running)
        #expect(await eventually { await w1.repositoryRoot == h.root(b) })
        #expect(h.log.created.isEmpty, "the saved repository is not reopened")
        #expect(h.registry.lookups[a] == nil && h.registry.lookups[h.root(a).url] == nil)
        #expect(h.coordinator.openOrder == [h.root(b)])
        #expect(h.savedRoots == [h.root(b)])
    }

    @Test func restorationWaitsForLaunchToFinishAndForAWindow() async {
        let a = CoordinatorHarness.savedRoot("A")
        let h = CoordinatorHarness(savedRoots: [a], launchFinished: false)
        _ = h.repo("A", files: filesA)
        h.coordinator.applicationDidFinishLaunching()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.registry.lookups.isEmpty, "no window to restore into yet")
        let w1 = h.makeWindow()
        #expect(await eventually { await w1.repositoryRoot == a })
        #expect(await h.running())

        // A launch window that closes and registers again as a fresh state.
        let h2 = CoordinatorHarness(savedRoots: [a], launchFinished: false)
        _ = h2.repo("A", files: filesA)
        let first = h2.makeWindow()
        h2.coordinator.windowWillClose(first.id, sceneRoot: nil)
        let second = h2.makeWindow()
        h2.coordinator.applicationDidFinishLaunching()
        #expect(await eventually { await second.repositoryRoot == a })
        #expect(first.isEmpty && first.isClosed)
        #expect(h2.coordinator.windows.count == 1)
    }

    @Test func finderURLReceivedWhileRestoringOpensAfterSettle() async {
        let h = CoordinatorHarness(savedRoots: [CoordinatorHarness.savedRoot("A")])
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        await h.gate.hold(a)
        let w1 = h.makeWindow()
        #expect(await eventually { await h.gate.waitingURLs == [a] })
        h.coordinator.openFromApp(b)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.registry.lookups[b] == nil, "queued until the batch settles")
        #expect(h.log.created.isEmpty)

        await h.gate.release(a)
        #expect(await eventually { await w1.repositoryRoot == h.root(a) })
        #expect(await h.running())
        #expect(
            await eventually { await h.log.created == [h.root(b)] },
            "opened after settle, alongside the restored window")
        #expect(h.coordinator.openOrder == [h.root(a), h.root(b)])
    }

    @Test func terminatingWhileDiscoveryIsHeldKeepsTheSavedSession() async {
        let saved = [CoordinatorHarness.savedRoot("A"), CoordinatorHarness.savedRoot("B")]
        let h = CoordinatorHarness(savedRoots: saved, savedActive: saved[1])
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        await h.gate.hold(b)
        let w1 = h.makeWindow()
        #expect(await eventually { await w1.repositoryRoot == h.root(a) })
        #expect(await eventually { await h.gate.waitingURLs == [b] })
        h.coordinator.windowDidBecomeKey(w1.id)

        h.coordinator.applicationWillTerminate()
        #expect(h.coordinator.isTerminating)
        #expect(h.savedRoots == saved, "B is still in the written session")
        #expect(h.savedActive == saved[1], "the saved active root is kept")
        h.coordinator.windowWillClose(w1.id, sceneRoot: h.root(a))
        #expect(h.savedRoots == saved, "closes during termination do not rewrite the session")
        await h.gate.release(b)
    }

    @Test func removesWhileTerminatingDoNotRewriteTheSession() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        let w1 = h.makeWindow()
        let w2 = h.makeWindow()
        await h.openAndSettle(a, into: w1)
        await h.openAndSettle(b, into: w2)
        h.coordinator.windowDidBecomeKey(w1.id)
        #expect(h.savedRoots == [h.root(a), h.root(b)])
        #expect(h.savedActive == h.root(a))

        h.coordinator.applicationWillTerminate()
        h.coordinator.windowWillClose(w1.id, sceneRoot: h.root(a))
        h.coordinator.windowWillClose(w2.id, sceneRoot: h.root(b))
        #expect(h.coordinator.windows.isEmpty)
        #expect(h.savedRoots == [h.root(a), h.root(b)])
        #expect(h.savedActive == h.root(a))
    }

    // MARK: Discovery against real repositories

    @Test func symlinkAndSubdirectoryResolveToOneRootWhileWorktreesStayDistinct() async throws {
        let base = FileManager.default.temporaryDirectory.appending(
            path: "DiffViewerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appending(path: "repo", directoryHint: .isDirectory)
        let sub = repo.appending(path: "sub", directoryHint: .isDirectory)
        let link = base.appending(path: "link", directoryHint: .isDirectory)
        let worktree = base.appending(path: "wt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        func git(_ arguments: [String], in directory: URL) async throws {
            _ = try await ProcessRunner.check(
                GitClient.executable, arguments: ["-c", "commit.gpgsign=false"] + arguments, currentDirectory: directory
            )
        }
        try await git(["init", "-q"], in: repo)
        try await git(
            ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "init"],
            in: repo)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
        try await git(["worktree", "add", "-q", worktree.path], in: repo)

        let root = try await RepositoryDiscovery.discover(repo).root
        #expect(root == RepositoryRoot(repo))
        #expect(try await RepositoryDiscovery.discover(sub).root == root)
        #expect(try await RepositoryDiscovery.discover(link).root == root)
        let other = try await RepositoryDiscovery.discover(worktree).root
        #expect(other != root)
        #expect(other == RepositoryRoot(worktree))
    }
}
