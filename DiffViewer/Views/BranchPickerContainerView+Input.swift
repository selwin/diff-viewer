import AppKit

/// The table's data source and delegate: items come from `state`, and a selection made by
/// a click or the keyboard becomes the highlight.
extension BranchPickerContainerView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        state.items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard state.items.indices.contains(row) else { return nil }
        switch state.items[row] {
        case let .header(group):
            let cell =
                tableView.makeView(withIdentifier: PickerGroupHeaderView.identifier, owner: nil)
                as? PickerGroupHeaderView ?? PickerGroupHeaderView(frame: .zero)
            cell.configure(title: group.title)
            return cell
        case let .branch(entry):
            let cell =
                tableView.makeView(withIdentifier: BranchPickerRowView.identifier, owner: nil)
                as? BranchPickerRowView ?? BranchPickerRowView(frame: .zero)
            cell.configure(entry)
            configureHighlightAndButtons(of: cell, row: row, animated: false)
            // No callback on a row that cannot be activated: the action must not be offered.
            guard state.canActivate(tableRow: row) else {
                cell.onActivate = nil
                return cell
            }
            // Read the row back from the cell: a recycled cell can move.
            cell.onActivate = { [weak self, weak cell] in
                guard let self, let cell else { return }
                let row = self.tableView.row(for: cell)
                if row >= 0 { activate(tableRow: row) }
            }
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        state.canHighlight(tableRow: row) ? PickerMetrics.rowHeight : PickerMetrics.headerRowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        state.canHighlight(tableRow: row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: PickerTableRowView.identifier, owner: nil) as? PickerTableRowView
            ?? PickerTableRowView(frame: .zero)
    }

    /// An empty selection changes nothing: the highlight is always a row.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        if tableView.selectedRow >= 0 {
            highlight(tableRow: tableView.selectedRow)
        } else if state.highlightedTableRow != nil {
            syncSelection()
        }
    }
}

/// Key equivalents the popover answers before the main menu.
extension BranchPickerContainerView {
    /// ⌘R fetches and ⌘N opens the New Branch sheet while the popover is key. The key
    /// window's views see a key equivalent before the main menu does, and this runs
    /// whichever view has focus, the search field's editor included, so the menu never
    /// gets them. Once the popover closes this view is out of the key window and ⌘R is
    /// Refresh again.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard modifiers == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": onFetch()
        // Taken even while the row is off, so it never falls through to the menu.
        case "n": if newBranchRow.isEnabled { onNewBranch() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
