import AppKit

/// The table's data source and delegate: items come from `state`, and a selection made by
/// a click or the keyboard becomes the highlight.
extension StashPickerContainerView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        state.items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard state.items.indices.contains(row) else { return nil }
        switch state.items[row] {
        case let .header(group):
            let header =
                tableView.makeView(withIdentifier: PickerGroupHeaderView.identifier, owner: nil)
                as? PickerGroupHeaderView ?? PickerGroupHeaderView()
            header.configure(title: group.title)
            return header
        case let .stash(stashRow):
            let view =
                tableView.makeView(withIdentifier: StashPickerRowView.identifier, owner: nil) as? StashPickerRowView
                ?? StashPickerRowView(frame: .zero)
            view.onActivate = activationHandler(for: view)
            view.configure(stashRow)
            return view
        }
    }

    /// Reads the row back from the cell: a recycled cell can move.
    private func activationHandler(for cell: NSView) -> () -> Void {
        { [weak self, weak cell] in
            guard let self, let cell else { return }
            let row = tableView.row(for: cell)
            if row >= 0 { activate(tableRow: row) }
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeight(forItem: row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        state.canHighlight(item: row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: PickerTableRowView.identifier, owner: nil) as? PickerTableRowView
            ?? PickerTableRowView()
    }

    /// An empty selection changes nothing: only the pointer leaving clears the highlight.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        if tableView.selectedRow >= 0 {
            highlight(item: tableView.selectedRow)
        } else if state.highlightedItemIndex != nil {
            syncSelection()
        }
    }
}
