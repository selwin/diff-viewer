import AppKit
import SwiftUI

/// The commit picker popover, anchored to the title bar's scope button. Activating a
/// scope selects it in the window and closes the popover; a click outside closes it too.
struct CommitPickerPopover: View {
    @Environment(WindowState.self) private var windowState
    /// Read once per presentation so "Today" does not shift while the popover is up.
    @State private var grouping = CommitDayGrouping()

    var body: some View {
        CommitPickerView(
            snapshot: windowState.commitPickerSnapshot,
            grouping: grouping,
            onActivate: { scope in
                windowState.select(scope: scope)
                windowState.isCommitPickerPresented = false
            },
            onDismiss: { windowState.isCommitPickerPresented = false },
            onLoadMore: {
                guard windowState.isCommitPickerPresented, !windowState.isLoadingHistory,
                    windowState.historyErrorMessage == nil
                else { return }
                windowState.loadMoreCommits()
            },
            onRetry: {
                guard windowState.isCommitPickerPresented else { return }
                windowState.retryHistoryLoad()
            }
        )
        .frame(width: 560, height: 520)
    }
}

/// Hands each snapshot to the container, whose state decides what changed.
struct CommitPickerView: NSViewRepresentable {
    let snapshot: CommitPickerSnapshot
    let grouping: CommitDayGrouping
    let onActivate: (DiffScope) -> Void
    let onDismiss: () -> Void
    let onLoadMore: () -> Void
    let onRetry: () -> Void

    func makeNSView(context: Context) -> CommitPickerContainerView {
        let view = CommitPickerContainerView(state: CommitPickerState(snapshot: snapshot, grouping: grouping))
        setCallbacks(on: view)
        return view
    }

    func updateNSView(_ view: CommitPickerContainerView, context: Context) {
        setCallbacks(on: view)
        view.apply(snapshot)
    }

    static func dismantleNSView(_ view: CommitPickerContainerView, coordinator: ()) {
        view.tearDown()
    }

    private func setCallbacks(on view: CommitPickerContainerView) {
        view.onActivate = onActivate
        view.onDismiss = onDismiss
        view.onLoadMore = onLoadMore
        view.onRetry = onRetry
    }
}
