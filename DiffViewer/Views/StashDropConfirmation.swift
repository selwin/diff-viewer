import AppKit

/// Asks before dropping a stash. A view concern, as in `BranchDeleteConfirmation`:
/// `WindowState.dropStash` runs what it is given, so its tests never put up a dialog.
@MainActor
enum StashDropConfirmation {
    /// The windows asking, held from the click until the answer, so a second click cannot
    /// stack another alert or a second drop there. Kept here rather than in the picker
    /// popover, which may close while the alert is up.
    private static var askingWindows: Set<ObjectIdentifier> = []

    /// True when the reader agreed. Hangs on `window` as a sheet, or runs app-modal
    /// without one. False without asking while that window is already asking.
    static func confirm(_ entry: StashEntry, window: NSWindow?) async -> Bool {
        let alert = alert(for: entry)
        // App-modal blocks every click, so only a sheet needs the guard.
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        let id = ObjectIdentifier(window)
        guard askingWindows.insert(id).inserted else { return false }
        defer { askingWindows.remove(id) }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    private static func alert(for entry: StashEntry) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Drop stash “\(entry.message)”?"
        alert.informativeText = "Its changes will be removed from the stash list and can't be popped again."
        alert.alertStyle = .warning

        alert.addButton(withTitle: "Drop")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
