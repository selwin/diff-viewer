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

    /// Syntax color runs per line index. Lines whose runs changed are reshaped; lines whose
    /// runs stayed equal are reused. Header text does not depend on syntax styles.
    var styles: [[StyleRun]]? {
        didSet {
            let old = oldValue
            let new = styles
            lineCache = lineCache.filter { Self.keepsShapedLine(at: $0.key, old: old, new: new) }
            needsDisplay = true
        }
    }

    /// Named scopes of this side's lines, for labelling separators. Set with `styles`
    /// through `setSyntax`.
    var outline: ScopeOutline?

    /// Find hits per document row, in raw UTF-16 offsets on this pane's side.
    var findMatches: [Int: [Range<Int>]] = [:] {
        didSet { needsDisplay = true }
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

    /// Called when a text selection starts or Select All is invoked here, so the other pane
    /// can drop its selection. Programmatic selection changes do not call it.
    var onInteraction: (() -> Void)?

    var foldOptions = FoldOptions()

    /// Called when the user clicks a separator row.
    var onFoldAction: ((FoldAction) -> Void)?

    /// Called with the document row to scroll to when the user clicks a move marker.
    var onJumpToDocumentRow: ((Int) -> Void)?

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
            outline = nil  // Outlines are per document.
            findMatches = [:]
            lineCache.removeAll()
            numberCache.removeAll()
            headerCache.removeAll()
            recomputeMetrics()
        case .append:
            // Rows are append-only, so the find fills stay valid until the next search lands.
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
    /// The shaped header text per changeset section index, for this pane's side.
    var headerCache: [Int: HeaderLines] = [:]

    /// A file band's text, shaped once per section and truncated at draw time because
    /// the width can change. The old pane draws `name`; the new pane draws the rail.
    /// Only the lines this side draws are shaped.
    struct HeaderLines {
        /// Nil on the new pane.
        let name: CTLine?
        /// Nil on the old pane, or for a file at the repository root.
        let directory: CTLine?
        /// Nil on the old pane, or when neither side changed.
        let churn: CTLine?
    }

    struct CachedLine {
        let line: CTLine
        let map: [Int]?
        let width: CGFloat
        /// UTF-16 length of the raw (tab-unexpanded) line; selection offsets are clamped to it.
        let rawLength: Int
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    /// A hidden pane stays loaded but must not take key events; its text is not on screen.
    override var acceptsFirstResponder: Bool { model != nil && !isHiddenOrHasHiddenAncestor }

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
    /// Clip origin at the last horizontal-scroll redraw; owned by `SideBySideView`.
    var lastClipX: CGFloat = 0

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
        contentWidth = documentTextX + CGFloat(maxLineUnits) * charWidth + 40
    }

    /// Measures only the lines an append added. The gutter can widen but never shrinks,
    /// so the numbers already drawn keep their position.
    private func extendMetrics(from previousLineCount: Int) {
        guard let model else { return }
        if previousLineCount < model.lines.count {
            for line in model.lines[previousLineCount...] { maxLineUnits = max(maxLineUnits, units(of: line)) }
        }
        gutterWidth = max(gutterWidth, width(forDigits: model.gutterDigits))
        contentWidth = documentTextX + CGFloat(maxLineUnits) * charWidth + 40
    }

    // MARK: - Text geometry

    /// Where text starts in document coordinates, so it scrolls with the content.
    var documentTextX: CGFloat { gutterWidth + textInset }

    func baselineY(in rowRect: NSRect) -> CGFloat { rowRect.minY + 2 + ascent }

    /// The rectangle behind the text span `x0..<x1` (relative to the text origin), inset one point
    /// above and below the row.
    func textSpanRect(x0: CGFloat, x1: CGFloat, in rowRect: NSRect) -> NSRect {
        NSRect(x: documentTextX + x0, y: rowRect.minY + 1, width: x1 - x0, height: rowRect.height - 2)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let drawStart = DispatchTime.now().uptimeNanoseconds
        defer { PipelineMetrics.addDrawTime(DispatchTime.now().uptimeNanoseconds - drawStart) }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        DiffTheme.background.setFill()
        context.fill(bounds.intersection(dirtyRect))
        guard let model else { return }

        let visible = visibleRect
        let rows = layout.rows(intersecting: dirtyRect.minY, dirtyRect.maxY)
        for displayIndex in rows where displayIndex < displayRows.count {
            let rowRect = rowRect(at: displayIndex)
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
        let isMoved = cell.map { model.isMoved(line: $0.lineIndex) } ?? false
        let (rowColor, tokenColor, gutterColor) = colors(
            for: row.kind, side: model.side, hasCell: cell != nil, isMoved: isMoved)
        if let cell {
            if let rowColor {
                rowColor.setFill()
                context.fill(fullWidthRect(rowRect))
            }
            let cached = cachedLine(for: cell.lineIndex, model: model)
            // The gutter tints are translucent, so nothing may be drawn under the gutter.
            context.saveGState()
            context.clip(
                to: NSRect(
                    x: rowRect.minX + gutterWidth, y: rowRect.minY, width: rowRect.width, height: rowRect.height))
            // A move's two ends match apart from whitespace, so token highlights would mark nothing useful.
            if !isMoved {
                drawHighlights(cell.highlights, cached: cached, in: rowRect, tokenColor: tokenColor, context: context)
            }
            drawFindMatches(ofRow: index, cached: cached, in: rowRect, context: context)
            drawSelection(ofRow: index, cached: cached, in: rowRect, context: context)
            drawLine(
                cached.line, at: CGPoint(x: documentTextX, y: baselineY(in: rowRect)), context: context)
            context.restoreGState()
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

    /// Row, token and gutter colours for one side's cell. `isMoved` is per side: a modified
    /// row can be moved on one side and keep its normal look on the other.
    private func colors(
        for kind: DiffRow.Kind, side: PaneModel.Side, hasCell: Bool, isMoved: Bool
    ) -> (NSColor?, NSColor, NSColor?) {
        guard hasCell else { return (nil, .clear, nil) }
        if isMoved { return (DiffTheme.movedRow, .clear, DiffTheme.movedGutter) }
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
            numberLine, at: CGPoint(x: gutterRect.maxX - 10 - CGFloat(width), y: baselineY(in: rowRect)),
            context: context)
        drawMoveMarker(forLine: cell.lineIndex, rowRect: rowRect, model: model, context: context)
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

    /// The x span of a raw UTF-16 range in a shaped line, relative to the text origin, left
    /// edge first. Right-to-left text puts the logical start on the right. A range that mixes
    /// directions still gets one span, between its two ends.
    func horizontalBounds(_ range: Range<Int>, in cached: CachedLine) -> (x0: CGFloat, x1: CGFloat) {
        let start = TabExpander.expandedIndex(forRaw: range.lowerBound, map: cached.map)
        let end = TabExpander.expandedIndex(forRaw: range.upperBound, map: cached.map)
        let x0 = CTLineGetOffsetForStringIndex(cached.line, start, nil)
        let x1 = CTLineGetOffsetForStringIndex(cached.line, end, nil)
        return (min(x0, x1), max(x0, x1))
    }

    private func drawHighlights(
        _ highlights: [Range<Int>], cached: CachedLine, in rowRect: NSRect, tokenColor: NSColor, context: CGContext
    ) {
        guard !highlights.isEmpty else { return }
        tokenColor.setFill()
        for range in highlights {
            let (x0, x1) = horizontalBounds(range, in: cached)
            guard x1 > x0 else { continue }
            context.fill(textSpanRect(x0: x0, x1: x1, in: rowRect))
        }
    }

    /// The selected span of one row, drawn over the token highlights and under the text.
    /// A row whose newline is selected extends one character past the end of the line.
    private func drawSelection(ofRow row: Int, cached: CachedLine, in rowRect: NSRect, context: CGContext) {
        guard let selection, let range = selection.range(forRow: row, lineLength: cached.rawLength),
            selectedFindMatch(inRow: row) == nil
        else { return }
        var (x0, x1) = horizontalBounds(range, in: cached)
        if selection.includesLineEnd(ofRow: row) { x1 += charWidth }
        guard x1 > x0 else { return }
        NSColor.selectedTextBackgroundColor.setFill()
        context.fill(textSpanRect(x0: x0, x1: x1, in: rowRect))
    }

    func drawLine(_ line: CTLine, at point: CGPoint, context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - Accessibility

    /// Buttons for the visible fold controls and move markers, so VoiceOver can use them.
    override func accessibilityChildren() -> [Any]? {
        foldControlElements() + moveMarkerElements()
    }

    private func foldControlElements() -> [NSAccessibilityElement] {
        guard let onFoldAction else { return [] }
        var elements: [NSAccessibilityElement] = []
        for index in layout.rows(intersecting: visibleRect.minY, visibleRect.maxY) where index < displayRows.count {
            guard case let .separator(hidden) = displayRows[index] else { continue }
            for (control, rect) in separatorLayout(for: hidden, rowRect: rowRect(at: index)).layout.controls {
                let action = Self.action(for: control, hidden: hidden)
                elements.append(
                    ButtonElement(
                        parent: self, frame: rect, label: accessibilityLabel(for: control, hidden: hidden),
                        onPress: { onFoldAction(action) }))
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
                let lower = TabExpander.expandedIndex(forRaw: run.range.lowerBound, map: expanded.map)
                let upper = TabExpander.expandedIndex(forRaw: run.range.upperBound, map: expanded.map)
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
        PipelineMetrics.countShapedLine()
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

/// An accessibility button for a control the pane draws itself.
final class ButtonElement: NSAccessibilityElement {
    private let onPress: () -> Void

    init(parent: NSView, frame: NSRect, label: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frame)
        setAccessibilityLabel(label)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}

extension DiffPaneView {
    /// Size the document view should have inside a clip view of the given width.
    func desiredSize(clipWidth: CGFloat, clipHeight: CGFloat) -> NSSize {
        NSSize(width: max(contentWidth, clipWidth), height: max(layout.contentHeight, clipHeight))
    }

    /// Runs and outline come from one style snapshot, so they are replaced together.
    func setSyntax(styles: [[StyleRun]]?, outline: ScopeOutline?) {
        self.styles = styles
        self.outline = outline
    }

    fileprivate func width(forDigits digits: Int) -> CGFloat {
        ceil(CGFloat(digits) * charWidth) + 20
    }

    /// Width of a line in character units, counting a tab as its expansion.
    fileprivate func units(of line: String) -> Int {
        var units = line.utf16.count
        if line.utf16.contains(9) { units += line.utf16.count(where: { $0 == 9 }) * (DiffTheme.tabWidth - 1) }
        return units
    }

    /// A shaped line bakes in its style runs, so it survives a style change only when both
    /// snapshots have runs for it and they are equal. A line shaped before any styles
    /// arrived is always reshaped.
    static func keepsShapedLine(at index: Int, old: [[StyleRun]]?, new: [[StyleRun]]?) -> Bool {
        guard let old, let new, old.indices.contains(index), new.indices.contains(index) else { return false }
        return old[index] == new[index]
    }
}
