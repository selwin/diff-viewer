import SwiftUI

/// Picks what the sidebar shows: the working tree, or one commit from the branch's
/// history. Sits above the file list, which it scopes. The same menu opens from the
/// title bar's `ScopePickerView`.
struct CommitPickerView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        Menu {
            ScopeMenuContent()
        } label: {
            ScopeLabel(title: title, identity: identity, glyph: scopeIcon)
        }
        // `.plain` leaves the label to SwiftUI. The bordered menu style keeps one image and one
        // text from its label and drops the rest, which rules out a two-line face.
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(ScopeMenuContent.scopeSelectionHelp)
    }

    private var title: String {
        switch windowState.scope {
        case .workingTree: "Working Tree"
        case let .commit(ref): windowState.selectedCommit?.subject ?? ref.shortSha
        }
    }

    private var identity: String {
        switch windowState.scope {
        case .workingTree: "uncommitted"
        case let .commit(ref): ref.shortSha
        }
    }

    private var scopeIcon: String {
        switch windowState.scope {
        case .workingTree: "arrow.triangle.branch"
        case .commit: "smallcircle.filled.circle"
        }
    }
}

/// The rows of the scope menu: Working Tree, the loaded commits, and what the history
/// has to say for itself. Shared by the sidebar picker and the title bar's.
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

/// The button face: always two lines in a fixed box, so switching scope never moves the
/// list below it. Plain data in, so it does not depend on `WindowState`.
private struct ScopeLabel: View {
    let title: String
    let identity: String
    let glyph: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The sha never truncates; only the title gives way.
                Text(identity)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        // The whole box opens the menu, not only the text.
        .contentShape(Rectangle())
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
