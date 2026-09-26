import AppKit
import SwiftUI

/// The staged files and the commit button, in a card docked below the Changes list.
struct StagingTrayView: View {
    /// From `StagingTrayLayout`; at 0 the list is left out and only the header and the
    /// button show.
    let listHeight: CGFloat
    let isExpanded: Bool
    let firstSelectedID: ChangedFile.ID?
    var focusedList: FocusState<SidebarList?>.Binding
    @Environment(WindowState.self) private var windowState
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cardFill = Color(nsColor: .controlBackgroundColor).opacity(0.85)

    var body: some View {
        let staged = windowState.stagedFiles
        let summary = StagingTraySummary(stagedFiles: staged, isMerging: windowState.commitDefaults.isMerging)
        VStack(spacing: 0) {
            header(summary, stagedIDs: staged.map(\.id))
            if listHeight > 0 {
                stagedList(staged)
                    // Under Reduce Motion the toggle has no animation, so the list's own
                    // fade is what cross-fades it in place of the slide.
                    .transition(reduceMotion ? .opacity.animation(.easeInOut(duration: 0.2)) : .opacity)
            }
            commitButton(summary)
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background {
            let card = RoundedRectangle(cornerRadius: 14, style: .continuous)
            card.fill(Self.cardFill)
                .overlay { card.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1 / displayScale) }
                .shadow(color: .black.opacity(0.06), radius: 16, y: -2)
        }
        .padding([.horizontal, .bottom], 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Staged files")
    }

    private func header(_ summary: StagingTraySummary, stagedIDs: [ChangedFile.ID]) -> some View {
        Button {
            guard let root = windowState.repositoryRoot else { return }
            // Handed over before the list goes: once it is removed, the focus binding may
            // already read nil, and the sidebar's own fallback would not see it was focused.
            if isExpanded, focusedList.wrappedValue == .staged { focusedList.wrappedValue = .changes }
            withAnimation(reduceMotion ? nil : .snappy) {
                windowState.preferences.setStagingTrayExpanded(!isExpanded, for: root)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text("Staged")
                    .font(.system(size: 11, weight: .bold))
                Text(summary.fileCountText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let churn = summary.churn {
                    ChurnLabel(stats: churn, font: .system(size: 11, weight: .medium).monospacedDigit())
                }
            }
            .contentTransition(.numericText())
            .animation(.default, value: stagedIDs)
            .animation(.default, value: summary.churn)
            .padding(.horizontal, 8)
            .frame(height: 24)
        }
        .buttonStyle(TrayHeaderButtonStyle())
        .padding(.horizontal, 4)
        .accessibilityLabel(summary.headerAccessibilityLabel + (isExpanded ? ", expanded" : ", collapsed"))
    }

    private func stagedList(_ staged: [ChangedFile]) -> some View {
        @Bindable var windowState = windowState
        // Bound to the same selection as Changes; `SidebarView` says how the two share it.
        return List(selection: $windowState.selection) {
            ForEach(staged) { file in
                SidebarFileRow(file: file, isFirstSelected: file.id == firstSelectedID)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, StagingTrayLayout.rowHeight)
        .modifier(SidebarListBehavior(list: .staged, focusedList: focusedList))
        .frame(height: listHeight)
        // Past the cap, the fade says there is more to scroll to.
        .overlay(alignment: .bottom) {
            if staged.count > StagingTrayLayout.maxVisibleRows {
                LinearGradient(colors: [.clear, Self.cardFill], startPoint: .top, endPoint: .bottom)
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
