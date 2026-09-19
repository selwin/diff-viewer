import SwiftUI

/// The rows of the scope menu: Working Tree, the loaded commits, and what the history
/// has to say for itself. Opened from the title bar's `ScopePickerView`.
struct ScopeMenuContent: View {
    @Environment(WindowState.self) private var windowState

    static let scopeSelectionHelp = "Choose what to compare: the working tree, or a commit against its parent"

    var body: some View {
        // Working Tree is always a row, whatever the history is doing: someone who
        // selects a commit and then checks out a branch with no commits still needs a
        // way back.
        Picker("Showing", selection: scopeBinding) {
            Text("Working Tree").tag(DiffScope.workingTree)
            ForEach(windowState.selectableCommits) { commit in
                Text(label(for: commit)).tag(DiffScope.commit(commit.ref))
            }
        }
        .pickerStyle(.inline)

        // Plain text in a menu reads as an unavailable item, which is what loading,
        // empty and failed histories should look like — distinct from each other, and
        // never a row that can be chosen.
        if let placeholder = windowState.historyPlaceholder {
            Divider()
            Text(placeholder.label)
        }

        if windowState.history.hasMore {
            Divider()
            Button("Load \(WindowState.commitPageSize) More…") { windowState.loadMoreCommits() }
                .disabled(windowState.isLoadingHistory)
        }
    }

    private var scopeBinding: Binding<DiffScope> {
        Binding(get: { windowState.scope }, set: { windowState.select(scope: $0) })
    }

    /// Shared rather than built per row: a page of fifty rows is formatted each time the
    /// menu opens. Confined to the main actor because `RelativeDateTimeFormatter` is a
    /// reference type, and every caller is a view body.
    @MainActor private static let ages: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// One line per row: menus on macOS do not lay out stacked text the way an ordinary
    /// view does, so everything a row shows goes into a single string.
    private func label(for commit: CommitSummary) -> String {
        let subject = commit.subject.count > 60 ? String(commit.subject.prefix(59)) + "…" : commit.subject
        let age = Self.ages.localizedString(for: commit.authoredAt, relativeTo: .now)
        var line = "\(commit.ref.shortSha)  \(subject) · \(age)"
        if commit.isMerge { line += "  (merge)" }
        return line
    }
}

extension WindowState.HistoryPlaceholder {
    var label: String {
        switch self {
        case .loading: "Loading…"
        case .empty: "No commits yet"
        case .failed: "Couldn't load history"
        }
    }
}
