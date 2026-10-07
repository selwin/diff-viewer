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
                presentError: WindowCoordinator.presentError,
                holdWindow: { windows.hold($0) },
                revealWindows: { windows.reveal(ordered: $0, selected: $1) },
                isWindowVisible: { windows[$0].map { $0.occlusionState.contains(.visible) } },
                schedule: { delay, action in
                    let (seconds, attoseconds) = delay.components
                    let interval = Double(seconds) + Double(attoseconds) * 1e-18
                    DispatchQueue.main.asyncAfter(deadline: .now() + interval) { action() }
                },
                windowIDsInTabOrder: { windows.windowIDsInTabOrder($0) }
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

    func id(of window: NSWindow) -> WindowID? {
        windows.first { $0.value === window }?.key
    }

    /// Keeps a restoration window invisible, unclickable, and out of tab groups until
    /// `reveal`.
    func hold(_ id: WindowID) {
        guard let window = windows[id] else { return }
        window.alphaValue = 0
        window.tabbingMode = .disallowed
        window.ignoresMouseEvents = true
    }

    /// Groups the transparent windows, selects the active tab, then reveals them.
    /// Returns the selected window's id.
    func reveal(ordered ids: [WindowID], selected: WindowID?) -> WindowID? {
        let live = ids.compactMap { id in windows[id].map { (id: id, window: $0) } }
        guard let first = live.first else { return nil }
        let (selectedID, selectedWindow) = live.first { $0.id == selected } ?? first
        let group = live.map(\.window)
        // Enable tabbing before explicitly assembling the group.
        for window in group { window.tabbingMode = .preferred }
        for (previous, next) in zip(group, group.dropFirst()) {
            previous.addTabbedWindow(next, ordered: .above)
        }
        selectedWindow.tabGroup?.selectedWindow = selectedWindow
        for window in group {
            window.ignoresMouseEvents = false
            window.alphaValue = 1
        }
        selectedWindow.makeKeyAndOrderFront(nil)
        return selectedID
    }

    /// The supplied IDs with each tab group's windows in tab-strip order.
    func windowIDsInTabOrder(_ ids: [WindowID]) -> [WindowID] {
        Self.arrange(ids, tabGroup: { self[$0]?.tabGroup?.windows.compactMap(self.id(of:)) })
    }

    /// Orders supplied IDs by tab group, placing each group at its first encountered member.
    /// Excludes IDs outside the input and emits each supplied ID once.
    nonisolated static func arrange(_ ids: [WindowID], tabGroup: (WindowID) -> [WindowID]?) -> [WindowID] {
        let eligibleIDs = Set(ids)
        var emittedIDs: Set<WindowID> = []
        var result: [WindowID] = []
        for id in ids where !emittedIDs.contains(id) {
            for member in tabGroup(id) ?? [] where eligibleIDs.contains(member) {
                if emittedIDs.insert(member).inserted { result.append(member) }
            }
            // Retain the current ID if the group did not emit it.
            if emittedIDs.insert(id).inserted { result.append(id) }
        }
        return result
    }
}
