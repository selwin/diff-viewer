import SwiftUI

/// The title bar's branch button: the current branch and how far it is from its
/// upstream. Opens the branch picker popover, which ⌘B also opens here by setting the
/// same flag.
struct BranchPickerView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        @Bindable var windowState = windowState
        // Capped for the same reason as the scope picker: a long branch name would
        // otherwise push the toolbar's other items into the overflow menu.
        // Allows extra width for the tracking counts after the branch name.
        CappedWidth(maximumWidth: 300) {
            Button {
                windowState.isBranchPickerPresented = true
            } label: {
                TitleBarPickerLabel(
                    icon: .gitBranch,
                    title: windowState.branchDisplayTitle,
                    subtitle: windowState.branchTrackingSummary,
                    isOpen: windowState.isBranchPickerPresented)
            }
            .buttonStyle(.plain)
            .disabled(!windowState.canOpenBranchPicker)
            .help(windowState.branchSwitchHelp)
            .popover(isPresented: $windowState.isBranchPickerPresented, arrowEdge: .bottom) {
                BranchPickerPopover()
            }
        }
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
                TitleBarPickerLabel(
                    icon: .gitCommit,
                    title: windowState.scopeDisplayTitle,
                    isOpen: windowState.isCommitPickerPresented)
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

/// The face both title bar pickers wear: a one-line outlined capsule at toolbar control
/// height, tinted on hover and filled grey while its popover is open. Plain data in, so it
/// does not depend on `WindowState`.
private struct TitleBarPickerLabel: View {
    let icon: ImageResource
    let title: String
    /// Follows the title after a separator, in secondary colour. Nil draws nothing.
    var subtitle: String?
    /// Whether the picker's popover is showing.
    var isOpen = false

    @State private var isHovering = false
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
            HStack(spacing: 6) {
                Text(title)
                    .fontWeight(.medium)
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
            }
            // Centred by its line box, the text reads low against the icons; lift it to the eye.
            .offset(y: -1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        // Wider than the height needs, so the text clears the capsule's round ends.
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background {
            if isOpen {
                Capsule().fill(.quaternary)
            } else {
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        if isHovering && isEnabled { Capsule().fill(.quinary) }
                    }
                    .overlay(Capsule().strokeBorder(.separator))
            }
        }
        // The whole capsule opens the picker, not only the text.
        .contentShape(Rectangle())
        // Not `onHover`: in a toolbar item that makes AppKit draw its own bezel at rest.
        .onContinuousHover { phase in
            if case .active = phase { isHovering = true } else { isHovering = false }
        }
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
