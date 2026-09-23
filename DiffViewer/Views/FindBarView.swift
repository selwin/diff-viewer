import SwiftUI

/// The strip under the header while find is open: query, side, counter, and steps.
struct FindBarView: View {
    @Bindable var find: FindState
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find", text: $find.query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 320)
                .focused($isFieldFocused)
                .onSubmit { find.next() }
            Picker("Side", selection: Binding(get: { find.side }, set: { find.selectSide($0) })) {
                Text("Old").tag(DocumentSide.old)
                Text("New").tag(DocumentSide.new)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Text(find.counterText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
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
            Spacer()
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
}
