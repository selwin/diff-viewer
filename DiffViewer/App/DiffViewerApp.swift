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
    @State private var model = AppModel()

    var body: some Scene {
        let preferences = model.preferences
        let windowState = model.windowState
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(preferences)
                .environment(windowState)
                .task {
                    let model = model
                    delegate.openHandler = { url in Task { await model.open(url) } }
                    await model.restoreLastRepository()
                    DebugLaunchOptions.apply(to: model)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(preferences.recentRepositoryRoots, id: \.path) { url in
                        Button(url.lastPathComponent) {
                            Task { await model.open(url) }
                        }
                    }
                }
                .disabled(preferences.recentRepositoryRoots.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await windowState.refresh() } }
                    .keyboardShortcut("r")
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
                Button("Next Change") { windowState.nextChange() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(windowState.changeBlockCount == 0)
                Button("Previous Change") { windowState.previousChange() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(windowState.changeBlockCount == 0)
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
}
