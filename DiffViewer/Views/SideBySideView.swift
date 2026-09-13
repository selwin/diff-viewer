import AppKit
import SwiftUI

/// Two diff panes with a shared vertical scroll position and independent
/// horizontal scrolling. Owns the per-file folding state; the panes and the
/// overview strip always see the same projection.
final class SideBySideContainerView: NSView {
    let leftPane = DiffPaneView(frame: .zero)
    let rightPane = DiffPaneView(frame: .zero)
    let overview = ChangeOverviewView(frame: .zero)
    private let leftScroll = NSScrollView()
    private let rightScroll = NSScrollView()
    private let divider = NSView()
    private var isSyncing = false

    private var document: DiffDocument?
    private var foldState = FoldState()
    private(set) var folded = FoldedRows.identity(documentRowCount: 0)
    private(set) var collapseUnchanged = true

    var foldOptions = FoldOptions() {
        didSet { leftPane.foldOptions = foldOptions; rightPane.foldOptions = foldOptions }
    }

    /// A visible document row and its pixel offset from the top of the viewport, used
    /// to keep the reader's place when the projection or row height changes.
    private struct Anchor {
        let documentRow: Int
        let offset: CGFloat
    }

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
            pane.onFoldAction = { [weak self] action in self?.handle(action) }
            addSubview(scroll)
        }
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DiffTheme.divider.cgColor
        addSubview(divider)
        addSubview(overview)
        overview.onSelectRow = { [weak self] row in self?.scroll(toRow: row) }

        // Selector-based observers are removed automatically when the view is deallocated.
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification,
            object: leftScroll.contentView)
        center.addObserver(
            self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification,
            object: rightScroll.contentView)
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

    // MARK: - Inputs

    /// Installs a document. When the same file is recomputed with identical rows
    /// (e.g. a refresh that changed nothing), expansions are kept; otherwise they
    /// reset. The viewport is re-anchored on the new-side source line that was at
    /// the top, so an edit elsewhere in the file does not move the reader.
    func setDocument(_ document: DiffDocument?, fontSize: CGFloat) {
        let previousAnchor = captureAnchor()
        let previousDocument = self.document
        let sameRows = previousDocument.map { $0.rows == document?.rows } ?? false
        if !sameRows { foldState = FoldState() }
        self.document = document

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

        var anchor: Anchor?
        if let previousAnchor, let previousDocument, let document {
            anchor = Self.translate(previousAnchor, from: previousDocument, to: document)
        }
        refold(anchor: anchor)
    }

    /// Changes the row height without touching fold state; keeps the top row in place.
    func setFontSize(_ fontSize: CGFloat) {
        guard rightPane.fontSize != fontSize else { return }
        let anchor = captureAnchor()
        leftPane.fontSize = fontSize
        rightPane.fontSize = fontSize
        restoreScroll(anchor)
    }

    func setCollapseUnchanged(_ collapse: Bool) {
        guard collapse != collapseUnchanged else { return }
        let anchor = captureAnchor()
        collapseUnchanged = collapse
        refold(anchor: anchor)
    }

    var currentBlock: Int? {
        didSet {
            overview.currentBlock = currentBlock
            applyCurrentBlock()
        }
    }

    private func handle(_ action: FoldAction) {
        guard let document else { return }
        let step = foldOptions.expansionStep
        switch action {
        case let .expandUp(hidden): foldState.expandUp(hidden, step: step)
        case let .expandDown(hidden): foldState.expandDown(hidden, step: step)
        case let .expandRun(hidden): foldState.expandRun(hidden)
        case .expandAll: foldState.expandAll(documentRowCount: document.rows.count)
        }
        refold(anchor: captureAnchor())
    }

    // MARK: - Projection

    private func refold(anchor: Anchor?) {
        if let document, collapseUnchanged {
            folded = RowFolding.fold(
                changeBlocks: document.changeBlocks, documentRowCount: document.rows.count, state: foldState,
                options: foldOptions)
        } else {
            folded = .identity(documentRowCount: document?.rows.count ?? 0)
        }
        leftPane.displayRows = folded.displayRows
        rightPane.displayRows = folded.displayRows
        applyCurrentBlock()
        restoreScroll(anchor)
    }

    private func applyCurrentBlock() {
        let range = currentBlock.flatMap { index -> Range<Int>? in
            guard overview.changeBlocks.indices.contains(index) else { return nil }
            return folded.displayRange(forDocumentRange: overview.changeBlocks[index])
        }
        leftPane.currentChangeRows = range
        rightPane.currentChangeRows = range
    }

    // MARK: - Scrolling

    private func captureAnchor() -> Anchor? {
        let range = visibleDisplayRange
        guard !range.isEmpty else { return nil }
        let top = range.lowerBound
        let offset = rightScroll.contentView.bounds.minY - rightPane.layout.y(forRow: top)
        return Anchor(documentRow: folded.documentRow(forDisplayIndex: top), offset: offset)
    }

    /// Maps an anchor across documents by source line: the new-side line at the top
    /// (old-side for a deleted row) is looked up in the new rows, or the next one after it.
    private static func translate(_ anchor: Anchor, from previous: DiffDocument, to next: DiffDocument) -> Anchor? {
        guard previous.rows.indices.contains(anchor.documentRow), !next.rows.isEmpty else { return nil }
        let row = previous.rows[anchor.documentRow]
        let target: Int
        if let new = row.new {
            target = next.rows.firstIndex { ($0.new?.lineIndex ?? -1) >= new.lineIndex } ?? next.rows.count - 1
        } else if let old = row.old {
            target = next.rows.firstIndex { ($0.old?.lineIndex ?? -1) >= old.lineIndex } ?? next.rows.count - 1
        } else {
            return nil
        }
        return Anchor(documentRow: target, offset: anchor.offset)
    }

    /// Re-lays out the panes for the current projection and scrolls so the anchor's
    /// document row sits where it was. The container's `layout()` is what resizes the
    /// pane frames, so it must run before clamping.
    private func restoreScroll(_ anchor: Anchor?) {
        needsLayout = true
        layoutSubtreeIfNeeded()
        let maxY = max(0, rightPane.frame.height - rightScroll.contentView.bounds.height)
        var y: CGFloat = 0
        if let anchor, anchor.documentRow < folded.documentRowCount {
            y = rightPane.layout.y(forRow: folded.displayIndex(forDocumentRow: anchor.documentRow)) + anchor.offset
        }
        y = min(max(0, y), maxY)
        for scroll in [leftScroll, rightScroll] {
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        updateOverviewViewport()
    }

    private func updateOverviewViewport() {
        overview.visibleRows = folded.documentRange(forDisplayRange: visibleDisplayRange)
    }

    /// Scrolls both panes so document `row` (or the separator hiding it) sits about a
    /// third of the way down the viewport.
    func scroll(toRow row: Int) {
        guard row >= 0, row < folded.documentRowCount else { return }
        let layout = rightPane.layout
        let display = folded.displayIndex(forDocumentRow: row)
        let target = max(0, layout.y(forRow: display) - rightScroll.contentView.bounds.height / 3)
        let maxY = max(0, rightPane.frame.height - rightScroll.contentView.bounds.height)
        let y = min(target, maxY)
        rightScroll.contentView.scroll(to: NSPoint(x: rightScroll.contentView.bounds.origin.x, y: y))
        rightScroll.reflectScrolledClipView(rightScroll.contentView)
    }

    var visibleDisplayRange: Range<Int> {
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
        // The overview reads the right pane, so update it after the sync either way.
        defer { isSyncing = false; updateOverviewViewport() }
        let y = source.contentView.bounds.origin.y
        var origin = target.contentView.bounds.origin
        guard abs(origin.y - y) > 0.5 else { return }
        origin.y = y
        target.contentView.scroll(to: origin)
        target.reflectScrolledClipView(target.contentView)
    }
}

/// SwiftUI wrapper. One instance lives per selected file, so any document update
/// is a recomputation of the same file and keeps the reader's place.
struct SideBySideView: NSViewRepresentable {
    let document: DiffDocument
    var styles: DocumentStyles?
    var fontSize: CGFloat = 12
    var scrollTarget: ScrollTarget?
    var currentBlock: Int?
    var collapseUnchanged = true
    var foldOptions = FoldOptions()

    func makeNSView(context: Context) -> SideBySideContainerView {
        let view = SideBySideContainerView(frame: .zero)
        view.foldOptions = foldOptions
        view.setCollapseUnchanged(collapseUnchanged)
        view.setDocument(document, fontSize: fontSize)
        context.coordinator.documentID = document.id
        applyStylesIfNeeded(to: view, coordinator: context.coordinator)
        applyScrollTargetIfNeeded(to: view, coordinator: context.coordinator)
        view.currentBlock = currentBlock
        return view
    }

    func updateNSView(_ view: SideBySideContainerView, context: Context) {
        if context.coordinator.documentID != document.id {
            view.setDocument(document, fontSize: fontSize)
            context.coordinator.documentID = document.id
            context.coordinator.stylesApplied = false
        } else {
            view.setFontSize(fontSize)
        }
        view.setCollapseUnchanged(collapseUnchanged)
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
        view.leftPane.styles = styles.old
        view.rightPane.styles = styles.new
        coordinator.stylesApplied = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var documentID: UUID?
        var stylesApplied = false
        var scrollTargetID: UUID?
    }
}
