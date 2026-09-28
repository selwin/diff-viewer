import AppKit

/// The branch picker's AppKit root: header, search field, the branch table or its empty
/// state, and the New Branch… row, laid out top-down by hand. Owns the `BranchPickerState` and applies each
/// snapshot and query to the table as the state directs.
@MainActor
final class BranchPickerContainerView: NSView {
    private static let searchInset: CGFloat = 12
    private static let gap: CGFloat = 8
    private static let searchHeight: CGFloat = 30
    /// What an empty list keeps room for: its message, or a spinner.
    private static let emptyListHeight: CGFloat = 120
    /// The hairline above the New Branch… row, and the gaps around the two.
    private static let footerHeight: CGFloat = 4 + 1 + 4 + BranchPickerNewBranchRow.height + 6

    private(set) var state: BranchPickerState

    var onActivate: (BranchActivation) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onPull: (String) -> Void = { _ in }
    var onPush: (String) -> Void = { _ in }
    /// Takes the branch, then the remote to publish it to.
    var onPublish: (String, String) -> Void = { _, _ in }
    /// Takes the branch as its row showed it, which the delete checks before it runs.
    var onDelete: (LocalBranch) -> Void = { _ in }
    /// The header's Fetch button and ⌘R.
    var onFetch: () -> Void = {}
    /// The New Branch… row and ⌘N.
    var onNewBranch: () -> Void = {}
    /// The clock the header's fetch time is read against.
    var now: @MainActor () -> Date = Date.init

    let header = BranchPickerHeaderView(frame: .zero)
    let searchField = FilledSearchField()
    /// The search field's rounded fill; the field itself draws no bezel.
    private let searchBackground = RoundedFillView(frame: .zero)
    let scrollView = NSScrollView()
    let tableView = CommitPickerTableView()
    let emptyState = CommitPickerEmptyStateView(frame: .zero)
    private let footerHairline = HairlineView(frame: .zero)
    let newBranchRow = BranchPickerNewBranchRow(frame: .zero)

    /// Set while the container itself moves the table's selection, which the delegate
    /// must not read back as the reader's choice.
    var isApplyingSelection = false
    private var hasRevealedHighlight = false
    private var hasFocusedSearchField = false
    private var keyObserver: (any NSObjectProtocol)?
    private var scrollObserver: (any NSObjectProtocol)?
    /// Refreshes the header's fetch text so its relative time doesn't stay "just now".
    private var fetchTimeTimer: Timer?
    /// The height the popover asks for: the full list's, up to the maximum. Held while a
    /// query filters the list, so the popover doesn't shrink under the reader's typing.
    private(set) var preferredHeight: CGFloat = 0

    init(state: BranchPickerState) {
        self.state = state
        super.init(frame: .zero)
        clipsToBounds = true
        configureSearchField()
        configureTable()
        for view in [header, searchBackground, searchField, scrollView, emptyState, footerHairline, newBranchRow] {
            addSubview(view)
        }
        configureHeader()
        newBranchRow.onActivate = { [weak self] in self?.onNewBranch() }
        fetchTimeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderFetchTime() }
        }
        renderChrome()
        updatePreferredHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The header's buttons act on the current branch, and return focus like the rows' do.
    private func configureHeader() {
        header.onFetch = { [weak self] in
            self?.onFetch()
            self?.returnFocusToSearchField()
        }
        header.onPull = { [weak self] name in
            self?.onPull(name)
            self?.returnFocusToSearchField()
        }
        header.onPush = { [weak self] name in
            self?.onPush(name)
            self?.returnFocusToSearchField()
        }
        header.onPublish = { [weak self] name, remote in
            self?.onPublish(name, remote)
            self?.returnFocusToSearchField()
        }
    }

    private func configureSearchField() {
        searchField.placeholderString = "Search"
        searchField.setAccessibilityLabel("Search branches")
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(queryChanged)
        searchField.delegate = self
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branch"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.gutterWidth = 0
        tableView.rowHeight = BranchPickerMetrics.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        // The search field keeps the keyboard; a click on a row or its buttons must not take it.
        tableView.refusesFirstResponder = true
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.handler = self
        // Hover is the highlight, as in a menu. Rows moving under a still pointer (a
        // keyboard move that scrolled) must not take it back from the keyboard.
        tableView.onHoverChange = { [weak self] _, current, pointerMoved in
            guard let self, pointerMoved, let current else { return }
            // Also sent for a move within the hovered row; only an actual change redraws.
            if state.highlight(tableRow: current) { syncSelection() }
        }
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
        let change = state.apply(snapshot)
        switch change.rows {
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
        // Reloaded cells configured their buttons already; the others are restyled here.
        if change.buttonsChanged {
            let visible = tableView.rows(in: tableView.visibleRect)
            updateRows(visible.lowerBound..<visible.upperBound, animated: false)
        }
        syncSelection()
        renderChrome()
        updatePreferredHeight()
        // Rows that arrive after the first layout get the initial reveal here: layout
        // may not run again.
        revealInitialHighlightIfReady()
        tableView.refreshHover()
    }

    /// Moves the table's selection to the highlight without scrolling. The rows' colours
    /// and pills follow the highlight.
    func syncSelection() {
        let wasApplying = isApplyingSelection
        isApplyingSelection = true
        defer { isApplyingSelection = wasApplying }
        let previous = tableView.selectedRow
        if let row = state.highlightedTableRow {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        updateRows([previous, state.highlightedTableRow].compactMap { $0 }, animated: true)
    }

    // MARK: Query

    /// Typing and the clear button both send this.
    @objc private func queryChanged() {
        applyQuery()
    }

    /// Setting the text by hand sends no action, so the state is updated here too.
    private func clearQuery() {
        searchField.stringValue = ""
        applyQuery()
    }

    /// The one path from the field's text to the table. An unchanged query (a typed
    /// space) keeps the scroll and highlight.
    private func applyQuery() {
        guard state.setQuery(searchField.stringValue) != .none else { return }
        isApplyingSelection = true
        tableView.cancelPress()
        tableView.reloadData()
        isApplyingSelection = false
        syncSelection()
        // The best match is shown at the top; with no query, the current branch as on open.
        if state.query.isEmpty {
            revealHighlight()
        } else {
            tableView.scroll(.zero)
        }
        renderChrome()
        updatePreferredHeight()
        tableView.refreshHover()
    }

    /// The timer's tick: only the fetch text ages, so nothing else is redrawn or laid out.
    private func renderFetchTime() {
        header.configureFetch(state.fetchText(now: now()))
    }

    private func renderChrome() {
        header.configure(state.headerText, fetch: state.fetchText(now: now()))
        newBranchRow.isEnabled = !state.snapshot.isSwitchingBranch
        wireKeyViewLoop()
        switch state.emptyState {
        case nil: emptyState.configure(text: nil, isLoading: false, showsRetry: false)
        case .loading: emptyState.configure(text: "Loading…", isLoading: true, showsRetry: false)
        case .noBranches: emptyState.configure(text: "No branches", isLoading: false, showsRetry: false)
        case .failed: emptyState.configure(text: "Couldn't read branches", isLoading: false, showsRetry: false)
        case .noMatches: emptyState.configure(text: "No matching branches", isLoading: false, showsRetry: false)
        }
        needsLayout = true
    }

    // MARK: Highlight

    /// Moves the highlight to a row the pointer or a click chose, without scrolling.
    func highlight(tableRow row: Int) {
        state.highlight(tableRow: row)
        syncSelection()
    }

    // MARK: Row buttons

    /// Sets `cell`'s highlight and its Pull and Push, Publish, or Delete from the current
    /// snapshot. The buttons show on the highlighted row, and wherever one runs. `animated`
    /// lets an on-screen cell ease its pills in or out as the highlight moves.
    func configureHighlightAndButtons(of cell: BranchPickerRowView, row: Int, animated: Bool) {
        let isHighlighted = row == state.highlightedTableRow
        cell.isHighlighted = isHighlighted
        guard let buttons = state.syncButtons(forTableRow: row), let branch = state.branch(forTableRow: row) else {
            cell.accessory = nil
            cell.showAccessory(false, animated: false)
            return
        }
        let view = cell.accessory as? BranchRowSyncButtons ?? BranchRowSyncButtons(style: .rowPills)
        view.isOnAccent = isHighlighted
        // The popover stays up during an operation, and the search field keeps the
        // keyboard: a click must not leave focus on a button that is about to disable.
        view.configure(
            buttons, isRevealed: isHighlighted, branch: branch.name,
            onPull: { [weak self] name in
                self?.onPull(name)
                self?.returnFocusToSearchField()
            },
            onPush: { [weak self] name in
                self?.onPush(name)
                self?.returnFocusToSearchField()
            },
            onPublish: { [weak self] name, remote in
                self?.onPublish(name, remote)
                self?.returnFocusToSearchField()
            },
            onDelete: { [weak self] in
                self?.onDelete(branch)
                self?.returnFocusToSearchField()
            })
        cell.accessory = view
        cell.showAccessory(view.shouldShow, animated: animated)
    }

    /// Re-configures whichever of `rows` have a cell on screen.
    private func updateRows(_ rows: some Sequence<Int>, animated: Bool) {
        for row in rows where row >= 0 && row < tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BranchPickerRowView
            else { continue }
            configureHighlightAndButtons(of: cell, row: row, animated: animated)
        }
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
        searchBackground.frame = NSRect(
            x: Self.searchInset, y: headerHeight + Self.gap, width: width - Self.searchInset * 2,
            height: Self.searchHeight)
        let fieldHeight = searchField.intrinsicContentSize.height
        searchField.frame = NSRect(
            x: searchBackground.frame.minX + 4, y: searchBackground.frame.midY - fieldHeight / 2,
            width: searchBackground.frame.width - 8, height: fieldHeight)
        let tableTop = searchBackground.frame.maxY + Self.gap
        let footerTop = height - Self.footerHeight
        scrollView.frame = NSRect(x: 0, y: tableTop, width: width, height: max(footerTop - tableTop, 0))
        emptyState.frame = scrollView.frame
        footerHairline.frame = NSRect(x: 0, y: footerTop + 4, width: width, height: 1)
        newBranchRow.frame = NSRect(
            x: 0, y: footerHairline.frame.maxY + 4, width: width, height: BranchPickerNewBranchRow.height)
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

    /// Recomputed from the unfiltered list only; SwiftUI reads it through `sizeThatFits`.
    private func updatePreferredHeight() {
        guard state.query.isEmpty else { return }
        let list = state.items.reduce(CGFloat(0)) { total, item in
            total + (item.row == nil ? BranchPickerMetrics.headerRowHeight : BranchPickerMetrics.rowHeight)
        }
        let chrome = header.fittingHeight + Self.gap + Self.searchHeight + Self.gap + Self.footerHeight
        let height = min(chrome + max(list, Self.emptyListHeight), BranchPickerMetrics.maximumHeight).rounded(.up)
        guard height != preferredHeight else { return }
        preferredHeight = height
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: BranchPickerMetrics.width, height: preferredHeight)
    }

    // MARK: Window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeKeyObserver()
        // SwiftUI dismantles the view lazily after a dismissal, but detaches it at once.
        guard let window else { return }
        window.initialFirstResponder = searchField
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusSearchFieldOnce() }
        }
        focusSearchFieldOnce()
    }

    /// The search field takes focus once per presentation, as soon as the popover's
    /// window is key: it is key from the moment it shows when the app is active. Under a
    /// scripted launch it is not key and this waits for the `didBecomeKey` observer.
    private func focusSearchFieldOnce() {
        guard !hasFocusedSearchField, let window, window.isKeyWindow else { return }
        hasFocusedSearchField = true
        window.makeFirstResponder(searchField)
    }

    /// The search field holds focus. Only a field that lost it is refocused, with the caret
    /// at the end: refocusing selects the text, and the next key would replace the query.
    private func returnFocusToSearchField() {
        guard searchField.currentEditor() == nil else { return }
        window?.makeFirstResponder(searchField)
        let end = searchField.stringValue.utf16.count
        searchField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    /// Search field → Fetch → Pull → Push → search field, over the header buttons that can
    /// act; AppKit skips buttons unless Full Keyboard Access is on. Set explicitly rather
    /// than recalculated, so the order doesn't depend on the popover window.
    private func wireKeyViewLoop() {
        let loop = [searchField] + header.keyViews(for: state.headerText.focusOrder)
        for (view, next) in zip(loop, loop.dropFirst() + [searchField]) { view.nextKeyView = next }
        // A focused button that just left the loop (disabled or hidden) hands focus back.
        if let focused = window?.firstResponder as? NSView, focused.isDescendant(of: header),
            !loop.contains(focused)
        {
            returnFocusToSearchField()
        }
    }

    /// Return from a focused header button still activates the highlighted row; other keys
    /// go on up the chain.
    override func keyDown(with event: NSEvent) {
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.isDisjoint(with: modifiers), [36, 76].contains(event.keyCode) else {
            return super.keyDown(with: event)
        }
        activate()
    }

    private func removeKeyObserver() {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    func tearDown() {
        fetchTimeTimer?.invalidate()
        fetchTimeTimer = nil
        removeKeyObserver()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss()
    }
}

/// Keys from the search field move the highlight and reveal it; Return and Escape act,
/// and so does a click on a row.
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
        guard let activation = state.activation(forTableRow: row) else { return }
        onActivate(activation)
    }

    func cancel() {
        onDismiss()
    }

    func canHighlight(tableRow row: Int) -> Bool {
        state.canHighlight(tableRow: row)
    }
}

/// The search field holds the keyboard; the arrows, Return and Escape reach the list.
extension BranchPickerContainerView: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveUp()
        case #selector(NSResponder.moveDown(_:)): moveDown()
        case #selector(NSResponder.insertNewline(_:)): activate()
        // Escape clears the query first, then dismisses.
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty { cancel() } else { clearQuery() }
        default: return false
        }
        return true
    }
}

/// A search field without a bezel, drawn over a `RoundedFillView`.
final class FilledSearchField: NSSearchField {
    override static var cellClass: AnyClass? {
        get { FilledSearchFieldCell.self }
        set {}
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Without a bezel the cell no longer keeps its text clear of the magnifier and the clear
/// button, so it is told where each goes, and the drawn text and the field editor are
/// both put in the text's place.
final class FilledSearchFieldCell: NSSearchFieldCell {
    private static let buttonWidth: CGFloat = 22

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        searchTextRect(forBounds: rect)
    }

    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate,
            start: selStart, length: selLength)
    }

    override func edit(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?
    ) {
        super.edit(
            withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate,
            event: event)
    }

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: rect.minY, width: Self.buttonWidth, height: rect.height)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let inset = Self.buttonWidth + 2
        return NSRect(x: rect.minX + inset, y: rect.minY, width: max(rect.width - inset * 2, 0), height: rect.height)
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - Self.buttonWidth, y: rect.minY, width: Self.buttonWidth, height: rect.height)
    }
}

/// A quiet rounded fill, behind a borderless control.
final class RoundedFillView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternarySystemFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
