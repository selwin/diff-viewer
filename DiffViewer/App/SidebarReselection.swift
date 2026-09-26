import Foundation

/// Where the selection lands after the sidebar's list is replaced.
///
/// A discard, a trash, or a branch switch keeps the reader on the files they were looking
/// at; a stage or unstage moves them on to the next file in the list they are working
/// down. The rules are pure functions that `WindowState` calls and tests can exercise
/// without a repository.
enum SidebarReselection {
    /// Where the selection lands for `pending`; with nothing pending, what survived.
    static func selection(
        for pending: WindowState.PendingReselection?, surviving: Set<DiffSelection>, in rows: [ChangedFile]
    ) -> Set<DiffSelection> {
        switch pending {
        case let .paths(selections)?: selection(after: selections, surviving: surviving, in: rows)
        case let .neighbour(sourceArea, sourceIndex)?:
            neighbour(from: sourceArea, at: sourceIndex, surviving: surviving, in: rows)
        case nil: surviving
        }
    }

    /// Where a set-valued selection lands after the list is replaced: whatever survived
    /// stays, each pending row is found again by path, and only when both come up empty
    /// does the remembered row index of the lowest pending row apply, once.
    ///
    /// Batching does not change the rule, only its arity: a reader who discarded three
    /// files keeps the one row that slid up into the place of the topmost of them.
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

    /// Where the selection lands after a stage or unstage moved selected rows out of
    /// `area`: whatever survived stays, and only when nothing did is it the row now at
    /// `index` among `area`'s rows, where the topmost moved row was. Clamped within `area`
    /// alone, so staging the last unstaged file selects the new last one and never a
    /// staged row; an area left empty selects nothing.
    static func neighbour(
        from area: ChangedFile.Area, at index: Int, surviving: Set<DiffSelection>, in rows: [ChangedFile]
    ) -> Set<DiffSelection> {
        guard surviving.isEmpty else { return surviving }
        guard let row = rowFallback(at: index, in: rows.filter { $0.area == area }) else { return [] }
        return [.file(row)]
    }

    /// The part of `selection` a refresh keeps: rows still in `rows`, plus each vanished
    /// row moved onto the rename from its path in the same area. Without the move, a
    /// selected deletion that status now pairs with an untracked file would drop out.
    /// All changes is not a file and always survives.
    static func surviving(
        _ selection: Set<DiffSelection>, before: [ChangedFile.ID: ChangedFile], in rows: [ChangedFile]
    ) -> Set<DiffSelection> {
        let liveIDs = Set(rows.map(\.id))
        var renamedFrom: [RenameSource: ChangedFile.ID] = [:]
        for row in rows where row.kind == .renamed {
            guard let original = row.originalPath else { continue }
            renamedFrom[RenameSource(area: row.area, path: original)] = row.id
        }
        return Set(
            selection.compactMap { item in
                guard let id = item.fileID, !liveIDs.contains(id) else { return item }
                guard let old = before[id] else { return nil }
                return renamedFrom[RenameSource(area: old.area, path: old.path)].map(DiffSelection.file)
            })
    }

    private struct RenameSource: Hashable {
        let area: ChangedFile.Area
        let path: String
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
