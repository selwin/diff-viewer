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

    /// Opens on the persisted side.
    func showFindBar() {
        guard isFindAvailable else { return }
        find.present(side: preferences.findSide)
    }

    /// Persisted, so the next opening in any window searches the same side.
    func selectFindSide(_ side: DocumentSide) {
        preferences.findSide = side
        find.selectSide(side)
    }

    /// The commit sheet owns the keyboard while it is up.
    var canSelectFindSide: Bool { find.isPresented && isFindAvailable && !isCommitSheetPresented }

    var findSideLabels: FindSideLabels { FindSideLabels.make(scope: scope, headState: headState) }

    /// Nil while the bar is closed, so the panes drop their headers and dimming.
    var paneFindScope: PaneFindScope? {
        guard find.isPresented, isFindAvailable else { return nil }
        return PaneFindScope(labels: findSideLabels, searchedSide: find.side)
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
