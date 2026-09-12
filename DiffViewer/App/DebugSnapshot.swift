import Foundation

import AppKit

/// Development aids (Debug builds only) so the app can be screenshotted without clicking:
/// - `DIFFVIEWER_SELECT=<changed file id>` selects that sidebar entry after launch
///   (ids look like `unstaged:src/app.swift`).
/// - `DIFFVIEWER_APPEARANCE=dark|light` forces the app appearance.
enum DebugLaunchOptions {
    @MainActor
    static func apply(to appState: AppState) {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        switch env["DIFFVIEWER_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        guard let selection = env["DIFFVIEWER_SELECT"], !selection.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            appState.selectedFileID = selection
        }
        #endif
    }
}
