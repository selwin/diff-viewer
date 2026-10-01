import AppKit

/// VoiceOver buttons for the controls the pane draws itself.
extension DiffPaneView {
    /// Buttons for the visible fold controls, scope copy icons and move markers, so VoiceOver can use them.
    override func accessibilityChildren() -> [Any]? {
        foldControlElements() + scopeCopyElements() + moveMarkerElements()
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

    /// The generation is captured so a press after the document changed copies nothing.
    private func scopeCopyElements() -> [NSAccessibilityElement] {
        let generation = documentGeneration
        var elements: [NSAccessibilityElement] = []
        for index in layout.rows(intersecting: visibleRect.minY, visibleRect.maxY) where index < displayRows.count {
            guard case let .separator(hidden) = displayRows[index],
                let presentation = scopeLabelPresentation(
                    for: hidden, layout: separatorLayout(for: hidden, rowRect: rowRect(at: index)).layout)
            else { continue }
            elements.append(
                ButtonElement(
                    parent: self, frame: presentation.copyRect,
                    label: "Copy scope name \(presentation.innermostName)",
                    onPress: { [weak self] in self?.copyScopeName(hidden: hidden, generation: generation) }))
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
