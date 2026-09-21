import AppKit

/// The branch picker's AppKit root: header, gutter, the branch table, and the footer or
/// empty state, laid out top-down by hand. Owns the `BranchPickerState` and applies each
/// snapshot to the table as the state directs.
@MainActor
final class BranchPickerContainerView: NSView {
    private(set) var state: BranchPickerState

    var onActivate: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    let header = BranchPickerHeaderView(frame: .zero)
    let gutter = CommitPickerGutterView(frame: .zero)
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

    init(state: BranchPickerState) {
        self.state = state
        super.init(frame: .zero)
        clipsToBounds = true
        configureTable()
        for view in [gutter, header, scrollView, footer, emptyState] { addSubview(view) }
        renderChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branch"))
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
            MainActor.assumeIsolated { self?.tableView.refreshHover() }
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // MARK: Snapshots

    /// An unchanged snapshot is skipped.
    func apply(_ snapshot: BranchPickerSnapshot) {
        guard snapshot != state.snapshot else { return }
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
        // Rows that arrive after the first layout get the initial reveal here: layout
        // may not run again.
        revealInitialHighlightIfReady()
        tableView.refreshHover()
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
        switch state.footer {
        case .none:
            footer.configure(text: "", tooltip: nil, isLoading: false, showsRetry: false)
            footer.isHidden = true
        case let .text(text, tooltip):
            footer.configure(text: text, tooltip: tooltip, isLoading: false, showsRetry: false)
            footer.isHidden = false
        }
        switch state.emptyState {
        case nil: emptyState.configure(text: nil, isLoading: false, showsRetry: false)
        case .loading: emptyState.configure(text: "Loading…", isLoading: true, showsRetry: false)
        case .noBranches: emptyState.configure(text: "No branches", isLoading: false, showsRetry: false)
        case .failed: emptyState.configure(text: "Couldn't read branches", isLoading: false, showsRetry: false)
        }
        needsLayout = true
    }

    // MARK: Highlight

    func highlight(tableRow row: Int) {
        state.highlight(tableRow: row)
    }

    /// After a keyboard move: the selection follows, and the highlight is scrolled into view.
    private func showHighlight() {
        syncSelection()
        revealHighlight()
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
        let tableTop = headerHeight + 8
        let footerHeight = footer.isHidden ? 0 : CommitPickerMetrics.footerHeight
        scrollView.frame = NSRect(x: 0, y: tableTop, width: width, height: max(height - tableTop - footerHeight, 0))
        footer.frame = NSRect(x: 0, y: height - footerHeight, width: width, height: footerHeight)
        emptyState.frame = scrollView.frame
        tableView.sizeLastColumnToFit()
        // The table only knows its rows once it has laid out, so the initial highlight
        // is selected here rather than in `init`.
        revealInitialHighlightIfReady()
    }

    /// Consumes the one initial reveal, but only once there is a row to reveal: branches
    /// can arrive after the popover opened, and the current branch still has to be shown.
    private func revealInitialHighlightIfReady() {
        guard !hasRevealedHighlight, scrollView.frame.height > 0, state.highlightedTableRow != nil else { return }
        hasRevealedHighlight = true
        syncSelection()
        revealHighlight()
    }

    /// Shows the highlighted row: once the rows and layout are first ready, then only
    /// after keyboard navigation.
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
        guard let window else { return }
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
    /// launch it is not key and this waits for the `didBecomeKey` observer.
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
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss()
    }
}

/// Plain keys in the table move the highlight and reveal it; Return and Escape act.
extension BranchPickerContainerView: PickerTableHandler {
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
        guard let row = state.highlightedTableRow else { return }
        activate(tableRow: row)
    }

    func activate(tableRow row: Int) {
        guard state.canActivate(tableRow: row), let name = state.branchName(forTableRow: row) else { return }
        onActivate(name)
    }

    func cancel() {
        onDismiss()
    }
}
