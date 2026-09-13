import AppKit
import SwiftUI

/// A zero-size view that finds its window's `NSWindow` and forwards its key,
/// occlusion, and close notifications to the coordinator under the window's id.
struct WindowAccessor: NSViewRepresentable {
    let windowID: WindowID
    let sceneRoot: RepositoryRoot?
    let services: AppServices

    func makeCoordinator() -> Coordinator {
        Coordinator(windowID: windowID, services: services)
    }

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.coordinator = context.coordinator
        context.coordinator.sceneRoot = sceneRoot
        return view
    }

    func updateNSView(_ view: AccessorView, context: Context) {
        context.coordinator.sceneRoot = sceneRoot
        // A window that SwiftUI closed and presented again got a fresh state and id;
        // its observers were removed on close, so attach again under the new id.
        if context.coordinator.windowID != windowID {
            context.coordinator.detach()
            context.coordinator.windowID = windowID
            context.coordinator.attach(to: view.window)
        }
    }

    static func dismantleNSView(_ view: AccessorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AccessorView: NSView {
        weak var coordinator: Coordinator?

        override init(frame: NSRect) {
            super.init(frame: frame)
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator {
        var windowID: WindowID
        var sceneRoot: RepositoryRoot?
        private let services: AppServices
        private weak var window: NSWindow?
        private var observers: [any NSObjectProtocol] = []

        init(windowID: WindowID, services: AppServices) {
            self.windowID = windowID
            self.services = services
        }

        func attach(to window: NSWindow?) {
            guard window !== self.window else { return }
            detach()
            guard let window else { return }
            self.window = window
            // The coordinator persists the session itself; AppKit must not save or
            // restore these windows.
            window.isRestorable = false
            // Tabs are the policy, not the system preference: every repository window
            // joins the key window's tab group when it is first ordered front.
            // `.automatic` would follow System Settings > "Prefer tabs", whose default
            // ("in full screen") yields separate windows.
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "repository"
            services.windows[windowID] = window
            let coordinator = services.coordinator
            coordinator.windowDidAttach(windowID, sceneRoot: sceneRoot)
            let center = NotificationCenter.default
            let id = windowID
            observers = [
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { coordinator.windowDidBecomeKey(id) }
                },
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { coordinator.windowDidResignKey(id) }
                },
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main)
                { [weak window] _ in
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        coordinator.windowOcclusionChanged(id, visible: window.occlusionState.contains(.visible))
                    }
                },
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        coordinator.windowWillClose(id, sceneRoot: self.sceneRoot)
                        self.detach()
                    }
                },
            ]
            // Notifications sent before the observers existed are not replayed.
            coordinator.windowOcclusionChanged(windowID, visible: window.occlusionState.contains(.visible))
            if window.isKeyWindow { coordinator.windowDidBecomeKey(windowID) }
        }

        func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            if window != nil { services.windows[windowID] = nil }
            window = nil
        }
    }
}
