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
            // Outside every section, so the whole-list row sits above the headings
            // rather than inside one of them.
            if !windowState.files.isEmpty {
                HStack(spacing: 8) {
                    Label("All changes", systemImage: "square.stack")
                    Spacer(minLength: 8)
                    ChurnLabel(stats: LineStats.total(of: windowState.files))
                }
                .tag(DiffSelection.allChanges)
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
        // The list-level form hands over the whole selection when the right-clicked row is
        // part of it, and that row alone when it is not, which is what a Finder-shaped
        // sidebar is expected to do.
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

    /// The menu for the rows `ids` names, in sidebar order: one code path for one row and
    /// for twenty, since the items a selection offers are the items every row in it offers.
    /// Right-clicking a row outside the selection still acts on that row alone — the list
    /// hands over just that id — and a header, blank space, or the All changes row names no
    /// file at all, which has nothing to act on.
    @ViewBuilder
    private func contextMenu(for ids: Set<ChangedFile.ID>) -> some View {
        let files = windowState.sidebarRows.filter { ids.contains($0.id) }
        if files.isEmpty {
            EmptyView()
        } else {
            // Whether a file is on disk is the view's question, not the model's: it is
            // true only at the moment the menu is built, and one stat per row per
            // right-click is cheap, where keeping it on `ChangedFile` would mean statting
            // every row on every refresh to hold an answer that goes stale anyway.
            let actions = FileAction.menu(for: files) { file in
                windowState.repositoryRoot.map {
                    FileManager.default.fileExists(atPath: $0.url.appendingPathComponent(file.path).path)
                } ?? false
            }
            let writes = actions.filter(\.isRepositoryWrite)
            let harmless = actions.filter { !$0.isRepositoryWrite }
            ForEach(writes, id: \.self) { action in
                Button(action.title(for: files)) { run(action, on: files) }
            }
            // Separate what changes the repository from what only looks at the files.
            if !writes.isEmpty, !harmless.isEmpty {
                Divider()
            }
            ForEach(harmless, id: \.self) { action in
                Button(action.title(for: files)) { run(action, on: files) }
            }
        }
    }

    /// The runner confirms first — once for the whole batch — so it needs this window to
    /// hang the sheet on.
    private func run(_ action: FileAction, on files: [ChangedFile]) {
        let runner = FileActionRunner(
            windowState: windowState,
            preferences: preferences,
            window: services.windows[windowState.id]
        )
        Task { await runner.run(action, on: files) }
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
        Color(nsColor: DiffTheme.badge(for: file.kind))
    }
}

/// Shared with the scope button in `CommitPickerView`, which sums the list it scopes.
struct ChurnLabel: View {
    let stats: LineStats?
    /// A selected row inverts its text to white; the counts follow the file name
    /// there and let the +/− signs carry the meaning.
    @Environment(\.backgroundProminence) private var prominence

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
                    Text("+\(added)").foregroundStyle(addedStyle)
                }
                if deleted > 0 {
                    Text("−\(deleted)").foregroundStyle(deletedStyle)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .fixedSize()
            .lineLimit(1)
            .help(countedHelpText(added: added, deleted: deleted))
        }
    }

    private var addedStyle: AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.green)
    }

    private var deletedStyle: AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.red)
    }

    private func countedHelpText(added: Int, deleted: Int) -> String {
        let addedLabel = added == 1 ? "1 line added" : "\(added) lines added"
        let deletedLabel = deleted == 1 ? "1 line deleted" : "\(deleted) lines deleted"
        return "\(addedLabel), \(deletedLabel)"
    }
}
