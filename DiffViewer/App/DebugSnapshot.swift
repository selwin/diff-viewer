import Foundation

/// Development aid (Debug builds only): `DIFFVIEWER_SELECT=<changed file id>` selects
/// that sidebar entry shortly after launch, so the diff view can be screenshotted
/// without any clicking. Ids look like `unstaged:src/app.swift`.
enum DebugLaunchOptions {
    @MainActor
    static func apply(to appState: AppState) {
        #if DEBUG
        guard let selection = ProcessInfo.processInfo.environment["DIFFVIEWER_SELECT"], !selection.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            appState.selectedFileID = selection
        }
        #endif
    }
}
