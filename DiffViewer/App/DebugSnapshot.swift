import Foundation

import AppKit

/// Development aids (Debug builds only) so the app can be screenshotted without clicking:
/// - `DIFFVIEWER_SELECT=<changed file id>` selects that sidebar entry after launch
///   (ids look like `unstaged:src/app.swift`).
/// - `DIFFVIEWER_APPEARANCE=dark|light` forces the app appearance.
/// - `DIFFVIEWER_NEXT=<n>` presses Next Change n times once the diff has loaded.
/// - `DIFFVIEWER_SNAPSHOT=<path.png>` renders the window contents to a PNG afterwards
///   (works even when the window is on another Space, unlike `screencapture`).
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
        let nextCount = Int(env["DIFFVIEWER_NEXT"] ?? "") ?? 0
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            appState.selectedFileID = selection
            if nextCount > 0 {
                try? await Task.sleep(for: .seconds(2))
                for _ in 0..<nextCount { appState.nextChange() }
            }
            if let path = env["DIFFVIEWER_SNAPSHOT"], !path.isEmpty {
                try? await Task.sleep(for: .seconds(nextCount > 0 ? 1 : 3))
                snapshot(to: path)
            }
        }
        #endif
    }

    @MainActor
    private static func snapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
