import SwiftUI

/// The preview overlapping the cards' bottom edge. With two different commits chosen in
/// Branches mode it is a pill per direction, each opening that comparison; otherwise one pill
/// says how much the target changed. Draws nothing until there is something to say.
struct ComparePreviewRows: View {
    let model: CompareWindowModel
    let onCompare: (CompareWindowModel.Direction) -> Void

    static let rowHeight: CGFloat = 28
    /// Leaves a hairline between the pills' rings.
    private static let pillSpacing: CGFloat = 10
    /// Both direction pills, so the window can reserve room for the tallest preview.
    static let tallestHeight = 2 * rowHeight + pillSpacing

    var body: some View {
        let directions = model.previewDirections
        let shown = directions.filter { model.churnAccessibilityLabel($0) != nil }
        if !shown.isEmpty {
            Group {
                if directions.count == 1, let label = model.churnAccessibilityLabel(.forward) {
                    pill(churn(.forward))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(label)
                } else {
                    VStack(spacing: Self.pillSpacing) {
                        ForEach(shown, id: \.self) { direction in
                            // As wide as the widest, so the two pills line up.
                            pill(row(direction).frame(maxWidth: .infinity))
                        }
                    }
                    // Room for the counts beside long names, which truncate instead.
                    .frame(maxWidth: 488)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityElement(children: .contain)
                }
            }
            .font(.system(size: 12))
        }
    }

    private func pill(_ content: some View) -> some View {
        content
            .frame(height: Self.rowHeight)
            .padding(.horizontal, 14)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .background {
                // The ring makes the pill look cut out of the cards behind it.
                Capsule().fill(Color(nsColor: .windowBackgroundColor)).padding(-4)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 1)
            }
    }

    private func row(_ direction: CompareWindowModel.Direction) -> some View {
        let ends = model.rowEnds(direction) ?? ("", "")
        let isEnabled = model.canCompare(direction)
        return Button {
            onCompare(direction)
        } label: {
            HStack(spacing: 12) {
                // Each name truncates on its own, so the arrow always shows the direction.
                HStack(spacing: 4) {
                    name(ends.from)
                    Text("→").accessibilityHidden(true)
                    name(ends.to)
                }
                .fontWeight(.medium)
                .foregroundStyle(isEnabled ? .primary : .secondary)
                Spacer(minLength: 0)
                churn(direction).fixedSize()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(
            "Open \(model.rowTitle(direction) ?? ""): \(model.churnAccessibilityLabel(direction) ?? "")")
    }

    private func name(_ text: String) -> some View {
        Text(text).lineLimit(1).truncationMode(.middle)
    }

    @ViewBuilder
    private func churn(_ direction: CompareWindowModel.Direction) -> some View {
        switch model.churn(direction) {
        case .hidden, .pending:
            EmptyView()
        case .comparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text("Comparing…").foregroundStyle(.secondary)
            }
        case .noDifferences:
            Text("No differences").foregroundStyle(.secondary)
        case .ready:
            if let counts = model.churnCounts(direction) {
                HStack(spacing: 8) {
                    Text(counts.files).foregroundStyle(.secondary)
                    Text(counts.added).foregroundStyle(Color(nsColor: DiffTheme.addedCount)).fontWeight(.semibold)
                    Text(counts.deleted).foregroundStyle(Color(nsColor: DiffTheme.deletedCount)).fontWeight(.semibold)
                }
            }
        case let .failed(reason):
            Text("Preview unavailable").foregroundStyle(.secondary).help(reason)
        }
    }
}
