import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            detail
        }
        .navigationTitle(appState.repoName)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            let state = appState
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await state.openRepo(at: url) }
            }
            return true
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.previousChange()
                } label: {
                    Label("Previous Change", systemImage: "chevron.up")
                }
                .help("Previous change (⌘↑)")
                .disabled(appState.changeBlockCount == 0)
                Button {
                    appState.nextChange()
                } label: {
                    Label("Next Change", systemImage: "chevron.down")
                }
                .help("Next change (⌘↓)")
                .disabled(appState.changeBlockCount == 0)
                Toggle(isOn: $appState.hideWhitespace) {
                    Label("Hide Whitespace", systemImage: "arrow.left.and.right.text.vertical")
                }
                .help("Hide whitespace-only changes (⇧⌘W)")
                Toggle(isOn: $appState.collapseUnchanged) {
                    Label("Collapse Unchanged", systemImage: "rectangle.compress.vertical")
                }
                .help("Collapse unchanged lines (⇧⌘U)")
                Button {
                    Task { await appState.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
            }
        }
        .alert("Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if appState.repoRoot == nil {
            ContentUnavailableView {
                Label("No Repository", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Open a git repository to view its changes.")
            } actions: {
                Button("Open Repository…") { appState.presentOpenPanel() }
                    .keyboardShortcut(.defaultAction)
            }
        } else if let file = appState.selectedFile {
            DiffDetailView(file: file)
                .id(file.id)
        } else {
            ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
        }
    }
}
