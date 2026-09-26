import AppKit

/// Confirms a destructive sidebar action, then hands it to the window's state.
///
/// The confirmation lives here rather than in `WindowState` because asking the reader a
/// question is a view concern: `perform` always runs what it is given, so the state's
/// tests never have to put up a dialog to exercise an action. `NSAlert` is used instead
/// of SwiftUI's `.alert` because only it can host the "Don't ask again" checkbox, and it
/// is already how the app asks a question (`WindowCoordinator.presentError`).
@MainActor
struct FileActionRunner {
    let windowState: WindowState
    let preferences: Preferences
    /// The window to attach the confirmation sheet to; nil falls back to an app-modal alert.
    let window: NSWindow?

    func run(_ action: FileAction, on files: [ChangedFile]) async {
        // The reader is still answering a question about the last trigger.
        guard !windowState.isConfirmingFileAction else { return }
        if action.isDestructive(for: files), preferences.confirmDestructiveFileActions {
            guard await confirm(action, on: files) else { return }
        }
        await windowState.perform(action, on: files)
    }

    /// Asks before a destructive action; true when the reader agreed. The flag is held
    /// only while the alert is up, so every answer, Cancel included, clears it.
    private func confirm(_ action: FileAction, on files: [ChangedFile]) async -> Bool {
        windowState.isConfirmingFileAction = true
        defer { windowState.isConfirmingFileAction = false }
        let alert = Self.confirmation(for: action, on: files)
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            preferences.confirmDestructiveFileActions = false
        }
        return true
    }

    /// The alert for one destructive action, asked once however many rows it covers. All
    /// four wordings live in one switch so the question, the consequence, and the button
    /// verb cannot drift apart. A single file is named; a batch is counted, because the
    /// reader can see which rows are highlighted and a list of names would not fit.
    private static func confirmation(for action: FileAction, on files: [ChangedFile]) -> NSAlert {
        let alert = NSAlert()
        let singleFile = files.count == 1 ? files.first : nil
        switch action {
        case .trash:
            alert.messageText =
                singleFile.map { "Move \($0.fileName) to the Trash?" }
                ?? "Move \(files.count) files to the Trash?"
            alert.informativeText =
                singleFile != nil
                ? "The file is untracked; it can be recovered from the Trash."
                : "The files are untracked; they can be recovered from the Trash."
            alert.addButton(withTitle: "Delete")
        default:
            alert.messageText =
                singleFile.map { "Discard changes to \($0.fileName)?" }
                ?? "Discard changes to \(files.count) files?"
            alert.informativeText =
                singleFile != nil
                ? "Unstaged changes to this file will be lost."
                : "Unstaged changes to these files will be lost."
            alert.addButton(withTitle: "Discard")
        }
        alert.alertStyle = .warning
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        return alert
    }
}

extension FileActionRunner {
    /// Hangs the confirmation on `windowState`'s own window, so the sidebar and the
    /// Changes menu build the runner the same way.
    init(windowState: WindowState, services: AppServices) {
        self.init(windowState: windowState, preferences: services.preferences, window: services.windows[windowState.id])
    }
}
