import Foundation

/// What a changeset load was asked to show. Kept with the load so the next one can tell
/// a reload of the same view, which keeps the document on screen, from a new selection,
/// which starts from empty.
struct ChangesetRequest: Equatable {
    let identity: WindowState.DetailIdentity

    /// All changes is one view whatever the list holds; a multi-file selection is the
    /// same view only while it holds the same files.
    func isReload(of previous: ChangesetRequest?) -> Bool {
        guard let previous else { return false }
        if identity.detail == .allChanges { return previous.identity.detail == .allChanges }
        return identity == previous.identity
    }
}
