import AppKit
import CoreText

/// A run of syntax color within a line (UTF-16 offsets). Filled in by the highlighter.
struct StyleRun: Sendable, Equatable {
    let range: Range<Int>
    let color: NSColor
}

/// Everything one pane needs to draw.
struct PaneModel {
    enum Side { case old, new }

    let side: Side
    let rows: [DiffRow]
    let lines: [String]
    /// Optional syntax color runs per line index.
    var styles: [[StyleRun]]?

    func cell(_ row: DiffRow) -> DiffSide? {
        side == .old ? row.old : row.new
    }
}

/// Draws one side of the diff: sticky line-number gutter, row backgrounds, token
/// highlights, and monospaced text. Only rows intersecting the dirty rect are drawn,
/// and shaped lines are cached, so large diffs scroll smoothly.
final class DiffPaneView: NSView {
    var model: PaneModel? {
        didSet { lineCache.removeAll(); recomputeMetrics(); needsDisplay = true }
    }

    var fontSize: CGFloat = 12 {
        didSet { if fontSize != oldValue { lineCache.removeAll(); recomputeMetrics(); needsDisplay = true } }
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
        let rowCount = model?.rows.count ?? 0
        layout = PaneLayout(rowHeight: lineHeight + 4, rowCount: rowCount)

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
        context.fill(dirtyRect)
        guard let model else { return }

        let visible = visibleRect
        let rows = layout.rows(intersecting: dirtyRect.minY, dirtyRect.maxY)
        for rowIndex in rows {
            let row = model.rows[rowIndex]
            let rowRect = NSRect(x: visible.minX, y: layout.y(forRow: rowIndex), width: visible.width, height: layout.rowHeight)
            let cell = model.cell(row)
            let (rowColor, tokenColor, gutterColor) = colors(for: row.kind, side: model.side, hasCell: cell != nil)

            if let cell {
                if let rowColor {
                    rowColor.setFill()
                    context.fill(NSRect(x: 0, y: rowRect.minY, width: max(bounds.width, visible.maxX), height: rowRect.height))
                }
                drawText(cell, in: rowRect, model: model, tokenColor: tokenColor, context: context)
            } else {
                drawPad(rowRect, context: context)
            }
            drawGutter(cell, rowRect: rowRect, gutterColor: gutterColor, context: context)
        }

        DiffTheme.divider.setFill()
        context.fill(NSRect(x: visible.minX + gutterWidth - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height))
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
        let fullRect = NSRect(x: 0, y: rowRect.minY, width: max(bounds.width, rowRect.maxX), height: rowRect.height)
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
        if let runs = model.styles?[lineIndex] {
            let length = attributed.length
            for run in runs {
                let lower = expanded.map.map { $0[min(run.range.lowerBound, $0.count - 1)] } ?? run.range.lowerBound
                let upper = expanded.map.map { $0[min(run.range.upperBound, $0.count - 1)] } ?? run.range.upperBound
                let clampedLower = min(max(lower, 0), length)
                let clampedUpper = min(max(upper, clampedLower), length)
                guard clampedUpper > clampedLower else { continue }
                attributed.addAttribute(.foregroundColor, value: run.color, range: NSRange(location: clampedLower, length: clampedUpper - clampedLower))
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
