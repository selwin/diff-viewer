import AppKit

/// Merge rows' previews: asked for while their rows are on screen in Merge, and shown
/// only while the loader has one for the row's current key.
extension BranchPickerContainerView {
    func registerForMergePreviews() {
        mergePreviewToken = mergePreviews?.registerConsumer { [weak self] key in
            self?.reloadRows(showing: key)
        }
    }

    /// Nil while pending, after a failure, or outside Merge.
    func mergePreview(forTableRow row: Int) -> MergePreview? {
        guard let key = state.mergePreviewKey(forTableRow: row) else { return nil }
        return mergePreviews?.cachedPreview(for: key)
    }

    /// Asks for the visible rows' keys, which replaces the last ask: rows scrolled away
    /// stop waiting, and Switch or a detached view asks for none.
    func requestVisibleMergePreviews() {
        guard let mergePreviews, let mergePreviewToken else { return }
        var keys: Set<MergePreviewKey> = []
        if state.tab == .merge, window != nil {
            let visible = tableView.rows(in: tableView.visibleRect)
            keys = state.requestedKeys(visibleRows: visible.lowerBound..<visible.upperBound)
        }
        mergePreviews.setRequestedKeys(keys, for: mergePreviewToken)
    }

    /// Every row's key, taken before a snapshot so rows whose key changes can be found.
    func mergePreviewKeysByRow() -> [BranchRowID: MergePreviewKey] {
        var keys: [BranchRowID: MergePreviewKey] = [:]
        for index in state.items.indices {
            if let id = state.row(forTableRow: index)?.id, let key = state.mergePreviewKey(forTableRow: index) {
                keys[id] = key
            }
        }
        return keys
    }

    /// A new HEAD or branch tip leaves a row's cell showing the old key's preview, even
    /// when the row itself didn't change: it is reloaded, so it shows the new key's or none.
    func reloadRowsWithChangedMergePreviewKeys(since oldKeys: [BranchRowID: MergePreviewKey]) {
        let changed = IndexSet(
            state.items.indices.filter { index in
                guard let id = state.row(forTableRow: index)?.id, let old = oldKeys[id] else { return false }
                return state.mergePreviewKey(forTableRow: index) != old
            })
        reloadRows(changed)
    }

    /// Updates the visible rows whose current key is `key`; rows off screen are configured
    /// when they scroll in, and leaving Merge reloaded every row already.
    private func reloadRows(showing key: MergePreviewKey) {
        guard state.tab == .merge else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        let rows = IndexSet(state.tableRows(matching: key).filter { visible.contains($0) })
        reloadRows(rows)
        guard !rows.isEmpty, mergePreviews?.cachedPreview(for: key) != nil else { return }
        for row in rows {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BranchPickerRowView)?
                .fadeInTrailing()
        }
    }

    private func reloadRows(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        isApplyingSelection = true
        tableView.reloadData(forRowIndexes: rows, columnIndexes: [0])
        isApplyingSelection = false
    }
}
