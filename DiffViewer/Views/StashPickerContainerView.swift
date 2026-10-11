import AppKit

/// The stash picker's AppKit root: header, search field and the list, laid out top-down
/// by hand on the popover's glass. Owns the `StashPickerState` and applies each snapshot
/// and query to the table as the state directs.
@MainActor
final class StashPickerContainerView: NSView {
    /// Between the search field and the first row.
    private static let listTopGap: CGFloat = 8
    /// Below the list, so the last row's highlight clears the popover's edge.
    private static let bottomGap: CGFloat = 8

    private(set) var state: StashPickerState

    var onActivate: (StashEntry) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onPop: (StashEntry) -> Void = { _ in }
    /// With the popover's window, for the confirmation sheet.
    var onDrop: (StashEntry, NSWindow?) -> Void = { _, _ in }

    let header = PickerHeaderView(wrapsTitle: false)
    let searchField = FilledSearchField()
    /// The search field's rounded fill; the field itself draws no bezel.
    let searchBackground = RoundedFillView(frame: .zero)
    let scrollView = NSScrollView()
    let tableView = PickerTableView()
    /// Over the list, for an empty list or a search with no match.
    private let emptyState = PickerEmptyStateView(frame: .zero)

    /// Set while the container itself moves the table's selection, which the delegate
    /// must not read back as the reader's choice.
    var isApplyingSelection = false
    private var hasRevealedHighlight = false
    private var hasFocusedSearchField = false
    private var keyObserver: (any NSObjectProtocol)?
    private var scrollObserver: (any NSObjectProtocol)?
    var displayOptionsObserver: (any NSObjectProtocol)?
    /// The height the popover asks for: the full list's, up to the maximum. It only grows
    /// while the popover is up, so neither a query nor a removed row makes it shrink.
    private(set) var preferredHeight: CGFloat = 0

    init(state: StashPickerState) {
        self.state = state
        super.init(frame: .zero)
        clipsToBounds = true
        configureSearchField()
        configureTable()
        for view in [header, searchBackground, searchField, scrollView, emptyState] { addSubview(view) }
        observeDisplayOptions()
        renderChrome()
        updatePreferredHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureSearchField() {
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search stashes",
            attributes: [
                .font: searchField.font ?? .systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: PickerStyle.placeholder,
            ])
        searchField.setAccessibilityLabel("Search stashes")
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(queryChanged)
        searchField.delegate = self
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("stash"))
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
        // The search field keeps the keyboard; a click on a row must not take it.
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
            MainActor.assumeIsolated { self?.tableView.refreshHover() }
        }
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { false }

    // MARK: Snapshots

    /// An unchanged snapshot is skipped.
    func apply(_ snapshot: StashPickerSnapshot) {
        guard snapshot != state.snapshot else { return }
        let buttonsChanged =
            snapshot.activeOperation != state.snapshot.activeOperation
            || snapshot.actionsBlockedReason != state.snapshot.actionsBlockedReason
        // A reload can move or drop the table's selection; none of that is the reader's.
        isApplyingSelection = true
        applyTableChange(state.apply(snapshot))
        isApplyingSelection = false
        let synced = syncSelection()
        // Reloaded cells configured their buttons already, and the selection sync updated
        // its rows; the others are updated here.
        if buttonsChanged {
            let visible = tableView.rows(in: tableView.visibleRect)
            updateRows((visible.lowerBound..<visible.upperBound).filter { !synced.contains($0) })
        }
        renderChrome()
        updatePreferredHeight()
        // Rows that arrive after the first layout get the initial reveal here: layout
        // may not run again.
        revealInitialHighlightIfReady()
        tableView.refreshHover()
    }

    private func applyTableChange(_ change: StashPickerTableChange) {
        switch change {
        case .none:
            break
        case .reloadAll:
            tableView.cancelPress()
            tableView.reloadData()
        }
    }

    /// Moves the table's selection to the highlight without scrolling. The pills follow it.
    /// Returns the rows it re-configured.
    @discardableResult
    func syncSelection() -> Set<Int> {
        let wasApplying = isApplyingSelection
        isApplyingSelection = true
        defer { isApplyingSelection = wasApplying }
        let previous = tableView.selectedRow
        if let row = state.highlightedItemIndex {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        let changed = Set([previous, state.highlightedItemIndex].compactMap { $0 })
        updateRows(changed)
        return changed
    }

    /// Sets `cell`'s pills from the current snapshot and highlight.
    func configureButtons(of cell: StashPickerRowView, row: Int) {
        guard let stashRow = state.items[row].stashRow else { return }
        cell.configure(
            stashRow, buttons: state.buttons(forItem: row), isHighlighted: row == state.highlightedItemIndex)
    }

    /// Re-configures whichever of `rows` have a cell on screen.
    private func updateRows(_ rows: some Sequence<Int>) {
        for row in rows where row >= 0 && row < tableView.numberOfRows && row < state.items.count {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? StashPickerRowView
            else { continue }
            configureButtons(of: cell, row: row)
        }
    }

    /// Header and empty text both follow the snapshot and the query, so every change re-reads them.
    private func renderChrome() {
        let headerText = state.headerText
        header.title = headerText.title
        header.subtitle = headerText.subtitle
        emptyState.configure(text: state.emptyText, isLoading: false)
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

    /// The one path from the field's text to the table.
    private func applyQuery() {
        let change = state.setQuery(searchField.stringValue)
        guard change != .none else { return }
        isApplyingSelection = true
        applyTableChange(change)
        isApplyingSelection = false
        syncSelection()
        renderChrome()
        // The best match is shown at the top; with no query, the displayed stash as on open.
        if state.query.isEmpty { revealHighlight() } else { tableView.scroll(.zero) }
        updatePreferredHeight()
        tableView.refreshHover()
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
        emptyState.frame = scrollView.frame
        tableView.sizeLastColumnToFit()
        // The table only knows its rows once it has laid out, so the initial highlight
        // is selected here rather than in `init`.
        revealInitialHighlightIfReady()
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
        case .stash: PickerStyle.rowHeight
        }
    }

    /// Recomputed from the unfiltered list only; SwiftUI reads it through `sizeThatFits`.
    /// It never shrinks while the popover is up: SwiftUI resizes a popover without
    /// animation. An empty list still keeps room for its message.
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
        removeKeyObserver()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        if let displayOptionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver) }
        displayOptionsObserver = nil
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss()
    }
}

/// Keys from the search field move the highlight and reveal it; Return and Escape act,
/// and so does a click on a row.
extension StashPickerContainerView: PickerTableHandler {
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
        guard let entry = state.highlightedActivation else { return }
        onActivate(entry)
    }

    func activate(tableRow row: Int) {
        guard let entry = state.activation(forItem: row) else { return }
        onActivate(entry)
    }

    func cancel() {
        onDismiss()
    }

    func canHighlight(tableRow row: Int) -> Bool {
        state.canHighlight(item: row)
    }
}

/// The search field holds the keyboard; the arrows, Return and Escape reach the list.
extension StashPickerContainerView: NSSearchFieldDelegate {
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
