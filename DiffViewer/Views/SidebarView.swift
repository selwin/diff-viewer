import SwiftUI

struct SidebarView: View {
    @Environment(AppServices.self) private var services
    @Environment(WindowState.self) private var windowState
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var windowState = windowState
        List(selection: $windowState.selection) {
            if !windowState.isEmpty, windowState.files.isEmpty {
                // A scope change empties the list before the read that refills it
                // returns; on a slow repository, saying "no changes" in that gap would
                // report a result nobody has yet.
                if windowState.isLoadingScope {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                } else {
                    Text(windowState.scope == .workingTree ? "No changes" : "No changes in this commit")
                        .foregroundStyle(.secondary)
                }
            }
            if !windowState.unstagedFiles.isEmpty {
                Section("Unstaged (\(windowState.unstagedFiles.count))") {
                    ForEach(windowState.unstagedFiles) { FileRow(file: $0) }
                }
            }
            if !windowState.stagedFiles.isEmpty {
                Section("Staged (\(windowState.stagedFiles.count))") {
                    ForEach(windowState.stagedFiles) { FileRow(file: $0) }
                }
            }
            // A commit has one list: its own staging is long settled.
            if !windowState.commitFiles.isEmpty {
                Section("Changed (\(windowState.commitFiles.count))") {
                    ForEach(windowState.commitFiles) { FileRow(file: $0) }
                }
            }
        }
        .listStyle(.sidebar)
        // Keyed on the ids, not the files: staging moves a row between sections and should
        // slide, while line counts arriving for the same rows should not start a transaction.
        .animation(.default, value: windowState.files.map(\.id))
        // The list-level form hands over the row that was right-clicked even when it is
        // not the selected one, which is what a Finder-shaped sidebar is expected to do.
        .contextMenu(forSelectionType: DiffSelection.self) { selections in
            contextMenu(for: Set(selections.compactMap(\.fileID)))
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !windowState.isEmpty {
                VStack(spacing: 0) {
                    CommitPickerView()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    Divider()
                }
                .background(.bar)
            }
        }
    }

    /// The menu for exactly one row. A header, blank space, a placeholder row, or a
    /// multiple selection hands over an empty or larger set and has nothing to act on.
    @ViewBuilder
    private func contextMenu(for ids: Set<ChangedFile.ID>) -> some View {
        if ids.count == 1, let id = ids.first, let file = windowState.files.first(where: { $0.id == id }) {
            // Whether the file is on disk is the view's question, not the model's: it is
            // true only at the moment the menu is built, and one stat per right-click is
            // cheap, where keeping it on `ChangedFile` would mean statting every row on
            // every refresh to hold an answer that goes stale anyway.
            let existsOnDisk =
                windowState.repositoryRoot.map {
                    FileManager.default.fileExists(atPath: $0.url.appendingPathComponent(file.path).path)
                } ?? false
            let actions = FileAction.menu(for: file, existsOnDisk: existsOnDisk)
            let writes = actions.filter(\.isRepositoryWrite)
            let harmless = actions.filter { !$0.isRepositoryWrite }
            ForEach(writes, id: \.self) { action in
                Button(action.title(for: file)) { run(action, on: file) }
            }
            // Separate what changes the repository from what only looks at the file.
            if !writes.isEmpty, !harmless.isEmpty {
                Divider()
            }
            ForEach(harmless, id: \.self) { action in
                Button(action.title(for: file)) { run(action, on: file) }
            }
        } else {
            EmptyView()
        }
    }

    /// The runner confirms first, so it needs this window to hang the sheet on.
    private func run(_ action: FileAction, on file: ChangedFile) {
        let runner = FileActionRunner(
            windowState: windowState,
            preferences: preferences,
            window: services.windows[windowState.id]
        )
        Task { await runner.run(action, on: file) }
    }
}

private struct FileRow: View {
    let file: ChangedFile

    var body: some View {
        HStack(spacing: 8) {
            Text(String(file.kind.rawValue))
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(badgeColor, in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            ChurnLabel(stats: file.lineStats)
        }
        .tag(DiffSelection.file(file.id))
        .help(file.originalPath.map { "\(file.kind.label) from \($0)" } ?? file.kind.label)
    }

    private var badgeColor: Color {
        switch file.kind {
        case .modified, .typeChanged: .orange
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed, .copied: .blue
        case .unmerged: .purple
        }
    }
}

/// Shared with the scope button in `CommitPickerView`, which sums the list it scopes.
struct ChurnLabel: View {
    let stats: LineStats?

    var body: some View {
        switch stats {
        case nil:
            EmptyView()
        case .binary:
            Text("binary")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize()
                .lineLimit(1)
                .help("Binary file")
        case .counted(let added, let deleted):
            // A side that did not change is left out, so a pure addition reads "+12"
            // rather than "+12 −0"; a file with no churn at all shows nothing.
            HStack(spacing: 4) {
                if added > 0 {
                    Text("+\(added)").foregroundStyle(.green)
                }
                if deleted > 0 {
                    Text("−\(deleted)").foregroundStyle(.red)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .fixedSize()
            .lineLimit(1)
            .help(countedHelpText(added: added, deleted: deleted))
        }
    }

    private func countedHelpText(added: Int, deleted: Int) -> String {
        let addedLabel = added == 1 ? "1 line added" : "\(added) lines added"
        let deletedLabel = deleted == 1 ? "1 line deleted" : "\(deleted) lines deleted"
        return "\(addedLabel), \(deletedLabel)"
    }
}
