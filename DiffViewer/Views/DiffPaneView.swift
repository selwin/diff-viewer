import AppKit
import CoreText

/// A run of syntax style within a line (UTF-16 offsets). Produced by the highlighter.
struct StyleRun: Sendable, Equatable {
    let range: Range<Int>
    let style: TokenStyle
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
    /// Document content. Installed through `install(_:mode:)`, which decides what has to
    /// be reset, so plain assignment is not allowed.
    private(set) var model: PaneModel?

    /// Syntax color runs per line index. Only the shaped line cache is reset; header text
    /// does not depend on syntax styles.
    var styles: [[StyleRun]]? {
        didSet { lineCache.removeAll(); needsDisplay = true }
    }

    /// Folded projection of `model.rows`. Only the row count changes; caches are
    /// keyed by line index and stay valid.
    var displayRows: [DisplayRow] = [] {
        didSet { layout.rowCount = displayRows.count; needsDisplay = true }
    }

    /// The text selected in this pane, in document rows and raw UTF-16 offsets.
    var selection: PaneSelection? {
        didSet { if selection != oldValue { needsDisplay = true } }
    }

    /// Called when a selection starts here, so the other pane can drop its own.
    var onSelectionStart: (() -> Void)?

    var foldOptions = FoldOptions()

    /// Called when the user clicks a separator row.
    var onFoldAction: ((FoldAction) -> Void)?

    /// Display rows of the current change block; drawn with an accent bar in the gutter.
    var currentChangeRows: Range<Int>? {
        didSet { if currentChangeRows != oldValue { needsDisplay = true } }
    }

    var fontSize: CGFloat = 12 {
        didSet {
            if fontSize != oldValue {
                lineCache.removeAll()
                numberCache.removeAll()
                headerCache.removeAll()
                recomputeMetrics()
                needsDisplay = true
            }
        }
    }

    /// Installs new content. `.replace` starts from scratch; `.append` is the same
    /// document with sections added at the end, so the selection and the shaped-line
    /// caches (keyed by line index, which never shifts) stay valid and only the new
    /// lines are measured.
    func install(_ model: PaneModel?, mode: DocumentUpdate.Mode) {
        let previousLineCount = self.model?.lines.count ?? 0
        self.model = model
        switch mode {
        case .replace:
            selection = nil
            lineCache.removeAll()
            numberCache.removeAll()
            headerCache.removeAll()
            recomputeMetrics()
        case .append:
            extendMetrics(from: previousLineCount)
        }
        needsDisplay = true
    }

    private(set) var layout = PaneLayout(rowHeight: 20, rowCount: 0)
    private(set) var contentWidth: CGFloat = 0
    private(set) var font = DiffTheme.font(size: 12)
    private(set) var ascent: CGFloat = 0
    private(set) var charWidth: CGFloat = 7
    private(set) var gutterWidth: CGFloat = 40
    let textInset: CGFloat = 8
    /// Widest line measured so far, in character units; an append only extends it.
    private var maxLineUnits = 0
    private var lineCache: [Int: CachedLine] = [:]
    private var numberCache: [Int: CTLine] = [:]
    /// One shaped header line per changeset section index, for this pane's side.
    var headerCache: [Int: CTLine] = [:]

    struct CachedLine {
        let line: CTLine
        let map: [Int]?
        let width: CGFloat
        /// UTF-16 length of the raw (tab-unexpanded) line; selection offsets are clamped to it.
        let rawLength: Int
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { model != nil }

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
        headerCache.removeAll()
        needsDisplay = true
    }

    /// Owned here because stored properties cannot live in the input extension.
    var trackingArea: NSTrackingArea?

    // MARK: - Metrics

    /// Measures everything from scratch: a new document, or the same one at a new font size.
    private func recomputeMetrics() {
        font = DiffTheme.font(size: fontSize)
        ascent = ceil(font.ascender)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        layout = PaneLayout(rowHeight: lineHeight + 4, rowCount: displayRows.count)

        gutterWidth = width(forDigits: model?.gutterDigits ?? 3)
        maxLineUnits = 0
        for line in model?.lines ?? [] { maxLineUnits = max(maxLineUnits, units(of: line)) }
        contentWidth = gutterWidth + textInset + CGFloat(maxLineUnits) * charWidth + 40
    }

    /// Measures only the lines an append added. The gutter can widen but never shrinks,
    /// so the numbers already drawn keep their position.
    private func extendMetrics(from previousLineCount: Int) {
        guard let model else { return }
        if previousLineCount < model.lines.count {
            for line in model.lines[previousLineCount...] { maxLineUnits = max(maxLineUnits, units(of: line)) }
        }
        gutterWidth = max(gutterWidth, width(forDigits: model.gutterDigits))
        contentWidth = gutterWidth + textInset + CGFloat(maxLineUnits) * charWidth + 40
    }

    private func width(forDigits digits: Int) -> CGFloat {
        ceil(CGFloat(digits) * charWidth) + 20
    }

    /// Width of a line in character units, counting a tab as its expansion.
    private func units(of line: String) -> Int {
        var units = line.utf16.count
        if line.utf16.contains(9) { units += line.utf16.count(where: { $0 == 9 }) * (DiffTheme.tabWidth - 1) }
        return units
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
            let rowRect = NSRect(
                x: visible.minX, y: layout.y(forRow: displayIndex), width: visible.width, height: layout.rowHeight)
            switch displayRows[displayIndex] {
            case let .documentRow(rowIndex):
                drawDocumentRow(model.rows[rowIndex], at: rowIndex, in: rowRect, model: model, context: context)
            case let .separator(hidden):
                drawSeparator(hidden, in: rowRect, context: context)
            case let .fileHeader(section):
                drawFileHeader(section: section, in: rowRect, model: model, context: context)
            case .spacer:
                drawSpacer(in: rowRect, context: context)
            case let .notice(section):
                drawNotice(section: section, in: rowRect, model: model, context: context)
            }
            if let current = currentChangeRows, current.contains(displayIndex) {
                NSColor.controlAccentColor.setFill()
                context.fill(NSRect(x: rowRect.minX, y: rowRect.minY, width: 3, height: rowRect.height))
            }
        }

        DiffTheme.divider.setFill()
        context.fill(NSRect(x: visible.minX + gutterWidth - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height))
    }

    private func drawDocumentRow(
        _ row: DiffRow, at index: Int, in rowRect: NSRect, model: PaneModel, context: CGContext
    ) {
        let cell = model.cell(row)
        let (rowColor, tokenColor, gutterColor) = colors(for: row.kind, side: model.side, hasCell: cell != nil)
        if let cell {
            if let rowColor {
                rowColor.setFill()
                context.fill(fullWidthRect(rowRect))
            }
            let cached = cachedLine(for: cell.lineIndex, model: model)
            drawHighlights(cell.highlights, cached: cached, in: rowRect, tokenColor: tokenColor, context: context)
            drawSelection(ofRow: index, cached: cached, in: rowRect, context: context)
            drawLine(
                cached.line, at: CGPoint(x: gutterWidth + textInset, y: rowRect.minY + 2 + ascent), context: context)
        } else {
            drawPad(rowRect, context: context)
        }
        drawGutter(cell, inRow: index, rowRect: rowRect, gutterColor: gutterColor, context: context)
    }

    /// The row across the whole document view, so a background reaches past the visible
    /// width.
    func fullWidthRect(_ rowRect: NSRect) -> NSRect {
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

    private func drawGutter(
        _ cell: DiffSide?, inRow row: Int, rowRect: NSRect, gutterColor: NSColor?, context: CGContext
    ) {
        let gutterRect = fillGutter(rowRect, color: gutterColor, context: context)
        guard let cell, let model else { return }
        let numberLine = numberLine(for: model.lineNumber(of: cell, inRow: row), changed: gutterColor != nil)
        let width = CTLineGetTypographicBounds(numberLine, nil, nil, nil)
        drawLine(
            numberLine, at: CGPoint(x: gutterRect.maxX - 10 - CGFloat(width), y: rowRect.minY + 2 + ascent),
            context: context)
    }

    /// Fills the gutter band of a row and returns it. Rows with no line number
    /// (separators, notices) fill it for continuity and draw nothing in it.
    @discardableResult
    func fillGutter(_ rowRect: NSRect, color: NSColor?, context: CGContext) -> NSRect {
        let gutterRect = NSRect(x: rowRect.minX, y: rowRect.minY, width: gutterWidth, height: rowRect.height)
        (color ?? DiffTheme.gutterBackground).setFill()
        context.fill(gutterRect)
        return gutterRect
    }

    private func drawHighlights(
        _ highlights: [Range<Int>], cached: CachedLine, in rowRect: NSRect, tokenColor: NSColor, context: CGContext
    ) {
        guard !highlights.isEmpty else { return }
        tokenColor.setFill()
        for range in highlights {
            let start = cached.map.map { $0[min(range.lowerBound, $0.count - 1)] } ?? range.lowerBound
            let end = cached.map.map { $0[min(range.upperBound, $0.count - 1)] } ?? range.upperBound
            let x0 = CTLineGetOffsetForStringIndex(cached.line, start, nil)
            let x1 = CTLineGetOffsetForStringIndex(cached.line, end, nil)
            guard x1 > x0 else { continue }
            context.fill(
                NSRect(
                    x: gutterWidth + textInset + x0, y: rowRect.minY + 1, width: x1 - x0, height: rowRect.height - 2))
        }
    }

    /// The selected span of one row, drawn over the token highlights and under the text.
    /// A row whose newline is selected extends one character past the end of the line.
    private func drawSelection(ofRow row: Int, cached: CachedLine, in rowRect: NSRect, context: CGContext) {
        guard let selection, let range = selection.range(forRow: row, lineLength: cached.rawLength) else { return }
        let start = cached.map.map { $0[min(range.lowerBound, $0.count - 1)] } ?? range.lowerBound
        let end = cached.map.map { $0[min(range.upperBound, $0.count - 1)] } ?? range.upperBound
        let x0 = CTLineGetOffsetForStringIndex(cached.line, start, nil)
        var x1 = CTLineGetOffsetForStringIndex(cached.line, end, nil)
        if selection.includesLineEnd(ofRow: row) { x1 += charWidth }
        guard x1 > x0 else { return }
        NSColor.selectedTextBackgroundColor.setFill()
        context.fill(
            NSRect(x: gutterWidth + textInset + x0, y: rowRect.minY + 1, width: x1 - x0, height: rowRect.height - 2))
    }

    func drawLine(_ line: CTLine, at point: CGPoint, context: CGContext) {
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
        guard onFoldAction != nil else { return [] }  // A changeset's separators are inert.
        let side = rowRect.height - 4
        var x = rowRect.minX + gutterWidth + textInset
        let controls = RowFolding.controls(for: hidden, documentRowCount: model?.rows.count ?? 0, options: foldOptions)
        return controls.map { control in
            defer { x += side + 4 }
            return (control, NSRect(x: x, y: rowRect.minY + 2, width: side, height: side))
        }
    }

    /// A folded run. Without a fold handler (a changeset) the row is inert: no control
    /// squares, and a leading ellipsis so it still reads as a gap.
    private func drawSeparator(_ hidden: Range<Int>, in rowRect: NSRect, context: CGContext) {
        DiffTheme.foldBackground.setFill()
        context.fill(fullWidthRect(rowRect))
        fillGutter(rowRect, color: nil, context: context)

        var textX = rowRect.minX + gutterWidth + textInset
        for (control, rect) in controlRects(for: hidden, rowRect: rowRect) {
            DiffTheme.foldControl.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            drawChevrons(for: control, in: rect, context: context)
            textX = rect.maxX + 4
        }

        let count = "\(hidden.count) unchanged line\(hidden.count == 1 ? "" : "s")"
        let text = onFoldAction == nil ? "⋯ \(count)" : count
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: DiffTheme.foldText])
        drawLine(
            CTLineCreateWithAttributedString(attributed), at: CGPoint(x: textX + 6, y: rowRect.minY + 2 + ascent),
            context: context)
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

    // MARK: - Accessibility

    /// One button per visible separator control, so VoiceOver can expand folded regions.
    override func accessibilityChildren() -> [Any]? {
        guard let onFoldAction else { return nil }
        var elements: [NSAccessibilityElement] = []
        for index in layout.rows(intersecting: visibleRect.minY, visibleRect.maxY) where index < displayRows.count {
            guard case let .separator(hidden) = displayRows[index] else { continue }
            for (control, rect) in controlRects(for: hidden, rowRect: separatorRowRect(at: index)) {
                let element = FoldControlElement()
                element.setAccessibilityRole(.button)
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(rect)
                element.setAccessibilityLabel(accessibilityLabel(for: control, hidden: hidden))
                let action = Self.action(for: control, hidden: hidden)
                element.onPress = { onFoldAction(action) }
                elements.append(element)
            }
        }
        return elements
    }

    private func accessibilityLabel(for control: FoldControl, hidden: Range<Int>) -> String {
        let step = min(foldOptions.expansionStep, hidden.count)
        switch control {
        case .expandUp: return "Show \(step) lines before the next change"
        case .expandDown: return "Show \(step) lines after the previous change"
        case .expandRun: return "Show all \(hidden.count) unchanged lines"
        }
    }

    // MARK: - Caches

    func cachedLine(for lineIndex: Int, model: PaneModel) -> CachedLine {
        if let cached = lineCache[lineIndex] { return cached }
        if lineCache.count > 4000 { lineCache.removeAll(keepingCapacity: true) }
        let raw = model.lines[lineIndex]
        let expanded = TabExpander.expand(raw, tabWidth: DiffTheme.tabWidth)
        let attributed = NSMutableAttributedString(
            string: expanded.text,
            attributes: [
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
                attributed.addAttribute(
                    .foregroundColor, value: DiffTheme.color(for: run.style),
                    range: NSRange(location: clampedLower, length: clampedUpper - clampedLower))
            }
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let cached = CachedLine(line: line, map: expanded.map, width: width, rawLength: raw.utf16.count)
        lineCache[lineIndex] = cached
        return cached
    }

    private func numberLine(for number: Int, changed: Bool) -> CTLine {
        let key = changed ? -number : number
        if let line = numberCache[key] { return line }
        if numberCache.count > 4000 { numberCache.removeAll(keepingCapacity: true) }
        let attributed = NSAttributedString(
            string: String(number),
            attributes: [
                .font: font,
                .foregroundColor: changed ? DiffTheme.lineNumberChanged : DiffTheme.lineNumber,
            ])
        let line = CTLineCreateWithAttributedString(attributed)
        numberCache[key] = line
        return line
    }
}

private final class FoldControlElement: NSAccessibilityElement {
    var onPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}
