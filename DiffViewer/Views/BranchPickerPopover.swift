import AppKit
import SwiftUI

/// The branch picker popover, anchored to the title bar's branch button. Activating a
/// branch checks it out and closes the popover; a click outside closes it too.
struct BranchPickerPopover: View {
    @Environment(WindowState.self) private var windowState
    /// Read once per presentation so "Today" does not shift while the popover is up.
    @State private var grouping = CommitDayGrouping()

    var body: some View {
        BranchPickerListView(
            snapshot: windowState.branchPickerSnapshot,
            grouping: grouping,
            onActivate: { name in
                Task { await windowState.switchBranch(to: name) }
                windowState.isBranchPickerPresented = false
            },
            onDismiss: { windowState.isBranchPickerPresented = false },
            onPull: { name in Task { await windowState.pull(branch: name) } },
            onPush: { name in Task { await windowState.push(branch: name) } }
        )
        .frame(width: 560, height: 520)
    }
}

/// Hands each snapshot to the container, whose state decides what changed.
struct BranchPickerListView: NSViewRepresentable {
    let snapshot: BranchPickerSnapshot
    let grouping: CommitDayGrouping
    let onActivate: (String) -> Void
    let onDismiss: () -> Void
    let onPull: (String) -> Void
    let onPush: (String) -> Void

    func makeNSView(context: Context) -> BranchPickerContainerView {
        let view = BranchPickerContainerView(state: BranchPickerState(snapshot: snapshot, grouping: grouping))
        setCallbacks(on: view)
        return view
    }

    func updateNSView(_ view: BranchPickerContainerView, context: Context) {
        setCallbacks(on: view)
        view.apply(snapshot)
    }

    static func dismantleNSView(_ view: BranchPickerContainerView, coordinator: ()) {
        view.tearDown()
    }

    private func setCallbacks(on view: BranchPickerContainerView) {
        view.onActivate = onActivate
        view.onDismiss = onDismiss
        view.onPull = onPull
        view.onPush = onPush
    }
}
