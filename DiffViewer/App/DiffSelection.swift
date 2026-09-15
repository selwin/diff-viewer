import Foundation

/// What the detail area is showing: every changed file in one scrolling view, or one
/// file from the sidebar.
///
/// A separate type rather than an optional file id so "All changes" is a choice the
/// reader can make, distinct from "nothing is selected". The sidebar tags its rows with
/// it, so it is also the list's selection value.
enum DiffSelection: Hashable, Sendable {
    case allChanges
    case file(ChangedFile.ID)

    /// The file this selection names, or nil for All changes.
    var fileID: ChangedFile.ID? {
        if case let .file(id) = self { return id }
        return nil
    }
}
