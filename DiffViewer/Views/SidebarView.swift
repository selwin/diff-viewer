import SwiftUI

/// The Changes list, and below it the staging tray while the working tree has something
/// to commit. Both lists share one selection; each has its own focus and scroll position.
struct SidebarView: View {
    @Environment(WindowState.self) private var windowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Owned by `ContentView`, which also needs to know when a list has focus.
    var focusedList: FocusState<SidebarList?>.Binding
    @State private var sidebarHeight: CGFloat = 0

    var body: some View {
        let isTrayExpanded =
            windowState.repositoryRoot.map { windowState.preferences.isStagingTrayExpanded(for: $0) } ?? false
        let capsule = windowState.stagingCapsule
        // A collapsed tray leaves its list out, which also moves focus off it below.
        let stagedListHeight =
            isTrayExpanded
            ? StagingTrayLayout.listHeight(
                rowCount: windowState.stagedFiles.count, sidebarHeight: sidebarHeight,
                holdsSelection: windowState.selectedFiles.contains { $0.area == .staged }, hasCapsule: capsule != nil)
            : 0
        let showsStagedList = windowState.showsStagingTray && stagedListHeight > 0
        VStack(spacing: 0) {
            changesList
            if windowState.showsStagingTray {
                StagingTrayView(
                    listHeight: stagedListHeight, isExpanded: isTrayExpanded,
                    hasCapsule: capsule != nil, focusedList: focusedList
                )
                .alignmentGuide(.stagingCapsule) { $0[.top] }
                // Under Reduce Motion nothing slides: the tray fades in place, with its own
                // animation since the layout ones below are off.
                .transition(
                    reduceMotion
                        ? .opacity.animation(.easeInOut(duration: 0.2)) : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Above both lists, and placed by layout, so it rides the tray as it slides and grows.
        .overlay(alignment: Alignment(horizontal: .center, vertical: .stagingCapsule)) {
            stagingCapsule(capsule)
        }
        // The capsule's entrance, and the tray making room for it in the same beat.
        .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.2), value: capsule != nil)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: {
            sidebarHeight = $0
        }
        // Keyed on the ids, not the files: staging moves a row between the lists and should
        // slide, while line counts arriving for the same rows should not start a transaction.
        // A merge shows the tray with no staged ids changing.
        .animation(reduceMotion ? nil : .default, value: windowState.files.map(\.id))
        .animation(reduceMotion ? nil : .default, value: windowState.showsStagingTray)
        // A focused list that goes away would leave the keyboard nowhere in the sidebar.
        .onChange(of: showsStagedList) { _, shows in
            if !shows, focusedList.wrappedValue == .staged { focusedList.wrappedValue = .changes }
        }
    }

    /// Centred on the tray's top edge, or floating 14pt above the sidebar's foot without one.
    /// One view whether it reads Stage or Unstage, so only coming and going run the entrance.
    private func stagingCapsule(_ capsule: StagingCapsule?) -> some View {
        let showsTray = windowState.showsStagingTray
        return ZStack {
            if let capsule {
                StagingCapsuleView(capsule: capsule)
                    .transition(
                        reduceMotion
                            ? .opacity.animation(.easeInOut(duration: 0.2))
                            : .opacity.combined(with: .offset(y: 12)).combined(with: .scale(scale: 0.94)))
            }
        }
        .alignmentGuide(.stagingCapsule) { showsTray ? $0[VerticalAlignment.center] : $0[.bottom] + 14 }
    }

    private var changesList: some View {
        @Bindable var windowState = windowState
        // Both lists bind the one selection, and the model's setter keeps it to one list:
        // a click, ⌘-click or ⇧-click in either clears the other's rows, so a selection
        // always has one staging action. The arrow keys stay within one list. The setter
        // also drops All changes from a multi-selection, so ⌘A and a ⇧-click range from
        // the top select only files.
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
                        SidebarFileRow(file: $0)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("Changes")
                        Text("\(windowState.unstagedFiles.count)")
                    }
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11, weight: .semibold))
                }
            }
            // A commit has one list: its own staging is long settled.
            if !windowState.commitFiles.isEmpty {
                Section("Changed (\(windowState.commitFiles.count))") {
                    ForEach(windowState.commitFiles) {
                        SidebarFileRow(file: $0)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Room for the last row to scroll clear of the staging capsule.
        .safeAreaPadding(.bottom, 64)
        .modifier(SidebarListBehavior(list: .changes, focusedList: focusedList))
    }
}

/// What both sidebar lists do alike: take part in focus and the Changes menu, clear the
/// selection on Escape or a blank click, and offer the file context menu.
struct SidebarListBehavior: ViewModifier {
    let list: SidebarList
    var focusedList: FocusState<SidebarList?>.Binding
    @Environment(AppServices.self) private var services
    @Environment(WindowState.self) private var windowState

    func body(content: Content) -> some View {
        content
            .focused(focusedList, equals: list)
            // Only while a list or a row control has focus, so Discard and Move to Trash
            // never act on rows the reader is not looking at.
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
    var showsChurn = true

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
            if showsChurn {
                ChurnLabel(stats: file.lineStats)
            }
        }
        .tag(DiffSelection.file(file.id))
        .help(file.originalPath.map { "\(file.kind.label) from \($0)" } ?? file.kind.label)
    }

    /// Truncated at the head so the file name at the end stays visible.
    private func caption(_ text: String) -> some View {
        Text(text).lineLimit(1).truncationMode(.head)
    }
}

extension VerticalAlignment {
    /// Where the staging capsule docks: the tray's top edge, or the sidebar's foot without a tray.
    private enum StagingCapsuleDock: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.bottom] }
    }

    fileprivate static let stagingCapsule = VerticalAlignment(StagingCapsuleDock.self)
}
