import SwiftUI

/// Stashes the working tree: an optional message and whether untracked files go too.
/// Stash only reports the submission; the parent dismisses and stashes, and git's refusal
/// arrives as the window's error.
struct StashSheet: View {
    @Environment(WindowState.self) private var windowState
    @Environment(Preferences.self) private var preferences
    @State private var message = ""
    @FocusState private var messageFocused: Bool
    let onStash: (StashSubmission) -> Void

    var body: some View {
        @Bindable var preferences = preferences
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Stash Changes").font(.system(size: 15, weight: .bold))
                Text("Stashes all staged and unstaged changes on \(windowState.currentHeadTitle)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 10) {
                messageField
                Toggle("Include untracked files", isOn: $preferences.stashIncludesUntracked)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                caption
            }
            actions
        }
        .padding(20)
        .frame(width: 380)
        // The same translucent material as the commit sheet.
        .presentationBackground(.regularMaterial)
        .onAppear { messageFocused = true }
    }

    private var blockedReason: String? {
        windowState.stashSubmissionBlockedReason(includeUntracked: preferences.stashIncludesUntracked)
    }

    private func submit() {
        guard blockedReason == nil else { return }
        onStash(StashSubmission(message: message, includeUntracked: preferences.stashIncludesUntracked))
    }

    private var messageField: some View {
        TextField("Message (optional)", text: $message)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($messageFocused)
            .onSubmit(submit)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: SheetFieldPalette.fieldFill)))
            .overlay {
                // A subtle focus cue instead of the system ring.
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        messageFocused ? Color.primary.opacity(0.3) : Color(nsColor: SheetFieldPalette.fieldBorder),
                        lineWidth: 0.5)
            }
    }

    /// The reason a stash can't go ahead, else how many files it takes. One line either
    /// way, so the sheet doesn't resize as the checkbox changes it.
    private var caption: some View {
        Text(blockedReason ?? countText)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 2)
    }

    private var countText: String {
        let churn = windowState.workingTreeChurn
        var count = churn?.trackedFileCount ?? 0
        if preferences.stashIncludesUntracked { count += churn?.untrackedFileCount ?? 0 }
        return count == 1 ? "1 file" : "\(count) files"
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                windowState.isStashSheetPresented = false
            } label: {
                Text("Cancel").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(SheetCapsuleButtonStyle(appearance: .neutral))
            .keyboardShortcut(.cancelAction)
            Button(action: submit) {
                HStack(spacing: 6) {
                    Text("Stash").font(.system(size: 13, weight: .semibold))
                    Text("⌘↩")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.6)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(SheetCapsuleButtonStyle(appearance: .prominent))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(blockedReason != nil)
            .help("Stash (⌘↩)")
        }
    }
}
