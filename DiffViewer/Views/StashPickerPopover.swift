import AppKit
import SwiftUI

/// The stash picker popover. Activating a stash shows it in the window and closes the
/// popover; a click outside closes it too.
struct StashPickerPopover: View {
    @Environment(WindowState.self) private var windowState
    /// Read once per presentation so "Today" does not shift while the popover is up.
    @State private var grouping = CommitDayGrouping()

    var body: some View {
        StashPickerView(
            snapshot: windowState.stashPickerSnapshot,
            grouping: grouping,
            onActivate: { entry in windowState.selectStash(entry) },
            onDismiss: { windowState.isStashPickerPresented = false }
        )
        // The height follows the list, through the representable's `sizeThatFits`.
        .frame(width: PickerStyle.width)
    }
}

/// Hands each snapshot to the container, whose state decides what changed.
struct StashPickerView: NSViewRepresentable {
    let snapshot: StashPickerSnapshot
    let grouping: CommitDayGrouping
    let onActivate: (StashEntry) -> Void
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> StashPickerContainerView {
        let view = StashPickerContainerView(state: StashPickerState(snapshot: snapshot, grouping: grouping))
        setCallbacks(on: view)
        return view
    }

    func updateNSView(_ view: StashPickerContainerView, context: Context) {
        setCallbacks(on: view)
        view.apply(snapshot)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StashPickerContainerView, context: Context) -> CGSize? {
        CGSize(width: PickerStyle.width, height: nsView.preferredHeight)
    }

    static func dismantleNSView(_ view: StashPickerContainerView, coordinator: ()) {
        view.tearDown()
    }

    private func setCallbacks(on view: StashPickerContainerView) {
        view.onActivate = onActivate
        view.onDismiss = onDismiss
    }
}
