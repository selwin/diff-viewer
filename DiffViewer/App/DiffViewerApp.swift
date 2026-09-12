import AppKit
import SwiftUI

/// Handles folders opened from Finder or the Dock icon. URLs that arrive before the
/// app has wired its handler are kept until it does.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openHandler: (@MainActor (URL) -> Void)? {
        didSet {
            guard let openHandler else { return }
            let queued = queuedURLs
            queuedURLs = []
            queued.forEach(openHandler)
        }
    }

    private var queuedURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let openHandler { openHandler(url) } else { queuedURLs.append(url) }
        }
    }
}

@main
struct DiffViewerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup(for: RepositoryRoot.self) { $root in
            RepositoryWindow(sceneRoot: $root, services: services, delegate: delegate)
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            RepositoryCommands(services: services)
        }
    }
}

/// The root view of one window: owns that window's state and registers it.
struct RepositoryWindow: View {
    @Binding var sceneRoot: RepositoryRoot?
    let services: AppServices
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var state: WindowState

    init(sceneRoot: Binding<RepositoryRoot?>, services: AppServices, delegate: AppDelegate) {
        _sceneRoot = sceneRoot
        self.services = services
        self.delegate = delegate
        _state = State(initialValue: services.makeWindowState())
    }

    var body: some View {
        ContentView()
            .environment(services)
            .environment(services.preferences)
            .environment(state)
            .background(WindowAccessor(windowID: state.id, sceneRoot: sceneRoot, services: services))
            .focusedSceneValue(\.windowState, state)
            .task {
                let coordinator = services.coordinator
                // Finder URLs queued in the delegate must reach the coordinator before the
                // first registration decides whether to reopen the recent repository.
                delegate.openHandler = { url in coordinator.openFromApp(url) }
                services.installOpenWindow(openWindow)
                coordinator.register(state, sceneRoot: sceneRoot) { sceneRoot = $0 }
                DebugLaunchOptions.apply(to: services)
            }
    }
}

struct WindowStateFocusKey: FocusedValueKey {
    typealias Value = WindowState
}

extension FocusedValues {
    /// The state of the window that has keyboard focus, for menu commands.
    var windowState: WindowState? {
        get { self[WindowStateFocusKey.self] }
        set { self[WindowStateFocusKey.self] = newValue }
    }
}

/// Menu commands. Repository actions target the focused window and are disabled
/// when no window is focused; settings bind to the app-wide preferences.
struct RepositoryCommands: Commands {
    let services: AppServices
    @FocusedValue(\.windowState) private var windowState

    private var origin: WindowCoordinator.OpenOrigin {
        windowState.map { .window($0.id) } ?? .app
    }

    var body: some Commands {
        let preferences = services.preferences
        let coordinator = services.coordinator
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") { coordinator.presentOpenPanel(from: origin) }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(preferences.recentRepositoryRoots, id: \.self) { root in
                    Button(root.name) {
                        let request = WindowCoordinator.OpenRequest(url: root.url, origin: origin)
                        Task { await coordinator.open(request) }
                    }
                }
            }
            .disabled(preferences.recentRepositoryRoots.isEmpty)
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { Task { await windowState?.refresh() } }
                .keyboardShortcut("r")
                .disabled(windowState == nil)
            Toggle("Hide Whitespace Changes", isOn: Binding(
                get: { preferences.hideWhitespace },
                set: { preferences.hideWhitespace = $0 }
            ))
            .keyboardShortcut("w", modifiers: [.command, .shift])
            Toggle("Collapse Unchanged Lines", isOn: Binding(
                get: { preferences.collapseUnchanged },
                set: { preferences.collapseUnchanged = $0 }
            ))
            .keyboardShortcut("u", modifiers: [.command, .shift])
            Divider()
            Button("Next Change") { windowState?.nextChange() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled((windowState?.changeBlockCount ?? 0) == 0)
            Button("Previous Change") { windowState?.previousChange() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled((windowState?.changeBlockCount ?? 0) == 0)
            Divider()
            Button("Increase Font Size") { preferences.adjustFontSize(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Font Size") { preferences.adjustFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Font Size") { preferences.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
