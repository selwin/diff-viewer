import AppKit
import SwiftUI

/// The branch picker popover, anchored to the title bar's branch button. Activating a
/// branch checks it out, or a remote one as a new tracking branch, and closes the
/// popover; so does New Branch…, which opens its sheet, and a Merge row, which opens the
/// Merge sheet. A click outside closes it too.
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
            tab: windowState.branchPickerTab,
            mergePreviews: windowState.session?.mergePreviews,
            onActivate: { activation in
                switch activation {
                case let .switchTo(name): Task { await windowState.switchBranch(to: name) }
                case let .checkoutTracking(branch): Task { await windowState.checkoutRemoteBranch(branch) }
                // Opening the sheet closes the popover itself.
                case let .merge(target):
                    windowState.openMergeSheetFromPicker(target)
                    return
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
            onNewBranch: { windowState.openNewBranchSheet(initialName: $0) },
            onTabChange: { windowState.branchPickerTab = $0 },
            now: windowState.now
        )
        // The height follows the list, through the representable's `sizeThatFits`.
        .frame(width: PickerStyle.width)
    }
}

/// Hands each snapshot to the container, whose state decides what changed.
struct BranchPickerListView: NSViewRepresentable {
    let snapshot: BranchPickerSnapshot
    let grouping: CommitDayGrouping
    /// The tab the popover opens on; later changes are the container's.
    let tab: BranchPickerTab
    /// Nil without a session: Merge rows then show no previews. Read once, like `tab`.
    let mergePreviews: MergePreviewLoader?
    let onActivate: (BranchActivation) -> Void
    let onDismiss: () -> Void
    let onPull: (String) -> Void
    let onPush: (String) -> Void
    let onPublish: (String, String) -> Void
    let onDelete: (LocalBranch, NSWindow?) -> Void
    let onFetch: () -> Void
    let onNewBranch: (String?) -> Void
    let onTabChange: (BranchPickerTab) -> Void
    let now: @MainActor () -> Date

    func makeNSView(context: Context) -> BranchPickerContainerView {
        let view = BranchPickerContainerView(
            state: BranchPickerState(snapshot: snapshot, grouping: grouping, tab: tab), mergePreviews: mergePreviews)
        setCallbacks(on: view)
        return view
    }

    func updateNSView(_ view: BranchPickerContainerView, context: Context) {
        setCallbacks(on: view)
        view.apply(snapshot)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BranchPickerContainerView, context: Context) -> CGSize? {
        CGSize(width: PickerStyle.width, height: nsView.preferredHeight)
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
        view.onTabChange = onTabChange
        view.now = now
    }
}
