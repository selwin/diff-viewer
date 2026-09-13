import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppServices.self) private var services
    @Environment(WindowState.self) private var windowState
    @Environment(Preferences.self) private var preferences

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
        .navigationSubtitle(windowState.subtitle)
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
        .toolbar {
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
        .alert("Error", isPresented: Binding(
            get: { windowState.errorMessage != nil },
            set: { if !$0 { windowState.errorMessage = nil } }
        )) {
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
        } else if let file = windowState.selectedFile {
            DiffDetailView(file: file)
                .id(file.id)
        } else {
            ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
        }
    }
}
