import AppKit

/// The Switch/Merge tabs, the search field's placeholder, the list's fade under the
/// footer, and redrawing for the accessibility display options.
extension BranchPickerContainerView {
    /// How far above the footer the rows start to fade, so the glass has little left to hide.
    private static let footerFadeLength: CGFloat = 16

    func configureTabControl() {
        tabControl.onSelect = { [weak self] index in self?.tabControlChanged(index) }
        tabControl.setAccessibilityLabel("Branch action")
    }

    func configureListFade() {
        scrollView.wantsLayer = true
        // AppKit flips the layer to match this flipped container, so y = 0 is the list's top.
        listFadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        listFadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        listFadeMask.colors = [
            NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor,
        ]
        scrollView.layer?.mask = listFadeMask
    }

    /// Opaque down to just above the capsule, clear by its middle.
    func updateListFadeMask(footerTop: CGFloat) {
        let listHeight = scrollView.frame.height
        let capsuleTop = footerTop - scrollView.frame.minY
        let clearAt = capsuleTop + PickerStyle.footerHeight / 2
        func fraction(_ y: CGFloat) -> Double {
            listHeight > 0 ? Double(min(max(y / listHeight, 0), 1)) : 0
        }
        let fadeStart = fraction(capsuleTop - Self.footerFadeLength)
        let fadeEnd = fraction(clearAt)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        listFadeMask.frame = scrollView.bounds
        listFadeMask.locations = [0, fadeStart, max(fadeEnd, fadeStart), 1].map { NSNumber(value: $0) }
        CATransaction.commit()
    }

    private func tabControlChanged(_ index: Int) {
        selectTab(index == 1 ? .merge : .switchBranch)
        // A refused tab leaves the selection where the state is.
        tabControl.selectedTabIndex = state.tab == .merge ? 1 : 0
        returnFocusToSearchField()
    }

    /// Accessibility display options change how the raised fills and highlight draw; the
    /// views redraw in place, with no reload.
    func observeDisplayOptions() {
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRendering() }
        }
    }

    private func refreshRendering() {
        header.refreshRendering()
        tabControl.refreshRendering()
        newBranchRow.refreshRendering()
        compareRow.refreshRendering()
        searchBackground.needsDisplay = true
        tableView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
            (rowView.view(atColumn: 0) as? BranchPickerRowView)?.refreshRendering()
        }
    }

    /// Merge names the branch the merge goes into.
    func renderPlaceholder() {
        var text = "Search branches"
        if state.tab == .merge, let branch = state.headerText.branch { text = "Merge into \(branch)…" }
        guard searchField.placeholderAttributedString?.string != text else { return }
        searchField.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [
                .font: searchField.font ?? .systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: PickerStyle.placeholder,
            ])
    }
}
