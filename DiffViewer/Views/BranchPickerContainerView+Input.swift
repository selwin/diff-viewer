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
                tableView.makeView(withIdentifier: BranchPickerGroupHeaderView.identifier, owner: nil)
                as? BranchPickerGroupHeaderView ?? BranchPickerGroupHeaderView(frame: .zero)
            cell.configure(group)
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
        state.canHighlight(tableRow: row) ? BranchPickerMetrics.rowHeight : BranchPickerMetrics.headerRowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        state.canHighlight(tableRow: row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView =
            tableView.makeView(withIdentifier: CommitPickerTableRowView.identifier, owner: nil)
            as? CommitPickerTableRowView ?? CommitPickerTableRowView(frame: .zero)
        rowView.style = .branchPicker
        return rowView
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
