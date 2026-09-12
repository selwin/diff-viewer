import Foundation
import Observation

/// What the app owns once: preferences, the difft cache, the prefetcher, and (until
/// windows multiply) the one window's state. Opening a repository into a populated
/// window replaces that window's state with a fresh one, since a `WindowState`
/// adopts a repository exactly once.
@MainActor
@Observable
final class AppModel {
    typealias Discoverer = @Sendable (URL) async throws -> RepositoryDiscovery.Result

    let preferences: Preferences
    let cache: DifftCache
    let prefetcher: DiffPrefetcher
    private(set) var windowState: WindowState

    private let discover: Discoverer
    private let watchRepository: WindowState.WatcherFactory
    /// Incremented per `open`; an open that is no longer the latest installs nothing.
    private var openGeneration = 0

    init(
        preferences: Preferences = Preferences(),
        cache: DifftCache = .bundled(),
        discover: @escaping Discoverer = RepositoryDiscovery.discover,
        watchRepository: @escaping WindowState.WatcherFactory = { root, onChange in RepoWatcher(root: root, onChange: onChange) }
    ) {
        self.preferences = preferences
        self.cache = cache
        self.discover = discover
        self.watchRepository = watchRepository
        prefetcher = DiffPrefetcher(cache: cache)
        windowState = Self.makeWindowState(preferences: preferences, cache: cache, prefetcher: prefetcher, watchRepository: watchRepository)
        preferences.onDiffSettingsChange = { [weak self] in
            self?.windowState.diffSettingsChanged()
        }
    }

    func restoreLastRepository() async {
        guard windowState.isEmpty, let last = preferences.recentRepositoryRoots.first else { return }
        await open(last)
    }

    func presentOpenPanel() {
        guard let url = RepositoryDiscovery.chooseFolder() else { return }
        Task { await open(url) }
    }

    func open(_ url: URL) async {
        openGeneration += 1
        let generation = openGeneration
        let discovered: RepositoryDiscovery.Result
        do {
            discovered = try await discover(url)
        } catch {
            guard generation == openGeneration else { return }
            windowState.errorMessage = "Not a git repository: \(url.path)\n\(error.localizedDescription)"
            return
        }
        guard generation == openGeneration else { return }
        if !windowState.adopt(root: discovered.root, client: discovered.client) {
            // The old repository's queue must not keep draining while the new one loads.
            prefetcher.cancel()
            let fresh = Self.makeWindowState(preferences: preferences, cache: cache, prefetcher: prefetcher, watchRepository: watchRepository)
            windowState.close()
            windowState = fresh
            fresh.adopt(root: discovered.root, client: discovered.client)
        }
        preferences.noteOpened(discovered.root)
    }

    private static func makeWindowState(
        preferences: Preferences, cache: DifftCache, prefetcher: DiffPrefetcher, watchRepository: @escaping WindowState.WatcherFactory
    ) -> WindowState {
        let state = WindowState(preferences: preferences, cache: cache, watchRepository: watchRepository)
        state.onRefreshPublished = { state, _ in
            guard let client = state.session?.client else { return }
            prefetcher.prefetch(files: state.filesToWarm, client: client)
        }
        return state
    }
}
