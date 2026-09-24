import AppKit
import SwiftUI

/// SwiftUI wrapper. One instance lives per selection, so a document update is either a
/// recomputation of the same file, which re-anchors on the row that was at the top, an
/// appended revision of the same changeset, which leaves the viewport untouched, or a
/// replaced changeset, which re-anchors on the file and line that was at the top.
struct SideBySideView: NSViewRepresentable {
    let content: PaneContent
    var styles: DocumentStyles?
    var fontSize: CGFloat = 12
    var scrollTarget: ScrollTarget?
    var currentBlock: Int?
    var collapseUnchanged = true
    var foldOptions = FoldOptions()
    /// Kept in the hierarchy but out of sight, so a caller can layer another view over it.
    var isHidden = false
    var onTopVisibleSectionChange: ((VisibleSectionReference?) -> Void)?
    var findScope: PaneFindScope?
    var findPresentation: FindPresentation?
    var findReveal: FindReveal?
    var paneFocusRequest: PaneFocusRequest?
    var onDisplayedDocumentChange: ((DisplayedDocument) -> Void)?
    var onPaneInteraction: ((DocumentSide) -> Void)?
    var onVisibleRowsChange: ((Range<Int>, UUID) -> Void)?
    var onPaneFocusApplied: ((UUID) -> Void)?

    func makeNSView(context: Context) -> SideBySideContainerView {
        let view = SideBySideContainerView(frame: .zero)
        // Before the content goes in, so the first install's report is not lost.
        setCallbacks(on: view)
        view.foldOptions = foldOptions
        view.setCollapseUnchanged(collapseUnchanged)
        view.setContent(content, fontSize: fontSize)
        context.coordinator.documentID = content.document.id
        view.setHidden(isHidden)
        view.setStyles(styles)
        applyFindInputs(to: view, coordinator: context.coordinator)
        applyScrollTargetIfNeeded(to: view, coordinator: context.coordinator)
        view.currentBlock = currentBlock
        return view
    }

    func updateNSView(_ view: SideBySideContainerView, context: Context) {
        setCallbacks(on: view)
        // Every changeset revision carries a fresh document id, so each publication
        // reaches the container, which decides whether it appends or replaces.
        if context.coordinator.documentID != content.document.id {
            view.setContent(content, fontSize: fontSize)
            context.coordinator.documentID = content.document.id
        } else {
            view.setFontSize(fontSize)
        }
        view.setCollapseUnchanged(collapseUnchanged)
        view.setHidden(isHidden)
        view.setStyles(styles)
        applyFindInputs(to: view, coordinator: context.coordinator)
        if view.currentBlock != currentBlock { view.currentBlock = currentBlock }
        applyScrollTargetIfNeeded(to: view, coordinator: context.coordinator)
    }

    private func setCallbacks(on view: SideBySideContainerView) {
        view.onTopVisibleSectionChange = onTopVisibleSectionChange
        view.onDisplayedDocumentChange = onDisplayedDocumentChange
        view.onPaneInteraction = onPaneInteraction
        view.onVisibleRowsChange = onVisibleRowsChange
        view.onPaneFocusApplied = onPaneFocusApplied
    }

    /// Shared by both paths so they cannot drift. Runs after the content is installed;
    /// the presentation goes first so a reveal lands on the projection it selects in.
    private func applyFindInputs(to view: SideBySideContainerView, coordinator: Coordinator) {
        if coordinator.lastFindScope != findScope {
            coordinator.lastFindScope = findScope
            view.setFindScope(findScope)
        }
        if coordinator.lastFindPresentation != findPresentation {
            coordinator.lastFindPresentation = findPresentation
            view.setFindPresentation(findPresentation)
        }
        if let findReveal, coordinator.findRevealID != findReveal.id {
            coordinator.findRevealID = findReveal.id
            view.reveal(findReveal)
        }
        // After `setHidden`, so a request cancelled in this update never lands; an unchanged
        // one is retried, since a pane that was hidden could not take focus earlier.
        if coordinator.lastPaneFocusRequest != paneFocusRequest {
            coordinator.lastPaneFocusRequest = paneFocusRequest
            view.setPaneFocusRequest(paneFocusRequest)
        } else {
            view.applyPendingFocus()
        }
    }

    private func applyScrollTargetIfNeeded(to view: SideBySideContainerView, coordinator: Coordinator) {
        guard let scrollTarget, coordinator.scrollTargetID != scrollTarget.id else { return }
        coordinator.scrollTargetID = scrollTarget.id
        view.scroll(toRow: scrollTarget.row)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var documentID: UUID?
        var scrollTargetID: UUID?
        var lastFindScope: PaneFindScope?
        var lastFindPresentation: FindPresentation?
        var findRevealID: UUID?
        var lastPaneFocusRequest: PaneFocusRequest?
    }
}
