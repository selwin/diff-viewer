import AppKit

/// The commit picker's AppKit root: header, search field and the list, laid out top-down
/// by hand on the popover's glass. Owns the `CommitPickerState`, applies each snapshot and
/// query to the table as the state directs, and asks for older pages when the state wants
/// them.
@MainActor
final class CommitPickerContainerView: NSView {
    /// How long typing must pause before a query reads older pages.
    private static let queryLoadDelay: TimeInterval = 0.3
    /// Between the search field and the first row.
    private static let listTopGap: CGFloat = 8
    /// Below the list, so the last row's highlight clears the popover's edge.
    private static let bottomGap: CGFloat = 8

    private(set) var state: CommitPickerState

    var onActivate: (DiffScope) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onLoadMore: () -> Void = {}
    var onRetry: () -> Void = {}

    let header = CommitPickerHeaderView()
    let searchField = FilledSearchField()
    /// The search field's rounded fill; the field itself draws no bezel.
    let searchBackground = RoundedFillView(frame: .zero)
    let scrollView = NSScrollView()
    let tableView = PickerTableView()

    /// Set while the container itself moves the table's selection, which the delegate
    /// must not read back as the reader's choice.
    var isApplyingSelection = false
    private var hasRevealedHighlight = false
    private var hasFocusedSearchField = false
    private var keyObserver: (any NSObjectProtocol)?
    private var scrollObserver: (any NSObjectProtocol)?
    var displayOptionsObserver: (any NSObjectProtocol)?
    /// The generation of a request decided but not yet run, until it runs or a load is
    /// seen in a snapshot, so a scroll cannot queue the request twice. A request from an
    /// earlier attachment never blocks one from the current attachment.
    private var pendingLoadGeneration: Int?
    /// Running while typing has not paused; no page is read for the query until it fires.
    private var queryLoadTimer: Timer?
    /// Bumped by `tearDown`, so work scheduled for a presentation can tell it is over.
    private(set) var teardownGeneration = 0
    /// The height the popover asks for: the full list's, up to the maximum. It only grows
    /// while the popover is up, so neither a query nor a removed row makes it shrink.
    private(set) var preferredHeight: CGFloat = 0

    init(state: CommitPickerState) {
        self.state = state
        super.init(frame: .zero)
        clipsToBounds = true
        configureSearchField()
        configureTable()
        for view in [header, searchBackground, searchField, scrollView] { addSubview(view) }
        header.onCopy = { [weak self] in self?.returnFocusToSearchField() }
        observeDisplayOptions()
        renderChrome()
        updatePreferredHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureSearchField() {
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search commits",
            attributes: [
                .font: searchField.font ?? .systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: PickerStyle.placeholder,
            ])
        searchField.setAccessibilityLabel("Search commits")
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(queryChanged)
        searchField.delegate = self
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("scope"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        // Only a fallback: `rowHeight(forItem:)` sizes every row.
        tableView.rowHeight = PickerStyle.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        // The search field keeps the keyboard; a click on a row or its copy button must not take it.
        tableView.refusesFirstResponder = true
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.handler = self
        // Hover is the highlight, as in a menu, and leaving the rows clears it. Rows moving
        // under a still pointer (a keyboard move that scrolled) must not take it back from
        // the keyboard.
        tableView.onHoverChange = { [weak self] _, current, pointerMoved in
            guard let self, pointerMoved else { return }
            // Also sent for a move within the hovered row; only an actual change redraws.
            if let current {
                if state.highlight(item: current) { syncSelection() }
            } else if state.highlight != .cleared {
                state.clearHighlight()
                syncSelection()
            }
        }
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
        if snapshot.isLoadingHistory { pendingLoadGeneration = nil }
        // A reload can move or drop the table's selection; none of that is the reader's.
        isApplyingSelection = true
        let isAnimatingRows = applyTableChange(state.apply(snapshot))
        isApplyingSelection = false
        syncSelection()
        renderChrome()
        updatePreferredHeight()
        // Rows that arrive after the first layout get the initial reveal here: layout
        // may not run again.
        revealInitialHighlightIfReady()
        // Rows still sliding are re-read once they settle.
        if !isAnimatingRows { tableView.refreshHover() }
        requestMoreIfNeeded()
    }

    /// Returns whether rows are animating in or out.
    private func applyTableChange(_ change: CommitPickerTableChange) -> Bool {
        switch change {
        case .none:
            return false
        case let .update(removed, inserted, refreshed):
            let animates = !removed.isEmpty || !inserted.isEmpty
            if animates { animateRows(removed: removed, inserted: inserted) }
            if !refreshed.isEmpty {
                tableView.reloadData(forRowIndexes: refreshed, columnIndexes: [0])
            }
            return animates
        case .reloadAll:
            tableView.cancelPress()
            tableView.reloadData()
            return false
        }
    }

    /// Rows that go fade out as the rows below slide up over them; new rows fade in as the
    /// rows below make room. Reduce Motion snaps instead.
    private func animateRows(removed: IndexSet, inserted: IndexSet) {
        // A press in flight names a row by index, and the indices are about to shift.
        tableView.cancelPress()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            if reduceMotion { context.duration = 0 }
            let effect: NSTableView.AnimationOptions = reduceMotion ? [] : .effectFade
            tableView.beginUpdates()
            tableView.removeRows(at: removed, withAnimation: effect)
            tableView.insertRows(at: inserted, withAnimation: effect)
            tableView.endUpdates()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.tableView.refreshHover() }
        }
    }

    /// Moves the table's selection to the highlight without scrolling. The rows' copy
    /// buttons follow the highlight.
    func syncSelection() {
        let wasApplying = isApplyingSelection
        isApplyingSelection = true
        defer { isApplyingSelection = wasApplying }
        let previous = tableView.selectedRow
        if let row = state.highlightedItemIndex {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        updateRows([previous, state.highlightedItemIndex].compactMap { $0 })
    }

    /// Re-applies the highlight to whichever of `rows` have a cell on screen.
    private func updateRows(_ rows: [Int]) {
        for row in rows where row >= 0 && row < tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            configureHighlight(of: cell, row: row)
        }
    }

    func configureHighlight(of cell: NSView, row: Int) {
        let isHighlighted = row == state.highlightedItemIndex
        (cell as? CommitPickerRowView)?.isHighlighted = isHighlighted
    }

    private func renderChrome() {
        header.configure(state.headerText)
        needsLayout = true
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

    /// The one path from the field's text to the table. The list filters on every
    /// keystroke; older pages are read for the query once typing pauses.
    private func applyQuery() {
        let change = state.setQuery(searchField.stringValue)
        guard change != .none else { return }
        isApplyingSelection = true
        let isAnimatingRows = applyTableChange(change)
        isApplyingSelection = false
        syncSelection()
        // The best match is shown at the top; with no query, the displayed scope as on open.
        if change == .reloadAll {
            if state.query.isEmpty { revealHighlight() } else { tableView.scroll(.zero) }
        }
        updatePreferredHeight()
        if !isAnimatingRows { tableView.refreshHover() }
        queryLoadTimer?.invalidate()
        queryLoadTimer = nil
        guard !state.query.isEmpty else { return requestMoreIfNeeded() }
        queryLoadTimer = Timer.scheduledTimer(withTimeInterval: Self.queryLoadDelay, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.queryLoadTimer = nil
                self?.requestMoreIfNeeded()
            }
        }
    }

    // MARK: Actions

    func perform(_ activation: CommitPickerActivation) {
        switch activation {
        case let .scope(scope):
            onActivate(scope)
        case .retry:
            requestRetry()
            returnFocusToSearchField()
        case .searchOlder:
            searchOlder()
            returnFocusToSearchField()
        }
    }

    /// Raises the search's budget and reads on at once: the reader asked, so the typing
    /// pause is not waited for.
    private func searchOlder() {
        queryLoadTimer?.invalidate()
        queryLoadTimer = nil
        isApplyingSelection = true
        let isAnimatingRows = applyTableChange(state.raiseSearchBudget())
        isApplyingSelection = false
        syncSelection()
        if !isAnimatingRows { tableView.refreshHover() }
        requestMoreIfNeeded()
    }

    // MARK: Loading

    /// Asks for the next page when the state wants one, unless typing has not paused.
    /// Never immediate: this runs from `apply`, inside a SwiftUI update, where the
    /// window's state must not change.
    private func requestMoreIfNeeded() {
        guard queryLoadTimer == nil, pendingLoadGeneration != teardownGeneration,
            state.shouldRequestMore(lastVisibleRow: lastVisibleRow())
        else { return }
        let generation = teardownGeneration
        pendingLoadGeneration = generation
        // Defer past the SwiftUI update, then re-check that loading is still wanted.
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Cleared on every exit, but only its own: a newer attachment's request stays pending.
            if pendingLoadGeneration == generation { pendingLoadGeneration = nil }
            guard generation == teardownGeneration, window != nil, queryLoadTimer == nil,
                state.shouldRequestMore(lastVisibleRow: lastVisibleRow())
            else { return }
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

    // MARK: Highlight

    /// Moves the highlight to a row the keyboard or type-select chose, without scrolling.
    func highlight(item index: Int) {
        state.highlight(item: index)
        syncSelection()
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
        let headerHeight = header.fittingHeight(width: width)
        header.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        let searchInset = PickerStyle.edgeInset - PickerStyle.searchOutset
        // The header's bottom padding is the whole gap, as above the branch picker's tabs.
        searchBackground.frame = NSRect(
            x: searchInset, y: headerHeight, width: width - searchInset * 2,
            height: PickerStyle.searchHeight)
        let fieldHeight = searchField.intrinsicContentSize.height
        searchField.frame = NSRect(
            x: searchBackground.frame.minX + 6, y: searchBackground.frame.midY - fieldHeight / 2,
            width: searchBackground.frame.width - 12, height: fieldHeight)
        let tableTop = searchBackground.frame.maxY + Self.listTopGap
        scrollView.frame = NSRect(
            x: 0, y: tableTop, width: width, height: max(bounds.height - tableTop - Self.bottomGap, 0))
        tableView.sizeLastColumnToFit()
        // The table only knows its rows once it has laid out, so the initial highlight
        // is selected here rather than in `init`.
        revealInitialHighlightIfReady()
        requestMoreIfNeeded()
    }

    /// Consumes the one initial reveal, but only once there is a row to reveal.
    private func revealInitialHighlightIfReady() {
        guard !hasRevealedHighlight, scrollView.frame.height > 0, state.highlightedItemIndex != nil else { return }
        hasRevealedHighlight = true
        syncSelection()
        revealHighlight()
    }

    /// Shows the highlighted row: once the rows and layout are first ready, then only
    /// after keyboard navigation or a cleared query.
    private func revealHighlight() {
        if let row = state.highlightedItemIndex {
            tableView.scrollRowToVisible(row)
        } else {
            tableView.scroll(.zero)
        }
    }

    /// The one source of row heights, for the table and the popover's height alike.
    func rowHeight(forItem index: Int) -> CGFloat {
        switch state.items[index] {
        case .header: PickerStyle.sectionHeaderHeight
        case .message: CommitPickerMessageRowView.height
        case .workingTree, .commit: PickerStyle.rowHeight
        }
    }

    /// Recomputed from the unfiltered list only; SwiftUI reads it through `sizeThatFits`.
    /// It never shrinks while the popover is up: SwiftUI resizes a popover without
    /// animation, so a shorter list would snap the popover over rows still fading out.
    private func updatePreferredHeight() {
        guard state.query.isEmpty else { return }
        let list = state.items.indices.reduce(CGFloat(0)) { $0 + rowHeight(forItem: $1) }
        let chrome =
            header.fittingHeight(width: PickerStyle.width) + PickerStyle.searchHeight
            + Self.listTopGap + Self.bottomGap
        let listHeight = max(min(list, PickerStyle.maximumListHeight), PickerStyle.minimumListHeight)
        let height = (chrome + listHeight).rounded(.up)
        guard height > preferredHeight else { return }
        preferredHeight = height
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: PickerStyle.width, height: preferredHeight)
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
        window.initialFirstResponder = searchField
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusSearchFieldOnce() }
        }
        focusSearchFieldOnce()
        // A request skipped before the view had a window is owed now.
        requestMoreIfNeeded()
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
    func returnFocusToSearchField() {
        guard searchField.currentEditor() == nil else { return }
        window?.makeFirstResponder(searchField)
        let end = searchField.stringValue.utf16.count
        searchField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    private func removeKeyObserver() {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    func tearDown() {
        queryLoadTimer?.invalidate()
        queryLoadTimer = nil
        removeKeyObserver()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        if let displayOptionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver) }
        displayOptionsObserver = nil
        teardownGeneration += 1
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss()
    }
}

/// Keys from the search field move the highlight and reveal it; Return and Escape act,
/// and so does a click on a row.
extension CommitPickerContainerView: PickerTableHandler {
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
        guard let activation = state.highlightedActivation else { return }
        perform(activation)
    }

    func activate(tableRow row: Int) {
        guard let activation = state.activation(forItem: row) else { return }
        perform(activation)
    }

    func cancel() {
        onDismiss()
    }

    func canHighlight(tableRow row: Int) -> Bool {
        state.canHighlight(item: row)
    }
}

/// The search field holds the keyboard; the arrows, Return and Escape reach the list.
extension CommitPickerContainerView: NSSearchFieldDelegate {
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
