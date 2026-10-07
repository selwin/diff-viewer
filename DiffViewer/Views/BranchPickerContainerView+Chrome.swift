import AppKit

/// The segmented control, the search field's placeholder, and redrawing for the
/// accessibility display options.
extension BranchPickerContainerView {
    func configureTabControl() {
        let segments = [("Switch", "arrow.left.arrow.right"), ("Merge", "arrow.triangle.merge")]
        tabControl.segmentCount = segments.count
        tabControl.trackingMode = .selectOne
        tabControl.controlSize = .small
        tabControl.segmentDistribution = .fillEqually
        tabControl.refusesFirstResponder = true
        for (index, (label, symbol)) in segments.enumerated() {
            tabControl.setLabel(label, forSegment: index)
            tabControl.setImage(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)), forSegment: index)
        }
        tabControl.target = self
        tabControl.action = #selector(tabControlChanged)
        tabControl.setAccessibilityLabel("Branch action")
    }

    @objc private func tabControlChanged() {
        selectTab(tabControl.selectedSegment == 1 ? .merge : .switchBranch)
        // A refused tab leaves the selection where the state is.
        tabControl.selectedSegment = state.tab == .merge ? 1 : 0
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
        newBranchRow.refreshRendering()
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
