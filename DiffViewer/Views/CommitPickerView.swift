import SwiftUI

/// Picks what the sidebar shows: the working tree, or one commit from the branch's
/// history. Sits above the file list, which it scopes.
struct CommitPickerView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        Menu {
            // Working Tree is always a row, whatever the history is doing: someone who
            // selects a commit and then checks out a branch with no commits still needs a
            // way back.
            Picker("Showing", selection: scopeBinding) {
                Text("Working Tree").tag(DiffScope.workingTree)
                ForEach(listedCommits) { commit in
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
        } label: {
            Text(currentLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .help("Choose what to compare: the working tree, or a commit against its parent")
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var scopeBinding: Binding<DiffScope> {
        Binding(
            get: { windowState.scope },
            set: { newScope in
                switch newScope {
                case .workingTree:
                    windowState.selectWorkingTree()
                case let .commit(ref):
                    guard let commit = listedCommits.first(where: { $0.ref == ref }) else { return }
                    windowState.select(commit: commit)
                }
            }
        )
    }

    /// The loaded page, plus the selected commit when it is not in it: a branch switch or
    /// a page reset can drop it, and the picker still has to tick what is on screen.
    private var listedCommits: [CommitSummary] {
        let page = windowState.history.commits
        guard let selected = windowState.selectedCommit, !page.contains(where: { $0.ref == selected.ref })
        else { return page }
        return [selected] + page
    }

    private var currentLabel: String {
        switch windowState.scope {
        case .workingTree: "Working Tree"
        case let .commit(ref): windowState.selectedCommit.map(label(for:)) ?? ref.shortSha
        }
    }

    /// One line per row: menus on macOS do not lay out stacked text the way an ordinary
    /// view does, so everything a row shows goes into a single string.
    private func label(for commit: CommitSummary) -> String {
        let subject = commit.subject.count > 60 ? String(commit.subject.prefix(59)) + "…" : commit.subject
        // Built per call rather than shared: a formatter is a reference type, and this
        // runs only while a menu is open.
        let ages = RelativeDateTimeFormatter()
        ages.unitsStyle = .abbreviated
        let age = ages.localizedString(for: commit.authoredAt, relativeTo: .now)
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
