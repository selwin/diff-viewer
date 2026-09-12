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
        if failing.contains(url) { throw ProcessError.failed(command: "git rev-parse", status: 128, stderr: "not a repo") }
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
    let suite = "DiffViewerTests.Coordinator.\(UUID().uuidString)"
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

    init() {
        defaults = UserDefaults(suiteName: suite)!
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
            discover: { url in
                try await gate.pass(url)
                guard let entry = await registry.lookup(url) else { throw ProcessError.failed(command: "test", status: 1, stderr: "no stub") }
                return (entry.root, entry.client)
            },
            hooks: WindowCoordinator.Hooks(
                createWindow: { log.created.append($0) },
                focusWindow: { log.focused.append($0) },
                presentError: { log.errors.append($0) }
            )
        )
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    var recent: [RepositoryRoot] { preferences.recentRepositoryRoots }

    func repo(_ name: String, files: [ChangedFile] = []) -> URL {
        let url = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        registry.entries[url] = (RepositoryRoot(url), StubRepoClient(files: files))
        return url
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
        #expect(h.coordinator.openOrder == [h.root(x), h.root(a), h.root(b)], "registration order never reorders the session")
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

    @Test func queuedFinderURLSkipsTheRecentRepositoryAtLaunch() async {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: filesA)
        let b = h.repo("B", files: filesB)
        h.preferences.noteOpened(h.root(a))
        #expect(h.coordinator.phase == .restoring)
        h.coordinator.openFromApp(b)
        let w1 = h.makeWindow()
        #expect(h.coordinator.phase == .running)
        #expect(await eventually { await w1.repositoryRoot == h.root(b) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.log.created.isEmpty, "the recent repository is not reopened")
        #expect(h.registry.lookups[a] == nil)
        #expect(h.coordinator.openOrder == [h.root(b)])
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
        #expect(h.coordinator.lastActiveRepositoryRoot == h.root(a), "an empty key window does not change the last active root")
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
        #expect(await eventually { await MainActor.run { w1.diffLoader.content != nil && w2.diffLoader.content != nil } })
        #expect(await eventually { await MainActor.run { !w1.diffLoader.hasActiveWork && !w2.diffLoader.hasActiveWork } })
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
        #expect(await eventually { await MainActor.run { !w1.diffLoader.hasActiveWork && w1.diffLoader.content != nil } })
        #expect(await h.client(a).contentReads >= readsA + 4, "every real toggle reloads the visible window")
        #expect(h.preferences.hideWhitespace)
        #expect(await h.client(b).contentReads == readsB, "the hidden window loads nothing")

        h.coordinator.windowOcclusionChanged(w2.id, visible: true)
        #expect(await eventually { await h.client(b).contentReads == readsB + 2 })
        #expect(!w2.diffStale)
    }

    // MARK: Discovery against real repositories

    @Test func symlinkAndSubdirectoryResolveToOneRootWhileWorktreesStayDistinct() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "DiffViewerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appending(path: "repo", directoryHint: .isDirectory)
        let sub = repo.appending(path: "sub", directoryHint: .isDirectory)
        let link = base.appending(path: "link", directoryHint: .isDirectory)
        let worktree = base.appending(path: "wt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        func git(_ arguments: [String], in directory: URL) async throws {
            _ = try await ProcessRunner.check(GitClient.executable, arguments: ["-c", "commit.gpgsign=false"] + arguments, currentDirectory: directory)
        }
        try await git(["init", "-q"], in: repo)
        try await git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
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
