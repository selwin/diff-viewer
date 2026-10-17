import CoreGraphics

/// A move's band in the connector between the panes, in connector coordinates (flipped,
/// y = 0 at the top of the viewport).
struct MoveConnectorBand: Equatable {
    struct End: Equatable {
        let top: CGFloat
        let bottom: CGFloat
    }

    let left: End
    let right: End
    /// The side whose end is off screen, pinned just past the viewport edge; nil when both
    /// ends are visible.
    let clampedSide: DocumentSide?
}

/// What a band is placed against: the row height, each clip's raw origin (negative or past
/// the end while rubber-banding, so a band stays with its rows) and the connector's height.
struct MoveConnectorViewport: Equatable {
    let rowHeight: CGFloat
    let leftClipMinY: CGFloat
    let rightClipMinY: CGFloat
    let height: CGFloat
}

/// A clamped band's pill: the move it belongs to, its band, and where it sits.
struct MoveConnectorPill: Equatable {
    let index: Int
    let band: MoveConnectorBand
    let rect: CGRect
}

/// Where a move's band goes. Shared by drawing and hit testing so a click lands on what
/// is drawn.
enum MoveConnectorGeometry {
    /// How far past the viewport edge an off-screen end is pinned, in rows. Clamped bands are
    /// not drawn, but their pills are placed from them.
    static let clampRows: CGFloat = 1.5

    static let pillHeight: CGFloat = 26
    /// Gap between a pill and the viewport edge, and between a pill and each side of the connector.
    static let pillInset: CGFloat = 2
    static let pillGap: CGFloat = 2

    /// The band for a move whose ends cover display rows `left` and `right`, or nil when
    /// neither end intersects the viewport. Ends on opposite sides of the viewport give no
    /// band either: there is no visible block to hang a pill on.
    static func band(left: Range<Int>, right: Range<Int>, in viewport: MoveConnectorViewport) -> MoveConnectorBand? {
        let rowHeight = viewport.rowHeight
        guard !left.isEmpty, !right.isEmpty, rowHeight > 0 else { return nil }
        let leftEnd = end(of: left, rowHeight: rowHeight, clipMinY: viewport.leftClipMinY)
        let rightEnd = end(of: right, rowHeight: rowHeight, clipMinY: viewport.rightClipMinY)
        let viewportHeight = viewport.height
        let margin = clampRows * rowHeight
        switch (
            placement(of: leftEnd, viewportHeight: viewportHeight),
            placement(of: rightEnd, viewportHeight: viewportHeight)
        )
        {
        case (.visible, .visible):
            return MoveConnectorBand(left: leftEnd, right: rightEnd, clampedSide: nil)
        case let (.visible, offScreen):
            let clamped = clamp(rightEnd, to: offScreen, margin: margin, viewportHeight: viewportHeight)
            return MoveConnectorBand(left: leftEnd, right: clamped, clampedSide: .new)
        case let (offScreen, .visible):
            let clamped = clamp(leftEnd, to: offScreen, margin: margin, viewportHeight: viewportHeight)
            return MoveConnectorBand(left: clamped, right: rightEnd, clampedSide: .old)
        default:
            return nil
        }
    }

    /// Display rows an end must overlap for its move to get a band, widened by the clamp
    /// margin: a cheap filter before any geometry. May run past either end of the rows.
    static func candidateRows(clipMinY: CGFloat, viewportHeight: CGFloat, rowHeight: CGFloat) -> Range<Int> {
        guard rowHeight > 0 else { return 0..<0 }
        let margin = Int(clampRows.rounded(.up))
        let first = Int(floor(clipMinY / rowHeight)) - margin
        let end = Int(ceil((clipMinY + viewportHeight) / rowHeight)) + margin
        return first..<max(first, end)
    }

    /// Where each clamped band's pill goes: beside the first row of the block that is still
    /// on screen, so the pill reads as that block's label. It holds the top inset while the
    /// block's top is scrolled off, then rides up with the block's bottom. Overlapping pills
    /// are pushed down, and any that no longer fit above the bottom inset are dropped.
    static func pills(
        for bands: [(index: Int, band: MoveConnectorBand)], width: CGFloat, viewportHeight: CGFloat
    ) -> [MoveConnectorPill] {
        let maximumPillY = viewportHeight - pillInset - pillHeight
        var preferredPlacements: [(index: Int, band: MoveConnectorBand, y: CGFloat)] = []
        for (index, band) in bands {
            guard let side = band.clampedSide else { continue }
            let visible = side == .old ? band.right : band.left
            let y = max(visible.top, min(pillInset, visible.bottom - pillHeight))
            preferredPlacements.append((index, band, min(y, maximumPillY)))
        }
        preferredPlacements.sort { ($0.y, $0.index) < ($1.y, $1.index) }

        var result: [MoveConnectorPill] = []
        var nextFree = -CGFloat.infinity
        for (index, band, y) in preferredPlacements {
            let placed = max(y, nextFree)
            guard placed + pillHeight <= viewportHeight - pillInset else { continue }
            result.append(
                MoveConnectorPill(
                    index: index, band: band,
                    rect: CGRect(x: pillInset, y: placed, width: width - 2 * pillInset, height: pillHeight)))
            nextFree = placed + pillHeight + pillGap
        }
        return result
    }

    /// Abbreviates line numbers from 10,000 using whole thousands or millions, rounded down.
    static func pillLabel(forLineNumber number: Int) -> String {
        if number < 10_000 { return String(number) }
        if number < 1_000_000 { return "\(number / 1000)k" }
        return "\(number / 1_000_000)M"
    }

    private enum Placement {
        case above, visible, below
    }

    private static func end(of rows: Range<Int>, rowHeight: CGFloat, clipMinY: CGFloat) -> MoveConnectorBand.End {
        MoveConnectorBand.End(
            top: CGFloat(rows.lowerBound) * rowHeight - clipMinY,
            bottom: CGFloat(rows.upperBound) * rowHeight - clipMinY)
    }

    private static func placement(of end: MoveConnectorBand.End, viewportHeight: CGFloat) -> Placement {
        if end.bottom <= 0 { return .above }
        if end.top >= viewportHeight { return .below }
        return .visible
    }

    /// Keeps the end's height and moves it to just past the edge it lies beyond.
    private static func clamp(
        _ end: MoveConnectorBand.End, to placement: Placement, margin: CGFloat, viewportHeight: CGFloat
    ) -> MoveConnectorBand.End {
        let height = end.bottom - end.top
        if placement == .above {
            return MoveConnectorBand.End(top: -margin - height, bottom: -margin)
        }
        return MoveConnectorBand.End(top: viewportHeight + margin, bottom: viewportHeight + margin + height)
    }
}
