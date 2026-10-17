import AppKit

/// The gutter between the panes. A move whose ends are both on screen gets a band from its
/// old rows to its new rows, so the reader sees where a block went. A move with an
/// off-screen end gets only a pill beside its visible rows, showing that end's line number.
/// A click on a band or pill jumps to the off-screen end, or to the new end when both are
/// visible.
final class MoveConnectorView: NSView, NSViewToolTipOwner {
    static let width: CGFloat = 24

    /// Called with the destination document row when a band or pill is clicked.
    var onJumpToDocumentRow: ((Int) -> Void)?

    /// The line number the given pane's gutter shows for the move's first line on that side.
    var lineNumberOfMoveEnd: ((DiffMove, DocumentSide) -> Int?)?

    /// Read at draw time for their clip origins. The right one also takes scroll-wheel
    /// events over the connector, which would otherwise scroll nothing.
    weak var leftScroll: NSScrollView?
    weak var rightScroll: NSScrollView?

    var rowHeight: CGFloat = 20 {
        didSet { if rowHeight != oldValue { needsDisplay = true } }
    }

    /// A move with its ends projected to display rows, rebuilt only when the moves or the
    /// projection change so a draw never touches `FoldedRows`.
    private struct ProjectedMove {
        let move: DiffMove
        let left: Range<Int>
        let right: Range<Int>
    }

    private var moves: [ProjectedMove] = []
    /// Clip origins at the last redraw, so a horizontal-only scroll does not redraw.
    private var drawnClipYs: (left: CGFloat, right: CGFloat)?
    private var trackingArea: NSTrackingArea?
    /// The pointer while it is over the connector. The hovered band is found from it at
    /// draw time, so a band that scrolls away from under a still pointer loses its hover.
    private var pointer: NSPoint?
    private var drawnHover: Int?
    /// The pills at the last draw, which the tool tips are registered for.
    private var drawnPills: [MoveConnectorPill] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Inputs

    func setMoves(_ moves: [DiffMove], folded: FoldedRows) {
        self.moves = moves.map { move in
            ProjectedMove(
                move: move, left: folded.displayRange(forDocumentRange: move.oldRowRange),
                right: folded.displayRange(forDocumentRange: move.newRowRange))
        }
        drawnHover = nil
        needsDisplay = true
    }

    /// Called on every clip-bounds change; only a vertical move shifts the bands.
    func redrawIfScrolledVertically() {
        guard let left = leftScroll?.contentView.bounds.minY, let right = rightScroll?.contentView.bounds.minY,
            drawnClipYs?.left != left || drawnClipYs?.right != right
        else { return }
        needsDisplay = true
    }

    // MARK: - Geometry

    /// The bands in move order, clamped ones included since they place the pills. Only moves
    /// with an end near either clip's visible rows get geometry.
    private func visibleBands() -> [(index: Int, band: MoveConnectorBand)] {
        guard let leftClip = leftScroll?.contentView.bounds, let rightClip = rightScroll?.contentView.bounds
        else { return [] }
        let viewport = MoveConnectorViewport(
            rowHeight: rowHeight, leftClipMinY: leftClip.minY, rightClipMinY: rightClip.minY, height: bounds.height)
        let leftRows = MoveConnectorGeometry.candidateRows(
            clipMinY: leftClip.minY, viewportHeight: viewport.height, rowHeight: rowHeight)
        let rightRows = MoveConnectorGeometry.candidateRows(
            clipMinY: rightClip.minY, viewportHeight: viewport.height, rowHeight: rowHeight)
        var bands: [(index: Int, band: MoveConnectorBand)] = []
        for (index, projected) in moves.enumerated()
        where projected.left.overlaps(leftRows) || projected.right.overlaps(rightRows) {
            guard let band = MoveConnectorGeometry.band(left: projected.left, right: projected.right, in: viewport)
            else { continue }
            bands.append((index, band))
        }
        return bands
    }

    /// The outline of a drawn band, both drawn and hit tested: cubic curves along its top and
    /// bottom edges, with control points at the gutter's mid x so each end leaves its pane level.
    private func outline(of band: MoveConnectorBand) -> CGPath {
        let path = CGMutablePath()
        let midX = bounds.width / 2
        path.move(to: CGPoint(x: 0, y: band.left.top))
        path.addCurve(
            to: CGPoint(x: bounds.width, y: band.right.top), control1: CGPoint(x: midX, y: band.left.top),
            control2: CGPoint(x: midX, y: band.right.top))
        path.addLine(to: CGPoint(x: bounds.width, y: band.right.bottom))
        path.addCurve(
            to: CGPoint(x: 0, y: band.left.bottom), control1: CGPoint(x: midX, y: band.right.bottom),
            control2: CGPoint(x: midX, y: band.left.bottom))
        path.closeSubpath()
        return path
    }

    /// The move under `point`: a pill wins over any band beneath it, and later bands are
    /// drawn over earlier ones. A clamped band is not drawn, so only its pill is a target.
    private func hitTarget(
        at point: NSPoint, bands: [(index: Int, band: MoveConnectorBand)], pills: [MoveConnectorPill]
    ) -> (index: Int, band: MoveConnectorBand)? {
        if let pill = pills.first(where: { $0.rect.contains(point) }) {
            return (pill.index, pill.band)
        }
        return bands.last { $0.band.clampedSide == nil && outline(of: $0.band).contains(point) }
    }

    private func hitTarget(at point: NSPoint) -> (index: Int, band: MoveConnectorBand)? {
        let bands = visibleBands()
        return hitTarget(at: point, bands: bands, pills: pillRects(for: bands))
    }

    private func pillRects(for bands: [(index: Int, band: MoveConnectorBand)]) -> [MoveConnectorPill] {
        MoveConnectorGeometry.pills(for: bands, width: bounds.width, viewportHeight: bounds.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawnClipYs = leftScroll.flatMap { left in
            rightScroll.map { (left.contentView.bounds.minY, $0.contentView.bounds.minY) }
        }
        DiffTheme.background.setFill()
        context.fill(bounds)
        DiffTheme.divider.setFill()
        context.fill(NSRect(x: 0, y: 0, width: 1, height: bounds.height))
        context.fill(NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height))

        let bands = visibleBands()
        let pills = pillRects(for: bands)
        drawnHover = pointer.flatMap { hitTarget(at: $0, bands: bands, pills: pills)?.index }
        // Only bands with both ends on screen are drawn; the others are just pills.
        let drawn = bands.filter { $0.band.clampedSide == nil }
        // Every band's base goes down before any band, so the hairlines stop where a band
        // meets its rows while crossing bands still show through each other.
        for (_, band) in drawn {
            context.addPath(outline(of: band))
            context.setFillColor(DiffTheme.background.cgColor)
            context.fillPath()
        }
        for (index, band) in drawn {
            draw(band, isHovered: index == drawnHover, context: context)
        }
        for pill in pills {
            drawPill(
                of: moves[pill.index].move, band: pill.band, in: pill.rect, isHovered: pill.index == drawnHover,
                context: context)
        }
        updateToolTips(for: pills)
    }

    /// Re-registers the tool tip rects only when the pills moved, since every scroll redraws.
    private func updateToolTips(for pills: [MoveConnectorPill]) {
        guard pills != drawnPills else { return }
        drawnPills = pills
        removeAllToolTips()
        for pill in pills { addToolTip(pill.rect, owner: self, userData: nil) }
    }

    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let pill = drawnPills.first(where: { $0.rect.contains(point) }), moves.indices.contains(pill.index),
            let side = pill.band.clampedSide, let number = lineNumberOfMoveEnd?(moves[pill.index].move, side)
        else { return "" }
        return "Go to line \(number)"
    }

    /// A capsule beside the block's visible end: the off-screen end's line number, and an
    /// arrow toward it. The background goes down first so bands do not show through.
    private func drawPill(
        of move: DiffMove, band: MoveConnectorBand, in rect: CGRect, isHovered: Bool, context: CGContext
    ) {
        guard let side = band.clampedSide else { return }
        let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2)
        DiffTheme.background.setFill()
        capsule.fill()
        (isHovered ? DiffTheme.movedBandMiddleHover : DiffTheme.movedGutterOnRow).setFill()
        capsule.fill()

        let clamped = side == .old ? band.left : band.right
        let pointsUp = clamped.bottom <= 0
        let number = lineNumberOfMoveEnd?(move, side)
        // Without a number the chevron is centered; otherwise it sits at the edge side.
        let chevronY =
            number == nil ? rect.midY : (pointsUp ? rect.minY + Self.chevronInset : rect.maxY - Self.chevronInset)
        strokeChevron(pointingUp: pointsUp, at: CGPoint(x: rect.midX, y: chevronY), context: context)
        if let number {
            let numberY = pointsUp ? rect.maxY - Self.numberInset : rect.minY + Self.numberInset
            drawNumber(number, centeredAt: CGPoint(x: rect.midX, y: numberY), maxWidth: rect.width - 4)
        }
    }

    /// Distance from the pill's end to the chevron's center and to the number's center.
    private static let chevronInset: CGFloat = 8
    private static let numberInset: CGFloat = 9

    /// Shrinks the font to 7pt to fit `maxWidth`. Numbers from 10,000 are abbreviated so they
    /// fit; the tooltip and accessibility label carry the full number.
    private func drawNumber(_ number: Int, centeredAt center: CGPoint, maxWidth: CGFloat) {
        let label = MoveConnectorGeometry.pillLabel(forLineNumber: number)
        var size: CGFloat = 9
        var string: NSAttributedString
        repeat {
            string = NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: .semibold, width: .condensed),
                    .foregroundColor: DiffTheme.movedAccent,
                ])
            size -= 0.5
        } while string.size().width > maxWidth && size >= 7
        let textSize = string.size()
        string.draw(at: NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2))
    }

    /// The view is flipped, so a chevron pointing up has its apex at the smaller y.
    private func strokeChevron(pointingUp: Bool, at center: CGPoint, context: CGContext) {
        let halfWidth: CGFloat = 3
        let height: CGFloat = 3
        let apexY = pointingUp ? center.y - height / 2 : center.y + height / 2
        let baseY = pointingUp ? center.y + height / 2 : center.y - height / 2
        context.saveGState()
        context.setStrokeColor(DiffTheme.movedAccent.cgColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: center.x - halfWidth, y: baseY))
        context.addLine(to: CGPoint(x: center.x, y: apexY))
        context.addLine(to: CGPoint(x: center.x + halfWidth, y: baseY))
        context.strokePath()
        context.restoreGState()
    }

    /// The band's fill runs from the left pane's moved rows (text area) to the right pane's
    /// (gutter), fading in the middle, so each end reads as its rows flowing out.
    private func draw(_ band: MoveConnectorBand, isHovered: Bool, context: CGContext) {
        let middle = isHovered ? DiffTheme.movedBandMiddleHover : DiffTheme.movedBandMiddle
        context.saveGState()
        context.addPath(outline(of: band))
        context.clip()
        drawHorizontalGradient([DiffTheme.movedRow, middle, DiffTheme.movedGutterOnRow], context: context)
        context.restoreGState()
    }

    /// Fills the current clip left to right through `colors`, evenly spaced.
    private func drawHorizontalGradient(_ colors: [NSColor], context: CGContext) {
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray,
                locations: nil)
        else { return }
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: bounds.width, y: 0), options: [])
    }

    // MARK: - Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(at: nil)
    }

    /// Redraws only when the hovered band or pill changes. The pointing hand says it is clickable.
    private func updateHover(at point: NSPoint?) {
        pointer = point
        let hovered = point.flatMap { hitTarget(at: $0)?.index }
        if point != nil { (hovered == nil ? NSCursor.arrow : NSCursor.pointingHand).set() }
        if hovered != drawnHover { needsDisplay = true }
    }

    override func scrollWheel(with event: NSEvent) {
        if let rightScroll { rightScroll.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let onJumpToDocumentRow, let hit = hitTarget(at: point) else { return }
        onJumpToDocumentRow(jumpTarget(of: hit.index, band: hit.band))
    }

    /// The end that is off screen, or the new end when both are visible.
    private func jumpTarget(of index: Int, band: MoveConnectorBand) -> Int {
        let move = moves[index].move
        return band.clampedSide == .old ? move.oldRowRange.lowerBound : move.newRowRange.lowerBound
    }

    // MARK: - Accessibility

    /// One button per drawn band and per pill, so VoiceOver can jump even when the move's
    /// gutter markers are off screen.
    override func accessibilityChildren() -> [Any]? {
        guard let onJumpToDocumentRow else { return [] }
        let bands = visibleBands()
        let pillsByIndex = Dictionary(uniqueKeysWithValues: pillRects(for: bands).map { ($0.index, $0) })
        return bands.compactMap { index, band in
            let target = jumpTarget(of: index, band: band)
            let frame: CGRect
            if band.clampedSide == nil {
                frame = outline(of: band).boundingBoxOfPath.intersection(bounds)
            } else if let pill = pillsByIndex[index] {
                frame = pill.rect
            } else {
                return nil
            }
            let jumpsToOldSide = band.clampedSide == .old
            var destination = jumpsToOldSide ? "where these lines came from" : "where these lines moved"
            if let side = band.clampedSide, let number = lineNumberOfMoveEnd?(moves[index].move, side) {
                destination = "line \(number), " + destination
            }
            return ButtonElement(
                parent: self, frame: frame, label: "Go to " + destination, onPress: { onJumpToDocumentRow(target) })
        }
    }
}
