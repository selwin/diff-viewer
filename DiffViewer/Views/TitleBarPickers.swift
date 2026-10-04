import SwiftUI

/// The title bar's branch pill: the current branch, which opens the branch picker, then
/// Pull and Push segments when there is something to sync. ⌘B opens the same popover by
/// setting the same flag.
struct BranchPickerView: View {
    @Environment(WindowState.self) private var windowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBranchTinted = false
    @State private var isLeadingSegmentTinted = false
    /// Segments that just went hidden, still drawn while they collapse.
    @State private var departure: SegmentDeparture?
    /// How far the departing segments have collapsed, 0 to 1.
    @State private var departureProgress = 0.0

    /// How long a departing segment takes to collapse.
    static let collapseDuration = Duration.milliseconds(250)

    var body: some View {
        @Bindable var windowState = windowState
        let live = windowState.currentBranchSync
        let sync = live.map { departure?.applied(to: $0) ?? $0 }
        let showsSegments = sync?.showsSegments ?? false
        // Eased, so the collapse starts and ends gently.
        let remaining = 1 - departureProgress * departureProgress * (3 - 2 * departureProgress)
        // Every segment is leaving, so the divider goes with them.
        let tailDeparts = departure != nil && !(live?.showsSegments ?? false)
        // Otherwise one segment leaves on its own, and the other stays.
        let departsPull = !tailDeparts && live.map { departure?.departsPull(in: $0) ?? false } ?? false
        let departsPush = !tailDeparts && live.map { departure?.departsPush(in: $0) ?? false } ?? false
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
                        .padding(.trailing, showsSegments ? 14 - 4 * (tailDeparts ? remaining : 1) : 14)
                        .frame(height: 36)
                        .modifier(PillPartHover { isBranchTinted = $0 })
                }
                .buttonStyle(.plain)
                .disabled(!windowState.canOpenBranchPicker)
                .help(windowState.branchSwitchHelp)
                .popover(isPresented: $windowState.isBranchPickerPresented, arrowEdge: .bottom) {
                    BranchPickerPopover()
                }
            }
            if let sync, showsSegments {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1, height: 18)
                        // Steps aside for a tinted neighbour, like a native segmented control's
                        // separator. Opacity, not removal, so the pill's width doesn't change.
                        .opacity(isBranchTinted || isLeadingSegmentTinted ? 0 : 1)
                    BranchSyncSegments(
                        sync: sync,
                        pullWidth: departsPull ? remaining : 1,
                        pushWidth: departsPush ? remaining : 1,
                        onLeadingTintChange: { isLeadingSegmentTinted = $0 }
                    )
                    .fixedSize()
                    // Disabled while another sheet or picker is up, like the branch button.
                    .disabled(!windowState.canOpenBranchPicker)
                }
                .modifier(Collapsing(width: tailDeparts ? remaining : 1))
            }
        }
        .background(TitleBarCapsule(isOpen: windowState.isBranchPickerPresented))
        // Clips each part's hover tint to the round ends.
        .clipShape(Capsule())
        .onChange(of: live) { old, new in
            if !reduceMotion, let next = SegmentDeparture.between(old, new) {
                departure = next
                departureProgress = 0
            } else if new?.branch != departure?.previous.branch {
                departure = nil
            }
        }
        .task(id: departure) {
            guard departure != nil else { return }
            // Stepped by hand rather than animated: the toolbar sizes its item from the
            // pill's actual width, so only real width changes move the neighbours with it.
            let start = ContinuousClock.now
            while !Task.isCancelled {
                let progress = (ContinuousClock.now - start) / Self.collapseDuration
                if progress >= 1 { break }
                departureProgress = progress
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard !Task.isCancelled else { return }
            departure = nil
            departureProgress = 0
        }
    }
}

/// The pill's Pull, then Push or Publish, each shown only when the sync rules say so.
private struct BranchSyncSegments: View {
    @Environment(WindowState.self) private var windowState
    let sync: CurrentBranchSyncPresentation
    /// The fraction of its width each segment takes: below 1 while it collapses.
    let pullWidth: Double
    let pushWidth: Double
    let onLeadingTintChange: (Bool) -> Void

    var body: some View {
        let showsPull = sync.buttons.pull != .hidden
        let showsPush = sync.buttons.push != .hidden
        HStack(spacing: 0) {
            if showsPull {
                segment(
                    arrow: "arrow.down", count: sync.pullCount, title: "Pull", state: sync.buttons.pull,
                    label: sync.pullAccessibilityLabel, isLast: !showsPush,
                    onTintChange: onLeadingTintChange
                ) {
                    let branch = sync.branch
                    Task { await windowState.pull(branch: branch) }
                }
                .modifier(Collapsing(width: pullWidth))
                .id(SegmentID(branch: sync.branch, operation: .pull))
            }
            if showsPush {
                pushSegment(onTintChange: showsPull ? nil : onLeadingTintChange)
                    .modifier(Collapsing(width: pushWidth))
                    .id(SegmentID(branch: sync.branch, operation: sync.buttons.pushOperation))
            }
        }
    }

    @ViewBuilder
    private func pushSegment(onTintChange: ((Bool) -> Void)?) -> some View {
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
                    isLast: true, onTintChange: onTintChange)
            }
            // `.button` lets `.plain` strip the menu's own bezel, so it looks like the Push segment.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .modifier(SegmentAvailability(state: sync.buttons.push, label: sync.pushAccessibilityLabel))
        } else {
            segment(
                arrow: "arrow.up", count: sync.pushCount, title: sync.buttons.pushTitle, state: sync.buttons.push,
                label: sync.pushAccessibilityLabel, isLast: true,
                onTintChange: onTintChange
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
        onTintChange: ((Bool) -> Void)?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            SyncSegmentLabel(
                arrow: arrow, count: count, title: title, state: state, isLast: isLast,
                onTintChange: onTintChange)
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

/// One segment's face: the arrow, action and count, when there is one, in the accent
/// colour. A running segment hides all three under a centred spinner, as the picker's own
/// buttons do; hidden, not removed, so the pill keeps its width.
private struct SyncSegmentLabel: View {
    let arrow: String
    let count: Int?
    let title: String
    let state: PickerButtonState
    /// The last segment pads its end so the title clears the capsule's round end.
    let isLast: Bool
    var onTintChange: ((Bool) -> Void)?

    /// The count from before the click: the refresh behind the spinner may clear `count`,
    /// and the hidden count still holds the segment's width.
    @State private var lastCount: Int?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let isRunning = state == .running
        HStack(spacing: 2) {
            Image(systemName: arrow)
                .font(.system(size: 10, weight: .bold))
            Text(title)
                .fontWeight(.medium)
            if let shown = count ?? (isRunning ? lastCount : nil) {
                Text("\(shown)")
                    .monospacedDigit()
            }
        }
        // Centred by its line box, the text reads low against the icons; lift it to the eye.
        // The spinner below is centred on the unlifted frame.
        .offset(y: -1)
        .opacity(isRunning ? 0 : 1)
        .overlay {
            if isRunning { ProgressView().controlSize(.small) }
        }
        .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        .onChange(of: count, initial: true) { _, new in
            if let new { lastCount = new }
        }
        .lineLimit(1)
        .padding(.leading, 10)
        .padding(.trailing, isLast ? 14 : 10)
        .frame(height: 36)
        .modifier(PillPartHover(onTintChange: onTintChange))
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
    /// Reports whether the part is tinted, so the pill can hide the divider beside it.
    var onTintChange: ((Bool) -> Void)?

    func body(content: Content) -> some View {
        let isTinted = isHovering && isEnabled
        content
            .background {
                if isTinted { Rectangle().fill(.quinary) }
            }
            .onChange(of: isTinted) { _, new in onTintChange?(new) }
            // A part can vanish under the pointer (its id changes, or the segments hide), which
            // would leave the divider hidden.
            .onDisappear { onTintChange?(false) }
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

/// Draws a part of the pill at a fraction of its width, cut from the trailing edge, and
/// takes no clicks while it collapses.
private struct Collapsing: ViewModifier {
    let width: Double

    func body(content: Content) -> some View {
        WidthFractionLayout(fraction: width) { content }
            .clipped()
            .opacity(width)
            .allowsHitTesting(width == 1)
    }
}

/// Reports a fraction of the child's ideal width without compressing its content, so the
/// label keeps its shape as the part narrows. Lays out exactly one child.
private struct WidthFractionLayout: Layout {
    let fraction: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        assert(subviews.count == 1)
        let ideal = idealSize(of: subviews[0], height: proposal.height)
        return CGSize(width: ideal.width * fraction, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        assert(subviews.count == 1)
        let ideal = idealSize(of: subviews[0], height: proposal.height)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(ideal))
    }

    /// Measured at an unspecified width, never the narrowed one, so the label can't truncate.
    private func idealSize(of subview: LayoutSubview, height: CGFloat?) -> CGSize {
        subview.sizeThatFits(ProposedViewSize(width: nil, height: height))
    }
}
