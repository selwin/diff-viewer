import AppKit
import SwiftUI

/// Handles folders opened from Finder or the Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openHandler: (@MainActor (URL) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        openHandler?(url)
    }
}

@main
struct DiffViewerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task {
                    let state = appState
                    delegate.openHandler = { url in Task { await state.openRepo(at: url) } }
                    await appState.restoreLastRepo()
                    DebugLaunchOptions.apply(to: appState)
                }
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
                Divider()
                Button("Next Change") { appState.nextChange() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(appState.changeBlockCount == 0)
                Button("Previous Change") { appState.previousChange() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(appState.changeBlockCount == 0)
                Divider()
                Button("Increase Font Size") { appState.adjustFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Font Size") { appState.adjustFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Font Size") { appState.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}
