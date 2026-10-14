import SwiftUI

/// The preview centred on the cards' bottom edge: how much the target changed since the
/// merge base. Draws nothing until there is something to say.
struct CompareChurnPill: View {
    let model: CompareWindowModel

    var body: some View {
        if let label = model.churnAccessibilityLabel {
            content
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                .background {
                    // The ring makes the pill look cut out of the cards behind it.
                    Capsule().fill(Color(nsColor: .windowBackgroundColor)).padding(-4)
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.churn {
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
            if let counts = model.churnCounts {
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
