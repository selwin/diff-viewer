import AppKit

/// Find: fills and the current match's selection, revealing a match, and pane focus.
extension SideBySideContainerView {
    /// Fills follow the content id alone, so they survive a refold until the re-run lands;
    /// the selection needs the exact projection. A nil index leaves the reader's selection.
    func setFindPresentation(_ presentation: FindPresentation?) {
        guard let presentation, let contentID = installedContentID, presentation.results.key.contentID == contentID
        else {
            leftPane.findMatches = [:]
            rightPane.findMatches = [:]
            appliedFindFills = nil
            return
        }
        let results = presentation.results
        let side = presentation.side
        let other: DocumentSide = side == .old ? .new : .old
        let matches = results.side(side)
        // A switch leaves no stale match selected on the old side; the reader's own is kept.
        if let owned = findOwnedSelection, owned.side != side {
            if pane(for: owned.side).selection == owned.selection { pane(for: owned.side).selection = nil }
            findOwnedSelection = nil
        }
        // A side switch keeps the results id, so the side is part of what was applied.
        if appliedFindFills?.resultsID != results.id || appliedFindFills?.side != side {
            pane(for: side).findMatches = matches.rangesByRow
            pane(for: other).findMatches = [:]
            appliedFindFills = (results.id, side)
        }
        guard results.key.matchesProjection(contentID: contentID, projectionID: projectionID),
            let index = presentation.currentIndex, matches.matches.indices.contains(index)
        else { return }
        let match = matches.matches[index]
        // Set directly, so neither pane reports an interaction.
        let selection = PaneSelection(
            anchor: TextPosition(row: match.documentRow, offset: match.utf16Range.lowerBound),
            head: TextPosition(row: match.documentRow, offset: match.utf16Range.upperBound))
        pane(for: side).selection = selection
        pane(for: other).selection = nil
        findOwnedSelection = (side, selection)
    }

    /// Scrolls both panes to the match's row, then only the match's pane horizontally.
    func reveal(_ reveal: FindReveal) {
        guard let contentID = installedContentID,
            reveal.key.matchesProjection(contentID: contentID, projectionID: projectionID)
        else { return }
        layoutSubtreeIfNeeded()
        let match = reveal.match
        scroll(toRow: match.documentRow)
        let target = pane(for: reveal.side)
        let targetScroll = scrollView(for: reveal.side)
        guard let span = target.horizontalBounds(ofRow: match.documentRow, range: match.utf16Range) else { return }
        let clip = targetScroll.contentView.bounds
        // The gutter is drawn over the left edge of the clip, so text starts after it.
        let leading = target.gutterWidth + target.textInset
        let textMinX = clip.minX + leading
        var x = clip.minX
        if span.x0 < textMinX || span.x1 - span.x0 > clip.maxX - textMinX {
            x = span.x0 - leading
        } else if span.x1 > clip.maxX {
            x = span.x1 - clip.width
        }
        x = min(max(0, x), max(0, target.frame.width - clip.width))
        guard x != clip.minX else { return }
        targetScroll.contentView.scroll(to: NSPoint(x: x, y: clip.minY))
        targetScroll.reflectScrolledClipView(targetScroll.contentView)
    }

    /// Replaces any pending request, so nil cancels one that has not landed yet.
    func setPaneFocusRequest(_ request: PaneFocusRequest?) {
        pendingFocus = request
        applyPendingFocus()
    }

    /// A request is acknowledged only once the pane actually became first responder.
    func applyPendingFocus() {
        guard let request = pendingFocus, !isHidden, let window else { return }
        let target = pane(for: request.side)
        guard target.acceptsFirstResponder, window.makeFirstResponder(target) else { return }
        pendingFocus = nil
        DispatchQueue.main.async { [weak self] in self?.onPaneFocusApplied?(request.id) }
    }
}
