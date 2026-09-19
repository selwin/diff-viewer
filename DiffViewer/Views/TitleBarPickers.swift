import SwiftUI

/// The title bar's branch pop-up: the current branch on its face, every local branch in
/// its menu. Choosing one checks it out.
struct BranchPickerView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        // Capped for the same reason as the scope picker: a long branch name would
        // otherwise send every item after it into the overflow menu.
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
            TitleBarPickerLabel(glyph: "arrow.triangle.branch", title: windowState.branchDisplayTitle)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
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

/// The title bar's scope pop-up: what the sidebar shows, the working tree or one commit.
struct ScopePickerView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        // Capped so a long subject ellipsizes instead of pushing the toolbar's other
        // items into the overflow menu.
        CappedWidth(maximumWidth: 360) {
            Menu {
                ScopeMenuContent()
            } label: {
                TitleBarPickerLabel(glyph: icon, title: windowState.scopeDisplayTitle)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(help)
        }
    }

    private var icon: String {
        switch windowState.scope {
        case .workingTree: "circle.and.line.horizontal"
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

/// The face both title bar pop-ups wear: an outlined one-line box at toolbar control
/// height with no fill, so it sits flat on the title bar. Plain data in, so it does not depend on
/// `WindowState`.
private struct TitleBarPickerLabel: View {
    let glyph: String
    let title: String

    // A plain-style menu draws no disabled state of its own, so the face dims itself.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        // The whole box opens the menu, not only the text.
        .contentShape(Rectangle())
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
