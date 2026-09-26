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
        let summary = StagingTraySummary(
            stagedFiles: windowState.stagedFiles, isMerging: windowState.commitDefaults.isMerging)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.commitTitle).font(.headline)
                subtitle(churn: summary.churn)
            }
            editor
            // Newest news first: a failed generation, then a reopened sheet explaining
            // itself, then merge status before template guidance.
            Group {
                if let error = windowState.commitGenerationError {
                    Text(error)
                } else if draftChanged {
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
                Button {
                    windowState.generateCommitMessage()
                } label: {
                    HStack(spacing: 4) {
                        Text("Generate")
                        Image(systemName: "sparkles").accessibilityHidden(true)
                    }
                }
                .disabled(!windowState.canGenerateCommitMessage)
                .help(
                    windowState.commitGenerationUnavailableReason
                        ?? "Generate a commit message from the staged changes (⌘G)"
                )
                .keyboardShortcut("g", modifiers: .command)
                if windowState.isGeneratingCommitMessage {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { windowState.isCommitSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Commit") { onSubmit(windowState.commitMessage) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!windowState.canCommit)
                    .help("Commit (⌘↩)")
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear { editorFocused = true }
    }

    /// "to main · +12 −4": each part only when there is one, and the dot only between two.
    @ViewBuilder
    private func subtitle(churn: LineStats?) -> some View {
        let branch = windowState.currentBranchName
        // Zero counts draw nothing, which would leave a dangling dot or an empty row.
        let churn = ChurnLabel.isEmpty(for: churn) ? nil : churn
        if branch != nil || churn != nil {
            HStack(spacing: 4) {
                if let branch {
                    Text("to \(branch)")
                }
                if branch != nil, churn != nil {
                    Text("·")
                }
                if let churn {
                    ChurnLabel(stats: churn, font: .subheadline.monospacedDigit())
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var editor: some View {
        @Bindable var windowState = windowState
        return TextEditor(text: $windowState.commitMessage)
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
    }
}
