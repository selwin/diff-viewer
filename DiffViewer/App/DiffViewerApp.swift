import AppKit
import SwiftUI

/// Handles folders opened from Finder or the Dock icon, the tab bar's "+" button, and
/// the session snapshot written at quit. URLs that arrive before the app has wired its
/// handler are kept until it does.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opens an empty window; set once the app's services exist.
    var newTabHandler: (@MainActor () -> Void)?
    /// Writes the session snapshot; set once the app's services exist.
    var terminationHandler: (@MainActor () -> Void)?

    /// The one place the session is written at quit. Window closes AppKit performs
    /// afterwards do not rewrite it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationHandler?()
        return .terminateNow
    }

    /// AppKit sends this up the responder chain from the tab bar's "+" button; the
    /// button is only shown when something implements it.
    @objc func newWindowForTab(_ sender: Any?) {
        newTabHandler?()
    }

    var openHandler: (@MainActor (URL) -> Void)? {
        didSet {
            guard let openHandler else { return }
            let queued = queuedURLs
            queuedURLs = []
            queued.forEach(openHandler)
        }
    }

    private var queuedURLs: [URL] = []

    /// Tells the coordinator launch has finished; set once the app's services exist.
    /// The first window registers before launch finishes, so the coordinator waits
    /// for this before deciding whether to restore the saved session.
    var launchHandler: (@MainActor () -> Void)? {
        didSet {
            if hasFinishedLaunching { launchHandler?() }
        }
    }

    private var hasFinishedLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        hasFinishedLaunching = true
        launchHandler?()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let openHandler { openHandler(url) } else { queuedURLs.append(url) }
        }
    }
}

@main
struct DiffViewerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var services = AppServices(defaults: DebugLaunchOptions.defaults)

    var body: some Scene {
        WindowGroup(id: AppServices.repositorySceneID, for: RepositoryRoot.self) { $root in
            RepositoryWindow(sceneRoot: $root, services: services, delegate: delegate)
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            RepositoryCommands(services: services)
            ChangesCommands(services: services)
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
            // Folders opened from Finder reach `AppDelegate.application(_:open:)` and
            // are routed by the coordinator. Letting every window "handle" the external
            // event keeps SwiftUI from presenting an extra empty window for it; a
            // scene-level `handlesExternalEvents(matching: [])` would instead present no
            // window at all when the app is launched by opening a folder.
            .handlesExternalEvents(preferring: [], allowing: ["*"])
            .task {
                // When the app is launched by opening a folder, SwiftUI closes the launch
                // window and presents it again for the external event, so this task runs
                // twice for one window. The closed state is torn down; start over.
                if state.isClosed { state = services.makeWindowState() }
                // Before registering: Finder URLs queued in the delegate must reach the
                // coordinator before launch finishes, when it decides whether to restore.
                services.installAppHooks(delegate: delegate, openWindow: openWindow)
                services.coordinator.register(state, sceneRoot: sceneRoot) { sceneRoot = $0 }
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

struct FileListWindowStateFocusKey: FocusedValueKey {
    typealias Value = WindowState
}

extension FocusedValues {
    /// The window whose file list has focus, for the Changes menu.
    var fileListWindowState: WindowState? {
        get { self[FileListWindowStateFocusKey.self] }
        set { self[FileListWindowStateFocusKey.self] = newValue }
    }
}

/// Menu commands. Repository actions target the focused window and are disabled
/// when no window is focused; settings bind to the app-wide preferences.
struct RepositoryCommands: Commands {
    let services: AppServices
    @FocusedValue(\.windowState) private var windowState
    @Environment(\.openWindow) private var openWindow

    private var origin: WindowCoordinator.OpenOrigin {
        windowState.map { .window($0.id) } ?? .app
    }

    var body: some Commands {
        let preferences = services.preferences
        let coordinator = services.coordinator
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { openWindow(id: AppServices.repositorySceneID) }
                .keyboardShortcut("t")
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
            Divider()
            Button("Commit…") { windowState?.isCommitSheetPresented = true }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!(windowState?.canOpenCommitSheet ?? false))
            Button("Choose Commit…") { windowState?.isCommitPickerPresented = true }
                .keyboardShortcut("k")
                .disabled(!(windowState?.canOpenCommitPicker ?? false))
            Button("Choose Branch…") { windowState?.isBranchPickerPresented = true }
                .keyboardShortcut("b")
                .disabled(!(windowState?.canOpenBranchPicker ?? false))
        }
        // Replaced rather than extended: this group holds the default Find submenu, which
        // would otherwise claim ⌘F a second time.
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { windowState?.showFindBar() }
                    .keyboardShortcut("f")
                    .disabled(!(windowState?.isFindAvailable ?? false))
                Button("Find Next") { windowState?.find.next() }
                    .keyboardShortcut("g")
                    .disabled(!(windowState?.canStepFind ?? false))
                Button("Find Previous") { windowState?.find.previous() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!(windowState?.canStepFind ?? false))
                Divider()
                // Menu key equivalents fire before the field editor, so these work while typing.
                Button("Search Left Side") { windowState?.selectFindSide(.old) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(!(windowState?.canSelectFindSide ?? false))
                Button("Search Right Side") { windowState?.selectFindSide(.new) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(!(windowState?.canSelectFindSide ?? false))
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { Task { await windowState?.refresh() } }
                .keyboardShortcut("r")
                .disabled(windowState == nil)
            Toggle(
                "Hide Whitespace Changes",
                isOn: Binding(
                    get: { preferences.hideWhitespace },
                    set: { preferences.hideWhitespace = $0 }
                )
            )
            .keyboardShortcut("w", modifiers: [.command, .shift])
            Toggle(
                "Collapse Unchanged Lines",
                isOn: Binding(
                    get: { preferences.collapseUnchanged },
                    set: { preferences.collapseUnchanged = $0 }
                )
            )
            .keyboardShortcut("u", modifiers: [.command, .shift])
            Toggle(
                "Confirm Destructive File Actions",
                isOn: Binding(
                    get: { preferences.confirmDestructiveFileActions },
                    set: { preferences.confirmDestructiveFileActions = $0 }
                )
            )
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

/// The Changes menu: the sidebar's writes on the selected rows, with shortcuts. Scoped to
/// file-list focus, so ⌘⌫ still deletes text in the find bar and the commit sheet.
struct ChangesCommands: Commands {
    let services: AppServices
    @FocusedValue(\.fileListWindowState) private var windowState

    var body: some Commands {
        // Built once per menu update rather than once per item: each build scans the selection.
        let groups = availableGroups
        CommandMenu("Changes") {
            button("Stage", for: .stage, in: groups)
                .keyboardShortcut("s")
            button("Unstage", for: .unstage, in: groups)
                .keyboardShortcut("s", modifiers: [.command, .shift])
            button("Discard Changes…", for: .discard, in: groups)
                .keyboardShortcut(.delete, modifiers: .command)
            button("Move to Trash…", for: .trash, in: groups)
        }
    }

    /// The selection's writes, or none while a branch switch or a confirmation is in progress.
    private var availableGroups: [FileAction.WriteGroup] {
        guard let windowState, !windowState.isSwitchingBranch, !windowState.isConfirmingFileAction else {
            return []
        }
        return windowState.selectedWriteGroups
    }

    /// Disabled when `groups` has nothing for `action`.
    private func button(_ title: String, for action: FileAction, in groups: [FileAction.WriteGroup]) -> some View {
        let group = groups.first { $0.action == action }
        return Button(title) {
            guard let windowState, let group else { return }
            let runner = FileActionRunner(windowState: windowState, services: services)
            Task { await runner.run(group.action, on: group.files) }
        }
        .disabled(group == nil)
    }
}
