import SwiftUI

/// The round button over the gap between the cards that exchanges base and compare. In Pull
/// Request mode the sides are fixed, so it is a plain arrow from the pull request to its base.
struct CompareSwapButton: View {
    let model: CompareWindowModel

    var body: some View {
        switch model.mode {
        case .branches:
            Button {
                model.swap()
            } label: {
                glyph("arrow.left.arrow.right", tint: model.canSwap ? Color.accentColor : Color.secondary.opacity(0.5))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(!model.canSwap)
            .accessibilityLabel("Swap base and compare")
            .help("Swap base and compare")
        case .pullRequest:
            glyph("arrow.left", tint: Color.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Compared against the default branch")
                .help("Compared against the default branch")
        }
    }

    private func glyph(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
            .background {
                // The ring makes the button look cut out of both cards.
                Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-5)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 1)
            }
    }
}
