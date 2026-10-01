import AppKit
import CoreText

/// Separator rows: the scope of the next change on the left, the fold controls and the
/// hidden-line count on the right.
extension DiffPaneView {
    /// The separator's layout and its shaped count, shared by drawing, clicks and
    /// accessibility. Changeset separators omit fold controls and prefix the count with an
    /// ellipsis.
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

    func drawSeparator(_ hidden: Range<Int>, at index: Int, in rowRect: NSRect, context: CGContext) {
        DiffTheme.foldBackground.setFill()
        context.fill(fullWidthRect(rowRect))
        fillGutter(rowRect, color: nil, context: context)

        let (layout, count) = separatorLayout(for: hidden, rowRect: rowRect)
        for (control, rect) in layout.controls {
            DiffTheme.foldControl.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            drawChevrons(for: control, in: rect, context: context)
        }
        let baseline = baselineY(in: rowRect)
        if let fitted = truncated(
            count, truncation: .end, availableWidth: layout.countWidth, color: DiffTheme.foldText)
        {
            drawLine(fitted, at: CGPoint(x: layout.countX, y: baseline), context: context)
        }
        guard let presentation = scopeLabelPresentation(for: hidden, layout: layout) else { return }
        drawLine(presentation.line, at: CGPoint(x: layout.labelX, y: baseline), context: context)
        if hoveredSeparatorRow == index {
            drawScopeCopyIcon(in: presentation.copyRect, copied: copiedScopeRange == hidden)
        }
    }

    // MARK: - Scope label

    /// The scope label as drawn and where its copy icon goes. Drawing, clicks and
    /// accessibility all lay it out through here, so the icon is hit where it is drawn.
    struct ScopeLabelPresentation {
        let line: CTLine
        /// What the copy icon copies, even when the parent is shown too.
        let innermostName: String
        let copyRect: NSRect
    }

    private static let scopeCopyImage = scopeSymbol("doc.on.doc")
    private static let scopeCopiedImage = scopeSymbol("checkmark")

    private static func scopeSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [DiffTheme.foldText])))
    }

    func scopeLabelPresentation(for hidden: Range<Int>, layout: SeparatorLayout) -> ScopeLabelPresentation? {
        guard let outline, let names = model?.scopeAnchor(after: hidden)?.names(in: outline) else { return nil }
        return Self.scopeLabelPresentation(names: names, layout: layout, font: font)
    }

    /// `Parent › name` for the next change's scope. When it does not fit, only the innermost
    /// name is shown, cut at the tail so its start stays readable. Nil, so neither label nor
    /// icon is drawn, when the icon would not fit after it.
    static func scopeLabelPresentation(
        names: [String], layout: SeparatorLayout, font: NSFont
    ) -> ScopeLabelPresentation? {
        guard let innermostName = names.last, layout.availableLabelTextWidth > 0 else { return nil }
        let nameAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: DiffTheme.foldScope]
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
        func width(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }
        // Measure shaped text so wide glyphs fit correctly.
        let chain = CTLineCreateWithAttributedString(label(names))
        let shaped =
            width(chain) <= layout.availableLabelTextWidth
            ? chain : CTLineCreateWithAttributedString(label([innermostName]))
        guard
            let line = truncated(
                shaped, truncation: .end, availableWidth: layout.availableLabelTextWidth,
                color: DiffTheme.foldScope, font: font),
            let copyRect = layout.copyRect(drawnLabelWidth: width(line))
        else { return nil }
        return ScopeLabelPresentation(line: line, innermostName: innermostName, copyRect: copyRect)
    }

    private func drawScopeCopyIcon(in rect: NSRect, copied: Bool) {
        if isPointerOnScopeCopy {
            DiffTheme.foldControl.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
        guard let image = copied ? Self.scopeCopiedImage : Self.scopeCopyImage else { return }
        let size = image.size
        let imageRect = NSRect(
            x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Copies the innermost scope name of the separator hiding `hidden`; the pointer and
    /// VoiceOver both come here. A press from another document, or for a separator no
    /// longer shown, copies nothing.
    func copyScopeName(hidden: Range<Int>, generation: Int) {
        guard generation == documentGeneration, displayRows.contains(.separator(hidden: hidden)), let outline,
            let name = model?.scopeAnchor(after: hidden)?.names(in: outline).last
        else { return }
        PickerCopyButton.copyToPasteboard(name)
        copyFeedbackTimer?.invalidate()
        copiedScopeRange = hidden
        let feedbackDuration: TimeInterval = 1.2
        copyFeedbackTimer = Timer.scheduledTimer(withTimeInterval: feedbackDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.copiedScopeRange = nil }
        }
    }

    private func drawChevrons(for control: FoldControl, in rect: NSRect, context: CGContext) {
        let chevrons: [(pointingUp: Bool, center: CGPoint)]
        switch control {
        case .expandUp:
            chevrons = [(true, CGPoint(x: rect.midX, y: rect.midY))]
        case .expandDown:
            chevrons = [(false, CGPoint(x: rect.midX, y: rect.midY))]
        case .expandRun:
            chevrons = [
                (true, CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.2)),
                (false, CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.2)),
            ]
        }
        strokeChevrons(
            chevrons, halfWidth: rect.width * 0.25, height: rect.height * 0.2, color: DiffTheme.foldText,
            context: context)
    }

    /// Strokes all chevrons as one path. The view is flipped, so a chevron pointing up has
    /// its apex at the smaller y.
    func strokeChevrons(
        _ chevrons: [(pointingUp: Bool, center: CGPoint)], halfWidth: CGFloat, height: CGFloat, color: NSColor,
        context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for (pointingUp, center) in chevrons {
            let apexY = pointingUp ? center.y - height / 2 : center.y + height / 2
            let baseY = pointingUp ? center.y + height / 2 : center.y - height / 2
            context.move(to: CGPoint(x: center.x - halfWidth, y: baseY))
            context.addLine(to: CGPoint(x: center.x, y: apexY))
            context.addLine(to: CGPoint(x: center.x + halfWidth, y: baseY))
        }
        context.strokePath()
        context.restoreGState()
    }
}
