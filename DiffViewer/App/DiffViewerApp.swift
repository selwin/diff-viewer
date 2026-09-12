import SwiftUI

@main
struct DiffViewerApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task { await appState.restoreLastRepo() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { appState.presentOpenPanel() }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(appState.recentRepos, id: \.path) { url in
                        Button(url.lastPathComponent) {
                            Task { await appState.openRepo(at: url) }
                        }
                    }
                }
                .disabled(appState.recentRepos.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await appState.refresh() } }
                    .keyboardShortcut("r")
                Toggle("Hide Whitespace Changes", isOn: Binding(
                    get: { appState.hideWhitespace },
                    set: { appState.hideWhitespace = $0 }
                ))
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
    }
}
