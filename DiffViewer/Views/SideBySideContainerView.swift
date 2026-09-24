import AppKit

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
    private let leftHeader = PaneHeaderView(frame: .zero)
    private let rightHeader = PaneHeaderView(frame: .zero)
    private var isSyncing = false
    /// Non-nil while find is open: the panes wear headers and the unsearched one is dimmed.
    private var findScope: PaneFindScope?

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
    /// Coalesces top-visible-section reports; delivery is always deferred to the next
    /// main-loop turn because this view is also driven from `updateNSView`.
    private let visibleSectionPublisher = VisibleSectionPublisher()

    /// Fresh whenever `folded` changes for new content or a refold, so a find result can
    /// tell whether it was computed against the rows on screen.
    private(set) var projectionID = UUID()
    /// The results and side whose fills the panes hold; nil after a clear or a fresh install.
    var appliedFindFills: (resultsID: UUID, side: DocumentSide)?
    /// The match selection find last set, until the reader touches a pane. Only this is
    /// cleared on a side switch, so a selection the reader made is never taken away.
    var findOwnedSelection: (side: DocumentSide, selection: PaneSelection)?
    private var isDisplayedDocumentReportPending = false
    /// Kept until a window can make the pane first responder.
    var pendingFocus: PaneFocusRequest?

    /// What find results are keyed by: the changeset's load, or the file document.
    var installedContentID: UUID? { changeset?.loadID ?? document?.id }

    /// Called with the rows the panes show after each projection change, at most once per
    /// main-loop turn and never with nothing installed.
    var onDisplayedDocumentChange: ((DisplayedDocument) -> Void)?
    /// Called when the reader clicks or selects all in a pane.
    var onPaneInteraction: ((DocumentSide) -> Void)?
    /// Called with the visible document rows and the installed content id on every
    /// viewport update.
    var onVisibleRowsChange: ((Range<Int>, UUID) -> Void)?
    /// Called on the next main-loop turn with the id of a focus request once it succeeds.
    var onPaneFocusApplied: ((UUID) -> Void)?

    /// Called with the changeset section whose rows are at the top of the viewport, nil
    /// for a file or an empty changeset. At most once per main-loop turn.
    var onTopVisibleSectionChange: ((VisibleSectionReference?) -> Void)? {
        didSet { visibleSectionPublisher.onChange = onTopVisibleSectionChange }
    }

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
            scroll.verticalScrollElasticity = .allowed
            scroll.horizontalScrollElasticity = .none
            scroll.contentView.drawsBackground = false
            pane.onFoldAction = { [weak self] action in self?.handle(action) }
            addSubview(scroll)
        }
        leftPane.onInteraction = { [weak self] in
            self?.rightPane.selection = nil
            self?.findOwnedSelection = nil
            self?.onPaneInteraction?(.old)
        }
        rightPane.onInteraction = { [weak self] in
            self?.leftPane.selection = nil
            self?.findOwnedSelection = nil
            self?.onPaneInteraction?(.new)
        }
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DiffTheme.divider.cgColor
        addSubview(divider)
        addSubview(overview)
        for header in [leftHeader, rightHeader] {
            header.isHidden = true
            addSubview(header)
        }
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
            redrawIfScrolledHorizontally(leftScroll, pane: leftPane)
            sync(from: leftScroll, to: rightScroll)
        } else {
            redrawIfScrolledHorizontally(rightScroll, pane: rightPane)
            sync(from: rightScroll, to: leftScroll)
        }
    }

    /// The gutter is drawn at the visible left edge, and a layer-backed clip view only
    /// redraws the strip a scroll exposes, so a horizontal scroll must redraw the pane.
    private func redrawIfScrolledHorizontally(_ scroll: NSScrollView, pane: DiffPaneView) {
        let x = scroll.contentView.bounds.origin.x
        guard x != pane.lastClipX else { return }
        pane.lastClipX = x
        pane.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        divider.layer?.backgroundColor = DiffTheme.divider.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPendingFocus()
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
            visibleSectionPublisher.reset()
            install(content, previousAnchor: anchor)
        case .append:
            append(content)
            // An append keeps the clip origin; only a new row height has to re-anchor.
            if fontChanged { restoreScroll(anchor) }
        }
    }

    /// The ordinary path. Expansions survive only when the rows are unchanged. The viewport
    /// is restored by source line: within the file for a single file, and by file id then
    /// source line through `ChangesetAnchor` for a replaced changeset. Both are approximate.
    private func install(_ content: PaneContent, previousAnchor: Anchor?) {
        let previousDocument = document
        let previousChangeset = changeset
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
        // The panes dropped their fills and selections; the same results must be able to apply again.
        appliedFindFills = nil
        findOwnedSelection = nil
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
        } else if let previousAnchor, let previousChangeset, let incomingChangeset = changeset {
            anchor = ChangesetAnchor.translate(
                displayIndex: previousAnchor.displayIndex, from: previousChangeset, to: incomingChangeset
            )
            .map { Anchor(documentRow: 0, displayIndex: $0, offset: previousAnchor.offset) }
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
        projectionChanged()
        leftPane.displayRows = folded.displayRows
        rightPane.displayRows = folded.displayRows
        needsLayout = true
        layoutSubtreeIfNeeded()
        for scroll in [leftScroll, rightScroll] { scroll.reflectScrolledClipView(scroll.contentView) }
        updateOverviewViewport()
        applyCurrentBlock()
    }

    /// Hands both panes the current document, with the changeset's sections and section
    /// index when there is one, so the gutter can number lines per file.
    private func installModels(mode: DocumentUpdate.Mode) {
        guard let document else { return }
        let sections = changeset?.sections ?? []
        let sectionIndex = changeset?.sectionIndex
        leftPane.install(
            PaneModel(
                side: .old, rows: document.rows, lines: document.oldLines, sections: sections,
                sectionIndex: sectionIndex), mode: mode)
        rightPane.install(
            PaneModel(
                side: .new, rows: document.rows, lines: document.newLines, sections: sections,
                sectionIndex: sectionIndex), mode: mode)
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

    /// Headers and dimming only change frames and alpha, never the clip's origin, so the
    /// top row stays put as the panes shrink or grow beneath the headers.
    func setFindScope(_ scope: PaneFindScope?) {
        guard scope != findScope else { return }
        findScope = scope
        leftHeader.isHidden = scope == nil
        rightHeader.isHidden = scope == nil
        if let scope {
            leftHeader.configure(label: scope.labels.old, isSearched: scope.searchedSide == .old)
            rightHeader.configure(label: scope.labels.new, isSearched: scope.searchedSide == .new)
        }
        leftScroll.alphaValue = scope.map { $0.searchedSide == .old ? 1 : Self.unsearchedAlpha } ?? 1
        rightScroll.alphaValue = scope.map { $0.searchedSide == .new ? 1 : Self.unsearchedAlpha } ?? 1
        needsLayout = true
        // The clips change height, so the viewport the overview and find read changes too.
        layoutSubtreeIfNeeded()
        updateOverviewViewport()
    }

    private static let unsearchedAlpha: CGFloat = 0.45

    /// Hides the panes without tearing them down, so folds, scroll position and selection
    /// survive. Resigns first responder on the way out so Copy and Select All cannot act
    /// on text nobody can see.
    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        guard hidden, let window else { return }
        if let responder = window.firstResponder as? NSView, responder === self || responder.isDescendant(of: self) {
            window.makeFirstResponder(nil)
        }
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
        projectionChanged()
        leftPane.displayRows = folded.displayRows
        rightPane.displayRows = folded.displayRows
        applyCurrentBlock()
        restoreScroll(anchor)
    }

    /// Called wherever `folded` is reassigned. Runs inside `updateNSView`, so the report is
    /// deferred, and built at delivery so a coalesced pair reports the later projection.
    private func projectionChanged() {
        projectionID = UUID()
        guard !isDisplayedDocumentReportPending else { return }
        isDisplayedDocumentReportPending = true
        DispatchQueue.main.async { [weak self] in self?.deliverDisplayedDocument() }
    }

    private func deliverDisplayedDocument() {
        isDisplayedDocumentReportPending = false
        guard let document, let contentID = installedContentID else { return }
        onDisplayedDocumentChange?(
            DisplayedDocument(
                document: document, displayRows: folded.displayRows, contentID: contentID,
                projectionID: projectionID))
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
        let rows = folded.documentRange(forDisplayRange: visibleDisplayRange)
        overview.visibleRows = rows
        if let contentID = installedContentID { onVisibleRowsChange?(rows, contentID) }
        updateTopVisibleSection()
    }

    /// Reports the section owning the display row at the clip's top edge. Reached after
    /// a replace, an append and every clip-bounds change, so the report follows scrolling
    /// and the clamped origin after a resize.
    private func updateTopVisibleSection() {
        var reference: VisibleSectionReference?
        if let changeset, !folded.displayRows.isEmpty {
            let index = rightPane.layout.row(atY: rightScroll.contentView.bounds.minY)
            if index < folded.displayRows.count,
                let section = changeset.sectionIndex.sectionIndex(containingDisplayIndex: index, in: folded)
            {
                reference = VisibleSectionReference(loadID: changeset.loadID, sectionIndex: section)
            }
        }
        if visibleSectionPublisher.update(reference) {
            DispatchQueue.main.async { [weak self] in self?.visibleSectionPublisher.deliver() }
        }
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

    // MARK: - Sides

    func pane(for side: DocumentSide) -> DiffPaneView { side == .old ? leftPane : rightPane }
    func scrollView(for side: DocumentSide) -> NSScrollView { side == .old ? leftScroll : rightScroll }

    var visibleDisplayRange: Range<Int> {
        let clip = rightScroll.contentView.bounds
        return rightPane.layout.rows(intersecting: clip.minY, clip.maxY)
    }

    override func layout() {
        super.layout()
        let overviewWidth = ChangeOverviewView.width
        let width = bounds.width - overviewWidth
        let leftWidth = floor((width - 1) / 2)
        // Not flipped: the headers take the top strip and the panes keep y = 0.
        let headerHeight = findScope == nil ? 0 : PaneHeaderView.height
        let height = max(0, bounds.height - headerHeight)
        leftHeader.frame = NSRect(x: 0, y: height, width: leftWidth, height: headerHeight)
        rightHeader.frame = NSRect(
            x: leftWidth + 1, y: height, width: bounds.width - leftWidth - 1, height: headerHeight)
        leftScroll.frame = NSRect(x: 0, y: 0, width: leftWidth, height: height)
        // Full height, so it also separates the two headers.
        divider.frame = NSRect(x: leftWidth, y: 0, width: 1, height: bounds.height)
        rightScroll.frame = NSRect(x: leftWidth + 1, y: 0, width: width - leftWidth - 1, height: height)
        overview.frame = NSRect(x: bounds.width - overviewWidth, y: 0, width: overviewWidth, height: height)
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
