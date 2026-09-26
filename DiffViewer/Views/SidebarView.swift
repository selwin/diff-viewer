import SwiftUI

/// The Changes list, and below it the staging tray while the working tree has something
/// to commit. Both lists share one selection; each has its own focus and scroll position.
struct SidebarView: View {
    @Environment(WindowState.self) private var windowState
    /// Owned by `ContentView`, which also needs to know when a list has focus.
    var focusedList: FocusState<SidebarList?>.Binding
    @State private var sidebarHeight: CGFloat = 0
    @State private var pendingReveal: SidebarReveal?

    var body: some View {
        // The selection popover points at this row, so it alone measures its frame.
        let firstSelectedID = windowState.selectedFiles.first?.id
        let stagedListHeight = StagingTrayLayout.listHeight(
            rowCount: windowState.stagedFiles.count, sidebarHeight: sidebarHeight,
            holdsSelection: windowState.selectedFiles.contains { $0.area == .staged })
        let showsStagedList = windowState.showsStagingTray && stagedListHeight > 0
        VStack(spacing: 0) {
            changesList(firstSelectedID: firstSelectedID)
            if windowState.showsStagingTray {
                StagingTrayView(
                    listHeight: stagedListHeight, firstSelectedID: firstSelectedID, focusedList: focusedList,
                    pendingReveal: $pendingReveal
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: {
            sidebarHeight = $0
        }
        // Keyed on the ids, not the files: staging moves a row between the lists and should
        // slide, while line counts arriving for the same rows should not start a transaction.
        // A merge shows the tray with no staged ids changing.
        .animation(.default, value: windowState.files.map(\.id))
        .animation(.default, value: windowState.showsStagingTray)
        // A stage or unstage carried the selection across: the list it landed in reveals
        // its first selected row there, and takes focus if the sidebar had it, so the
        // keyboard keeps working on the rows the reader was on.
        .onChange(of: windowState.selectionMove) { _, move in
            guard let move else { return }
            let list = SidebarList(area: move.area)
            guard let row = windowState.selectedFiles.first(where: { SidebarList(area: $0.area) == list }) else {
                return
            }
            pendingReveal = SidebarReveal(
                list: list, rowID: row.id, takesFocus: focusedList.wrappedValue != nil, serial: move.serial)
        }
        // A focused list that goes away would leave the keyboard nowhere in the sidebar.
        .onChange(of: showsStagedList) { _, shows in
            if !shows, focusedList.wrappedValue == .staged { focusedList.wrappedValue = .changes }
        }
    }

    private func changesList(firstSelectedID: ChangedFile.ID?) -> some View {
        @Bindable var windowState = windowState
        // Both lists bind the one selection. The intent: a plain click in either replaces
        // it, ⌘-click keeps the other list's rows, ⇧-click extends within the clicked list
        // and keeps the other's, and the arrow keys stay within one list. If AppKit drops
        // the rows its table does not hold on ⌘- or ⇧-click, the fallback is one list at a
        // time: each list's getter filters the selection to its own rows and its setter
        // replaces the selection with them.
        return List(selection: $windowState.selection) {
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
                Section {
                    ForEach(windowState.unstagedFiles) {
                        SidebarFileRow(file: $0, isFirstSelected: $0.id == firstSelectedID)
                    }
                } header: {
                    HStack {
                        Text("Changes")
                        Spacer()
                        Text("\(windowState.unstagedFiles.count)")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    // Section headers run to the sidebar's edge; the rows' counts stop short of it.
                    .padding(.trailing, 12)
                }
            }
            // A commit has one list: its own staging is long settled.
            if !windowState.commitFiles.isEmpty {
                Section("Changed (\(windowState.commitFiles.count))") {
                    ForEach(windowState.commitFiles) {
                        SidebarFileRow(file: $0, isFirstSelected: $0.id == firstSelectedID)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .modifier(SidebarListBehavior(list: .changes, focusedList: focusedList, pendingReveal: $pendingReveal))
    }
}

/// A row a stage or unstage carried into `list`, waiting for that list to scroll to it.
/// `takesFocus` records whether a sidebar list had focus when the row moved.
struct SidebarReveal: Equatable {
    let list: SidebarList
    let rowID: ChangedFile.ID
    let takesFocus: Bool
    let serial: Int
}

/// What both sidebar lists do alike: report their viewport to the selection popover, take
/// part in focus and the Changes menu, clear the selection on Escape or a blank click,
/// offer the file context menu, and reveal a row moved into them.
struct SidebarListBehavior: ViewModifier {
    let list: SidebarList
    var focusedList: FocusState<SidebarList?>.Binding
    @Binding var pendingReveal: SidebarReveal?
    @Environment(AppServices.self) private var services
    @Environment(WindowState.self) private var windowState
    @Environment(SidebarRowFrames.self) private var rowFrames
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                // The proxy's frame already leaves out the toolbar's safe area, so a row
                // scrolled under the toolbar falls outside it and counts as out of sight.
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    rowFrames.visibleListFrames[list] = frame
                    height = frame.height
                    reveal(with: proxy)
                }
                .onDisappear { rowFrames.visibleListFrames[list] = nil }
                .onAppear { reveal(with: proxy) }
                .onChange(of: pendingReveal) { reveal(with: proxy) }
                .focused(focusedList, equals: list)
                // Only while a list or a row control has focus, so the Changes menu's
                // shortcuts never fire from the find bar or the commit sheet, where S and U
                // are typed.
                .focusedValue(\.fileListWindowState, windowState)
                .onExitCommand { windowState.selection = [] }
                // A row click takes focus back from the diff pane, and a click below the
                // last row clears the selection as Finder does; the List does neither by
                // itself. Each list's monitor looks only at clicks inside that list.
                .background { SidebarClickMonitor { windowState.selection = [] } }
                // The list-level form hands over the whole selection when the right-clicked
                // row is part of it, and that row alone when it is not, which is what a
                // Finder-shaped sidebar is expected to do.
                .contextMenu(forSelectionType: DiffSelection.self) { selections in
                    SidebarFileContextMenu(
                        ids: Set(selections.compactMap(\.fileID)), windowState: windowState, services: services)
                }
        }
    }

    /// Waits for a laid-out list: a tray the same refresh inserted has no rows to scroll to
    /// yet. The first attempt against a list with height settles the reveal, so a later
    /// resize never scrolls the reader back.
    private func reveal(with proxy: ScrollViewProxy) {
        guard let pendingReveal, pendingReveal.list == list, height > 0 else { return }
        proxy.scrollTo(pendingReveal.rowID)
        if pendingReveal.takesFocus { focusedList.wrappedValue = list }
        self.pendingReveal = nil
    }
}

/// The menu for the rows `ids` names, in sidebar order: one code path for one row and for
/// twenty. Every item, write or not, must apply to every selected file.
/// Right-clicking a row outside the selection still acts on that row alone — the list
/// hands over just that id — and a header, blank space, or the All changes row names no
/// file at all, which has nothing to act on.
struct SidebarFileContextMenu: View {
    let ids: Set<ChangedFile.ID>
    let windowState: WindowState
    let services: AppServices

    var body: some View {
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
        let runner = FileActionRunner(windowState: windowState, services: services)
        Task { await runner.run(action, on: files) }
    }
}

struct SidebarFileRow: View {
    let file: ChangedFile
    /// The selection popover points at this row.
    let isFirstSelected: Bool
    @Environment(SidebarRowFrames.self) private var rowFrames
    /// Kept for a row the List hides and shows again in place: its frame has not changed,
    /// so the geometry callback stays quiet, but hiding it cleared the store.
    @State private var measuredFrame: CGRect?

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
        // Every other row returns nil, so only the first selected row ever reports.
        .onGeometryChange(for: CGRect?.self) { proxy in
            isFirstSelected ? proxy.frame(in: .global) : nil
        } action: { frame in
            measuredFrame = frame
            publishFrame()
        }
        .onChange(of: isFirstSelected) { _, isFirst in
            if !isFirst { rowFrames.clearFirstSelectedRow(ifOwnedBy: file.id) }
        }
        .onAppear {
            rowFrames.rowAppeared(file.id)
            publishFrame()
        }
        .onDisappear { rowFrames.rowDisappeared(file.id) }
        .tag(DiffSelection.file(file.id))
        .help(file.originalPath.map { "\(file.kind.label) from \($0)" } ?? file.kind.label)
    }

    private func publishFrame() {
        guard isFirstSelected, let measuredFrame else { return }
        rowFrames.firstSelectedRow = SidebarRowFrames.RowFrame(id: file.id, frame: measuredFrame)
    }

    /// Truncated at the head so the file name at the end stays visible.
    private func caption(_ text: String) -> some View {
        Text(text).lineLimit(1).truncationMode(.head)
    }
}
