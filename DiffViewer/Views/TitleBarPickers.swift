import SwiftUI

/// The title bar's branch pill: the current branch, which opens the branch picker, then
/// Pull and Push segments when there is something to sync. ⌘B opens the same popover by
/// setting the same flag.
struct BranchPickerView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        @Bindable var windowState = windowState
        let sync = windowState.currentBranchSync
        let showsSegments = sync?.showsSegments ?? false
        HStack(spacing: 0) {
            // Capped like the scope picker, so a long branch name can't push the toolbar's
            // other items into overflow. Only the name part is capped: the name keeps the
            // same room with or without segments, and they add their own width.
            CappedWidth(maximumWidth: 300) {
                Button {
                    windowState.isBranchPickerPresented = true
                } label: {
                    TitleBarPickerContent(icon: .gitBranch, title: windowState.branchDisplayTitle)
                        .padding(.leading, 14)
                        .padding(.trailing, showsSegments ? 10 : 14)
                        .frame(height: 36)
                        .modifier(PillPartHover())
                }
                .buttonStyle(.plain)
                .disabled(!windowState.canOpenBranchPicker)
                .help(windowState.branchSwitchHelp)
                .popover(isPresented: $windowState.isBranchPickerPresented, arrowEdge: .bottom) {
                    BranchPickerPopover()
                }
            }
            if let sync, showsSegments {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 18)
                BranchSyncSegments(sync: sync)
                    .fixedSize()
                    // Disabled while another sheet or picker is up, like the branch button.
                    .disabled(!windowState.canOpenBranchPicker)
            }
        }
        .background(TitleBarCapsule(isOpen: windowState.isBranchPickerPresented))
        // Clips each part's hover tint to the round ends.
        .clipShape(Capsule())
    }
}

/// The pill's Pull, then Push or Publish, each shown only when the sync rules say so.
private struct BranchSyncSegments: View {
    @Environment(WindowState.self) private var windowState
    let sync: CurrentBranchSyncPresentation

    var body: some View {
        let showsPush = sync.buttons.push != .hidden
        HStack(spacing: 0) {
            if sync.buttons.pull != .hidden {
                segment(
                    arrow: "arrow.down", count: sync.pullCount, title: "Pull", state: sync.buttons.pull,
                    label: sync.pullAccessibilityLabel, isLast: !showsPush
                ) {
                    let branch = sync.branch
                    Task { await windowState.pull(branch: branch) }
                }
                .id(SegmentID(branch: sync.branch, operation: .pull))
            }
            if showsPush {
                pushSegment
                    .id(SegmentID(branch: sync.branch, operation: sync.buttons.pushOperation))
            }
        }
    }

    @ViewBuilder
    private var pushSegment: some View {
        let branch = sync.branch
        if case let .menu(items)? = sync.buttons.publish {
            Menu {
                ForEach(items, id: \.remote) { item in
                    Button(item.remote) {
                        Task { await windowState.publish(branch: branch, to: item.remote) }
                    }
                    .disabled(!item.isEnabled)
                }
            } label: {
                SyncSegmentLabel(
                    arrow: "arrow.up", count: nil, title: sync.buttons.pushTitle, state: sync.buttons.push,
                    isLast: true)
            }
            // `.button` lets `.plain` strip the menu's own bezel, so it looks like the Push segment.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .modifier(SegmentAvailability(state: sync.buttons.push, label: sync.pushAccessibilityLabel))
        } else {
            segment(
                arrow: "arrow.up", count: sync.pushCount, title: sync.buttons.pushTitle, state: sync.buttons.push,
                label: sync.pushAccessibilityLabel, isLast: true
            ) {
                switch sync.buttons.publish {
                case let .remote(remote)?: Task { await windowState.publish(branch: branch, to: remote) }
                case .menu?: break
                case nil: Task { await windowState.push(branch: branch) }
                }
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func segment(
        arrow: String, count: Int?, title: String, state: PickerButtonState, label: String, isLast: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            SyncSegmentLabel(arrow: arrow, count: count, title: title, state: state, isLast: isLast)
        }
        .buttonStyle(.plain)
        .modifier(SegmentAvailability(state: state, label: label))
    }
}

/// A segment's identity. A new branch or operation starts a fresh label, so a count
/// kept for one never shows on another.
private struct SegmentID: Hashable {
    let branch: String
    let operation: SyncOperation
}

/// One segment's face: the arrow and action in the accent colour, then the count in
/// secondary colour when there is one. A running segment covers the arrow and
/// action with a spinner, as the picker's own buttons do, so the pill keeps its width.
private struct SyncSegmentLabel: View {
    let arrow: String
    let count: Int?
    let title: String
    let state: PickerButtonState
    /// The last segment pads its end so the title clears the capsule's round end.
    let isLast: Bool

    /// The count from before the click: the refresh behind the spinner may clear `count`.
    @State private var lastCount: Int?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let isRunning = state == .running
        HStack(spacing: 2) {
            HStack(spacing: 2) {
                Image(systemName: arrow)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .fontWeight(.medium)
            }
            .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            // Centred by its line box, the text reads low against the icons; lift it to the
            // eye, and the arrow with it so the two line up.
            .offset(y: -1)
            .opacity(isRunning ? 0 : 1)
            .overlay {
                if isRunning { ProgressView().controlSize(.small) }
            }
            if let shown = count ?? (isRunning ? lastCount : nil) {
                Text("\(shown)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // Lifted like the title, so the two share a baseline.
                    .offset(y: -1)
            }
        }
        .onChange(of: count, initial: true) { _, new in
            if let new { lastCount = new }
        }
        .lineLimit(1)
        .padding(.leading, 10)
        .padding(.trailing, isLast ? 14 : 10)
        .frame(height: 36)
        .modifier(PillPartHover())
    }
}

/// A segment's enabled state, tooltip and spoken label. Only an enabled segment takes
/// clicks and focus; a disabled one says why on hover and to VoiceOver.
private struct SegmentAvailability: ViewModifier {
    let state: PickerButtonState
    let label: String

    func body(content: Content) -> some View {
        let reason: String? = if case let .disabled(reason) = state { reason } else { nil }
        content
            .disabled(state != .enabled)
            .help(reason ?? "")
            .accessibilityLabel(label)
            .accessibilityHint(reason ?? "")
    }
}

/// Tints one part of the pill on hover, so it is clear which part a click hits.
private struct PillPartHover: ViewModifier {
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .background {
                if isHovering && isEnabled { Rectangle().fill(.quinary) }
            }
            // The whole part takes the click, not only the text.
            .contentShape(Rectangle())
            // Not `onHover`: in a toolbar item that makes AppKit draw its own bezel at rest.
            .onContinuousHover { phase in
                let hovering = if case .active = phase { true } else { false }
                // Only on a change, so moving the pointer doesn't invalidate the view.
                if hovering != isHovering { isHovering = hovering }
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

/// The scope picker's face: a one-line outlined capsule at toolbar control height, tinted
/// on hover and filled grey while its popover is open. Plain data in, so it does not
/// depend on `WindowState`.
private struct TitleBarPickerLabel: View {
    let icon: ImageResource
    let title: String
    /// Whether the picker's popover is showing.
    var isOpen = false

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        TitleBarPickerContent(icon: icon, title: title)
            // Wider than the height needs, so the text clears the capsule's round ends.
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(TitleBarCapsule(isOpen: isOpen, isHovering: isHovering && isEnabled))
            // The whole capsule opens the picker, not only the text.
            .contentShape(Rectangle())
            // Not `onHover`: in a toolbar item that makes AppKit draw its own bezel at rest.
            .onContinuousHover { phase in
                if case .active = phase { isHovering = true } else { isHovering = false }
            }
    }
}

/// What both title bar pickers show inside their capsule: an icon, the title and a chevron.
private struct TitleBarPickerContent: View {
    let icon: ImageResource
    let title: String

    // A plain-style button draws no disabled state of its own, so the face dims itself.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 6) {
            // A fixed frame, because a template image takes no font: pinning it keeps the
            // icon matching the chevron.
            Image(icon)
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundStyle(.secondary)
            Text(title)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                // Centred by its line box, the text reads low against the icons; lift it to the eye.
                .offset(y: -1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// The title bar pickers' outlined capsule: tinted on hover, filled grey while a popover is open.
private struct TitleBarCapsule: View {
    var isOpen = false
    var isHovering = false

    var body: some View {
        if isOpen {
            Capsule().fill(.quaternary)
        } else {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    if isHovering { Capsule().fill(.quinary) }
                }
                .overlay(Capsule().strokeBorder(.separator))
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
