import Foundation

/// Where the selection lands after the sidebar's list is replaced.
///
/// Two different events replace the list: the commit picker changes scope, and a file
/// action stages, discards, or trashes rows. Both want the same thing — the reader is
/// still looking at the files they were looking at — so the rule lives in one pure
/// function that `WindowState` calls and tests can exercise without a repository.
enum SidebarReselection {
    /// Where a set-valued selection lands after the list is replaced: whatever survived
    /// stays, each pending row is found again by path, and only when both come up empty
    /// does the remembered row index of the lowest pending row apply, once.
    ///
    /// Batching does not change the rule, only its arity: a reader who staged three files
    /// keeps all three, and a reader who discarded three keeps the one row that slid up
    /// into the place of the topmost of them.
    static func selection(
        after pending: [WindowState.PendingSelection], surviving: Set<DiffSelection>, in rows: [ChangedFile]
    ) -> Set<DiffSelection> {
        guard !pending.isEmpty else { return surviving }
        // Grouped once rather than scanned once per pending row: a batch action can hand
        // over as many rows as the reader had selected.
        let byPath = Dictionary(grouping: rows, by: \.path)
        let matches = pending.compactMap { pathMatch(for: $0, in: byPath[$0.path] ?? []) }
        if !matches.isEmpty || !surviving.isEmpty {
            return surviving.union(matches.map(DiffSelection.file))
        }
        // Every path is gone and nothing else is selected, so the index applies — for the
        // topmost row that was lost, which is where the reader's eye is.
        guard let row = rowFallback(at: pending.compactMap(\.row).min(), in: rows) else { return surviving }
        return [.file(row)]
    }

    /// The row carrying `previous`'s path, or nil when the path is gone from `rows`.
    ///
    /// The path wins wherever it still exists; the area it came from is preferred, then
    /// unstaged, which is the half a reader works from.
    private static func pathMatch(
        for previous: WindowState.PendingSelection, in rows: [ChangedFile]
    ) -> ChangedFile.ID? {
        let matches = rows.filter { $0.path == previous.path }
        let match =
            matches.first { $0.area == previous.area }
            ?? matches.first { $0.area == .unstaged }
            ?? matches.first
        return match?.id
    }

    /// The row that took the place of the one at `row`. The last row can be the one that
    /// went away, so the index is clamped rather than dropped: removing the bottom file
    /// selects the new bottom file.
    private static func rowFallback(at row: Int?, in rows: [ChangedFile]) -> ChangedFile.ID? {
        guard let row, !rows.isEmpty else { return nil }
        return rows[min(max(row, 0), rows.count - 1)].id
    }
}
