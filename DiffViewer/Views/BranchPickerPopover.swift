import AppKit
import SwiftUI

/// The branch picker popover, anchored to the title bar's branch button. Activating a
/// branch checks it out, or a remote one as a new tracking branch, and closes the
/// popover; so does New Branch…, which opens its sheet. A click outside closes it too.
struct BranchPickerPopover: View {
    @Environment(WindowState.self) private var windowState
    /// For the window the delete confirmation hangs on.
    @Environment(AppServices.self) private var services
    /// Read once per presentation so "Today" does not shift while the popover is up.
    @State private var grouping = CommitDayGrouping()

    var body: some View {
        BranchPickerListView(
            snapshot: windowState.branchPickerSnapshot,
            grouping: grouping,
            onActivate: { activation in
                switch activation {
                case let .switchTo(name): Task { await windowState.switchBranch(to: name) }
                case let .checkoutTracking(branch): Task { await windowState.checkoutRemoteBranch(branch) }
                }
                windowState.isBranchPickerPresented = false
            },
            onDismiss: { windowState.isBranchPickerPresented = false },
            onPull: { name in Task { await windowState.pull(branch: name) } },
            onPush: { name in Task { await windowState.push(branch: name) } },
            onPublish: { name, remote in Task { await windowState.publish(branch: name, to: remote) } },
            onDelete: { branch, pickerWindow in
                Task {
                    // On the popover itself, so asking doesn't close it; the row goes once
                    // the delete's branch read lands.
                    let window = pickerWindow ?? services.windows[windowState.id]
                    guard await BranchDeleteConfirmation.confirm(branch, window: window) else { return }
                    await windowState.deleteBranch(branch)
                }
            },
            onFetch: { Task { await windowState.fetchAllRemotes() } },
            onNewBranch: { windowState.openNewBranchSheetFromPicker() },
            now: windowState.now
        )
        // The height follows the list, through the representable's `sizeThatFits`.
        .frame(width: PickerMetrics.width)
    }
}

/// Hands each snapshot to the container, whose state decides what changed.
struct BranchPickerListView: NSViewRepresentable {
    let snapshot: BranchPickerSnapshot
    let grouping: CommitDayGrouping
    let onActivate: (BranchActivation) -> Void
    let onDismiss: () -> Void
    let onPull: (String) -> Void
    let onPush: (String) -> Void
    let onPublish: (String, String) -> Void
    let onDelete: (LocalBranch, NSWindow?) -> Void
    let onFetch: () -> Void
    let onNewBranch: () -> Void
    let now: @MainActor () -> Date

    func makeNSView(context: Context) -> BranchPickerContainerView {
        let view = BranchPickerContainerView(state: BranchPickerState(snapshot: snapshot, grouping: grouping))
        setCallbacks(on: view)
        return view
    }

    func updateNSView(_ view: BranchPickerContainerView, context: Context) {
        setCallbacks(on: view)
        view.apply(snapshot)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BranchPickerContainerView, context: Context) -> CGSize? {
        CGSize(width: PickerMetrics.width, height: nsView.preferredHeight)
    }

    static func dismantleNSView(_ view: BranchPickerContainerView, coordinator: ()) {
        view.tearDown()
    }

    private func setCallbacks(on view: BranchPickerContainerView) {
        view.onActivate = onActivate
        view.onDismiss = onDismiss
        view.onPull = onPull
        view.onPush = onPush
        view.onPublish = onPublish
        view.onDelete = onDelete
        view.onFetch = onFetch
        view.onNewBranch = onNewBranch
        view.now = now
    }
}
