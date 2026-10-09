import AppKit
import SwiftUI

/// The staged files and the commit button, in a sheet docked below the Changes list.
struct StagingTrayView: View {
    /// The staged files by directory, in list order.
    let groups: [DirectoryGroup]
    /// From `StagingTrayLayout`; at 0 the list is left out and only the header and the
    /// button show.
    let listHeight: CGFloat
    /// Whether the list scrolls, which the fade at its foot says.
    let overflows: Bool
    let isExpanded: Bool
    /// Whether the staging capsule sits on the tray's top edge, reaching 15pt into it.
    let hasCapsule: Bool
    var focusedList: FocusState<SidebarList?>.Binding
    @Environment(WindowState.self) private var windowState
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sheetFill = Color(nsColor: .controlBackgroundColor).opacity(0.85)
    private static let rowInsets = EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 4)

    var body: some View {
        let staged = windowState.stagedFiles
        let summary = StagingTraySummary(stagedFiles: staged, isMerging: windowState.commitDefaults.isMerging)
        VStack(spacing: 0) {
            header(summary, stagedIDs: staged.map(\.id))
            if listHeight > 0 {
                stagedList
                    // Opens like a drawer but leaves at once: a list on its way out keeps its
                    // old place and size, so the header would slide over its rows. Under
                    // Reduce Motion the toggle has no animation, so the list fades itself.
                    .transition(
                        reduceMotion
                            ? AnyTransition.opacity.animation(.easeInOut(duration: 0.2))
                            : .asymmetric(insertion: AnyTransition(DrawerTransition()), removal: .identity)
                    )
            }
            commitButton(summary)
        }
        .padding(.top, 6 + (hasCapsule ? StagingTrayLayout.capsuleClearance : 0))
        .padding(.bottom, 8)
        // A bottom sheet across the sidebar's full width, so the rows get all of it.
        .background {
            let sheet = UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous)
            sheet.fill(Self.sheetFill)
                .overlay { sheet.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1 / displayScale) }
                .shadow(color: .black.opacity(0.06), radius: 16, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Staged files")
    }

    private func header(_ summary: StagingTraySummary, stagedIDs: [ChangedFile.ID]) -> some View {
        Button {
            guard let root = windowState.repositoryRoot else { return }
            // Handed over before the list goes: once it is removed, the focus binding may
            // already read nil, and the sidebar's own fallback would not see it was focused.
            if isExpanded, focusedList.wrappedValue == .staged { focusedList.wrappedValue = .changes }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                windowState.preferences.setStagingTrayExpanded(!isExpanded, for: root)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Centred on the title; on its baseline the chevron reads low.
                HStack(spacing: 6) {
                    // The app's heading size, as on the window title and the New Branch sheet.
                    Text("Staged")
                        .font(.system(size: 15, weight: .bold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                Text(summary.fileCountText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let churn = summary.churn {
                    // The rows' own churn font, so the total reads as their sum.
                    ChurnLabel(stats: churn)
                }
            }
            .contentTransition(.numericText())
            .animation(.default, value: stagedIDs)
            .animation(.default, value: summary.churn)
            // Lines the title up with the Changes heading and both lists' rows.
            .padding(.leading, 10)
            // The list insets its rows 8pt more than this; matching it lines the total
            // up with the rows' churn.
            .padding(.trailing, 16)
            .frame(height: 28)
        }
        .buttonStyle(TrayHeaderButtonStyle())
        .padding(.horizontal, 4)
        .accessibilityLabel(summary.headerAccessibilityLabel + (isExpanded ? ", expanded" : ", collapsed"))
    }

    private var stagedList: some View {
        @Bindable var windowState = windowState
        // Bound to the same selection as Changes; `SidebarView` says how the two share it.
        return List(selection: $windowState.selection) {
            ForEach(groups) { DirectoryFileSection(group: $0, rowInsets: Self.rowInsets) }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .modifier(SidebarListBehavior(list: .staged, focusedList: focusedList))
        .frame(height: listHeight)
        .overlay(alignment: .bottom) {
            if overflows {
                LinearGradient(colors: [.clear, Self.sheetFill], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .allowsHitTesting(false)
            }
        }
    }

    private func commitButton(_ summary: StagingTraySummary) -> some View {
        Button {
            windowState.isCommitSheetPresented = true
        } label: {
            HStack(spacing: 6) {
                Text(summary.commitTitle)
                    .font(.system(size: 13, weight: .semibold))
                // Hooks and signing can take seconds; the button alone would look stuck.
                if windowState.isCommitting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("⌘↩").opacity(0.7)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        // Repository ▸ Commit… owns ⌘↩, so the button has no shortcut of its own.
        .disabled(!windowState.canOpenCommitSheet)
        .accessibilityLabel(summary.commitAccessibilityLabel)
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}

/// Opens the list like a drawer: its height grows from 0 with the rows pinned to its top,
/// so they rise with the header from behind the commit button.
private struct DrawerTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .frame(height: phase.isIdentity ? nil : 0, alignment: .top)
            .clipped()
    }
}

/// The header is a whole-row button; a plain style would give no sign it can be clicked.
private struct TrayHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverFill(configuration: configuration)
    }

    private struct HoverFill: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            let opacity = configuration.isPressed ? 0.1 : isHovered ? 0.06 : 0
            configuration.label
                .contentShape(.rect)
                .background(Color.primary.opacity(opacity), in: .rect(cornerRadius: 6))
                .onHover { isHovered = $0 }
        }
    }
}
