import AppKit

/// Row highlight and buttons.
extension BranchPickerContainerView {
    /// Sets `cell`'s highlight and its Pull and Push, Publish, or Delete from the current
    /// snapshot. The buttons show on the highlighted row, and wherever one runs, in the
    /// Switch tab only. `animated` lets an on-screen cell ease its pills in or out as the
    /// highlight moves. `shortcuts` decides which pills show their key.
    func configureHighlightAndButtons(
        of cell: BranchPickerRowView, row: Int, animated: Bool, shortcuts: SyncShortcutTargets
    ) {
        let isHighlighted = row == state.highlightedTableRow
        guard state.tab == .switchBranch, let buttons = state.syncButtons(forTableRow: row),
            let branch = state.branch(forTableRow: row)
        else {
            // No pills, so nothing needs the status's room.
            cell.setHighlight(isHighlighted, hidesStatus: false)
            cell.syncButtons = nil
            cell.showSyncButtons(false, animated: false)
            return
        }
        let view = cell.syncButtons ?? BranchRowSyncButtons(style: .rowPills)
        // The popover stays up during an operation, and the search field keeps the
        // keyboard: a click must not leave focus on a button that is about to disable.
        view.configure(
            buttons, isRevealed: isHighlighted, branch: branch.name,
            onPull: { [weak self] name in
                self?.onPull(name)
                self?.returnFocusToSearchField()
            },
            onPush: { [weak self] name in
                self?.onPush(name)
                self?.returnFocusToSearchField()
            },
            onPublish: { [weak self] name, remote in
                self?.onPublish(name, remote)
                self?.returnFocusToSearchField()
            },
            onDelete: { [weak self] in
                self?.onDelete(branch, self?.window)
                self?.returnFocusToSearchField()
            })
        view.setShortcutGlyphs(pull: shortcuts.pull == .row(tableRow: row), push: shortcuts.push == .row(tableRow: row))
        cell.syncButtons = view
        // The status gives way only to pills that show.
        cell.setHighlight(isHighlighted, hidesStatus: isHighlighted && view.shouldShow)
        cell.showSyncButtons(view.shouldShow, animated: animated)
    }

    /// Re-configures whichever of `rows` have a cell on screen.
    func updateRows(_ rows: some Sequence<Int>, animated: Bool, shortcuts: SyncShortcutTargets) {
        for row in rows where row >= 0 && row < tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BranchPickerRowView
            else { continue }
            configureHighlightAndButtons(of: cell, row: row, animated: animated, shortcuts: shortcuts)
        }
    }
}
