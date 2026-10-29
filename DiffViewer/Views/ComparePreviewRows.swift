import SwiftUI

/// The preview overlapping the cards' bottom edge. With two different commits chosen in
/// Branches mode it has a row per direction, each opening that comparison; otherwise one row
/// says how much the target changed. Draws nothing until there is something to say.
struct ComparePreviewRows: View {
    let model: CompareWindowModel
    let onCompare: (CompareWindowModel.Direction) -> Void

    static let rowHeight: CGFloat = 28
    private static let directionRowHeight: CGFloat = 24
    private static let directionPadding: CGFloat = 2
    /// Both direction rows, so the window can reserve room for the tallest preview.
    static let tallestHeight = 2 * directionRowHeight + 2 * directionPadding

    var body: some View {
        let directions = model.previewDirections
        let shown = directions.filter { model.churnAccessibilityLabel($0) != nil }
        if !shown.isEmpty {
            Group {
                if directions.count == 1, let label = model.churnAccessibilityLabel(.forward) {
                    churn(.forward)
                        .frame(height: Self.rowHeight)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(label)
                } else {
                    VStack(spacing: 0) {
                        ForEach(shown, id: \.self, content: row)
                    }
                    .padding(.vertical, Self.directionPadding)
                    // Room for the counts beside long names, which truncate instead.
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityElement(children: .contain)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .background {
                // The ring makes the preview look cut out of the cards behind it.
                shape.fill(Color(nsColor: .windowBackgroundColor)).padding(-4)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 1)
            }
        }
    }

    /// A capsule while there is one row; two keep its rounded ends.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.rowHeight / 2, style: .continuous)
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
            .frame(height: Self.directionRowHeight)
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
