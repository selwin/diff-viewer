import AppKit
import CoreText

/// Separator rows: the scope of the next change on the left, the fold controls and the
/// hidden-line count on the right.
extension DiffPaneView {
    /// The separator's layout and its shaped count, shared by drawing, clicks and
    /// accessibility. A changeset's separators are inert: no controls, and a leading ellipsis
    /// so the row still reads as a gap.
    func separatorLayout(for hidden: Range<Int>, rowRect: NSRect) -> (layout: SeparatorLayout, count: CTLine) {
        let count = "\(hidden.count) unchanged line\(hidden.count == 1 ? "" : "s")"
        let controls =
            onFoldAction == nil
            ? [] : RowFolding.controls(for: hidden, documentRowCount: model?.rows.count ?? 0, options: foldOptions)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: onFoldAction == nil ? "⋯ \(count)" : count,
                attributes: [.font: font, .foregroundColor: DiffTheme.foldText]))
        let layout = SeparatorLayout(
            rowRect: rowRect, gutterWidth: gutterWidth, textInset: textInset, charWidth: charWidth,
            countWidth: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), controls: controls)
        return (layout, line)
    }

    func drawSeparator(_ hidden: Range<Int>, in rowRect: NSRect, context: CGContext) {
        DiffTheme.foldBackground.setFill()
        context.fill(fullWidthRect(rowRect))
        fillGutter(rowRect, color: nil, context: context)

        let (layout, count) = separatorLayout(for: hidden, rowRect: rowRect)
        for (control, rect) in layout.controls {
            DiffTheme.foldControl.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            drawChevrons(for: control, in: rect, context: context)
        }
        let baseline = rowRect.minY + 2 + ascent
        if let fitted = truncated(
            count, truncation: .end, availableWidth: layout.countWidth, color: DiffTheme.foldText)
        {
            drawLine(fitted, at: CGPoint(x: layout.countX, y: baseline), context: context)
        }
        drawScopeLabel(for: hidden, layout: layout, baseline: baseline, context: context)
    }

    /// `Parent › name` for the next change's scope. When it does not fit, only the innermost
    /// name is shown, cut at the tail so its start stays readable; nothing if not even that fits.
    private func drawScopeLabel(
        for hidden: Range<Int>, layout: SeparatorLayout, baseline: CGFloat, context: CGContext
    ) {
        guard let outline, let allNames = model?.scopeAnchor(after: hidden)?.names(in: outline), !allNames.isEmpty
        else { return }
        let nameAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: DiffTheme.foldScope]
        // The label as drawn, so the fit decision measures exactly what is shaped.
        func label(_ names: [String]) -> NSAttributedString {
            let text = NSMutableAttributedString()
            for (index, name) in names.enumerated() {
                if index > 0 {
                    text.append(
                        NSAttributedString(
                            string: " › ", attributes: [.font: font, .foregroundColor: DiffTheme.foldText]))
                }
                text.append(NSAttributedString(string: name, attributes: nameAttributes))
            }
            return text
        }
        let names = SeparatorLayout.labelNames(allNames, availableWidth: layout.labelWidth) {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(label($0)), nil, nil, nil))
        }
        guard
            let line = truncated(
                CTLineCreateWithAttributedString(label(names)), truncation: .end, availableWidth: layout.labelWidth,
                color: DiffTheme.foldScope)
        else { return }
        drawLine(line, at: CGPoint(x: layout.labelX, y: baseline), context: context)
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
}
