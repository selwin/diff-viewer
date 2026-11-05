import AppKit
import CoreText

/// Drawing for the rows a changeset adds to a document: the header band that names each
/// file, the gap between two files, and the one-line notice a file with no rows shows.
/// Like the gutter, every piece is placed from `rowRect.minX` (the visible left edge), so
/// it stays put while the pane scrolls horizontally.
extension DiffPaneView {

    // MARK: - File header

    /// `HeaderStrip`'s padding, so the badge lines up with the file header above the panes.
    private static let fileHeaderInset: CGFloat = 12

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
        let baseline = baselineY(in: rowRect)
        switch model.side {
        case .old:
            let badgeSize = rowRect.height - 6
            let badgeRect = NSRect(
                x: rowRect.minX + Self.fileHeaderInset, y: rowRect.minY + 3, width: badgeSize, height: badgeSize)
            drawBadge(section.file.kind, in: badgeRect, context: context)
            if let name = fileNameLayout(section: index, model: model) {
                drawFileNameSelection(section: index, name: name, in: rowRect, context: context)
                drawLine(name.line, at: CGPoint(x: name.x, y: baseline), context: context)
            }
        case .new:
            drawRail(lines, in: rowRect, baseline: baseline, context: context)
        }
    }

    private func drawFileNameSelection(section: Int, name: FileNameLayout, in rowRect: NSRect, context: CGContext) {
        guard let selection = fileNameSelection, selection.section == section, !selection.isEmpty else { return }
        let length = name.text.utf16.count
        let lower = Self.fileNameX(forOffset: selection.range.lowerBound, line: name.line, length: length)
        let upper = Self.fileNameX(forOffset: selection.range.upperBound, line: name.line, length: length)
        NSColor.selectedTextBackgroundColor.setFill()
        context.fill(
            NSRect(
                x: name.x + min(lower, upper), y: rowRect.minY + 1, width: abs(upper - lower),
                height: rowRect.height - 2))
    }

    /// The name as a band draws it. Drawing and hit testing share this, so the selection
    /// lines up with the glyphs.
    struct FileNameLayout {
        let line: CTLine
        let x: CGFloat
        let text: String
    }

    /// Nil on the new pane or with no room. Every band has the same x extent, so no row is needed.
    func fileNameLayout(section index: Int, model: PaneModel) -> FileNameLayout? {
        guard model.side == .old, model.sections.indices.contains(index) else { return nil }
        let lines = headerLines(section: index, model: model)
        // Past the badge, which is as wide as the row is high less 6 pt, and a 6 pt gap.
        let x = visibleRect.minX + Self.fileHeaderInset + layout.rowHeight
        guard let name = lines.name, let text = lines.nameString,
            let line = truncated(
                name, truncation: .end, availableWidth: visibleRect.maxX - textInset - x, color: DiffTheme.headerText)
        else { return nil }
        return FileNameLayout(line: line, x: x, text: text)
    }

    /// The x of a string offset, from the line's start. Core Text answers 0 both for text the
    /// ellipsis cut off and for a real position at the line's start (the first character of
    /// a right-to-left run can sit there), so only the carets tell them apart. Cut text
    /// takes the x of the string's end, which is the far edge of the ellipsis in either direction.
    static func fileNameX(forOffset offset: Int, line: CTLine, length: Int) -> CGFloat {
        var isDrawn = false
        CTLineEnumerateCaretOffsets(line) { _, index, isLeadingEdge, stop in
            if index == offset, isLeadingEdge {
                isDrawn = true
                stop.pointee = true
            }
        }
        return CGFloat(CTLineGetOffsetForStringIndex(line, isDrawn ? offset : length, nil))
    }

    /// The string offset at `x`, from the line's start. Core Text resolves direction, and maps
    /// the ellipsis and anything past it to the string's end, so a drag there takes the cut text.
    static func fileNameOffset(forX x: CGFloat, line: CTLine, length: Int) -> Int {
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        return min(max(index == kCFNotFound ? 0 : index, 0), length)
    }

    /// The band and name offset under `point`, only over the drawn name itself.
    func fileNameTarget(at point: NSPoint) -> (section: Int, offset: Int)? {
        guard let model, point.y >= 0, point.y < layout.contentHeight else { return nil }
        let index = layout.row(atY: point.y)
        guard index < displayRows.count, case let .fileHeader(section) = displayRows[index],
            let name = fileNameLayout(section: section, model: model)
        else { return nil }
        let x = point.x - name.x
        guard x >= 0, x <= CGFloat(CTLineGetTypographicBounds(name.line, nil, nil, nil)) else { return nil }
        return (section, Self.fileNameOffset(forX: x, line: name.line, length: name.text.utf16.count))
    }

    /// The full text a name selection indexes into.
    func fileNameText(section: Int) -> String? {
        guard let model, model.sections.indices.contains(section) else { return nil }
        return headerLines(section: section, model: model).nameString
    }

    /// The text of the name selection, or nil when there is none.
    func selectedFileNameText() -> String? {
        guard let selection = fileNameSelection, let text = fileNameText(section: selection.section) else { return nil }
        return selection.text(in: text)
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
    func truncated(
        _ line: CTLine, truncation: CTLineTruncationType, availableWidth: CGFloat, color: NSColor
    ) -> CTLine? {
        Self.truncated(line, truncation: truncation, availableWidth: availableWidth, color: color, font: font)
    }

    /// `font` shapes the ellipsis; static so the separator label can be laid out without a view.
    static func truncated(
        _ line: CTLine, truncation: CTLineTruncationType, availableWidth: CGFloat, color: NSColor, font: NSFont
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
            let name = nameText(for: section.file)
            lines = HeaderLines(
                name: CTLineCreateWithAttributedString(name), nameString: name.string, directory: nil, churn: nil)
        case .new:
            let directory = section.file.directory
            lines = HeaderLines(
                name: nil,
                nameString: nil,
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
        let counts = ChurnText.lineCounts(added: section.added, deleted: section.deleted, locale: .current)
        if let added = counts.added { append(added, color: DiffTheme.addedCount) }
        if let deleted = counts.deleted { append(deleted, color: DiffTheme.deletedCount) }
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
        drawLine(line, at: CGPoint(x: textX, y: baselineY(in: rowRect)), context: context)
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
