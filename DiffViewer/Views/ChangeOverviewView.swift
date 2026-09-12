import AppKit

/// A thin strip mapping the whole diff onto the pane height: one mark per change
/// block, the visible viewport, and the current change. Clicking jumps.
final class ChangeOverviewView: NSView {
    var rows: [DiffRow] = [] { didSet { needsDisplay = true } }
    var changeBlocks: [Range<Int>] = [] { didSet { needsDisplay = true } }
    var visibleRows: Range<Int> = 0..<0 { didSet { needsDisplay = true } }
    var currentBlock: Int? { didSet { needsDisplay = true } }
    var onSelectRow: ((Int) -> Void)?

    static let width: CGFloat = 14

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // macOS 14+ no longer clips drawing to bounds by default; the dirty rect can
        // span the whole window, so without this the background fill covers siblings.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        DiffTheme.gutterBackground.setFill()
        bounds.intersection(dirtyRect).fill()
        DiffTheme.divider.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        guard !rows.isEmpty else { return }

        let scale = bounds.height / CGFloat(rows.count)
        for (index, block) in changeBlocks.enumerated() {
            let y = CGFloat(block.lowerBound) * scale
            let height = max(2, CGFloat(block.count) * scale)
            color(for: block).setFill()
            NSRect(x: 3, y: y, width: bounds.width - 6, height: height).fill()
            if index == currentBlock {
                NSColor.controlAccentColor.setStroke()
                let path = NSBezierPath(rect: NSRect(x: 1.5, y: y - 1.5, width: bounds.width - 3, height: height + 3))
                path.lineWidth = 1
                path.stroke()
            }
        }

        if !visibleRows.isEmpty {
            let y = CGFloat(visibleRows.lowerBound) * scale
            let height = max(4, CGFloat(visibleRows.count) * scale)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSRect(x: 1, y: y, width: bounds.width - 1, height: height).fill()
        }
    }

    private func color(for block: Range<Int>) -> NSColor {
        var hasAdded = false
        var hasDeleted = false
        for row in rows[block] {
            switch row.kind {
            case .added: hasAdded = true
            case .deleted: hasDeleted = true
            case .modified: hasAdded = true; hasDeleted = true
            case .equal: break
            }
        }
        switch (hasAdded, hasDeleted) {
        case (true, true): return NSColor.systemOrange
        case (true, false): return NSColor.systemGreen
        case (false, true): return NSColor.systemRed
        default: return NSColor.systemGray
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !rows.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = min(max(Int(point.y / bounds.height * CGFloat(rows.count)), 0), rows.count - 1)
        onSelectRow?(row)
    }
}
