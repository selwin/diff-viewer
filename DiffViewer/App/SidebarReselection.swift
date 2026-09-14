import Foundation

/// Where the selection lands after the sidebar's list is replaced.
///
/// Two different events replace the list: the commit picker changes scope, and a file
/// action stages, discards, or trashes a row. Both want the same thing — the reader is
/// still looking at the file they were looking at — so the rule lives in one pure
/// function that `WindowState` calls and tests can exercise without a repository.
enum SidebarReselection {
    /// The row to select in `rows`, or nil when nothing fits.
    ///
    /// The path wins wherever it still exists, because that is the file the reader was
    /// reading. A path can appear in two areas at once (staged and unstaged edits to the
    /// same file), so the area it came from is preferred, then unstaged, which is the
    /// half a reader works from. Only when the path is gone entirely — discarded,
    /// trashed, or absent from the new scope — does the remembered row index apply, so
    /// deleting a row selects whatever slid up into its place.
    static func target(for previous: WindowState.PendingSelection, in rows: [ChangedFile]) -> ChangedFile.ID? {
        let matches = rows.filter { $0.path == previous.path }
        let match =
            matches.first { $0.area == previous.area }
            ?? matches.first { $0.area == .unstaged }
            ?? matches.first
        if let match { return match.id }
        // The last row can be the one that went away, so the index is clamped rather
        // than dropped: removing the bottom file selects the new bottom file.
        guard let row = previous.row, !rows.isEmpty else { return nil }
        return rows[min(max(row, 0), rows.count - 1)].id
    }
}
