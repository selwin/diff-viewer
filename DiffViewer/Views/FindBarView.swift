import SwiftUI

/// The strip under the header while find is open: query, side, status, and steps.
struct FindBarView: View {
    @Environment(WindowState.self) private var windowState
    @Bindable var find: FindState
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find", text: $find.query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(minWidth: 120, maxWidth: 320)
                .focused($isFieldFocused)
                .onSubmit { find.next() }
            // Once the field is at its minimum, the segments shorten their names before the row overflows.
            ViewThatFits(in: .horizontal) {
                ForEach(Self.segmentWidths, id: \.self) { scopeControl(maximumSegmentWidth: $0) }
            }
            // Served before the field, which only keeps its minimum; otherwise the stack splits
            // the spare width and the narrowest variant wins.
            .layoutPriority(1)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(
                    find.status == .noResults ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.secondary)
                )
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            Button {
                find.previous()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Previous match")
            .keyboardShortcut(.return, modifiers: .shift)
            .disabled(!find.canStep)
            Button {
                find.next()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Next match")
            .disabled(!find.canStep)
            Spacer(minLength: 0)
            Button("Done") { find.dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .onAppear { isFieldFocused = true }
        .onChange(of: find.focusRequest) { isFieldFocused = true }
    }

    private static let segmentWidths: [CGFloat] = [180, 110, 72]

    private func scopeControl(maximumSegmentWidth: CGFloat) -> some View {
        FindScopeControl(
            labels: windowState.findSideLabels, side: find.side, oldCount: find.displayCount(for: .old),
            newCount: find.displayCount(for: .new), hasQuery: !find.query.isEmpty,
            onSelect: { windowState.selectFindSide($0) }, maximumSegmentWidth: maximumSegmentWidth
        )
        .fixedSize()
    }

    private var statusText: String {
        switch find.status {
        case .empty: ""
        case .noResults: "No results"
        case let .position(index, count): "\(index + 1) of \(count)"
        case let .count(count): count == 1 ? "1 match" : "\(count) matches"
        }
    }
}
