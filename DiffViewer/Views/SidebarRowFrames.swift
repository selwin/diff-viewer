import SwiftUI

/// Where the sidebar's rows are, for the selection popover to point at.
///
/// Its own object, read only by the popover, so a scroll re-renders the popover and not
/// the window. Every frame is in `.global` space: a named space may not reach through the
/// List's AppKit hosting.
@MainActor
@Observable
final class SidebarRowFrames {
    struct RowFrame: Equatable {
        let id: ChangedFile.ID
        let frame: CGRect
    }

    /// The first selected row's frame, reported by that row alone.
    var firstSelectedRow: RowFrame?
    /// Rows the List has built. A built row may still be scrolled out of sight; this is
    /// row lifetime, which is what tells an unmeasured row's direction.
    private(set) var mountedRowIDs: Set<ChangedFile.ID> = []
    /// Each list's scroll viewport, without the part under the toolbar. A list that is not
    /// on screen has no entry.
    var visibleListFrames: [SidebarList: CGRect] = [:]

    func rowAppeared(_ id: ChangedFile.ID) {
        if !mountedRowIDs.contains(id) { mountedRowIDs.insert(id) }
    }

    func rowDisappeared(_ id: ChangedFile.ID) {
        if mountedRowIDs.contains(id) { mountedRowIDs.remove(id) }
        clearFirstSelectedRow(ifOwnedBy: id)
    }

    /// Only the row that wrote the entry may clear it, so an old row's late callback
    /// never wipes the frame its successor just stored.
    func clearFirstSelectedRow(ifOwnedBy id: ChangedFile.ID) {
        if firstSelectedRow?.id == id { firstSelectedRow = nil }
    }
}
