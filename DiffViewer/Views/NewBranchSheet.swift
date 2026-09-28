import SwiftUI

/// Names a new branch made at HEAD. Create only reports the checked name; the parent
/// dismisses and creates, and git's refusal arrives as the window's error.
struct NewBranchSheet: View {
    @Environment(WindowState.self) private var windowState
    @State private var validation: NewBranchNameValidation
    @State private var text = ""
    @FocusState private var nameFocused: Bool
    let onCreate: (String) -> Void

    init(validation: NewBranchNameValidation, onCreate: @escaping (String) -> Void) {
        _validation = State(initialValue: validation)
        self.onCreate = onCreate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Branch").font(.headline)
                if !windowState.branchDisplayTitle.isEmpty {
                    Text("From \(windowState.branchDisplayTitle)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            TextField("Branch name", text: $text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($nameFocused)
                .accessibilityLabel("Branch name")
                .onChange(of: text) { validation.update(text) }
            // A space holds the line, so the sheet doesn't resize as the reason comes and goes.
            Text(validation.message ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Spacer()
                Button("Cancel") { windowState.isNewBranchSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { onCreate(validation.name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validation.canCreate)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { nameFocused = true }
        .onChange(of: windowState.branches) { validation.branchesChanged() }
        .onDisappear { validation.cancel() }
    }
}
