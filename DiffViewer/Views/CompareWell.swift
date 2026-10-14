import SwiftUI

/// The bottom of a card: what is chosen on that side, or a dashed prompt. The base's text is
/// right-aligned and the target's left-aligned, so both face the swap button between the cards.
struct CompareWell: View {
    let model: CompareWindowModel
    let side: CompareWindowModel.Side

    /// Room on the side facing the swap button, which overlaps the cards' edges.
    private static let innerPadding: CGFloat = 34
    private static let outerPadding: CGFloat = 14
    private static let cornerRadius: CGFloat = 14

    private var isBase: Bool { side == .base }
    private var isSameAsBase: Bool { side == .target && model.isTargetSameAsBase }

    var body: some View {
        content
            .padding(.leading, isBase ? Self.outerPadding : Self.innerPadding)
            .padding(.trailing, isBase ? Self.innerPadding : Self.outerPadding)
            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: isBase ? .trailing : .leading)
            .background { background }
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        if let ref = model.selection(side) {
            VStack(alignment: isBase ? .trailing : .leading, spacing: 2) {
                Text(verbatim: ref.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isBase ? Color.primary : Color.accentColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(ref.name)
                if let subtitle = model.wellSubtitle(side) {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(isSameAsBase ? Color(nsColor: .systemOrange) : .secondary)
                        .lineLimit(1)
                }
            }
        } else {
            VStack(alignment: isBase ? .trailing : .leading, spacing: 2) {
                Text(isBase ? "Choose a base" : "Choose a branch to compare")
                    .font(.system(size: 15, weight: .medium))
                Text("Pick one from the list").font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        if model.selection(side) == nil {
            shape.strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else {
            shape.fill(isBase ? Color(nsColor: .systemGray).opacity(0.1) : Color.accentColor.opacity(0.1))
        }
    }
}
