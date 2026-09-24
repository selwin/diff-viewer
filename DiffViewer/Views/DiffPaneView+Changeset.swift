import AppKit
import CoreText

/// Drawing for the rows a changeset adds to a document: the header band that names each
/// file, the gap between two files, and the one-line notice a file with no rows shows.
/// Like the gutter, every piece is placed from `rowRect.minX` (the visible left edge), so
/// it stays put while the pane scrolls horizontally.
extension DiffPaneView {

    // MARK: - File header

    /// The same layout as `FileHeaderView`, split across the two panes: the old pane
    /// names the file, the new pane carries the trailing rail with the directory and the
    /// churn. In the rail the counts are right-aligned and the directory is truncated into
    /// the remaining space.
    func drawFileHeader(section index: Int, in rowRect: NSRect, model: PaneModel, context: CGContext) {
        guard model.sections.indices.contains(index) else { return }
        let section = model.sections[index]
        let fullRect = fullWidthRect(rowRect)
        DiffTheme.headerBackground.setFill()
        context.fill(fullRect)
        DiffTheme.divider.setFill()
        context.fill(NSRect(x: fullRect.minX, y: fullRect.minY, width: fullRect.width, height: 1))

        let lines = headerLines(section: index, model: model)
        let baseline = rowRect.minY + 2 + ascent
        switch model.side {
        case .old:
            let badgeSize = rowRect.height - 6
            let badgeRect = NSRect(
                x: rowRect.minX + textInset, y: rowRect.minY + 3, width: badgeSize, height: badgeSize)
            drawBadge(section.file.kind, in: badgeRect, context: context)
            let textX = badgeRect.maxX + 6
            if let name = lines.name,
                let line = truncated(
                    name, truncation: .end, availableWidth: rowRect.maxX - textInset - textX,
                    color: DiffTheme.headerText)
            {
                drawLine(line, at: CGPoint(x: textX, y: baseline), context: context)
            }
        case .new:
            drawRail(lines, in: rowRect, baseline: baseline, context: context)
        }
    }

    /// Churn first, right-aligned against the edge; then, when both are present and at
    /// least 40 pt remain, a divider and the directory right-aligned in the rest. With no
    /// churn the directory takes the whole rail. Under 40 pt the directory and its divider
    /// are both skipped, never an orphan divider.
    private func drawRail(_ lines: HeaderLines, in rowRect: NSRect, baseline: CGFloat, context: CGContext) {
        var x = rowRect.maxX - textInset
        if let churn = lines.churn {
            x -= CGFloat(CTLineGetTypographicBounds(churn, nil, nil, nil))
            drawLine(churn, at: CGPoint(x: x, y: baseline), context: context)
        }
        guard let directory = lines.directory else { return }
        let dividerSpace: CGFloat = lines.churn == nil ? 0 : 8 + 1 + 8
        let availableWidth = x - dividerSpace - (rowRect.minX + textInset)
        guard availableWidth >= 40,
            let line = truncated(
                directory, truncation: .middle, availableWidth: availableWidth, color: DiffTheme.headerSecondary)
        else { return }
        if lines.churn != nil {
            DiffTheme.divider.setFill()
            context.fill(NSRect(x: x - 8 - 1, y: rowRect.midY - 7, width: 1, height: 14))
            x -= dividerSpace
        }
        x -= CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        drawLine(line, at: CGPoint(x: x, y: baseline), context: context)
    }

    /// Shortened with an ellipsis when it would not fit in `availableWidth`; nil when
    /// there is no room at all. Done at draw time, not in the cache, because it depends
    /// on the pane's current width. `color` is the ellipsis colour, which should match
    /// the text it stands in for.
    private func truncated(
        _ line: CTLine, truncation: CTLineTruncationType, availableWidth: CGFloat, color: NSColor
    ) -> CTLine? {
        guard availableWidth > 0 else { return nil }
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > Double(availableWidth) else { return line }
        // Without a token Core Text cuts the line off silently, and a clipped path or error
        // would read as complete. When even the token does not fit, show the token alone
        // rather than the overflowing line.
        let token = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\u{2026}", attributes: [.font: font, .foregroundColor: color]))
        return CTLineCreateTruncatedLine(line, Double(availableWidth), truncation, token) ?? token
    }

    /// A rounded square in the kind's colour with its letter, the same mapping the
    /// sidebar uses.
    private func drawBadge(_ kind: ChangedFile.Kind, in rect: NSRect, context: CGContext) {
        DiffTheme.badge(for: kind).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        let badgeFont = NSFont.monospacedSystemFont(ofSize: max(fontSize - 1, 8), weight: .bold)
        let attributed = NSAttributedString(
            string: String(kind.rawValue), attributes: [.font: badgeFont, .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        // The view is flipped, so the baseline sits below the centre by half the cap height.
        drawLine(
            line, at: CGPoint(x: rect.midX - width / 2, y: rect.midY + badgeFont.capHeight / 2), context: context)
    }

    /// The band's text for a section, shaped once. Only the lines this side draws are
    /// shaped. Only the section's own counts reach the pane, so the cache stays valid for
    /// the document's lifetime.
    private func headerLines(section index: Int, model: PaneModel) -> HeaderLines {
        if let cached = headerCache[index] { return cached }
        let section = model.sections[index]
        let lines: HeaderLines
        switch model.side {
        case .old:
            lines = HeaderLines(
                name: CTLineCreateWithAttributedString(nameText(for: section.file)), directory: nil, churn: nil)
        case .new:
            let directory = section.file.directory
            lines = HeaderLines(
                name: nil,
                directory: directory.isEmpty ? nil : CTLineCreateWithAttributedString(secondaryText(directory)),
                churn: churnText(for: section).map(CTLineCreateWithAttributedString))
        }
        headerCache[index] = lines
        return lines
    }

    /// The file name in semibold, then where a rename came from.
    private func nameText(for file: ChangedFile) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: file.fileName,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: DiffTheme.headerText,
            ])
        if let original = file.originalPath {
            text.append(secondaryText("  ← \(original)"))
        }
        return text
    }

    private func secondaryText(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: DiffTheme.headerSecondary])
    }

    /// "+12 −3" from the counts captured when the section was built; a side that did not
    /// change is left out, matching `ChurnLabel`, and no churn at all is nil. Deliberately
    /// a snapshot: the sticky header above the panes reads current, fingerprint-checked
    /// stats (`ChangesetChurn.stats`), so for a non-text section the two can differ. Live
    /// stats in the band would need their own update path into the panes.
    private func churnText(for section: ChangesetSection) -> NSAttributedString? {
        let text = NSMutableAttributedString()
        func append(_ string: String, color: NSColor) {
            if text.length > 0 { text.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        if section.added > 0 { append("+\(section.added)", color: DiffTheme.addedCount) }
        if section.deleted > 0 { append("−\(section.deleted)", color: DiffTheme.deletedCount) }
        return text.length > 0 ? text : nil
    }

    // MARK: - Spacer and notice

    /// The gap before a file header. Nothing but the pane background, so the break
    /// between two files reads as empty space.
    func drawSpacer(in rowRect: NSRect, context: CGContext) {
        DiffTheme.background.setFill()
        context.fill(fullWidthRect(rowRect))
    }

    /// The single line a file with no rows shows instead of a diff.
    func drawNotice(section index: Int, in rowRect: NSRect, model: PaneModel, context: CGContext) {
        guard model.sections.indices.contains(index) else { return }
        DiffTheme.background.setFill()
        context.fill(fullWidthRect(rowRect))
        fillGutter(rowRect, color: nil, context: context)

        let attributed = NSAttributedString(
            string: Self.noticeText(for: model.sections[index].outcome, kind: model.sections[index].file.kind),
            attributes: [.font: font, .foregroundColor: DiffTheme.noticeText])
        let textX = rowRect.minX + gutterWidth + textInset
        guard
            let line = truncated(
                CTLineCreateWithAttributedString(attributed), truncation: .end,
                availableWidth: rowRect.maxX - textInset - textX, color: DiffTheme.noticeText)
        else { return }
        drawLine(line, at: CGPoint(x: textX, y: rowRect.minY + 2 + ascent), context: context)
    }

    /// Precondition: a `.text` section has rows and so never produces a notice row.
    static func noticeText(for outcome: FileOutcome, kind: ChangedFile.Kind) -> String {
        switch outcome {
        case .text: preconditionFailure("a .text section is drawn as rows, not as a notice")
        case .noVisibleChanges: "No visible differences"
        case .binary: "Binary file"
        case .identical: kind == .renamed ? "Renamed without changes" : "No differences"
        case .tooLarge: "Too large to show here"
        case .notShown: "Not shown here, select it in the sidebar"
        case let .failed(message): message
        }
    }
}
