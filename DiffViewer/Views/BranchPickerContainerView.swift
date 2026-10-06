import AppKit

/// The branch picker's AppKit root, laid out top-down by hand: the header, the Switch and
/// Merge… tabs, a sheet holding the instruction, search field and the branch table or its
/// empty state, and the New Branch… footer. Owns the `BranchPickerState` and applies each
/// snapshot, query and tab to the table as the state directs.
@MainActor
final class BranchPickerContainerView: NSView {
    /// The sheet's padding: the instruction and search field sit inside its sides, and the
    /// rows carry their own inset.
    private static let sheetTopPadding: CGFloat = 11
    private static let sheetSidePadding: CGFloat = 10
    private static let sheetBottomPadding: CGFloat = 6
    /// Between the instruction and the search field.
    private static let instructionGap: CGFloat = 9
    /// Between the search field and the first row.
    private static let listTopGap: CGFloat = 6

    private(set) var state: BranchPickerState

    var onActivate: (BranchActivation) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onPull: (String) -> Void = { _ in }
    var onPush: (String) -> Void = { _ in }
    /// Takes the branch, then the remote to publish it to.
    var onPublish: (String, String) -> Void = { _, _ in }
    /// Takes the branch as its row showed it, which the delete checks before it runs, and
    /// the popover's window for the confirmation to hang on.
    var onDelete: (LocalBranch, NSWindow?) -> Void = { _, _ in }
    /// The header's Fetch button and ⌘R.
    var onFetch: () -> Void = {}
    /// The New Branch… row, Return on it, and ⌘N.
    var onNewBranch: () -> Void = {}
    /// The tab the reader chose, or the one Merge fell back to; the window remembers it.
    var onTabChange: (BranchPickerTab) -> Void = { _ in }
    /// The clock the header's fetch time is read against.
    var now: @MainActor () -> Date = Date.init

    let header = BranchPickerHeaderView()
    let tabBar = BranchPickerTabBar(frame: .zero)
    private let sheet = BranchPickerSheetView(frame: .zero)
    private let instruction = BranchPickerInstructionView(frame: .zero)
    let searchField = FilledSearchField()
    /// The search field's rounded fill; the field itself draws no bezel.
    private let searchBackground = RoundedFillView(frame: .zero)
    let scrollView = NSScrollView()
    let tableView = PickerTableView()
    let emptyState = PickerEmptyStateView(frame: .zero)
    let newBranchRow = BranchPickerNewBranchRow(frame: .zero)

    /// Set while the container itself moves the table's selection, which the delegate
    /// must not read back as the reader's choice.
    var isApplyingSelection = false
    private var hasFocusedSearchField = false
    private var keyObserver: (any NSObjectProtocol)?
    private var scrollObserver: (any NSObjectProtocol)?
    /// Nil without a session, when Merge rows show no previews.
    let mergePreviews: MergePreviewLoader?
    var mergePreviewToken: MergePreviewLoader.ConsumerToken?
    /// Refreshes the header's fetch text so its relative time doesn't stay "just now".
    private var fetchTimeTimer: Timer?
    /// The height the popover asks for: the full list's, up to the maximum. It only grows
    /// while the popover is up, so neither a query nor a removed row makes it shrink.
    private(set) var preferredHeight: CGFloat = 0

    init(state: BranchPickerState, mergePreviews: MergePreviewLoader?) {
        self.state = state
        self.mergePreviews = mergePreviews
        super.init(frame: .zero)
        clipsToBounds = true
        configureSearchField()
        configureTable()
        for view in [header, tabBar, sheet, instruction, searchBackground, searchField, scrollView, emptyState] {
            addSubview(view)
        }
        addSubview(newBranchRow)
        configureHeader()
        tabBar.onSelect = { [weak self] tab in
            self?.selectTab(tab)
            self?.returnFocusToSearchField()
        }
        newBranchRow.onActivate = { [weak self] in self?.onNewBranch() }
        newBranchRow.onHighlightRequested = { [weak self] in
            guard let self, newBranchRow.isEnabled else { return }
            if self.state.highlightNewBranch() { syncSelection() }
        }
        fetchTimeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderFetchTime() }
        }
        registerForMergePreviews()
        renderChrome()
        renderInstruction()
        updatePreferredHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The header's buttons act on the current branch, and return focus like the rows' do.
    private func configureHeader() {
        header.onCopy = { [weak self] in self?.returnFocusToSearchField() }
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
        searchField.placeholderString = "Search branches"
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
        tableView.rowHeight = PickerMetrics.rowHeight
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
            MainActor.assumeIsolated {
                self?.tableView.refreshHover()
                self?.requestVisibleMergePreviews()
            }
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
        let tab = state.tab
        let oldKeys = mergePreviewKeysByRow()
        let change = state.apply(snapshot)
        // Merge falling back to Switch restyles every cell.
        let tabChanged = state.tab != tab
        var isAnimatingRows = false
        switch tabChanged ? .reloadAll : change.rows {
        case .none:
            break
        case let .update(removed, inserted, refreshed):
            if !removed.isEmpty || !inserted.isEmpty {
                animateRows(removed: removed, inserted: inserted)
                isAnimatingRows = true
            }
            if !refreshed.isEmpty {
                tableView.reloadData(forRowIndexes: refreshed, columnIndexes: [0])
            }
        case .reloadAll:
            tableView.cancelPress()
            tableView.reloadData()
        }
        isApplyingSelection = false
        // Before the restyle below, so a highlight that moved eases its pills in.
        syncSelection()
        // Reloaded cells configured their buttons already; the others are restyled here.
        if change.buttonsChanged {
            let visible = tableView.rows(in: tableView.visibleRect)
            updateRows(visible.lowerBound..<visible.upperBound, animated: false, shortcuts: state.shortcutTargets)
        }
        renderChrome()
        updatePreferredHeight()
        // Rows still sliding are re-read once they settle.
        if !isAnimatingRows { tableView.refreshHover() }
        reloadRowsWithChangedMergePreviewKeys(since: oldKeys)
        requestVisibleMergePreviews()
        if tabChanged { onTabChange(state.tab) }
    }

    /// Rows that go fade out as the rows below slide up over them; new rows fade in as the
    /// rows below make room. Reduce Motion snaps instead.
    private func animateRows(removed: IndexSet, inserted: IndexSet) {
        // A press in flight names a row by index, and the indices are about to shift.
        tableView.cancelPress()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            if reduceMotion { context.duration = 0 }
            // Fades only: a slide effect collapses the row's frame, and with it the cell's
            // content and selection fill, before the animation starts.
            let effect: NSTableView.AnimationOptions = reduceMotion ? [] : .effectFade
            tableView.beginUpdates()
            tableView.removeRows(at: removed, withAnimation: effect)
            tableView.insertRows(at: inserted, withAnimation: effect)
            tableView.endUpdates()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.tableView.refreshHover() }
        }
    }

    /// Moves the table's selection to the highlight without scrolling. The rows' colours
    /// and pills follow the highlight, and the shortcut glyphs follow the buttons the keys
    /// now press.
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
        newBranchRow.isHighlighted = state.isNewBranchHighlighted
        let shortcuts = state.shortcutTargets
        updateRows([previous, state.highlightedTableRow].compactMap { $0 }, animated: true, shortcuts: shortcuts)
        header.setShortcutGlyphs(pull: shortcuts.pull == .header, push: shortcuts.push == .header)
        renderInstruction()
    }

    private func renderInstruction() {
        instruction.configure(state.instruction)
    }

    // MARK: Tabs

    /// The query and highlight stay; every cell is reloaded, since what a row says and
    /// offers depends on the tab.
    func selectTab(_ tab: BranchPickerTab) {
        guard state.setTab(tab) else { return }
        isApplyingSelection = true
        tableView.cancelPress()
        tableView.reloadData()
        isApplyingSelection = false
        syncSelection()
        renderChrome()
        tableView.refreshHover()
        requestVisibleMergePreviews()
        onTabChange(state.tab)
    }

    // MARK: Query

    /// Typing and the clear button both send this.
    @objc private func queryChanged() {
        applyQuery()
    }

    /// Setting the text by hand sends no action, so the state is updated here too.
    func clearQuery() {
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
        // The best match is shown at the top; with no query, the list is back at the top.
        if state.query.isEmpty {
            revealHighlight()
        } else {
            tableView.scroll(.zero)
        }
        renderChrome()
        updatePreferredHeight()
        tableView.refreshHover()
        requestVisibleMergePreviews()
    }

    /// The timer's tick: only the fetch text ages, so nothing else is redrawn or laid out.
    private func renderFetchTime() {
        header.configureFetch(state.fetchText(now: now()))
    }

    private func renderChrome() {
        header.configure(state.headerText, fetch: state.fetchText(now: now()))
        let shortcuts = state.shortcutTargets
        header.setShortcutGlyphs(pull: shortcuts.pull == .header, push: shortcuts.push == .header)
        tabBar.configure(selected: state.tab, isMergeAvailable: state.isMergeAvailable)
        newBranchRow.isEnabled = !state.snapshot.isSwitchingBranch
        wireKeyViewLoop()
        switch state.emptyState {
        case nil: emptyState.configure(text: nil, isLoading: false)
        case .loading: emptyState.configure(text: "Loading…", isLoading: true)
        case .noBranches: emptyState.configure(text: "No branches", isLoading: false)
        case .failed: emptyState.configure(text: "Couldn't read branches", isLoading: false)
        case .noMatches: emptyState.configure(text: "No matching branches", isLoading: false)
        }
        needsLayout = true
    }

    // MARK: Highlight

    /// Moves the highlight to a row the pointer or a click chose, without scrolling.
    func highlight(tableRow row: Int) {
        state.highlight(tableRow: row)
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
        let height = bounds.height
        let headerHeight = header.fittingHeight(width: width)
        header.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        tabBar.frame = NSRect(x: 0, y: headerHeight, width: width, height: BranchPickerTabBar.height)
        let footerTop = height - BranchPickerNewBranchRow.height
        sheet.frame = NSRect(x: 0, y: tabBar.frame.maxY, width: width, height: max(footerTop - tabBar.frame.maxY, 0))
        let contentWidth = width - Self.sheetSidePadding * 2
        instruction.frame = NSRect(
            x: Self.sheetSidePadding, y: sheet.frame.minY + Self.sheetTopPadding, width: contentWidth,
            height: BranchPickerInstructionView.height)
        searchBackground.frame = NSRect(
            x: Self.sheetSidePadding, y: instruction.frame.maxY + Self.instructionGap, width: contentWidth,
            height: PickerMetrics.searchHeight)
        let fieldHeight = searchField.intrinsicContentSize.height
        searchField.frame = NSRect(
            x: searchBackground.frame.minX + 4, y: searchBackground.frame.midY - fieldHeight / 2,
            width: searchBackground.frame.width - 8, height: fieldHeight)
        let tableTop = searchBackground.frame.maxY + Self.listTopGap
        let tableBottom = footerTop - Self.sheetBottomPadding
        scrollView.frame = NSRect(x: 0, y: tableTop, width: width, height: max(tableBottom - tableTop, 0))
        emptyState.frame = scrollView.frame
        newBranchRow.frame = NSRect(x: 0, y: footerTop, width: width, height: BranchPickerNewBranchRow.height)
        tableView.sizeLastColumnToFit()
        // The first layout is when the visible rows are first known.
        requestVisibleMergePreviews()
    }

    /// Shows the highlighted row after keyboard navigation. The list opens at the top with
    /// nothing highlighted, so there is no initial reveal.
    private func revealHighlight() {
        // The list stays where it is: New Branch… sits below it.
        guard !state.isNewBranchHighlighted else { return }
        if let row = state.highlightedTableRow {
            tableView.scrollRowToVisible(row)
        } else {
            tableView.scroll(.zero)
        }
    }

    /// Recomputed from the unfiltered list only; SwiftUI reads it through `sizeThatFits`.
    /// It never shrinks while the popover is up: SwiftUI resizes a popover without
    /// animation, so a shorter list would snap the footer up over rows still fading out.
    private func updatePreferredHeight() {
        guard state.query.isEmpty else { return }
        let list = state.items.reduce(CGFloat(0)) { total, item in
            total + (item.row == nil ? PickerMetrics.headerRowHeight : PickerMetrics.rowHeight)
        }
        let chrome =
            header.fittingHeight(width: PickerMetrics.width) + BranchPickerTabBar.height + Self.sheetTopPadding
            + BranchPickerInstructionView.height + Self.instructionGap + PickerMetrics.searchHeight + Self.listTopGap
            + Self.sheetBottomPadding + BranchPickerNewBranchRow.height
        let height = min(chrome + max(list, PickerMetrics.emptyListHeight), PickerMetrics.maximumHeight).rounded(.up)
        guard height > preferredHeight else { return }
        preferredHeight = height
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: PickerMetrics.width, height: preferredHeight)
    }

    // MARK: Window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeKeyObserver()
        // SwiftUI dismantles the view lazily after a dismissal, but detaches it at once:
        // queued previews stop being wanted now, and running ones stay cached.
        requestVisibleMergePreviews()
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

    /// Search field → Copy → Fetch → Pull → Push → search field, over the header buttons
    /// that can act; AppKit skips buttons unless Full Keyboard Access is on. Set explicitly
    /// rather than recalculated, so the order doesn't depend on the popover window.
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
        // A confirmation still up would otherwise never answer once its popover is gone.
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        fetchTimeTimer?.invalidate()
        fetchTimeTimer = nil
        removeKeyObserver()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        if let mergePreviewToken { mergePreviews?.unregisterConsumer(mergePreviewToken) }
        mergePreviewToken = nil
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
        if state.isNewBranchHighlighted {
            // A disabled row does nothing, and never falls through to a branch.
            if newBranchRow.isEnabled { onNewBranch() }
            return
        }
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

/// Row highlight and buttons, outside the class body to keep it under the length lint.
extension BranchPickerContainerView {
    /// Sets `cell`'s highlight and its Pull and Push, Publish, or Delete from the current
    /// snapshot. The buttons show on the highlighted row, and wherever one runs, in the
    /// Switch tab only. `animated` lets an on-screen cell ease its pills in or out as the
    /// highlight moves. `shortcuts` decides which pills show their key.
    func configureHighlightAndButtons(
        of cell: BranchPickerRowView, row: Int, animated: Bool, shortcuts: SyncShortcutTargets
    ) {
        let isHighlighted = row == state.highlightedTableRow
        cell.isHighlighted = isHighlighted
        guard state.tab == .switchBranch, let buttons = state.syncButtons(forTableRow: row),
            let branch = state.branch(forTableRow: row)
        else {
            cell.syncButtons = nil
            cell.showSyncButtons(false, animated: false)
            return
        }
        let view = cell.syncButtons ?? BranchRowSyncButtons(style: .rowPills)
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
                self?.onDelete(branch, self?.window)
                self?.returnFocusToSearchField()
            })
        view.setShortcutGlyphs(pull: shortcuts.pull == .row(tableRow: row), push: shortcuts.push == .row(tableRow: row))
        cell.syncButtons = view
        cell.showSyncButtons(view.shouldShow, animated: animated)
    }

    /// Re-configures whichever of `rows` have a cell on screen.
    private func updateRows(_ rows: some Sequence<Int>, animated: Bool, shortcuts: SyncShortcutTargets) {
        for row in rows where row >= 0 && row < tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BranchPickerRowView
            else { continue }
            configureHighlightAndButtons(of: cell, row: row, animated: animated, shortcuts: shortcuts)
        }
    }
}
