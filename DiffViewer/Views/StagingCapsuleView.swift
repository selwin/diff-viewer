import SwiftUI

/// The floating Stage / Unstage button at the foot of the sidebar: Stage All with nothing
/// selected, or the selected rows' staging action, with the shortcut that does the same.
struct StagingCapsuleView: View {
    let capsule: StagingCapsule
    @Environment(WindowState.self) private var windowState
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            FileActionRunner.runStagingAction(capsule.action, in: windowState, services: services)
        } label: {
            // The keycap gives way first in a narrow sidebar; the counts stay exact, and the
            // shortcut stays in the hint.
            ViewThatFits(in: .horizontal) {
                content(showsKeycap: true)
                content(showsKeycap: false)
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: StagingTrayLayout.capsuleHeight)
            // A new title reshapes the capsule in place; appearing is the sidebar's transition.
            .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.2), value: capsule.title)
        }
        .buttonStyle(StagingCapsuleButtonStyle())
        // A click leaves the keyboard on the list, so the arrow keys still move the selection.
        .focusable(false)
        .focusEffectDisabled()
        .disabled(!windowState.canStartStagingAction)
        .accessibilityLabel(capsule.accessibilityLabel)
        .accessibilityHint(capsule.spokenShortcut)
    }

    private func content(showsKeycap: Bool) -> some View {
        HStack(spacing: 10) {
            // Neutral like the title: blue is the Commit button's.
            Image(systemName: capsule.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(capsule.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
                churnLine
            }
            if showsKeycap {
                Text(capsule.shortcut)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(Color.primary.opacity(0.1), in: .rect(cornerRadius: 6))
                    .padding(.leading, 8)
                    .contentTransition(.opacity)
                    .accessibilityHidden(true)
            }
        }
    }

    private static let churnFont = Font.system(size: 11, weight: .semibold).monospacedDigit()

    /// One font and one line in every state, so the title never moves when the counts arrive.
    /// Hidden text reserves the second line while counts are unknown.
    @ViewBuilder
    private var churnLine: some View {
        switch capsule.churn {
        case let .counted(added, deleted):
            ChurnLabel(stats: .counted(added: added, deleted: deleted), font: Self.churnFont)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .default, value: capsule.churn)
        case .noLineChanges:
            Text("No line changes")
                .font(Self.churnFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .unknown:
            Text("No line changes")
                .font(Self.churnFont)
                .lineLimit(1)
                .hidden()
        }
    }
}

/// A neutral raised capsule: blue belongs to the Commit button below it.
private struct StagingCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RaisedCapsule(configuration: configuration)
    }

    private struct RaisedCapsule: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let isDark = colorScheme == .dark
            configuration.label
                .background { fill(isDark: isDark) }
                .overlay {
                    let border = isDark ? Color.white.opacity(0.22) : Color.black.opacity(0.12)
                    Capsule().strokeBorder(border, lineWidth: 0.5)
                }
                .compositingGroup()
                .shadow(color: .black.opacity(isDark ? 0.45 : 0.18), radius: 9, y: 6)
                .opacity(isEnabled ? 1 : 0.6)
                .contentShape(.capsule)
                .onHover { isHovered = $0 }
        }

        /// Dark mode uses the design's warm greys; light mode uses the system control colour,
        /// darkened slightly on hover and more on press.
        @ViewBuilder
        private func fill(isDark: Bool) -> some View {
            let pressed = isEnabled && configuration.isPressed
            let hovered = isEnabled && isHovered
            if isDark {
                Capsule().fill(Color(hex: pressed ? 0x504C49 : hovered ? 0x45423F : 0x3A3736))
            } else {
                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                    .overlay { Capsule().fill(Color.primary.opacity(pressed ? 0.1 : hovered ? 0.05 : 0)) }
            }
        }
    }
}

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
