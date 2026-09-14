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

    func run(_ action: FileAction, on file: ChangedFile) async {
        if action.isDestructive(for: file), preferences.confirmDestructiveFileActions {
            let alert = Self.confirmation(for: action, on: file)
            let response: NSApplication.ModalResponse
            if let window {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on {
                preferences.confirmDestructiveFileActions = false
            }
        }
        await windowState.perform(action, on: file)
    }

    /// The alert for one destructive action. Both wordings live in one switch so the
    /// question, the consequence, and the button verb cannot drift apart.
    private static func confirmation(for action: FileAction, on file: ChangedFile) -> NSAlert {
        let alert = NSAlert()
        switch action {
        case .trash:
            alert.messageText = "Move \(file.fileName) to the Trash?"
            alert.informativeText = "The file is untracked; it can be recovered from the Trash."
            alert.addButton(withTitle: "Delete")
        default:
            alert.messageText = "Discard changes to \(file.fileName)?"
            alert.informativeText = "Unstaged changes to this file will be lost."
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
