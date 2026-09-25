import SwiftUI

struct SidebarView: View {
    @Environment(AppServices.self) private var services
    @Environment(WindowState.self) private var windowState
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var windowState = windowState
        let staged = windowState.stagedFiles
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
                } else if windowState.listReadFailed {
                    // The list was emptied for a re-read that then threw: "no changes"
                    // would describe a working tree nobody has read.
                    HStack(spacing: 6) {
                        Text("Couldn't load changes").foregroundStyle(.secondary)
                        Button("Retry") { Task { await windowState.refresh() } }
                            .buttonStyle(.link)
                            .controlSize(.small)
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
            if !staged.isEmpty {
                Section("Staged (\(staged.count))") {
                    commitRow
                    ForEach(staged) { FileRow(file: $0) }
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
    }

    /// Opens the commit sheet. The first row of the Staged section, with selection off so
    /// it never highlights like a file.
    private var commitRow: some View {
        HStack {
            Spacer()
            // Hooks and signing can take seconds; the button alone would look stuck.
            if windowState.isCommitting {
                ProgressView().controlSize(.small)
            }
            Button("Commit…") { windowState.isCommitSheetPresented = true }
                .disabled(!windowState.canOpenCommitSheet)
                .help("Commit (⌘↩)")
        }
        .controlSize(.small)
        .selectionDisabled()
    }

    /// The menu for the rows `ids` names, in sidebar order: one code path for one row and
    /// for twenty. Write actions use the eligible subset of selected files; non-write
    /// actions must apply to every selected file.
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
            let harmless = FileAction.harmless(for: files) { file in
                windowState.repositoryRoot.map {
                    FileManager.default.fileExists(atPath: $0.url.appendingPathComponent(file.path).path)
                } ?? false
            }
            let writes = FileAction.writeGroups(for: files)
            // A switch in progress refuses writes anyway; greying them out says so first.
            ForEach(writes, id: \.action) { group in
                Button(group.action.title(for: group.files)) { run(group.action, on: group.files) }
                    .disabled(windowState.isSwitchingBranch)
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
            KindBadge(kind: file.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let originalPath = file.originalPath {
                    // The arrow sits outside the truncated text so a long old path keeps it.
                    HStack(spacing: 3) {
                        Text("←")
                        caption(originalPath)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if !file.directory.isEmpty {
                    caption(file.directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            ChurnLabel(stats: file.lineStats)
        }
        .tag(DiffSelection.file(file.id))
        .help(file.originalPath.map { "\(file.kind.label) from \($0)" } ?? file.kind.label)
    }

    /// Truncated at the head so the file name at the end stays visible.
    private func caption(_ text: String) -> some View {
        Text(text).lineLimit(1).truncationMode(.head)
    }
}
