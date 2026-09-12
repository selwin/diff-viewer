import AppKit
import CoreText

/// A run of syntax style within a line (UTF-16 offsets). Produced by the highlighter.
struct StyleRun: Sendable, Equatable {
    let range: Range<Int>
    let style: TokenStyle
}

/// The document content one pane draws from.
struct PaneModel {
    enum Side { case old, new }

    let side: Side
    let rows: [DiffRow]
    let lines: [String]

    func cell(_ row: DiffRow) -> DiffSide? {
        side == .old ? row.old : row.new
    }
}

/// A click on a separator row. Ranges are hidden document rows.
enum FoldAction: Equatable {
    case expandUp(Range<Int>)
    case expandDown(Range<Int>)
    case expandRun(Range<Int>)
    case expandAll
}

/// Draws one side of the diff: sticky line-number gutter, row backgrounds, token
/// highlights, monospaced text, and separator rows for folded regions. Only rows
/// intersecting the dirty rect are drawn, and shaped lines are cached, so large
/// diffs scroll smoothly.
final class DiffPaneView: NSView {
    /// Document content. Set once per document; recomputes metrics and clears caches.
    var model: PaneModel? {
        didSet { lineCache.removeAll(); numberCache.removeAll(); recomputeMetrics(); needsDisplay = true }
    }

    /// Syntax color runs per line index. Only the shaped-text cache is reset.
    var styles: [[StyleRun]]? {
        didSet { lineCache.removeAll(); needsDisplay = true }
    }

    /// Folded projection of `model.rows`. Only the row count changes; caches are
    /// keyed by line index and stay valid.
    var displayRows: [DisplayRow] = [] {
        didSet { layout.rowCount = displayRows.count; needsDisplay = true }
    }

    var foldOptions = FoldOptions()

    /// Called when the user clicks a separator row.
    var onFoldAction: ((FoldAction) -> Void)?

    /// Display rows of the current change block; drawn with an accent bar in the gutter.
    var currentChangeRows: Range<Int>? {
        didSet { if currentChangeRows != oldValue { needsDisplay = true } }
    }

    var fontSize: CGFloat = 12 {
        didSet { if fontSize != oldValue { lineCache.removeAll(); numberCache.removeAll(); recomputeMetrics(); needsDisplay = true } }
    }

    private(set) var layout = PaneLayout(rowHeight: 20, rowCount: 0)
    private(set) var contentWidth: CGFloat = 0
    private var font = DiffTheme.font(size: 12)
    private var ascent: CGFloat = 0
    private var charWidth: CGFloat = 7
    private var gutterWidth: CGFloat = 40
    private let textInset: CGFloat = 8
    private var lineCache: [Int: CachedLine] = [:]
    private var numberCache: [Int: CTLine] = [:]

    private struct CachedLine {
        let line: CTLine
        let map: [Int]?
        let width: CGFloat
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        recomputeMetrics()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lineCache.removeAll()
        numberCache.removeAll()
        needsDisplay = true
    }

    // MARK: - Metrics

    private func recomputeMetrics() {
        font = DiffTheme.font(size: fontSize)
        ascent = ceil(font.ascender)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        layout = PaneLayout(rowHeight: lineHeight + 4, rowCount: displayRows.count)

        let lineCount = model?.lines.count ?? 0
        let digits = max(3, String(max(lineCount, 1)).count)
        gutterWidth = ceil(CGFloat(digits) * charWidth) + 20

        var maxUnits = 0
        if let lines = model?.lines {
            for line in lines {
                var units = line.utf16.count
                if line.utf16.contains(9) { units += line.utf16.count(where: { $0 == 9 }) * (DiffTheme.tabWidth - 1) }
                if units > maxUnits { maxUnits = units }
            }
        }
        contentWidth = gutterWidth + textInset + CGFloat(maxUnits) * charWidth + 40
    }

    /// Size the document view should have inside a clip view of the given width.
    func desiredSize(clipWidth: CGFloat, clipHeight: CGFloat) -> NSSize {
        NSSize(width: max(contentWidth, clipWidth), height: max(layout.contentHeight, clipHeight))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        DiffTheme.background.setFill()
        context.fill(bounds.intersection(dirtyRect))
        guard let model else { return }

        let visible = visibleRect
        let rows = layout.rows(intersecting: dirtyRect.minY, dirtyRect.maxY)
        for displayIndex in rows where displayIndex < displayRows.count {
            let rowRect = NSRect(x: visible.minX, y: layout.y(forRow: displayIndex), width: visible.width, height: layout.rowHeight)
            switch displayRows[displayIndex] {
            case let .documentRow(rowIndex):
                drawDocumentRow(model.rows[rowIndex], in: rowRect, model: model, context: context)
            case let .separator(hidden):
                drawSeparator(hidden, in: rowRect, context: context)
            }
            if let current = currentChangeRows, current.contains(displayIndex) {
                NSColor.controlAccentColor.setFill()
                context.fill(NSRect(x: rowRect.minX, y: rowRect.minY, width: 3, height: rowRect.height))
            }
        }

        DiffTheme.divider.setFill()
        context.fill(NSRect(x: visible.minX + gutterWidth - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height))
    }

    private func drawDocumentRow(_ row: DiffRow, in rowRect: NSRect, model: PaneModel, context: CGContext) {
        let cell = model.cell(row)
        let (rowColor, tokenColor, gutterColor) = colors(for: row.kind, side: model.side, hasCell: cell != nil)
        if let cell {
            if let rowColor {
                rowColor.setFill()
                context.fill(fullWidthRect(rowRect))
            }
            drawText(cell, in: rowRect, model: model, tokenColor: tokenColor, context: context)
        } else {
            drawPad(rowRect, context: context)
        }
        drawGutter(cell, rowRect: rowRect, gutterColor: gutterColor, context: context)
    }

    private func fullWidthRect(_ rowRect: NSRect) -> NSRect {
        NSRect(x: 0, y: rowRect.minY, width: max(bounds.width, rowRect.maxX), height: rowRect.height)
    }

    private func colors(for kind: DiffRow.Kind, side: PaneModel.Side, hasCell: Bool) -> (NSColor?, NSColor, NSColor?) {
        guard hasCell else { return (nil, .clear, nil) }
        switch kind {
        case .equal:
            return (nil, .clear, nil)
        case .modified:
            return side == .old
                ? (DiffTheme.deletedRow, DiffTheme.deletedToken, DiffTheme.deletedGutter)
                : (DiffTheme.addedRow, DiffTheme.addedToken, DiffTheme.addedGutter)
        case .deleted:
            return (DiffTheme.deletedRow, DiffTheme.deletedToken, DiffTheme.deletedGutter)
        case .added:
            return (DiffTheme.addedRow, DiffTheme.addedToken, DiffTheme.addedGutter)
        }
    }

    private func drawPad(_ rowRect: NSRect, context: CGContext) {
        let fullRect = fullWidthRect(rowRect)
        DiffTheme.padBackground.setFill()
        context.fill(fullRect)
        context.saveGState()
        context.clip(to: fullRect)
        context.setStrokeColor(DiffTheme.padStripe.cgColor)
        context.setLineWidth(1)
        let step: CGFloat = 8
        var x = floor(fullRect.minX / step) * step - rowRect.height
        while x < fullRect.maxX {
            context.move(to: CGPoint(x: x, y: fullRect.maxY))
            context.addLine(to: CGPoint(x: x + rowRect.height, y: fullRect.minY))
            x += step
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawGutter(_ cell: DiffSide?, rowRect: NSRect, gutterColor: NSColor?, context: CGContext) {
        let gutterRect = NSRect(x: rowRect.minX, y: rowRect.minY, width: gutterWidth, height: rowRect.height)
        (gutterColor ?? DiffTheme.gutterBackground).setFill()
        context.fill(gutterRect)
        guard let cell else { return }
        let numberLine = numberLine(for: cell.lineNumber, changed: gutterColor != nil)
        let width = CTLineGetTypographicBounds(numberLine, nil, nil, nil)
        drawLine(numberLine, at: CGPoint(x: gutterRect.maxX - 10 - CGFloat(width), y: rowRect.minY + 2 + ascent), context: context)
    }

    private func drawText(_ cell: DiffSide, in rowRect: NSRect, model: PaneModel, tokenColor: NSColor, context: CGContext) {
        let cached = cachedLine(for: cell.lineIndex, model: model)
        let textX = gutterWidth + textInset
        let baseline = rowRect.minY + 2 + ascent

        if !cell.highlights.isEmpty {
            tokenColor.setFill()
            for range in cell.highlights {
                let start = cached.map.map { $0[min(range.lowerBound, $0.count - 1)] } ?? range.lowerBound
                let end = cached.map.map { $0[min(range.upperBound, $0.count - 1)] } ?? range.upperBound
                let x0 = CTLineGetOffsetForStringIndex(cached.line, start, nil)
                let x1 = CTLineGetOffsetForStringIndex(cached.line, end, nil)
                guard x1 > x0 else { continue }
                let rect = NSRect(x: textX + x0, y: rowRect.minY + 1, width: x1 - x0, height: rowRect.height - 2)
                context.fill(rect)
            }
        }
        drawLine(cached.line, at: CGPoint(x: textX, y: baseline), context: context)
    }

    private func drawLine(_ line: CTLine, at point: CGPoint, context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - Separators

    /// Control squares for a separator, left to right after the gutter. The same
    /// geometry is used for drawing and hit testing. `rowRect.minX` is the visible
    /// left edge, so controls stay put under horizontal scrolling like the gutter.
    func controlRects(for hidden: Range<Int>, rowRect: NSRect) -> [(control: FoldControl, rect: NSRect)] {
        let side = rowRect.height - 4
        var x = rowRect.minX + gutterWidth + textInset
        let controls = RowFolding.controls(for: hidden, documentRowCount: model?.rows.count ?? 0, options: foldOptions)
        return controls.map { control in
            defer { x += side + 4 }
            return (control, NSRect(x: x, y: rowRect.minY + 2, width: side, height: side))
        }
    }

    private func drawSeparator(_ hidden: Range<Int>, in rowRect: NSRect, context: CGContext) {
        DiffTheme.foldBackground.setFill()
        context.fill(fullWidthRect(rowRect))
        drawGutter(nil, rowRect: rowRect, gutterColor: nil, context: context)

        var textX = rowRect.minX + gutterWidth + textInset
        for (control, rect) in controlRects(for: hidden, rowRect: rowRect) {
            DiffTheme.foldControl.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            drawChevrons(for: control, in: rect, context: context)
            textX = rect.maxX + 4
        }

        let text = "\(hidden.count) unchanged line\(hidden.count == 1 ? "" : "s")"
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: DiffTheme.foldText])
        drawLine(CTLineCreateWithAttributedString(attributed), at: CGPoint(x: textX + 6, y: rowRect.minY + 2 + ascent), context: context)
    }

    private func drawChevrons(for control: FoldControl, in rect: NSRect, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(DiffTheme.foldText.cgColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let halfWidth = rect.width * 0.25
        let height = rect.height * 0.2
        // The view is flipped: smaller y is higher on screen.
        func chevron(pointingUp: Bool, centerY: CGFloat) {
            let apexY = pointingUp ? centerY - height / 2 : centerY + height / 2
            let baseY = pointingUp ? centerY + height / 2 : centerY - height / 2
            context.move(to: CGPoint(x: rect.midX - halfWidth, y: baseY))
            context.addLine(to: CGPoint(x: rect.midX, y: apexY))
            context.addLine(to: CGPoint(x: rect.midX + halfWidth, y: baseY))
        }
        switch control {
        case .expandUp:
            chevron(pointingUp: true, centerY: rect.midY)
        case .expandDown:
            chevron(pointingUp: false, centerY: rect.midY)
        case .expandRun:
            chevron(pointingUp: true, centerY: rect.midY - rect.height * 0.2)
            chevron(pointingUp: false, centerY: rect.midY + rect.height * 0.2)
        }
        context.strokePath()
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let onFoldAction, point.y >= 0, point.y < layout.contentHeight else { return super.mouseDown(with: event) }
        let index = layout.row(atY: point.y)
        guard index < displayRows.count, case let .separator(hidden) = displayRows[index] else { return super.mouseDown(with: event) }
        if event.modifierFlags.contains(.option) { return onFoldAction(.expandAll) }

        let rowRect = NSRect(x: visibleRect.minX, y: layout.y(forRow: index), width: visibleRect.width, height: layout.rowHeight)
        switch controlRects(for: hidden, rowRect: rowRect).first(where: { $0.rect.contains(point) })?.control {
        case .expandUp?: onFoldAction(.expandUp(hidden))
        case .expandDown?: onFoldAction(.expandDown(hidden))
        case .expandRun?, nil: onFoldAction(.expandRun(hidden))
        }
    }

    // MARK: - Caches

    private func cachedLine(for lineIndex: Int, model: PaneModel) -> CachedLine {
        if let cached = lineCache[lineIndex] { return cached }
        if lineCache.count > 4000 { lineCache.removeAll(keepingCapacity: true) }
        let raw = model.lines[lineIndex]
        let expanded = TabExpander.expand(raw, tabWidth: DiffTheme.tabWidth)
        let attributed = NSMutableAttributedString(string: expanded.text, attributes: [
            .font: font,
            .foregroundColor: DiffTheme.text,
        ])
        if let styles, lineIndex < styles.count {
            let runs = styles[lineIndex]
            let length = attributed.length
            for run in runs {
                let lower = expanded.map.map { $0[min(run.range.lowerBound, $0.count - 1)] } ?? run.range.lowerBound
                let upper = expanded.map.map { $0[min(run.range.upperBound, $0.count - 1)] } ?? run.range.upperBound
                let clampedLower = min(max(lower, 0), length)
                let clampedUpper = min(max(upper, clampedLower), length)
                guard clampedUpper > clampedLower else { continue }
                attributed.addAttribute(.foregroundColor, value: DiffTheme.color(for: run.style), range: NSRange(location: clampedLower, length: clampedUpper - clampedLower))
            }
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let cached = CachedLine(line: line, map: expanded.map, width: width)
        lineCache[lineIndex] = cached
        return cached
    }

    private func numberLine(for number: Int, changed: Bool) -> CTLine {
        let key = changed ? -number : number
        if let line = numberCache[key] { return line }
        if numberCache.count > 4000 { numberCache.removeAll(keepingCapacity: true) }
        let attributed = NSAttributedString(string: String(number), attributes: [
            .font: font,
            .foregroundColor: changed ? DiffTheme.lineNumberChanged : DiffTheme.lineNumber,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        numberCache[key] = line
        return line
    }
}
