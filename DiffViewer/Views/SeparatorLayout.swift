import Foundation

/// Where a separator row's parts go. The fold controls and the hidden-line count sit at the
/// right end so they never move for the scope label, which takes the space left of them.
/// Drawing and hit testing both use it, so a click lands on the control that is drawn.
struct SeparatorLayout {
    /// Space between two control squares.
    static let controlSpacing: CGFloat = 4
    /// Space between the last control square and the count.
    static let countSpacing: CGFloat = 10

    /// Control squares, left to right.
    let controls: [(control: FoldControl, rect: NSRect)]
    let countX: CGFloat
    /// Room for the count from `countX`; less than its natural width only on a narrow row.
    let countWidth: CGFloat
    /// The scope label starts at `labelX` and may take `labelWidth`; zero or less means no room.
    let labelX: CGFloat
    let labelWidth: CGFloat
    /// The copy icon's square, the same size as a fold control.
    let copyControlSide: CGFloat
    /// Space between the drawn label and the copy icon.
    let copySpacing: CGFloat
    /// Label room minus the copy icon's, reserved even while the icon is hidden so hover never changes truncation.
    let availableLabelTextWidth: CGFloat
    /// Top of the control squares.
    private let controlY: CGFloat

    /// `rowRect` spans the visible width, so the row stays put under horizontal scrolling.
    init(
        rowRect: NSRect, gutterWidth: CGFloat, textInset: CGFloat, charWidth: CGFloat, countWidth: CGFloat,
        controls: [FoldControl]
    ) {
        let side = rowRect.height - 4
        copyControlSide = side
        copySpacing = charWidth
        let controlY = rowRect.minY + 2
        self.controlY = controlY
        let controlsWidth = CGFloat(controls.count) * (side + Self.controlSpacing) - Self.controlSpacing
        let controlsSpan = controls.isEmpty ? 0 : controlsWidth + Self.countSpacing
        labelX = rowRect.minX + gutterWidth + textInset
        let right = rowRect.maxX - textInset
        var x: CGFloat
        var shown = controls
        if labelX + controlsSpan + countWidth <= right {
            countX = right - countWidth
            self.countWidth = countWidth
            x = countX - controlsSpan
            // About two characters of space keep the label from running into the controls.
            labelWidth = x - 2 * charWidth - labelX
        } else {
            // Right-aligned, they would run into the gutter, so start at the text edge and let
            // the count shrink. Controls that leave the count no room are dropped; a click
            // anywhere on the row still expands the whole run.
            if labelX + controlsSpan >= right { shown = [] }
            x = labelX
            countX = labelX + (shown.isEmpty ? 0 : controlsSpan)
            self.countWidth = max(right - countX, 0)
            labelWidth = 0
        }
        availableLabelTextWidth = labelWidth - (copySpacing + copyControlSide)
        self.controls = shown.map { control in
            defer { x += side + Self.controlSpacing }
            return (control, NSRect(x: x, y: controlY, width: side, height: side))
        }
    }

    /// The copy icon right after a label drawn `drawnLabelWidth` wide. Nil when there is no
    /// label room, or when the label overflows it, as a lone ellipsis can.
    func copyRect(drawnLabelWidth: CGFloat) -> NSRect? {
        guard availableLabelTextWidth > 0, drawnLabelWidth <= availableLabelTextWidth else { return nil }
        return NSRect(
            x: labelX + drawnLabelWidth + copySpacing, y: controlY, width: copyControlSide, height: copyControlSide)
    }
}
