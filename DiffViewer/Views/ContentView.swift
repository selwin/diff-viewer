import SwiftUI

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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $appState.hideWhitespace) {
                    Label("Hide Whitespace", systemImage: "arrow.left.and.right.text.vertical")
                }
                .help("Hide whitespace-only changes (⇧⌘W)")
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
            VStack(alignment: .leading) {
                Text(file.path).font(.headline)
                Text(file.kind.label).foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
        }
    }
}
