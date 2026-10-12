import AppKit

/// The segmented control, the search field's placeholder, the list's fade under the
/// footer, and redrawing for the accessibility display options.
extension BranchPickerContainerView {
    /// How far above the footer the rows start to fade, so the glass has little left to hide.
    private static let footerFadeLength: CGFloat = 16

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
