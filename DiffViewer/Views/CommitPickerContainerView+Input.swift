import AppKit

/// The table's data source and delegate: rows come from `state`, and a selection the
/// keyboard or type-select makes becomes the highlight.
extension CommitPickerContainerView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        state.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard state.rows.indices.contains(row) else { return nil }
        let cell =
            tableView.makeView(withIdentifier: ScopeRowContentView.identifier, owner: nil) as? ScopeRowContentView
            ?? ScopeRowContentView(frame: .zero)
        let entry = state.rows[row]
        cell.configure(
            ScopeRowContentView.Content(
                gutterTitle: entry.dayLabel?.title, gutterSubtitle: entry.dayLabel?.subtitle,
                subject: entry.commit.subject, showsPill: entry.isDisplayedScope, trailing: entry.commit.ref.shortSha,
                trailingStyle: .hash))
        // Read the row back from the cell: a recycled cell can move.
        cell.onActivate = { [weak self, weak cell] in
            guard let self, let cell else { return }
            let row = self.tableView.row(for: cell)
            if row >= 0 { activate(tableRow: row) }
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView =
            tableView.makeView(withIdentifier: CommitPickerTableRowView.identifier, owner: nil)
            as? CommitPickerTableRowView ?? CommitPickerTableRowView(frame: .zero)
        // A recycled row view keeps its last hover.
        rowView.isHovered = row == self.tableView.hoveredRow
        return rowView
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        state.rows.indices.contains(row) ? state.rows[row].commit.subject : nil
    }

    /// An empty selection changes nothing: the highlight is Working Tree or a row.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        if tableView.selectedRow >= 0 {
            highlight(tableRow: tableView.selectedRow)
        } else if state.highlightedTableRow != nil {
            syncSelection()
        }
    }
}
