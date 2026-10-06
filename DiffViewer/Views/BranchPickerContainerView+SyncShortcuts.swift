import AppKit

/// ⌘P and ⇧⌘P in the picker: each presses the highlighted row's Push or Pull when that
/// button can act, else the header's, else nothing.
extension BranchPickerContainerView {
    func pressSyncShortcut(_ shortcut: SyncShortcut) {
        switch state.shortcutTarget(for: shortcut) {
        case .header?:
            let pressed = shortcut == .pull ? header.pressPull() : header.pressPush()
            if !pressed { NSSound.beep() }
        case let .row(tableRow)?:
            pressRowButton(shortcut, tableRow: tableRow)
        case nil:
            NSSound.beep()
        }
        // A Publish menu closed without a choice runs no callback to do this.
        returnFocusToSearchField()
    }

    /// Acts on the row's branch as it is now. The pills' own callbacks are bypassed, so a
    /// highlighted row scrolled out of view still acts; only a remote menu needs its cell.
    private func pressRowButton(_ shortcut: SyncShortcut, tableRow: Int) {
        guard let branch = state.branch(forTableRow: tableRow), let buttons = state.syncButtons(forTableRow: tableRow)
        else { return NSSound.beep() }
        switch (shortcut, buttons.publish) {
        case (.pull, _): onPull(branch.name)
        case (.push, nil): onPush(branch.name)
        case let (.push, .remote(remote)?): onPublish(branch.name, remote)
        case (.push, .menu?): showPublishMenu(forTableRow: tableRow)
        }
    }

    /// Opens the row's remote menu from its Publish pill, brought on screen and settled
    /// first. Never falls back to another branch: without the pill, it beeps.
    private func showPublishMenu(forTableRow tableRow: Int) {
        tableView.scrollRowToVisible(tableRow)
        guard let cell = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: true) as? BranchPickerRowView
        else { return NSSound.beep() }
        configureHighlightAndButtons(of: cell, row: tableRow, animated: false, shortcuts: state.shortcutTargets)
        cell.layoutSubtreeIfNeeded()
        if cell.syncButtons?.pressPush() != true { NSSound.beep() }
    }
}
