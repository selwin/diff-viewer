import AppKit
import CoreText

/// Drawing for the rows a changeset adds to a document: the header band that names each
/// file, the gap between two files, and the one-line notice a file with no rows shows.
/// Like the gutter, every piece is placed from `rowRect.minX` (the visible left edge), so
/// it stays put while the pane scrolls horizontally.
extension DiffPaneView {

    // MARK: - File header

    func drawFileHeader(section index: Int, in rowRect: NSRect, model: PaneModel, context: CGContext) {
        guard model.sections.indices.contains(index) else { return }
        let section = model.sections[index]
        let fullRect = fullWidthRect(rowRect)
        DiffTheme.headerBackground.setFill()
        context.fill(fullRect)
        DiffTheme.divider.setFill()
        context.fill(NSRect(x: fullRect.minX, y: fullRect.minY, width: fullRect.width, height: 1))

        var textX = rowRect.minX + textInset
        if model.side == .old {
            let badgeSize = rowRect.height - 6
            let badgeRect = NSRect(x: textX, y: rowRect.minY + 3, width: badgeSize, height: badgeSize)
            drawBadge(section.file.kind, in: badgeRect, context: context)
            textX = badgeRect.maxX + 6
        }
        let line = truncated(
            headerLine(section: index, model: model), from: textX, in: rowRect, color: DiffTheme.headerSecondary)
        drawLine(line, at: CGPoint(x: textX, y: rowRect.minY + 2 + ascent), context: context)
    }

    /// Shortened with an ellipsis when it would run past the right edge of the row. Done
    /// at draw time, not in the cache, because it depends on the pane's current width.
    /// `color` is the ellipsis colour, which should match the text it stands in for.
    private func truncated(_ line: CTLine, from textX: CGFloat, in rowRect: NSRect, color: NSColor) -> CTLine {
        let availableWidth = rowRect.maxX - textX - textInset
        guard availableWidth > 0, CTLineGetTypographicBounds(line, nil, nil, nil) > Double(availableWidth) else {
            return line
        }
        // Without a token Core Text cuts the line off silently, and a clipped path or error
        // would read as complete. When even the token does not fit, show the token alone
        // rather than the overflowing line.
        let token = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\u{2026}", attributes: [.font: font, .foregroundColor: color]))
        return CTLineCreateTruncatedLine(line, Double(availableWidth), .end, token) ?? token
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

    /// The header text for this pane's side, shaped once per section.
    private func headerLine(section index: Int, model: PaneModel) -> CTLine {
        if let cached = headerCache[index] { return cached }
        let section = model.sections[index]
        let attributed = model.side == .old ? oldHeaderText(for: section) : newHeaderText(for: section)
        let line = CTLineCreateWithAttributedString(attributed)
        headerCache[index] = line
        return line
    }

    /// Left pane: what the file is called, where it lives, and where it came from.
    private func oldHeaderText(for section: ChangesetSection) -> NSAttributedString {
        let file = section.file
        let text = NSMutableAttributedString(
            string: file.fileName,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: DiffTheme.headerText,
            ])
        var trailing = ""
        if !file.directory.isEmpty { trailing += "  \(file.directory)" }
        if let original = file.originalPath { trailing += "  ← \(original)" }
        if !trailing.isEmpty {
            text.append(
                NSAttributedString(
                    string: trailing, attributes: [.font: font, .foregroundColor: DiffTheme.headerSecondary]))
        }
        return text
    }

    /// Right pane: the churn, the language, and (outside a commit) which two versions
    /// are being compared.
    private func newHeaderText(for section: ChangesetSection) -> NSAttributedString {
        let text = NSMutableAttributedString()
        func append(_ string: String, color: NSColor) {
            if text.length > 0 { text.append(spacer) }
            text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        // A side that did not change is left out, matching the sidebar's ChurnLabel.
        if section.added > 0 { append("+\(section.added)", color: DiffTheme.addedCount) }
        if section.deleted > 0 { append("−\(section.deleted)", color: DiffTheme.deletedCount) }
        if case let .text(language) = section.outcome, let language {
            append(language, color: DiffTheme.headerSecondary)
        }
        if !section.file.area.isCommit {
            append(section.file.area.comparisonLabel, color: DiffTheme.headerSecondary)
        }
        return text
    }

    private var spacer: NSAttributedString {
        NSAttributedString(string: "  ", attributes: [.font: font])
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
            string: Self.noticeText(for: model.sections[index].outcome),
            attributes: [.font: font, .foregroundColor: DiffTheme.noticeText])
        let textX = rowRect.minX + gutterWidth + textInset
        let line = truncated(
            CTLineCreateWithAttributedString(attributed), from: textX, in: rowRect, color: DiffTheme.noticeText)
        drawLine(line, at: CGPoint(x: textX, y: rowRect.minY + 2 + ascent), context: context)
    }

    /// Precondition: a `.text` section has rows and so never produces a notice row.
    static func noticeText(for outcome: FileOutcome) -> String {
        switch outcome {
        case .text: preconditionFailure("a .text section is drawn as rows, not as a notice")
        case .noVisibleChanges: "No visible differences"
        case .binary: "Binary file"
        case .identical: "No differences"
        case .tooLarge: "Too large to show here"
        case .notShown: "Not shown here, select it in the sidebar"
        case let .failed(message): message
        }
    }
}
