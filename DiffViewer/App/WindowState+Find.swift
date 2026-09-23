import Foundation

/// The window's side of find: when the bar may open, and which reports from the panes
/// reach `FindState`.
extension WindowState {
    /// Text or a changeset on screen. The detail view hides the panes whenever the loader
    /// holds an error, even with content still loaded, so an error rules find out too.
    var isFindAvailable: Bool {
        guard diffLoader.errorMessage == nil else { return false }
        switch diffLoader.content {
        case .text, .changeset: return true
        default: return false
        }
    }

    /// The id a displayed document must carry to belong to what the loader shows now.
    var currentContentID: UUID? {
        switch diffLoader.content {
        case let .text(document): document.id
        case let .changeset(changeset): changeset.loadID
        default: nil
        }
    }

    func showFindBar() {
        guard isFindAvailable else { return }
        find.present()
    }

    /// Drops deferred reports from a container on its way out, which still describe the
    /// previous content.
    func reportDisplayed(_ displayed: DisplayedDocument) {
        guard isFindAvailable, displayed.contentID == currentContentID else { return }
        find.update(displayed: displayed)
    }

    /// The commit sheet owns the keyboard while it is up.
    var canStepFind: Bool { isFindAvailable && find.canStep && !isCommitSheetPresented }
}
