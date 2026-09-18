import SwiftUI

/// Writes the commit message and records the index as a commit. Sits below the file list
/// in working-tree scope; the draft, whether Commit is available, and the caption below
/// the editor all come from `WindowState`.
struct CommitBoxView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        @Bindable var windowState = windowState
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $windowState.commitMessage)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .frame(height: 96)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .accessibilityLabel("Commit message")
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
            HStack(spacing: 8) {
                // One slot: a merge is the more urgent of the two to say.
                Group {
                    if windowState.commitDefaults.isMerging {
                        Text("Merge in progress")
                    } else if windowState.commitNeedsTemplateEdit {
                        Text("Edit the template to commit")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Spacer()
                // Hooks and signing can take seconds; the button alone would look stuck.
                if windowState.isCommitting {
                    ProgressView().controlSize(.small)
                }
                // Like Refresh, the shortcut lives on the menu item so it fires once.
                Button("Commit") { Task { await windowState.commit() } }
                    .disabled(!windowState.canCommit)
                    .help("Commit (⌘↩)")
            }
        }
    }
}
