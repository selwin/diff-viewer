import SwiftUI

extension View {
    /// The rounded, softly shadowed card behind each of the Compare window's columns.
    func compareCard() -> some View {
        background {
            let card = RoundedRectangle(cornerRadius: 20, style: .continuous)
            card.fill(Color(nsColor: .controlBackgroundColor))
                .overlay { card.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
    }
}
