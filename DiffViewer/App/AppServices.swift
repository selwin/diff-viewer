import AppKit
import Observation
import SwiftUI

/// What the app owns exactly once: preferences, the difft and result caches, the
/// prefetcher, the window coordinator, and the map from window ids to their `NSWindow`s.
///
/// `@Observable` only so views can receive it through `.environment(_:)`; it holds no
/// state that changes after creation.
@MainActor
@Observable
final class AppServices {
    /// The repository window scene, so an empty window can be opened by id.
    static let repositorySceneID = "repository"

    let preferences: Preferences
    let cache: DifftCache
    let resultCache = DiffResultCache()
    let prefetcher: DiffPrefetcher
    let coordinator: WindowCoordinator
    let windows = NativeWindowRegistry()

    init(defaults: UserDefaults = .standard, cache: DifftCache = .bundled()) {
        preferences = Preferences(defaults: defaults)
        self.cache = cache
        prefetcher = DiffPrefetcher(cache: cache)
        let windows = windows
        let opener = WindowOpener()
        coordinator = WindowCoordinator(
            preferences: preferences,
            prefetcher: prefetcher,
            defaults: defaults,
            hooks: WindowCoordinator.Hooks(
                createWindow: { root in opener.action?(value: root) },
                focusWindow: { id in windows[id]?.makeKeyAndOrderFront(nil) },
                presentError: WindowCoordinator.presentError
            )
        )
        self.opener = opener
    }

    private let opener: WindowOpener
    private var hooksInstalled = false

    /// Connects the app delegate and SwiftUI's window opener to the coordinator. Runs
    /// once; the first window's task calls it because only a view can obtain the
    /// opener. Setting `launchHandler` delivers a launch that already finished.
    func installAppHooks(delegate: AppDelegate, openWindow: OpenWindowAction) {
        opener.action = openWindow
        guard !hooksInstalled else { return }
        hooksInstalled = true
        let coordinator = coordinator
        delegate.openHandler = { url in coordinator.openFromApp(url) }
        delegate.newTabHandler = { [weak self] in self?.openEmptyWindow() }
        delegate.terminationHandler = { coordinator.applicationWillTerminate() }
        delegate.launchHandler = { coordinator.applicationDidFinishLaunching() }
    }

    /// Opens an empty window, which becomes a tab of the key window. It adopts the
    /// next repository opened from it.
    func openEmptyWindow() {
        opener.action?(id: Self.repositorySceneID)
    }

    func makeWindowState() -> WindowState {
        WindowState(preferences: preferences, cache: cache, resultCache: resultCache) { root, onChange in
            RepoWatcher(root: root.url, onChange: onChange)
        }
    }
}

/// Holds the SwiftUI `openWindow` action, which only a view can obtain.
@MainActor
final class WindowOpener {
    var action: OpenWindowAction?
}

/// `NSWindow` by window id, maintained by each window's `WindowAccessor`. Distinct
/// from the coordinator's table of `WindowState`s.
@MainActor
final class NativeWindowRegistry {
    private var windows: [WindowID: NSWindow] = [:]

    subscript(id: WindowID) -> NSWindow? {
        get { windows[id] }
        set { windows[id] = newValue }
    }
}
