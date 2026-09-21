import AppKit

/// The commit picker's AppKit root: header, gutter, the pinned Working Tree row, the
/// commit table, and the footer or empty state, laid out top-down by hand. Owns the
/// `CommitPickerState` and applies each snapshot to the table as the state directs.
@MainActor
final class CommitPickerContainerView: NSView {
    private(set) var state: CommitPickerState

    var onActivate: (DiffScope) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onLoadMore: () -> Void = {}
    var onRetry: () -> Void = {}

    let header = CommitPickerHeaderView(frame: .zero)
    let gutter = CommitPickerGutterView(frame: .zero)
    let pinnedRow = CommitPickerPinnedRowView(frame: .zero)
    let scrollView = NSScrollView()
    let tableView = CommitPickerTableView()
    let footer = CommitPickerFooterView(frame: .zero)
    let emptyState = CommitPickerEmptyStateView(frame: .zero)

    /// Set while the container itself moves the table's selection, which the delegate
    /// must not read back as the reader's choice.
    var isApplyingSelection = false
    private var hasRevealedHighlight = false
    private var hasFocusedTable = false
    private var keyObserver: (any NSObjectProtocol)?
    private var scrollObserver: (any NSObjectProtocol)?
    /// Set from the moment a load is decided until the deferred request runs or a load
    /// is seen in a snapshot, so a scroll cannot queue the request twice.
    private var isLoadMorePending = false
    /// Bumped by `tearDown`, so work scheduled for a presentation can tell it is over.
    private(set) var teardownGeneration = 0

    init(state: CommitPickerState) {
        self.state = state
        super.init(frame: .zero)
        clipsToBounds = true
        configureTable()
        for view in [gutter, header, pinnedRow, scrollView, footer, emptyState] { addSubview(view) }
        pinnedRow.onActivate = { [weak self] in self?.onActivate(.workingTree) }
        footer.onRetry = { [weak self] in self?.requestRetry() }
        emptyState.onRetry = { [weak self] in self?.requestRetry() }
        renderChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("scope"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = CommitPickerMetrics.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: CommitPickerMetrics.rowGap)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.handler = self
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tableView.refreshHover()
                self?.requestMoreIfNeeded()
            }
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // MARK: Snapshots

    /// An unchanged snapshot is skipped; pagination is re-checked on scroll and layout.
    func apply(_ snapshot: CommitPickerSnapshot) {
        guard snapshot != state.snapshot else { return }
        if snapshot.isLoadingHistory { isLoadMorePending = false }
        // A reload can move or drop the table's selection; none of that is the reader's.
        isApplyingSelection = true
        switch state.apply(snapshot) {
        case .none:
            break
        case let .incremental(inserted, refreshed):
            if let inserted {
                tableView.insertRows(at: IndexSet(integersIn: inserted), withAnimation: [])
            }
            if !refreshed.isEmpty {
                tableView.reloadData(forRowIndexes: refreshed, columnIndexes: [0])
            }
        case .reloadAll:
            tableView.cancelPress()
            tableView.reloadData()
        }
        isApplyingSelection = false
        syncSelection()
        renderChrome()
        tableView.refreshHover()
        requestMoreIfNeeded()
    }

    /// Moves the table's selection to the highlight without scrolling.
    func syncSelection() {
        let wasApplying = isApplyingSelection
        isApplyingSelection = true
        defer { isApplyingSelection = wasApplying }
        if let row = state.highlightedTableRow {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    private func renderChrome() {
        header.configure(state.headerText)
        pinnedRow.configure(
            trailing: state.workingTreeTrailingText, showsPill: state.snapshot.displayedScope == .workingTree)
        pinnedRow.isHighlighted = state.highlightedScope == .workingTree
        footer.configure(state.footer)
        footer.isHidden = state.footer == .none
        emptyState.configure(state.emptyState)
        needsLayout = true
    }

    // MARK: Highlight

    func highlight(tableRow row: Int) {
        state.highlight(tableRow: row)
        pinnedRow.isHighlighted = false
    }

    /// After a keyboard move: the selection and pinned row follow, and the highlight
    /// is scrolled into view.
    private func showHighlight() {
        syncSelection()
        pinnedRow.isHighlighted = state.highlightedScope == .workingTree
        revealHighlight()
    }

    // MARK: Loading

    /// Asks for the next page once the last row is on screen. Never immediate: this runs
    /// from `apply`, inside a SwiftUI update, where the window's state must not change.
    private func requestMoreIfNeeded() {
        guard !isLoadMorePending, state.shouldRequestMore(lastVisibleRow: lastVisibleRow()) else { return }
        isLoadMorePending = true
        let generation = teardownGeneration
        // Defer past the SwiftUI update, then re-check that loading is still wanted.
        Task { @MainActor [weak self] in
            guard let self, generation == teardownGeneration, window != nil else { return }
            isLoadMorePending = false
            guard state.shouldRequestMore(lastVisibleRow: lastVisibleRow()) else { return }
            onLoadMore()
        }
    }

    private func lastVisibleRow() -> Int? {
        let rows = tableView.rows(in: tableView.visibleRect)
        return rows.length > 0 ? rows.location + rows.length - 1 : nil
    }

    private func requestRetry() {
        let generation = teardownGeneration
        Task { @MainActor [weak self] in
            guard let self, generation == teardownGeneration, window != nil else { return }
            onRetry()
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let headerHeight = header.fittingHeight
        header.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        gutter.frame = NSRect(
            x: 0, y: headerHeight, width: CommitPickerMetrics.gutterWidth, height: height - headerHeight)
        pinnedRow.frame = NSRect(x: 0, y: headerHeight + 8, width: width, height: CommitPickerMetrics.rowHeight)
        let tableTop = pinnedRow.frame.maxY + 8
        let footerHeight = footer.isHidden ? 0 : CommitPickerMetrics.footerHeight
        scrollView.frame = NSRect(x: 0, y: tableTop, width: width, height: max(height - tableTop - footerHeight, 0))
        footer.frame = NSRect(x: 0, y: height - footerHeight, width: width, height: footerHeight)
        emptyState.frame = scrollView.frame
        tableView.sizeLastColumnToFit()
        // The table only knows its rows once it has laid out, so the initial highlight
        // is selected here rather than in `init`.
        if !hasRevealedHighlight, scrollView.frame.height > 0 {
            hasRevealedHighlight = true
            syncSelection()
            revealHighlight()
        }
        requestMoreIfNeeded()
    }

    /// Shows the highlighted row, or the top for Working Tree. Called once when the
    /// popover first has a height, then only for keyboard moves; snapshots never scroll.
    private func revealHighlight() {
        if let row = state.highlightedTableRow {
            tableView.scrollRowToVisible(row)
        } else {
            tableView.scroll(.zero)
        }
    }

    // MARK: Window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeKeyObserver()
        // SwiftUI dismantles the view lazily after a dismissal, but detaches it at once.
        guard let window else {
            teardownGeneration += 1
            return
        }
        window.initialFirstResponder = tableView
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusTableOnce() }
        }
        focusTableOnce()
    }

    /// The table takes focus once per presentation, as soon as the popover's window is
    /// key: it is key from the moment it shows when the app is active. Under a scripted
    /// launch it is not key and this waits for the `didBecomeKey` observer, which was seen
    /// to land the table when `DebugLaunchOptions` makes the window key by hand.
    private func focusTableOnce() {
        guard !hasFocusedTable, let window, window.isKeyWindow else { return }
        hasFocusedTable = true
        window.makeFirstResponder(tableView)
    }

    private func removeKeyObserver() {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    func tearDown() {
        removeKeyObserver()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        teardownGeneration += 1
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss()
    }
}

/// Plain keys in the table move the highlight and reveal it; Return and Escape act.
extension CommitPickerContainerView: CommitPickerTableHandler {
    func moveUp() {
        state.moveUp()
        showHighlight()
    }

    func moveDown() {
        state.moveDown()
        showHighlight()
    }

    func moveToFirst() {
        state.moveToFirst()
        showHighlight()
    }

    func moveToLast() {
        state.moveToLast()
        showHighlight()
    }

    func activate() {
        onActivate(state.highlightedScope)
    }

    func activate(tableRow row: Int) {
        guard let scope = state.scope(forTableRow: row) else { return }
        onActivate(scope)
    }

    func cancel() {
        onDismiss()
    }
}
