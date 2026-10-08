import SwiftUI

/// The sidebar title bar's Stashes button: the word and, when there are any, how many.
/// Shown with no stashes too, dimmed, so the picker can be found before the first one.
/// The toolbar draws its glass, matching the sidebar toggle beside it.
struct StashesCapsuleView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        let count = windowState.stashList.entries.count
        Button {
            windowState.isStashPickerPresented = true
        } label: {
            HStack(spacing: 6) {
                // The title bar pickers' size and weight.
                Text("Stashes")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(count == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if count > 0 {
                    Text(count, format: .number)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        // The toolbar's button style would otherwise grey it like a secondary label.
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(.quaternary))
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 4)
            .background(StashPickerAnchor(windowState: windowState, isPresented: windowState.isStashPickerPresented))
        }
        .disabled(!windowState.canOpenStashPicker)
        .help("Show stashes")
        .accessibilityLabel(count == 1 ? "1 stash" : "\(count) stashes")
    }
}
