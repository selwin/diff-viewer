import AppKit
import SwiftUI

/// The find bar's side scope: one segment per side, each reading `name  count`. A native
/// segmented control, so it looks and behaves like the system's.
struct FindScopeControl: NSViewRepresentable {
    let labels: FindSideLabels
    let side: DocumentSide
    let oldCount: Int?
    let newCount: Int?
    let hasQuery: Bool
    let onSelect: (DocumentSide) -> Void
    /// The widest a segment may grow before its name is shortened.
    var maximumSegmentWidth: CGFloat = 180

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(frame: .zero)
        control.segmentCount = 2
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.font = Self.font
        control.target = context.coordinator
        control.action = #selector(Coordinator.segmentChanged(_:))
        control.cell?.setAccessibilityLabel("Search in")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.onSelect = onSelect
        for (segment, documentSide) in [DocumentSide.old, .new].enumerated() {
            let label = labels.label(for: documentSide)
            let text = FindScopeSegmentText(
                name: label.title, count: documentSide == .old ? oldCount : newCount, hasQuery: hasQuery)
            control.setImage(label.icon?.templateImage, forSegment: segment)
            control.setLabel(
                Self.visibleLabel(text, icon: label.icon, maximumWidth: maximumSegmentWidth), forSegment: segment)
            control.setToolTip(text.toolTip, forSegment: segment)
        }
        control.selectedSegment = side == .old ? 0 : 1
        applyAccessibilityLabels(to: control)
        control.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject {
        var onSelect: (DocumentSide) -> Void

        init(onSelect: @escaping (DocumentSide) -> Void) { self.onSelect = onSelect }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            onSelect(sender.selectedSegment == 0 ? .old : .new)
        }
    }

    /// The segments have no public accessibility hook, but the cell's segment elements keep a
    /// label set on them, so VoiceOver reads the full name and count even when the face is cut.
    private func applyAccessibilityLabels(to control: NSSegmentedControl) {
        let elements = (control.cell?.accessibilityChildren() ?? []).compactMap {
            ($0 as AnyObject) as? NSAccessibilityProtocol
        }
        for (element, documentSide) in zip(elements, [DocumentSide.old, .new]) {
            let text = FindScopeSegmentText(
                name: labels.label(for: documentSide).title, count: documentSide == .old ? oldCount : newCount,
                hasQuery: hasQuery)
            element.setAccessibilityLabel(text.accessibilityLabel)
        }
    }

    // MARK: - Faces

    /// The name is shortened in the middle so the whole segment fits; the count never is.
    private static func visibleLabel(
        _ text: FindScopeSegmentText, icon: FindSideLabel.Icon?, maximumWidth: CGFloat
    ) -> String {
        let suffix = text.countText.map { "  " + $0 } ?? ""
        let available = maximumWidth - chromeWidth(for: icon) - width(of: suffix, font: font)
        return truncatingMiddle(text.name, toFit: available, font: font) + suffix
    }

    private static var chromeWidths: [FindSideLabel.Icon?: CGFloat] = [:]

    /// Everything a segment adds around its label text: the image, its gap, and the padding.
    /// Measured once per icon on a real control with the same image and font, so it tracks
    /// the system's metrics. A lone segment carries both outer edges, erring on the safe side.
    private static func chromeWidth(for icon: FindSideLabel.Icon?) -> CGFloat {
        if let cached = chromeWidths[icon] { return cached }
        let probe = NSSegmentedControl(frame: .zero)
        probe.segmentCount = 1
        probe.segmentStyle = .rounded
        probe.controlSize = .small
        probe.font = font
        probe.setImage(icon?.templateImage, forSegment: 0)
        probe.setLabel("x", forSegment: 0)
        probe.sizeToFit()
        let chrome = ceil(probe.frame.width - width(of: "x", font: font))
        chromeWidths[icon] = chrome
        return chrome
    }

    private static func width(of string: String, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: string, attributes: [.font: font]).size().width)
    }

    /// `name` shortened with a middle "…" to the longest head and tail that fit `width`.
    /// Both ends carry meaning in a ref name (prefix and ticket number), so both are kept.
    nonisolated static func truncatingMiddle(_ name: String, toFit width: CGFloat, font: NSFont) -> String {
        func fits(_ string: String) -> Bool {
            NSAttributedString(string: string, attributes: [.font: font]).size().width <= width
        }
        guard !fits(name) else { return name }
        let characters = Array(name)
        func shortened(keeping count: Int) -> String {
            let head = (count + 1) / 2
            return String(characters[..<head]) + "…" + String(characters[(characters.count - (count - head))...])
        }
        // The widest kept count that fits; widths grow with the count, so bisect.
        var low = 0
        var high = characters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(shortened(keeping: mid)) { low = mid } else { high = mid - 1 }
        }
        return shortened(keeping: low)
    }
}

extension FindSideLabel.Icon {
    /// 12pt, matching the toolbar's glyphs. Built once, since the control is updated as counts arrive.
    @MainActor var templateImage: NSImage? {
        switch self {
        case .branch: Self.branchImage
        case .commit: Self.commitImage
        case .workingTree: Self.workingTreeImage
        }
    }

    @MainActor private static let branchImage = Self.branch.makeTemplateImage()
    @MainActor private static let commitImage = Self.commit.makeTemplateImage()
    @MainActor private static let workingTreeImage = Self.workingTree.makeTemplateImage()

    /// Working Tree has no toolbar glyph, so it takes a system folder.
    private func makeTemplateImage() -> NSImage? {
        let image: NSImage?
        switch self {
        case .branch: image = NSImage(resource: .gitBranch).copy() as? NSImage
        case .commit: image = NSImage(resource: .gitCommit).copy() as? NSImage
        case .workingTree:
            return NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
        }
        image?.size = NSSize(width: 12, height: 12)
        image?.isTemplate = true
        return image
    }
}

/// One segment's words apart from truncation, which needs a font.
struct FindScopeSegmentText: Equatable {
    let name: String
    /// Nil hides the count: there is no query. A dash stands in until the first result.
    let countText: String?
    let toolTip: String
    let accessibilityLabel: String

    init(name: String, count: Int?, hasQuery: Bool) {
        self.name = name
        guard hasQuery else {
            countText = nil
            toolTip = name
            accessibilityLabel = name
            return
        }
        countText = count.map(String.init) ?? "–"
        guard let count else {
            toolTip = name
            accessibilityLabel = name
            return
        }
        let matches = count == 1 ? "1 match" : "\(count) matches"
        toolTip = "\(name) · \(matches)"
        accessibilityLabel = "\(name), \(matches)"
    }
}
