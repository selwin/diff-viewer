import AppKit

/// The gutter between the panes. Each move with an end on screen gets a band from its
/// old rows to its new rows, so the reader sees where a block went without scrolling. A
/// click on a band jumps to its off-screen end, or to its new end when both are visible.
final class MoveConnectorView: NSView {
    static let width: CGFloat = 24

    /// Called with the document row to scroll to when a band is clicked.
    var onJumpToDocumentRow: ((Int) -> Void)?

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

    /// The bands to draw, in move order. Only moves with an end near either clip's visible
    /// rows get geometry.
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

    /// The band's outline, both drawn and hit tested: cubic curves along its top and bottom
    /// edges, with control points at the gutter's mid x so each end leaves its pane level.
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

    /// The topmost band under `point`; later bands are drawn over earlier ones.
    private func band(at point: NSPoint, in bands: [(index: Int, band: MoveConnectorBand)]) -> (
        index: Int, band: MoveConnectorBand
    )? {
        bands.last { outline(of: $0.band).contains(point) }
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
        drawnHover = pointer.flatMap { band(at: $0, in: bands)?.index }
        // Every band's base goes down before any band, so the hairlines stop where a band
        // meets its rows while crossing bands still show through each other.
        for (_, band) in bands {
            drawFading(band, context: context) {
                context.addPath(outline(of: band))
                context.setFillColor(DiffTheme.background.cgColor)
                context.fillPath()
            }
        }
        for (index, band) in bands {
            drawFading(band, context: context) { draw(band, isHovered: index == drawnHover, context: context) }
        }
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

    /// Runs `body` so that, when one end is clamped, what it draws fades out toward the
    /// viewport edge that end leaves through.
    private func drawFading(_ band: MoveConnectorBand, context: CGContext, _ body: () -> Void) {
        guard let fadeEdge = fadeEdgeY(of: band) else { return body() }
        context.saveGState()
        context.clip(to: outline(of: band).boundingBoxOfPath.insetBy(dx: -1, dy: -1))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        fadeOut(towardY: fadeEdge, context: context)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// The viewport edge a clamped end leaves through, or nil when both ends are visible.
    private func fadeEdgeY(of band: MoveConnectorBand) -> CGFloat? {
        guard let side = band.clampedSide else { return nil }
        let end = side == .old ? band.left : band.right
        return end.bottom <= 0 ? 0 : bounds.height
    }

    /// Erases the band progressively over the last two rows before `edgeY`, so it reads as
    /// continuing off screen rather than stopping at the edge.
    private func fadeOut(towardY edgeY: CGFloat, context: CGContext) {
        let length = 2 * rowHeight
        let inner = edgeY == 0 ? length : edgeY - length
        let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray
        guard let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1]) else { return }
        context.setBlendMode(.destinationOut)
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: inner), end: CGPoint(x: 0, y: edgeY),
            options: [.drawsAfterEndLocation])
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

    /// Redraws only when the hovered band changes. The pointing hand says a band is clickable.
    private func updateHover(at point: NSPoint?) {
        pointer = point
        let hovered = point.flatMap { band(at: $0, in: visibleBands())?.index }
        if point != nil { (hovered == nil ? NSCursor.arrow : NSCursor.pointingHand).set() }
        if hovered != drawnHover { needsDisplay = true }
    }

    override func scrollWheel(with event: NSEvent) {
        if let rightScroll { rightScroll.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let onJumpToDocumentRow, let hit = band(at: point, in: visibleBands()) else { return }
        onJumpToDocumentRow(jumpTarget(of: hit.index, band: hit.band))
    }

    /// The end that is off screen, or the new end when both are visible.
    private func jumpTarget(of index: Int, band: MoveConnectorBand) -> Int {
        let move = moves[index].move
        return band.clampedSide == .old ? move.oldRowRange.lowerBound : move.newRowRange.lowerBound
    }

    // MARK: - Accessibility

    /// One button per visible band, so VoiceOver can jump even when the band's gutter
    /// markers are off screen.
    override func accessibilityChildren() -> [Any]? {
        guard let onJumpToDocumentRow else { return [] }
        return visibleBands().map { index, band in
            let target = jumpTarget(of: index, band: band)
            let label = band.clampedSide == .old ? "Go to where these lines came from" : "Go to where these lines moved"
            return ButtonElement(
                parent: self, frame: outline(of: band).boundingBoxOfPath.intersection(bounds), label: label,
                onPress: { onJumpToDocumentRow(target) })
        }
    }
}
