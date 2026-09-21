import SwiftUI

/// The title bar's branch pop-up: the current branch on its face, every local branch in
/// its menu. Choosing one checks it out.
struct BranchPickerView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        // Capped for the same reason as the scope picker: a long branch name would
        // otherwise send every item after it into the overflow menu.
        // Allows extra width for the tracking counts after the branch name.
        CappedWidth(maximumWidth: 300) {
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
            TitleBarPickerLabel(
                icon: .gitBranch,
                title: windowState.branchDisplayTitle,
                subtitle: windowState.branchTrackingSummary)
        }
        // The button menu style is what lets the plain button style below apply: the
        // default style draws its own hover capsule behind the label's outlined box.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(windowState.isSwitchingBranch || windowState.headState == nil)
        .help(windowState.branchSwitchHelp)
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

/// The title bar's scope button: what the sidebar shows, the working tree or one commit.
/// Opens the commit picker popover, which ⌘K also opens here by setting the same flag.
struct ScopePickerView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        @Bindable var windowState = windowState
        // Capped so a long subject ellipsizes instead of pushing the toolbar's other
        // items into the overflow menu.
        CappedWidth(maximumWidth: 360) {
            Button {
                windowState.isCommitPickerPresented = true
            } label: {
                TitleBarPickerLabel(icon: .gitCommit, title: windowState.scopeDisplayTitle)
            }
            .buttonStyle(.plain)
            .disabled(!windowState.canOpenCommitPicker)
            .help(help)
            .popover(isPresented: $windowState.isCommitPickerPresented, arrowEdge: .bottom) {
                CommitPickerPopover()
            }
        }
    }

    /// The whole subject, since the face may have cut it short.
    private var help: String {
        switch windowState.scope {
        case .workingTree: WindowState.scopeSelectionHelp
        case .commit: windowState.scopeDisplayTitle
        }
    }
}

/// The face both title bar pickers wear: an outlined one-line box at toolbar control
/// height with no fill, so it sits flat on the title bar. Plain data in, so it does not depend on
/// `WindowState`.
private struct TitleBarPickerLabel: View {
    let icon: ImageResource
    let title: String
    /// Follows the title after a separator, in secondary colour. Nil draws nothing.
    var subtitle: String?

    // A plain-style menu or button draws no disabled state of its own, so the face dims itself.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 6) {
            // A fixed frame, because a `Menu` and a `Button` scale their labels differently
            // and a template image takes no font: pinning it keeps both faces matching the chevron.
            Image(icon)
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            if let subtitle {
                // Its own element, so the stack's spacing pads the dot evenly on both sides.
                Text("·")
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    // Keeps the counts whole: a long title ellipsizes in front of them.
                    .layoutPriority(1)
            }
            // Small, medium-weight chevrons match a native pop-up button's indicator.
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .medium))
                .imageScale(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        // The whole box opens the picker, not only the text.
        .contentShape(Rectangle())
    }
}

/// Caps the picker's reported ideal width so long labels can truncate instead of forcing
/// the toolbar item into overflow. Lays out exactly one child.
private struct CappedWidth: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        assert(subviews.count == 1)
        // The ideal width, not the proposed one: the toolbar proposes the width it measured
        // last time, so honouring it would freeze the item at the size of its old label.
        let ideal = subviews[0].sizeThatFits(ProposedViewSize(width: nil, height: proposal.height))
        // Caps the ideal width, never the minimum: a picker squeezed below it would overlap its neighbour.
        let minimum = subviews[0].sizeThatFits(.zero).width
        return CGSize(width: max(min(ideal.width, maximumWidth), minimum), height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        assert(subviews.count == 1)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
