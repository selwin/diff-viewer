import AppKit

/// Asks before deleting a branch whose upstream is gone. A view concern, as in
/// `FileActionRunner`: `WindowState.deleteBranch` runs what it is given, so its tests
/// never put up a dialog. Always asked: deleting may make the branch's unique commits hard
/// to recover.
@MainActor
enum BranchDeleteConfirmation {
    /// The windows asking, held from the click until the answer, so a second click cannot
    /// stack another alert or a second delete there. Kept here rather than in the picker
    /// popover, which may close while the alert is up.
    private static var askingWindows: Set<ObjectIdentifier> = []

    /// True when the reader agreed. Hangs on `window` as a sheet, or runs app-modal
    /// without one. False without asking while that window is already asking.
    static func confirm(_ branch: LocalBranch, window: NSWindow?) async -> Bool {
        let alert = alert(for: branch)
        // App-modal blocks every click, so only a sheet needs the guard.
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        let id = ObjectIdentifier(window)
        guard askingWindows.insert(id).inserted else { return false }
        defer { askingWindows.remove(id) }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    /// Names the upstream from the row the reader confirmed.
    private static func alert(for branch: LocalBranch) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Delete branch \(branch.name)?"
        let consequence = "Commits unique to this branch may be hard to recover."
        alert.informativeText =
            branch.upstream.map { "Its upstream \($0.shortName) is gone. \(consequence)" } ?? consequence
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
