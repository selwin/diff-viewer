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
    /// What the pill shows, set one update after the window state changes, so a switch
    /// starts from what was on screen.
    @State private var shown: PillFace?
    /// The face before a branch switch, fading out while the pill eases to the new width.
    @State private var previous: PillFace?
    /// How far the switch has eased from `previous` to `shown`, 0 to 1.
    @State private var switchProgress = 0.0

    /// How long a departing segment takes to collapse, and a switch to ease.
    static let collapseDuration = Duration.milliseconds(250)

    var body: some View {
        @Bindable var windowState = windowState
        let current = PillFace(title: windowState.branchDisplayTitle, sync: windowState.currentBranchSync)
        let face = shown ?? settled(current, after: PillFace(title: current.title, sync: nil))
        let live = face.sync
        let sync = live.map { departure?.applied(to: $0) ?? $0 }
        let showsSegments = sync?.showsSegments ?? false
        let remaining = 1 - Self.eased(departureProgress)
        // Every segment is leaving, so the divider goes with them.
        let tailDeparts = departure != nil && !(live?.showsSegments ?? false)
        // Otherwise one segment leaves on its own, and the other stays.
        let departsPull = !tailDeparts && live.map { departure?.departsPull(in: $0) ?? false } ?? false
        let departsPush = !tailDeparts && live.map { departure?.departsPush(in: $0) ?? false } ?? false
        let fade = Crossfade(progress: Self.easedOut(switchProgress))
        // The name's end padding narrows beside segments, and eases with a switch.
        let trailing = showsSegments ? 14 - 4 * (tailDeparts ? remaining : 1) : 14
        let previousTrailing: CGFloat = previous?.sync?.showsSegments == true ? 10 : 14
        let nameTrailing = previous == nil ? trailing : previousTrailing + (trailing - previousTrailing) * fade.progress
        HStack(spacing: 0) {
            // Capped like the scope picker, so a long branch name can't push the toolbar's
            // other items into overflow. Only the name part is capped: the name keeps the
            // same room with or without segments, and they add their own width.
            CappedWidth(maximumWidth: 300) {
                Button {
                    windowState.isBranchPickerPresented = true
                } label: {
                    TitleBarPickerContent(
                        icon: .gitBranch, title: face.title,
                        transition: previous.map { TitleTransition(previous: $0.title, fade: fade) }
                    )
                    .padding(.leading, 14)
                    .padding(.trailing, nameTrailing)
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
            if let previous {
                // Both branches' segments are laid out, so the pill's width moves straight from
                // the old total to the new one.
                CrossfadeLayout(progress: fade.progress) {
                    switchingSegments(previous.sync)
                        .opacity(fade.outgoing)
                    switchingSegments(face.sync)
                        .opacity(fade.incoming)
                }
                .clipped()
                .allowsHitTesting(false)
            } else if let sync, showsSegments {
                segments(sync: sync, remaining: remaining, departsPull: departsPull, departsPush: departsPush)
                    .modifier(Collapsing(width: tailDeparts ? remaining : 1))
            }
        }
        // Clips each part's hover tint to the glass's round ends.
        .clipShape(Capsule())
        // Its own glass, since the toolbar's would wrap both pickers in one capsule.
        .glassEffect(in: .capsule)
        .onChange(of: current, initial: true) { _, new in
            let from = shown ?? PillFace(title: new.title, sync: nil)
            let next = settled(new, after: from)
            // A switch eases from what was on screen; anything else shows at once.
            if next.title != from.title, !from.title.isEmpty, !reduceMotion {
                previous = from
                switchProgress = 0
            }
            shown = next
        }
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
            guard await Self.step({ departureProgress = $0 }) else { return }
            departure = nil
            departureProgress = 0
        }
        .task(id: previous) {
            guard previous != nil else { return }
            guard await Self.step({ switchProgress = $0 }) else { return }
            previous = nil
            switchProgress = 0
        }
    }

    /// The face to show for `new`. Segments for a branch other than the one named stay as
    /// they were while the name holds, and hide when it changes, so one branch's segments
    /// never sit beside another's name.
    private func settled(_ new: PillFace, after old: PillFace) -> PillFace {
        guard let sync = new.sync, sync.branch != windowState.displayedBranchName else { return new }
        return PillFace(title: new.title, sync: new.title == old.title ? old.sync : nil)
    }

    /// The divider, then Pull and Push or Publish.
    private func segments(
        sync: CurrentBranchSyncPresentation, remaining: Double, departsPull: Bool, departsPush: Bool
    ) -> some View {
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
    }

    /// One side of a switch's segments: a branch's segments, or nothing at zero width.
    @ViewBuilder
    private func switchingSegments(_ sync: CurrentBranchSyncPresentation?) -> some View {
        if let sync, sync.showsSegments {
            segments(sync: sync, remaining: 1, departsPull: false, departsPush: false)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Eased, so a width change starts and ends gently.
    private static func eased(_ progress: Double) -> Double {
        progress * progress * (3 - 2 * progress)
    }

    /// Fast at first and gentle at the end, so a switch answers the click at once.
    private static func easedOut(_ progress: Double) -> Double {
        1 - pow(1 - progress, 3)
    }

    /// Reports progress from 0 towards 1 over `collapseDuration`; false if cancelled first.
    /// Stepped by hand rather than animated: the toolbar sizes its item from the pill's
    /// actual width, so only real width changes move the neighbours with it.
    private static func step(_ update: (Double) -> Void) async -> Bool {
        let start = ContinuousClock.now
        while !Task.isCancelled {
            let progress = (ContinuousClock.now - start) / collapseDuration
            if progress >= 1 { return true }
            update(progress)
            try? await Task.sleep(for: .milliseconds(8))
        }
        return false
    }
}

/// The pill's name and the segments beside it.
private struct PillFace: Equatable {
    let title: String
    let sync: CurrentBranchSyncPresentation?
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
                    arrow: "arrow.down", count: sync.pullCount, title: "Pull", shortcut: "⇧⌘P",
                    state: sync.buttons.pull, label: sync.pullAccessibilityLabel, isLast: !showsPush,
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
                // No glyph: ⌘P has no one remote to publish to, so the menu has no shortcut.
                SyncSegmentLabel(
                    arrow: "arrow.up", count: nil, title: sync.buttons.pushTitle, shortcut: nil,
                    state: sync.buttons.push, isLast: true, onTintChange: onTintChange)
            }
            // `.button` lets `.plain` strip the menu's own bezel, so it looks like the Push segment.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .modifier(SegmentAvailability(state: sync.buttons.push, label: sync.pushAccessibilityLabel))
        } else {
            segment(
                arrow: "arrow.up", count: sync.pushCount, title: sync.buttons.pushTitle, shortcut: "⌘P",
                state: sync.buttons.push, label: sync.pushAccessibilityLabel, isLast: true,
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
        arrow: String, count: Int?, title: String, shortcut: String, state: PickerButtonState, label: String,
        isLast: Bool, onTintChange: ((Bool) -> Void)?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            SyncSegmentLabel(
                arrow: arrow, count: count, title: title, shortcut: shortcut, state: state, isLast: isLast,
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
/// colour, then the menu shortcut. A running segment hides them under a centred spinner,
/// as the picker's own buttons do; hidden, not removed, so the pill keeps its width.
private struct SyncSegmentLabel: View {
    let arrow: String
    let count: Int?
    let title: String
    let shortcut: String?
    let state: PickerButtonState
    /// The last segment pads its end so the title clears the pill's round end.
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
                .font(.system(size: 13, weight: .medium))
            if let shown = count ?? (isRunning ? lastCount : nil) {
                Text("\(shown)")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
            }
            // Styled as on the commit sheet's Commit button.
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.6)
                    .padding(.leading, 3)
                    .accessibilityHidden(true)
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
                TitleBarPickerContent(icon: .gitCommit, title: windowState.scopeDisplayTitle)
                    // Wider than the height needs, so the text clears the round ends.
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    // The whole capsule opens the picker, not only the text.
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            // Its own glass, like the branch pill beside it.
            .glassEffect(.regular.interactive(), in: .capsule)
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

/// What both title bar pickers show on their glass: an icon, the title and a chevron.
private struct TitleBarPickerContent: View {
    let icon: ImageResource
    let title: String
    /// Set while the title changes, so the face eases to the new title's width.
    var transition: TitleTransition?

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
            if let transition {
                CrossfadeLayout(progress: transition.fade.progress) {
                    titleText(transition.previous)
                        .opacity(transition.fade.outgoing)
                        .accessibilityHidden(true)
                    titleText(title)
                        .opacity(transition.fade.incoming)
                }
                .clipped()
            } else {
                titleText(title)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func titleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            // Centred by its line box, the text reads low against the icons; lift it to the eye.
            .offset(y: -1)
    }
}

/// A title on its way out, and how the old and new titles are fading.
private struct TitleTransition {
    let previous: String
    let fade: Crossfade
}

/// How far a switch has eased, 0 to 1, and how strongly the old and new faces show.
private struct Crossfade {
    let progress: Double

    // The fades barely overlap: two different faces drawn on top of each other at similar
    // strength read as a smudge.
    var outgoing: Double { max(0, 1 - progress / 0.4) }
    var incoming: Double { max(0, (progress - 0.3) / 0.7) }
}

/// Stacks the old face and the new one, and reports a width between theirs, so the pill
/// eases to the new width instead of jumping. Each keeps its own width and is clipped
/// rather than truncated while the width moves. Lays out exactly two children.
private struct CrossfadeLayout: Layout {
    let progress: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        assert(subviews.count == 2)
        let from = idealSize(of: subviews[0], height: proposal.height)
        let to = idealSize(of: subviews[1], height: proposal.height)
        let width = from.width + (to.width - from.width) * progress
        // Never wider than offered, so a capped pill still holds its width.
        return CGSize(width: min(width, proposal.width ?? width), height: max(from.height, to.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let ideal = idealSize(of: subview, height: proposal.height)
            subview.place(
                at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: ideal.width, height: bounds.height))
        }
    }

    private func idealSize(of subview: LayoutSubview, height: CGFloat?) -> CGSize {
        subview.sizeThatFits(ProposedViewSize(width: nil, height: height))
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
