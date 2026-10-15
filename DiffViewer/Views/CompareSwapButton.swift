import SwiftUI

/// The round button over the gap between the cards that exchanges base and compare.
struct CompareSwapButton: View {
    let model: CompareWindowModel

    var body: some View {
        Button {
            model.swap()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.canSwap ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                .background {
                    // The ring makes the button look cut out of both cards.
                    Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-5)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 1)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!model.canSwap)
        .accessibilityLabel("Swap base and compare")
        .help("Swap base and compare")
    }
}
