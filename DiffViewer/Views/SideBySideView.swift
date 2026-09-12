import AppKit
import SwiftUI

/// Two diff panes with a shared vertical scroll position and independent
/// horizontal scrolling.
final class SideBySideContainerView: NSView {
    let leftPane = DiffPaneView(frame: .zero)
    let rightPane = DiffPaneView(frame: .zero)
    let overview = ChangeOverviewView(frame: .zero)
    private let leftScroll = NSScrollView()
    private let rightScroll = NSScrollView()
    private let divider = NSView()
    private var isSyncing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (scroll, pane, showsVertical) in [(leftScroll, leftPane, false), (rightScroll, rightPane, true)] {
            scroll.documentView = pane
            scroll.hasVerticalScroller = showsVertical
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = true
            scroll.backgroundColor = DiffTheme.background
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.copiesOnScroll = false
            scroll.verticalScrollElasticity = .allowed
            scroll.horizontalScrollElasticity = .none
            scroll.contentView.drawsBackground = false
            addSubview(scroll)
        }
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DiffTheme.divider.cgColor
        addSubview(divider)
        addSubview(overview)
        overview.onSelectRow = { [weak self] row in self?.scroll(toRow: row) }

        // Selector-based observers are removed automatically when the view is deallocated.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: leftScroll.contentView)
        center.addObserver(self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: rightScroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clipBoundsChanged(_ note: Notification) {
        if (note.object as AnyObject?) === leftScroll.contentView {
            sync(from: leftScroll, to: rightScroll)
        } else {
            sync(from: rightScroll, to: leftScroll)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        divider.layer?.backgroundColor = DiffTheme.divider.cgColor
    }

    /// Installs a document. With `preserveScroll`, the current vertical offset is kept
    /// (used when the same file is recomputed, e.g. after a whitespace toggle or edit).
    func setDocument(_ document: DiffDocument?, fontSize: CGFloat, preserveScroll: Bool = false) {
        let previousY = rightScroll.contentView.bounds.origin.y
        leftPane.fontSize = fontSize
        rightPane.fontSize = fontSize
        if let document {
            leftPane.model = PaneModel(side: .old, rows: document.rows, lines: document.oldLines)
            rightPane.model = PaneModel(side: .new, rows: document.rows, lines: document.newLines)
            overview.rows = document.rows
            overview.changeBlocks = document.changeBlocks
        } else {
            leftPane.model = nil
            rightPane.model = nil
            overview.rows = []
            overview.changeBlocks = []
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        let maxY = max(0, rightPane.frame.height - rightScroll.contentView.bounds.height)
        let y = preserveScroll ? min(previousY, maxY) : 0
        for scroll in [leftScroll, rightScroll] {
            scroll.contentView.scroll(to: NSPoint(x: preserveScroll ? scroll.contentView.bounds.origin.x : 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        updateOverviewViewport()
    }

    var currentBlock: Int? {
        get { overview.currentBlock }
        set {
            overview.currentBlock = newValue
            let range = newValue.flatMap { overview.changeBlocks.indices.contains($0) ? overview.changeBlocks[$0] : nil }
            leftPane.currentChangeRows = range
            rightPane.currentChangeRows = range
        }
    }

    private func updateOverviewViewport() {
        overview.visibleRows = visibleRowRange
    }

    /// Scrolls both panes so `row` sits about a third of the way down the viewport.
    func scroll(toRow row: Int) {
        let layout = rightPane.layout
        let target = max(0, layout.y(forRow: row) - rightScroll.contentView.bounds.height / 3)
        let maxY = max(0, rightPane.frame.height - rightScroll.contentView.bounds.height)
        let y = min(target, maxY)
        rightScroll.contentView.scroll(to: NSPoint(x: rightScroll.contentView.bounds.origin.x, y: y))
        rightScroll.reflectScrolledClipView(rightScroll.contentView)
    }

    var visibleRowRange: Range<Int> {
        let clip = rightScroll.contentView.bounds
        return rightPane.layout.rows(intersecting: clip.minY, clip.maxY)
    }

    override func layout() {
        super.layout()
        let overviewWidth = ChangeOverviewView.width
        let width = bounds.width - overviewWidth
        let leftWidth = floor((width - 1) / 2)
        leftScroll.frame = NSRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
        divider.frame = NSRect(x: leftWidth, y: 0, width: 1, height: bounds.height)
        rightScroll.frame = NSRect(x: leftWidth + 1, y: 0, width: width - leftWidth - 1, height: bounds.height)
        overview.frame = NSRect(x: bounds.width - overviewWidth, y: 0, width: overviewWidth, height: bounds.height)
        for (scroll, pane) in [(leftScroll, leftPane), (rightScroll, rightPane)] {
            let clip = scroll.contentView.bounds.size
            let size = pane.desiredSize(clipWidth: clip.width, clipHeight: clip.height)
            if pane.frame.size != size { pane.setFrameSize(size) }
        }
    }

    private func sync(from source: NSScrollView?, to target: NSScrollView?) {
        guard !isSyncing, let source, let target else { return }
        isSyncing = true
        defer { isSyncing = false }
        updateOverviewViewport()
        let y = source.contentView.bounds.origin.y
        var origin = target.contentView.bounds.origin
        guard abs(origin.y - y) > 0.5 else { return }
        origin.y = y
        target.contentView.scroll(to: origin)
        target.reflectScrolledClipView(target.contentView)
    }
}

/// SwiftUI wrapper. One instance lives per selected file, so any document update
/// is a recomputation of the same file and keeps the scroll position.
struct SideBySideView: NSViewRepresentable {
    let document: DiffDocument
    var styles: DocumentStyles?
    var fontSize: CGFloat = 12
    var scrollTarget: ScrollTarget?
    var currentBlock: Int?

    func makeNSView(context: Context) -> SideBySideContainerView {
        let view = SideBySideContainerView(frame: .zero)
        view.setDocument(document, fontSize: fontSize)
        context.coordinator.documentID = document.id
        applyStylesIfNeeded(to: view, coordinator: context.coordinator)
        applyScrollTargetIfNeeded(to: view, coordinator: context.coordinator)
        view.currentBlock = currentBlock
        return view
    }

    func updateNSView(_ view: SideBySideContainerView, context: Context) {
        if context.coordinator.documentID != document.id || view.rightPane.fontSize != fontSize {
            view.setDocument(document, fontSize: fontSize, preserveScroll: true)
            context.coordinator.documentID = document.id
            context.coordinator.stylesApplied = false
        }
        applyStylesIfNeeded(to: view, coordinator: context.coordinator)
        if view.currentBlock != currentBlock { view.currentBlock = currentBlock }
        applyScrollTargetIfNeeded(to: view, coordinator: context.coordinator)
    }

    private func applyScrollTargetIfNeeded(to view: SideBySideContainerView, coordinator: Coordinator) {
        guard let scrollTarget, coordinator.scrollTargetID != scrollTarget.id else { return }
        coordinator.scrollTargetID = scrollTarget.id
        view.scroll(toRow: scrollTarget.row)
    }

    private func applyStylesIfNeeded(to view: SideBySideContainerView, coordinator: Coordinator) {
        guard !coordinator.stylesApplied, let styles, styles.documentID == document.id else { return }
        view.leftPane.applyStyles(styles.old)
        view.rightPane.applyStyles(styles.new)
        coordinator.stylesApplied = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var documentID: UUID?
        var stylesApplied = false
        var scrollTargetID: UUID?
    }
}
