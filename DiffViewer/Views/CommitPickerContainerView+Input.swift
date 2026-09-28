import AppKit

/// The table's data source and delegate: items come from `state`, and a selection made by
/// a click or the keyboard becomes the highlight.
extension CommitPickerContainerView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        state.items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard state.items.indices.contains(row) else { return nil }
        let cell: NSTableCellView
        switch state.items[row] {
        case let .header(section, _):
            let header =
                tableView.makeView(withIdentifier: PickerGroupHeaderView.identifier, owner: nil)
                as? PickerGroupHeaderView ?? PickerGroupHeaderView(frame: .zero)
            header.configure(title: section.title)
            return header
        case let .workingTree(entry):
            let view = makeRowView()
            view.configure(entry)
            cell = view
        case let .commit(entry):
            let view = makeRowView()
            view.configure(entry)
            cell = view
        case let .message(message):
            let view =
                tableView.makeView(withIdentifier: CommitPickerMessageRowView.identifier, owner: nil)
                as? CommitPickerMessageRowView ?? CommitPickerMessageRowView(frame: .zero)
            view.configure(message)
            view.onActivate = message.action == nil ? nil : activationHandler(for: view)
            cell = view
        }
        configureHighlight(of: cell, row: row)
        return cell
    }

    private func makeRowView() -> CommitPickerRowView {
        let view =
            tableView.makeView(withIdentifier: CommitPickerRowView.identifier, owner: nil) as? CommitPickerRowView
            ?? CommitPickerRowView(frame: .zero)
        view.onActivate = activationHandler(for: view)
        view.copyButton.onCopy = { [weak self] in self?.returnFocusToSearchField() }
        return view
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
            ?? PickerTableRowView(frame: .zero)
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
