import AppKit

/// Redrawing for the accessibility display options.
extension StashPickerContainerView {
    /// Accessibility display options change how the search fill, the highlight and the
    /// tiles draw; the views redraw in place, with no reload.
    func observeDisplayOptions() {
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRendering() }
        }
    }

    private func refreshRendering() {
        searchBackground.needsDisplay = true
        tableView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
            (rowView.view(atColumn: 0) as? StashPickerRowView)?.refreshRendering()
        }
    }
}
