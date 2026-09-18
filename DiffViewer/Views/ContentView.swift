import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppServices.self) private var services
    @Environment(WindowState.self) private var windowState
    @Environment(Preferences.self) private var preferences
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        @Bindable var windowState = windowState
        @Bindable var preferences = preferences
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            detail
        }
        .navigationTitle(windowState.title)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            let coordinator = services.coordinator
            let origin = WindowCoordinator.OpenOrigin.window(windowState.id)
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await coordinator.open(WindowCoordinator.OpenRequest(url: url, origin: origin)) }
            }
            return true
        }
        // The window title still names the tab and the Window menu; only the toolbar's
        // copy goes, so the pickers can follow the name. `.navigation` is the one placement
        // on the leading side, and it sits before the toolbar's own title: `.automatic`,
        // `.secondaryAction`, `.principal` and `.toolbar(id:)` items all land on the
        // trailing side next to the diff buttons.
        .toolbar(removing: .title)
        .toolbar {
            // Xcode-scheme-picker style: the repository, what is checked out, and what the
            // panes compare.
            ToolbarItem(placement: .navigation) {
                Text(windowState.title)
                    .font(.headline)
                    // The title the toolbar drew dimmed with the window; this one has to.
                    .foregroundStyle(appearsActive ? .primary : .tertiary)
            }
            // A bare name, not a glass pill.
            .sharedBackgroundVisibility(.hidden)
            // One item, so the toolbar draws one capsule around both: menus in a
            // `ToolbarItemGroup` or a `ControlGroup` each get their own.
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 4) {
                    BranchPickerView()
                    ScopePickerView()
                }
            }
            // The toolbar's title carried the flexible space that kept the buttons on the
            // trailing edge; without it they close up behind the pickers. `ToolbarSpacer`
            // is ignored here, a `Spacer` item is not.
            ToolbarItem(placement: .primaryAction) { Spacer() }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    windowState.previousChange()
                } label: {
                    Label("Previous Change", systemImage: "chevron.up")
                }
                .help("Previous change (⌘↑)")
                .disabled(windowState.changeBlockCount == 0)
                Button {
                    windowState.nextChange()
                } label: {
                    Label("Next Change", systemImage: "chevron.down")
                }
                .help("Next change (⌘↓)")
                .disabled(windowState.changeBlockCount == 0)
                Toggle(isOn: $preferences.hideWhitespace) {
                    Label("Hide Whitespace", systemImage: "arrow.left.and.right.text.vertical")
                }
                .help("Hide whitespace-only changes (⇧⌘W)")
                Toggle(isOn: $preferences.collapseUnchanged) {
                    Label("Collapse Unchanged", systemImage: "rectangle.compress.vertical")
                }
                .help("Collapse unchanged lines (⇧⌘U)")
                Button {
                    Task { await windowState.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { windowState.errorMessage != nil },
                set: { if !$0 { windowState.errorMessage = nil } }
            )
        ) {
            Button("OK") { windowState.errorMessage = nil }
        } message: {
            Text(windowState.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if windowState.isEmpty {
            ContentUnavailableView {
                Label("No Repository", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Open a git repository to view its changes.")
            } actions: {
                Button("Open Repository…") { services.coordinator.presentOpenPanel(from: .window(windowState.id)) }
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            // Identified by the selection so switching detail views starts a fresh
            // renderer rather than reusing the previous one's state.
            switch windowState.detailSelection {
            case .allChanges, .files:
                // One id for every changeset, All changes included: the loader clears its
                // content the moment a new one starts, so the same view takes the next
                // document in place instead of being rebuilt around it.
                ChangesetDetailView()
                    .id("changeset")
            case .file:
                if let file = windowState.selectedFile {
                    DiffDetailView(file: file)
                        .id(file.id)
                } else {
                    // The selected file is gone from the list; the next refresh decides
                    // where the selection lands.
                    selectFilePlaceholder
                }
            case .nothing:
                selectFilePlaceholder
            }
        }
    }

    private var selectFilePlaceholder: some View {
        ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
    }
}
