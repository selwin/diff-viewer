import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
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
        .navigationTitle(windowState.repoName)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            let model = model
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await model.open(url) }
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
                Button("Open Repository…") { model.presentOpenPanel() }
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
