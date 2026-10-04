import SwiftUI

/// The branch pill and the scope button, side by side in one toolbar item.
struct TitleBarPickers: View {
    @Environment(WindowState.self) private var windowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The live pill's activity, copied in an animated transaction so the scope button
    /// slides with the pill's edge. An implicit `.animation` here is ignored by the toolbar.
    @State private var shownActivity: HeadChangeActivity?

    var body: some View {
        HStack(spacing: 8) {
            BranchPickerView(activity: shownActivity)
            ScopePickerView()
        }
        .onChange(of: windowState.headChangeActivity, initial: true) { _, activity in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.4)) { shownActivity = activity }
        }
    }
}

/// The title bar's branch pill: the current branch, which opens the branch picker, then
/// Pull and Push segments when there is something to sync. ⌘B opens the same popover by
/// setting the same flag. Right after a switch, create or merge it turns into a dark
/// capsule that says what happened.
struct BranchPickerView: View {
    /// What the live pill shows, or nil for the normal pill.
    let activity: HeadChangeActivity?
    @Environment(WindowState.self) private var windowState
    @State private var isBranchTinted = false
    @State private var isLeadingSegmentTinted = false

    var body: some View {
        @Bindable var windowState = windowState
        // Read only for the normal pill: the live capsule hides the segments.
        let sync = activity == nil ? windowState.currentBranchSync : nil
        let showsSegments = sync?.showsSegments ?? false
        HStack(spacing: 0) {
            // Capped like the scope picker, so a long branch name can't push the toolbar's
            // other items into overflow. Only the name part is capped: the name keeps the
            // same room with or without segments, and they add their own width.
            CappedWidth(maximumWidth: 300) {
                Button {
                    windowState.isBranchPickerPresented = true
                } label: {
                    if let activity {
                        HeadChangeCapsuleLabel(activity: activity)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                    } else {
                        TitleBarPickerContent(icon: .gitBranch, title: windowState.branchDisplayTitle)
                            .padding(.leading, 14)
                            .padding(.trailing, showsSegments ? 10 : 14)
                            .frame(height: 36)
                            .modifier(PillPartHover { isBranchTinted = $0 })
                    }
                }
                .buttonStyle(.plain)
                .disabled(!windowState.canOpenBranchPicker)
                .help(activity?.accessibilityText ?? windowState.branchSwitchHelp)
                .popover(isPresented: $windowState.isBranchPickerPresented, arrowEdge: .bottom) {
                    BranchPickerPopover()
                }
            }
            if let sync, showsSegments {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 18)
                    // Steps aside for a tinted neighbour, like a native segmented control's
                    // separator. Opacity, not removal, so the pill's width doesn't change.
                    .opacity(isBranchTinted || isLeadingSegmentTinted ? 0 : 1)
                BranchSyncSegments(sync: sync, onLeadingTintChange: { isLeadingSegmentTinted = $0 })
                    .fixedSize()
                    // Disabled while another sheet or picker is up, like the branch button.
                    .disabled(!windowState.canOpenBranchPicker)
            }
        }
        .background {
            if activity != nil {
                HeadChangeSurface().transition(.opacity)
            } else {
                TitleBarCapsule(isOpen: windowState.isBranchPickerPresented).transition(.opacity)
            }
        }
        // Clips each part's hover tint to the round ends.
        .clipShape(Capsule())
        // Observed here, not in the label, which comes and goes with the activity.
        .onChange(of: finishedActivityID) { _, id in
            guard id != nil, let activity = windowState.headChangeActivity else { return }
            AccessibilityNotification.Announcement(activity.accessibilityText).post()
        }
    }

    /// The ID of the activity once it has finished; running states are not announced.
    private var finishedActivityID: Int? {
        guard let activity = windowState.headChangeActivity, case .finished = activity.state else { return nil }
        return activity.activityID
    }
}

/// The live pill's surface: the text colour inverted, so it reads dark in light mode and light
/// in dark mode.
private struct HeadChangeSurface: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Capsule().fill(Color.primary.opacity(contrast == .increased ? 1 : 0.88))
    }
}

/// What the live pill says: a spinner or a status dot, a semibold title, and the detail at
/// reduced opacity, which is the only part that truncates.
private struct HeadChangeCapsuleLabel: View {
    let activity: HeadChangeActivity

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let foreground = Color(nsColor: .windowBackgroundColor)
        HStack(spacing: 6) {
            indicator
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                Text(activity.title)
                    .fontWeight(.semibold)
                    .fixedSize()
                    .layoutPriority(1)
                Text(activity.detail)
                    .fontWeight(.medium)
                    .foregroundStyle(foreground.opacity(contrast == .increased ? 1 : 0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Lifted like the normal pill's text, so the two sit at the same height.
            .offset(y: -1)
        }
        .foregroundStyle(foreground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.accessibilityText)
        .accessibilityHint("Open branch picker")
    }

    @ViewBuilder
    private var indicator: some View {
        switch activity.tone {
        case .progress:
            // A symbol, not `ProgressView`: the AppKit spinner keeps the window's appearance,
            // so it would vanish against the inverted surface. This one takes the text colour.
            Image(systemName: "progress.indicator")
                .font(.system(size: 12, weight: .semibold))
                .symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
        case .success:
            Circle().fill(Color.green).frame(width: 6, height: 6)
        case .warning:
            Circle().fill(Color(nsColor: .systemOrange)).frame(width: 6, height: 6)
        }
    }
}

/// The pill's Pull, then Push or Publish, each shown only when the sync rules say so.
private struct BranchSyncSegments: View {
    @Environment(WindowState.self) private var windowState
    let sync: CurrentBranchSyncPresentation
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
                .id(SegmentID(branch: sync.branch, operation: .pull))
            }
            if showsPush {
                pushSegment(onTintChange: showsPull ? nil : onLeadingTintChange)
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
/// colour. A running segment covers the arrow and
/// action with a spinner, as the picker's own buttons do, so the pill keeps its width.
private struct SyncSegmentLabel: View {
    let arrow: String
    let count: Int?
    let title: String
    let state: PickerButtonState
    /// The last segment pads its end so the title clears the capsule's round end.
    let isLast: Bool
    var onTintChange: ((Bool) -> Void)?

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
                    // Lifted like the title, so the two share a baseline.
                    .offset(y: -1)
            }
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
