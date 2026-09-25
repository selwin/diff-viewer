import CoreGraphics

/// Where the selection popover goes: beside the sidebar at the first selected row, or
/// pinned to the list's edge nearest that row when it is out of sight. Every input is in
/// the overlay's own coordinates.
struct SelectionPopoverPlacement: Equatable {
    /// The panel's top-left corner, arrow excluded.
    let origin: CGPoint
    /// The arrow's centre, down from the panel's top; nil draws no arrow.
    let arrowY: CGFloat?

    /// Between the sidebar's trailing edge and the panel, room for the arrow.
    static let sidebarGap: CGFloat = 10
    static let margin: CGFloat = 8
    static let cornerRadius: CGFloat = 14
    static let arrowHalfHeight: CGFloat = 7
    /// The arrow's centre stays this far from the panel's top and bottom, clear of the
    /// rounded corners; unclamped, the arrow rests here, level with the row's middle.
    static let arrowInset: CGFloat = 23

    // swiftlint:disable function_parameter_count
    /// The placement, or nil to hide the popover: a row out of sight whose direction is
    /// unknown is better not pointed at than pointed at the wrong way.
    static func place(
        rowFrame: CGRect?, selectedRowIndex: Int, mountedIndexRange: ClosedRange<Int>?, visibleListFrame: CGRect,
        containerSize: CGSize, popoverSize: CGSize
    ) -> SelectionPopoverPlacement? {
        let preferredX = visibleListFrame.maxX + sidebarGap
        let x = max(margin, min(preferredX, containerSize.width - popoverSize.width - margin))
        // Pulled left over the sidebar, the arrow would be drawn over the rows.
        let arrowFits = x >= preferredX
        let lowestY = margin
        let highestY = max(lowestY, containerSize.height - popoverSize.height - margin)
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, lowestY), highestY) }

        if let rowFrame, rowFrame.midY >= visibleListFrame.minY, rowFrame.midY <= visibleListFrame.maxY {
            // Measured from the row's middle: the frame is the row's content, which sits
            // inside its highlight by an amount the List decides.
            let y = clampY(rowFrame.midY - arrowInset)
            let highestArrow = max(arrowInset, popoverSize.height - arrowInset)
            let arrowY = min(max(rowFrame.midY - y, arrowInset), highestArrow)
            // A row half past the window's edge can be beyond the arrow's reach; the panel
            // then waits at the edge without pointing at the neighbouring row.
            let arrowOnRow = (rowFrame.minY...rowFrame.maxY).contains(y + arrowY)
            return SelectionPopoverPlacement(
                origin: CGPoint(x: x, y: y), arrowY: arrowFits && arrowOnRow ? arrowY : nil)
        }

        let pinsToTop: Bool
        if let rowFrame {
            pinsToTop = rowFrame.midY < visibleListFrame.minY
        } else if let mountedIndexRange, selectedRowIndex < mountedIndexRange.lowerBound {
            pinsToTop = true
        } else if let mountedIndexRange, selectedRowIndex > mountedIndexRange.upperBound {
            pinsToTop = false
        } else {
            return nil
        }
        let y =
            pinsToTop
            ? visibleListFrame.minY + margin : visibleListFrame.maxY - popoverSize.height - margin
        return SelectionPopoverPlacement(origin: CGPoint(x: x, y: clampY(y)), arrowY: nil)
    }
    // swiftlint:enable function_parameter_count

    /// The stored row frame when it belongs to the first selected row, else nil: during a
    /// fast selection change the entry may still be the previous row's.
    static func rowFrame(_ frame: CGRect?, measuredFor rowID: ChangedFile.ID?, firstSelectedID: ChangedFile.ID)
        -> CGRect?
    {
        rowID == firstSelectedID ? frame : nil
    }

    /// The lowest and highest sidebar index among the built rows, or nil when none is built.
    static func mountedIndexRange(of mounted: Set<ChangedFile.ID>, in rows: [ChangedFile.ID]) -> ClosedRange<Int>? {
        let indices = rows.indices.filter { mounted.contains(rows[$0]) }
        guard let first = indices.first, let last = indices.last else { return nil }
        return first...last
    }
}
