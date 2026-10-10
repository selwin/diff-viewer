import AppKit
import SwiftUI

/// The stash picker popover. Activating a stash shows it in the window and closes the
/// popover; a click outside closes it too. Pop and Drop… keep it open, as branch Delete does.
struct StashPickerPopover: View {
    @Environment(WindowState.self) private var windowState
    /// For the window the drop confirmation hangs on.
    @Environment(AppServices.self) private var services
    /// Read once per presentation so "Today" does not shift while the popover is up.
    @State private var grouping = CommitDayGrouping()

    var body: some View {
        StashPickerView(
            snapshot: windowState.stashPickerSnapshot,
            grouping: grouping,
            onActivate: { entry in windowState.selectStash(entry) },
            onDismiss: { windowState.isStashPickerPresented = false },
            onPop: { entry in Task { await windowState.popStash(entry) } },
            onDrop: { entry, pickerWindow in
                Task {
                    // On the popover itself, so asking doesn't close it; the row goes once
                    // the drop's stash read lands.
                    let window = pickerWindow ?? services.windows[windowState.id]
                    guard await StashDropConfirmation.confirm(entry, window: window) else { return }
                    await windowState.dropStash(entry)
                }
            }
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
    let onPop: (StashEntry) -> Void
    let onDrop: (StashEntry, NSWindow?) -> Void

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
        view.onPop = onPop
        view.onDrop = onDrop
    }
}
