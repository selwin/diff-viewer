import SwiftUI

/// The bottom of a card: what is chosen on that side, or a dashed prompt. The base's text is
/// right-aligned and the target's left-aligned, so both face the swap button between the cards.
struct CompareWell: View {
    let side: CompareWindowModel.Side
    /// Nil shows the placeholder.
    let content: CompareWellContent?
    let placeholder: (title: String, subtitle: String)

    /// Room on the side facing the swap button, which overlaps the cards' edges.
    private static let innerPadding: CGFloat = 34
    private static let outerPadding: CGFloat = 14
    private static let cornerRadius: CGFloat = 14

    private var isBase: Bool { side == .base }

    var body: some View {
        text
            .padding(.leading, isBase ? Self.outerPadding : Self.innerPadding)
            .padding(.trailing, isBase ? Self.innerPadding : Self.outerPadding)
            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: isBase ? .trailing : .leading)
            .background { background }
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var text: some View {
        if let content {
            VStack(alignment: isBase ? .trailing : .leading, spacing: 2) {
                Text(verbatim: content.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isBase ? Color.primary : Color.accentColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(content.title)
                if let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(content.isWarning ? Color(nsColor: .systemOrange) : .secondary)
                        .lineLimit(1)
                }
            }
        } else {
            VStack(alignment: isBase ? .trailing : .leading, spacing: 2) {
                Text(placeholder.title).font(.system(size: 15, weight: .medium))
                Text(placeholder.subtitle).font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        if content == nil {
            shape.strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else {
            shape.fill(isBase ? Color(nsColor: .systemGray).opacity(0.1) : Color.accentColor.opacity(0.1))
        }
    }
}
