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
                as? PickerGroupHeaderView ?? PickerGroupHeaderView(style: Self.groupHeaderStyle)
            cell.configure(title: group.title)
            return cell
        case let .branch(entry):
            let cell =
                tableView.makeView(withIdentifier: BranchPickerRowView.identifier, owner: nil)
                as? BranchPickerRowView ?? BranchPickerRowView(frame: .zero)
            cell.copyButton.onCopy = { [weak self] in self?.returnFocusToSearchField() }
            cell.configure(
                entry, trailing: state.trailingLabel(forTableRow: row, preview: mergePreview(forTableRow: row)),
                blockedReason: state.blockedReason(forTableRow: row), actionName: activationName(for: entry))
            configureHighlightAndButtons(of: cell, row: row, animated: false, shortcuts: state.shortcutTargets)
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

    /// By the item's kind: the current branch takes no highlight but is a full row.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        state.row(forTableRow: row) != nil ? BranchPickerStyle.rowHeight : BranchPickerStyle.sectionHeaderHeight
    }

    /// What VoiceOver calls a row's activation in the current tab.
    private func activationName(for row: BranchPickerRow) -> String {
        switch state.tab {
        case .merge: "Merge branch"
        case .switchBranch: row.kind == .remoteOnly ? "Check out branch" : "Switch to branch"
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        state.canHighlight(tableRow: row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: PickerTableRowView.identifier, owner: nil) as? PickerTableRowView
            ?? PickerTableRowView(style: Self.rowViewStyle)
    }

    /// Accepts table selections; restores a highlighted branch after external deselection.
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
    /// The footer, Return on it, and ⌘N, with the search's proposal; off while a switch runs.
    func createBranch() {
        guard newBranchRow.isEnabled else { return }
        onNewBranch(newBranchProposal)
    }

    /// ⌘R fetches, ⌘N opens New Branch, ⌘1 and ⌘2 pick a tab, ⌘C copies the highlighted
    /// branch's name, and ⌘P and ⇧⌘P push and pull. They are taken whichever view has
    /// focus, so the main menu only gets them once the popover closes.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        let hasSyncShortcutModifiers = modifiers == .command || modifiers == [.command, .shift]
        if hasSyncShortcutModifiers, event.charactersIgnoringModifiers?.lowercased() == "p" {
            pressSyncShortcut(modifiers.contains(.shift) ? .pull : .push)
            // Consume unavailable shortcuts too, so the main menu cannot act on another branch.
            return true
        }
        guard modifiers == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": onFetch()
        // Taken even while the row is off, so it never falls through to the menu.
        case "n": createBranch()
        case "1": selectTab(.switchBranch)
        case "2": selectTab(.merge)
        case "c":
            // With text selected in the query, or no row to copy (a resting selection
            // included), ⌘C is AppKit's.
            if let editor = searchField.currentEditor(), editor.selectedRange.length > 0 {
                return super.performKeyEquivalent(with: event)
            }
            guard let branch = state.copyableRow else { return super.performKeyEquivalent(with: event) }
            copyBranchName(branch.name, rowID: branch.id)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// The rows' right-click menu, and the copy it shares with ⌘C.
extension BranchPickerContainerView {
    func menu(forTableRow row: Int) -> NSMenu? {
        guard let branch = state.row(forTableRow: row) else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy Branch Name", action: #selector(copyBranchNameChosen), keyEquivalent: "")
        item.target = self
        // Bound now: a refresh can move or replace the row while the menu is open.
        item.representedObject = BranchNameCopy(name: branch.name, rowID: branch.id)
        menu.addItem(item)
        return menu
    }

    @objc private func copyBranchNameChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? BranchNameCopy else { return }
        copyBranchName(choice.name, rowID: choice.rowID)
    }

    /// Copies `name`, then shows the checkmark on its row's cell only if that cell still
    /// shows `name`: cells are reused, and a refresh can change what one shows. This skips
    /// the button's `onCopy`, so focus is returned here.
    private func copyBranchName(_ name: String, rowID: BranchRowID) {
        PickerCopyButton.copyToPasteboard(name)
        if let row = state.items.firstIndex(where: { $0.row?.id == rowID }),
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BranchPickerRowView,
            cell.copyButton.text == name
        {
            cell.copyButton.showCopied()
        }
        returnFocusToSearchField()
    }
}

/// A row menu's copy, bound to the row's name and identity when the menu is built.
private final class BranchNameCopy {
    let name: String
    let rowID: BranchRowID

    init(name: String, rowID: BranchRowID) {
        self.name = name
        self.rowID = rowID
    }
}

/// The search field holds the keyboard; the arrows, Return and Escape reach the list, and
/// ⇥ toggles Switch and Merge. ⇧⇥ is left to AppKit, which walks the key-view loop back
/// through the header's buttons.
extension BranchPickerContainerView: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveUp()
        case #selector(NSResponder.moveDown(_:)): moveDown()
        case #selector(NSResponder.insertNewline(_:)): activate()
        // Taken even while Merge is unavailable, so focus stays in the field.
        case #selector(NSResponder.insertTab(_:)): selectTab(state.tab == .merge ? .switchBranch : .merge)
        // Escape clears the query first, then dismisses.
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty { cancel() } else { clearQuery() }
        default: return false
        }
        return true
    }
}
