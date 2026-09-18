import SwiftUI

/// The title bar's branch pop-up: the current branch on its face, every local branch in
/// its menu. Choosing one checks it out.
struct BranchPickerView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        // Capped for the same reason as the scope pill: a long branch name would otherwise
        // send every item after it into the overflow menu.
        CappedWidth(maximumWidth: 240) {
            branchMenu
        }
    }

    private var branchMenu: some View {
        Menu {
            if windowState.headState == nil {
                // No picker until HEAD has been read: a selection with no rows would be
                // an empty menu, and there is no failed-read state to tell apart.
                Text("Loading…")
            } else {
                Picker("Branch", selection: selection) {
                    // The selection always has a row, whatever the list says: the branch
                    // list and HEAD are separate reads, and an unborn branch or a stale
                    // list can leave the current name out. Without its row SwiftUI logs
                    // an invalid-selection warning and shows no tick.
                    if let current = windowState.currentBranchName, !windowState.localBranches.contains(current) {
                        Text(current).tag(String?.some(current))
                            .disabled(true)
                    }
                    if windowState.currentBranchName == nil {
                        Text(windowState.branchDisplayTitle).tag(String?.none)
                            .disabled(true)
                    }
                    ForEach(windowState.localBranches, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label(windowState.branchDisplayTitle, systemImage: "arrow.triangle.branch")
        }
        // The toolbar shows a menu's label as its icon alone unless told otherwise.
        .labelStyle(.titleAndIcon)
        .disabled(windowState.isSwitchingBranch || windowState.headState == nil)
        .help("Switch branch")
    }

    /// No local state: the face follows HEAD, and a switch that fails leaves it where git
    /// left it. The disabled rows can never be chosen, so a nil never reaches the setter.
    private var selection: Binding<String?> {
        Binding(
            get: { windowState.currentBranchName },
            set: { newValue in
                guard let name = newValue, name != windowState.currentBranchName else { return }
                Task { await windowState.switchBranch(to: name) }
            }
        )
    }
}

/// The title bar's scope pop-up: the same menu as the sidebar's `CommitPickerView`, with
/// a one-line face the toolbar can draw natively.
struct ScopePickerView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        // Capped so a long subject ellipsizes instead of pushing the toolbar's other
        // items into the overflow menu. On the menu, not its text: the toolbar draws the
        // face natively from the label's string and drops any modifier on the `Text`.
        CappedWidth(maximumWidth: 360) {
            Menu {
                ScopeMenuContent()
            } label: {
                Label(windowState.scopeDisplayTitle, systemImage: icon)
            }
            .labelStyle(.titleAndIcon)
            .help(help)
        }
    }

    private var icon: String {
        switch windowState.scope {
        case .workingTree: "folder"
        case .commit: "smallcircle.filled.circle"
        }
    }

    /// The whole subject, since the face may have cut it short.
    private var help: String {
        switch windowState.scope {
        case .workingTree: ScopeMenuContent.scopeSelectionHelp
        case .commit: windowState.scopeDisplayTitle
        }
    }
}

/// Caps the menu's reported ideal width so long labels can truncate instead of forcing
/// the toolbar item into overflow. Lays out exactly one child.
private struct CappedWidth: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        assert(subviews.count == 1)
        let width = min(proposal.width ?? maximumWidth, maximumWidth)
        let size = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        // Caps the ideal width, never the minimum: a menu squeezed below it would overlap its neighbour.
        let minimum = subviews[0].sizeThatFits(.zero).width
        return CGSize(width: max(min(size.width, width), minimum), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        assert(subviews.count == 1)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
