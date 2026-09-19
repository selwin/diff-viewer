import SwiftUI

/// The modal where the commit message is written and confirmed. The draft, whether
/// Commit is available, and the caption below the editor all come from `WindowState`;
/// Commit only reports the confirmed text, and the parent dismisses and commits.
struct CommitSheetView: View {
    @Environment(WindowState.self) private var windowState
    @FocusState private var editorFocused: Bool
    /// The draft changed while a confirmed message was on its way; say so.
    let draftChanged: Bool
    let onSubmit: (String) -> Void

    var body: some View {
        @Bindable var windowState = windowState
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit").font(.headline)
            TextEditor(text: $windowState.commitMessage)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .frame(height: 160)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .accessibilityLabel("Commit message")
                .focused($editorFocused)
                .overlay(alignment: .topLeading) {
                    // Padded to sit where the editor's own first line starts, so typing
                    // does not shift the text.
                    if windowState.commitMessage.isEmpty {
                        Text("Commit message")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .allowsHitTesting(false)
                    }
                }
            // A reopened sheet explains itself first; then merge status before template guidance.
            Group {
                if draftChanged {
                    Text("The commit message changed. Review it before committing.")
                } else if windowState.commitDefaults.isMerging {
                    Text("Merge in progress")
                } else if windowState.commitNeedsTemplateEdit {
                    Text("Edit the template to commit")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            HStack {
                Spacer()
                Button("Cancel") { windowState.isCommitSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Commit") { onSubmit(windowState.commitMessage) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!windowState.canCommit)
                    .help("Commit (⌘↩)")
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear { editorFocused = true }
    }
}
