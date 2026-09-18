import AppKit
import SwiftUI

/// What the panes show. `.file` folds with user state and the collapse-unchanged
/// preference; `.changeset` is a fixed projection from `ChangesetProjection`:
/// no fold state, no fold actions, no collapse toggle.
enum PaneContent {
    case file(DiffDocument)
    case changeset(ChangesetDocument)

    var document: DiffDocument {
        switch self {
        case let .file(document): document
        case let .changeset(changeset): changeset.document
        }
    }

    /// Nil for a file, which is why a file always installs as a replace.
    var identity: ChangesetIdentity? {
        switch self {
        case .file: nil
        case let .changeset(changeset): changeset.identity
        }
    }

    var changesetDocument: ChangesetDocument? {
        switch self {
        case .file: nil
        case let .changeset(changeset): changeset
        }
    }
}

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
    /// The installed changeset, nil when a single file is installed. Its identity is what
    /// an incoming publication is compared against.
    private var changeset: ChangesetDocument?
    /// The style snapshot already handed to the panes; a snapshot that finished after the
    /// document went out reuses the document's id, so only its own id can dedupe it.
    private var appliedStylesID: UUID?
    private var foldState = FoldState()
    private(set) var folded = FoldedRows.identity(documentRowCount: 0)
    private(set) var collapseUnchanged = true

    var foldOptions = FoldOptions() {
        didSet { leftPane.foldOptions = foldOptions; rightPane.foldOptions = foldOptions }
    }

    /// A visible row and its pixel offset from the top of the viewport, used to keep the
    /// reader's place when the projection or row height changes. A file re-anchors on the
    /// document row; a changeset re-anchors on the display index, because its projection
    /// is append-stable and its synthetic rows have no document row of their own.
    private struct Anchor {
        let documentRow: Int
        let displayIndex: Int
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
        leftPane.onSelectionStart = { [weak self] in self?.rightPane.selection = nil }
        rightPane.onSelectionStart = { [weak self] in self?.leftPane.selection = nil }
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

    /// Installs content. A changeset revision that extends the installed one is appended,
    /// which keeps the selection, the caches and the scroll position; anything else is a
    /// fresh install.
    func setContent(_ content: PaneContent, fontSize: CGFloat) {
        let mode = DocumentUpdate.mode(installed: changeset?.identity, incoming: content.identity)
        // The anchor is read at the old row height, before the font size changes it.
        let fontChanged = rightPane.fontSize != fontSize
        let anchor = captureAnchor()
        leftPane.fontSize = fontSize
        rightPane.fontSize = fontSize
        switch mode {
        case .replace:
            install(content, previousAnchor: anchor)
        case .append:
            append(content)
            // An append keeps the clip origin; only a new row height has to re-anchor.
            if fontChanged { restoreScroll(anchor) }
        }
    }

    /// The ordinary path. When the same file is recomputed with identical rows (e.g. a
    /// refresh that changed nothing), expansions are kept; otherwise they reset. The
    /// viewport is re-anchored on the new-side source line that was at the top, so an
    /// edit elsewhere in the file does not move the reader. A changeset never translates
    /// an anchor: earlier files shift every later row, so the old index means nothing.
    private func install(_ content: PaneContent, previousAnchor: Anchor?) {
        let previousDocument = document
        let previousWasChangeset = changeset != nil
        let incoming = content.document
        let sameRows = previousDocument.map { $0.rows == incoming.rows } ?? false
        if !sameRows { foldState = FoldState() }
        document = incoming
        changeset = content.changesetDocument

        let isChangeset = changeset != nil
        for pane in [leftPane, rightPane] {
            // A changeset's separators are inert: there is no per-file fold state to hold.
            pane.onFoldAction = isChangeset ? nil : { [weak self] action in self?.handle(action) }
        }
        installModels(mode: .replace)
        // Styles are applied separately by `setStyles`; the panes must not keep the
        // previous document's colours until then.
        leftPane.styles = nil
        rightPane.styles = nil
        appliedStylesID = nil
        overview.rows = incoming.rows
        overview.changeBlocks = incoming.changeBlocks

        var anchor: Anchor?
        if let previousAnchor, let previousDocument, !isChangeset, !previousWasChangeset {
            anchor = Self.translate(previousAnchor, from: previousDocument, to: incoming)
        }
        refold(anchor: anchor)
    }

    /// Installs an appended revision without changing the clip origin. Growing a document
    /// view leaves the origin where it is, so the reader stays where they were while later
    /// files stream in.
    private func append(_ content: PaneContent) {
        guard let incoming = content.changesetDocument else { return }
        document = incoming.document
        changeset = incoming
        installModels(mode: .append)
        overview.rows = incoming.document.rows
        overview.changeBlocks = incoming.document.changeBlocks
        folded = incoming.folded
        leftPane.displayRows = folded.displayRows
        rightPane.displayRows = folded.displayRows
        needsLayout = true
        layoutSubtreeIfNeeded()
        for scroll in [leftScroll, rightScroll] { scroll.reflectScrolledClipView(scroll.contentView) }
        updateOverviewViewport()
        applyCurrentBlock()
    }

    /// Hands both panes the current document, with the changeset's sections when there is
    /// one, so the gutter can number lines per file.
    private func installModels(mode: DocumentUpdate.Mode) {
        guard let document else { return }
        let sections = changeset?.sections ?? []
        leftPane.install(
            PaneModel(side: .old, rows: document.rows, lines: document.oldLines, sections: sections), mode: mode)
        rightPane.install(
            PaneModel(side: .new, rows: document.rows, lines: document.newLines, sections: sections), mode: mode)
    }

    /// Applies a style snapshot built for the installed document. A snapshot is
    /// identified by its own id, not the document's, so a reload of the same document
    /// still reapplies its styles.
    func setStyles(_ styles: DocumentStyles?) {
        guard let styles, let document, styles.documentID == document.id, styles.id != appliedStylesID else { return }
        leftPane.styles = styles.old
        rightPane.styles = styles.new
        appliedStylesID = styles.id
    }

    /// Changes the row height without touching fold state; keeps the top row in place.
    func setFontSize(_ fontSize: CGFloat) {
        guard rightPane.fontSize != fontSize else { return }
        let anchor = captureAnchor()
        leftPane.fontSize = fontSize
        rightPane.fontSize = fontSize
        restoreScroll(anchor)
    }

    /// Records the preference. A changeset's projection is fixed, so only a file refolds.
    func setCollapseUnchanged(_ collapse: Bool) {
        guard collapse != collapseUnchanged else { return }
        let anchor = captureAnchor()
        collapseUnchanged = collapse
        guard changeset == nil else { return }
        refold(anchor: anchor)
    }

    var currentBlock: Int? {
        didSet {
            overview.currentBlock = currentBlock
            applyCurrentBlock()
        }
    }

    private func handle(_ action: FoldAction) {
        guard let document, changeset == nil else { return }
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
        if let changeset {
            folded = changeset.folded
        } else if let document, collapseUnchanged {
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
        return Anchor(
            documentRow: folded.documentRow(forDisplayIndex: top), displayIndex: top, offset: offset)
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
        return Anchor(documentRow: target, displayIndex: anchor.displayIndex, offset: anchor.offset)
    }

    /// Re-lays out the panes for the current projection and scrolls so the anchor's
    /// document row sits where it was. The container's `layout()` is what resizes the
    /// pane frames, so it must run before clamping.
    private func restoreScroll(_ anchor: Anchor?) {
        needsLayout = true
        layoutSubtreeIfNeeded()
        let maxY = max(0, rightPane.frame.height - rightScroll.contentView.bounds.height)
        var y: CGFloat = 0
        if let anchor {
            if changeset != nil {
                // A header or notice maps to a boundary that can equal the row count, so
                // the display index is the only usable anchor for a changeset.
                let index = min(anchor.displayIndex, max(0, folded.displayRows.count - 1))
                y = rightPane.layout.y(forRow: index) + anchor.offset
            } else if anchor.documentRow < folded.documentRowCount {
                y = rightPane.layout.y(forRow: folded.displayIndex(forDocumentRow: anchor.documentRow)) + anchor.offset
            }
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

/// SwiftUI wrapper. One instance lives per selection, so a document update is either a
/// recomputation of the same file, which re-anchors on the row that was at the top, or the
/// next revision of the same changeset, which leaves the viewport untouched.
struct SideBySideView: NSViewRepresentable {
    let content: PaneContent
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
        view.setContent(content, fontSize: fontSize)
        context.coordinator.documentID = content.document.id
        view.setStyles(styles)
        applyScrollTargetIfNeeded(to: view, coordinator: context.coordinator)
        view.currentBlock = currentBlock
        return view
    }

    func updateNSView(_ view: SideBySideContainerView, context: Context) {
        // Every changeset revision carries a fresh document id, so each publication
        // reaches the container, which decides whether it appends or replaces.
        if context.coordinator.documentID != content.document.id {
            view.setContent(content, fontSize: fontSize)
            context.coordinator.documentID = content.document.id
        } else {
            view.setFontSize(fontSize)
        }
        view.setCollapseUnchanged(collapseUnchanged)
        view.setStyles(styles)
        if view.currentBlock != currentBlock { view.currentBlock = currentBlock }
        applyScrollTargetIfNeeded(to: view, coordinator: context.coordinator)
    }

    private func applyScrollTargetIfNeeded(to view: SideBySideContainerView, coordinator: Coordinator) {
        guard let scrollTarget, coordinator.scrollTargetID != scrollTarget.id else { return }
        coordinator.scrollTargetID = scrollTarget.id
        view.scroll(toRow: scrollTarget.row)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var documentID: UUID?
        var scrollTargetID: UUID?
    }
}
