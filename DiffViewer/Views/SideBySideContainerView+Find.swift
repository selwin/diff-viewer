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
            appliedResultsID = nil
            return
        }
        let results = presentation.results
        let side = results.key.side
        let other: DocumentSide = side == .old ? .new : .old
        if results.id != appliedResultsID {
            pane(for: side).findMatches = results.rangesByRow
            pane(for: other).findMatches = [:]
            appliedResultsID = results.id
        }
        guard results.key.matchesProjection(contentID: contentID, projectionID: projectionID),
            let index = presentation.currentIndex, results.matches.indices.contains(index)
        else { return }
        let match = results.matches[index]
        // Set directly, so neither pane reports an interaction.
        pane(for: side).selection = PaneSelection(
            anchor: TextPosition(row: match.documentRow, offset: match.utf16Range.lowerBound),
            head: TextPosition(row: match.documentRow, offset: match.utf16Range.upperBound))
        pane(for: other).selection = nil
    }

    /// Scrolls both panes to the match's row, then only the match's pane horizontally.
    func reveal(_ reveal: FindReveal) {
        guard let contentID = installedContentID,
            reveal.key.matchesProjection(contentID: contentID, projectionID: projectionID)
        else { return }
        layoutSubtreeIfNeeded()
        let match = reveal.match
        scroll(toRow: match.documentRow)
        let target = pane(for: reveal.key.side)
        let targetScroll = scrollView(for: reveal.key.side)
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
