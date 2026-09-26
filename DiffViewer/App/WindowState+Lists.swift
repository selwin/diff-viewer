import Foundation

/// The sidebar's two lists: Changes, which holds everything but the staged files, and the
/// staging tray's list below it. Each has its own focus and scroll position.
enum SidebarList: Hashable {
    case changes
    case staged

    /// The list rows of `area` are drawn in.
    init(area: ChangedFile.Area) {
        self = area == .staged ? .staged : .changes
    }
}

/// The lists and names derived from `session`, `files` and `selection`: what the sidebar
/// draws, what the detail area shows, and what the prefetcher warms.
///
/// An extension rather than more of the class body, which is long enough already. Every
/// member here only reads state, so none of it has to live in the file that owns it.
extension WindowState {
    var repositoryRoot: RepositoryRoot? { session?.root }
    var isEmpty: Bool { session == nil }
    var repoName: String { repositoryRoot?.name ?? "DiffViewer" }

    /// What the detail area shows, derived from the selection set.
    enum DetailSelection: Equatable {
        case nothing
        /// The set contains All changes; it wins over any file rows also in the set, which
        /// is routine: ⌘A and a ⇧-click range from the top both include that row.
        case allChanges
        /// Exactly one file row.
        case file(ChangedFile.ID)
        /// Two or more file rows; `selectedFiles` lists them in sidebar order.
        case files
    }

    /// The mode and the rows the pane is drawn from. Equal identities draw the same rows,
    /// so a change that keeps it resets no navigation; a refresh may still reload the same
    /// rows because their contents changed.
    struct DetailIdentity: Equatable {
        let detail: DetailSelection
        let ids: [ChangedFile.ID]
    }

    var detailSelection: DetailSelection {
        guard !selection.contains(.allChanges) else { return .allChanges }
        let ids = selection.compactMap(\.fileID)
        if ids.isEmpty { return .nothing }
        return ids.count == 1 ? .file(ids[0]) : .files
    }

    var detailIdentity: DetailIdentity {
        switch detailSelection {
        case .allChanges: DetailIdentity(detail: .allChanges, ids: sidebarRows.map(\.id))
        case .files: DetailIdentity(detail: .files, ids: selectedFiles.map(\.id))
        case let .file(id): DetailIdentity(detail: .file(id), ids: [id])
        case .nothing: DetailIdentity(detail: .nothing, ids: [])
        }
    }

    /// The selected file rows, in sidebar order rather than the set's own. A changeset is
    /// drawn in that order, so this is what builds it.
    var selectedFiles: [ChangedFile] {
        sidebarRows.filter { selection.contains(.file($0.id)) }
    }

    /// The writes the selected file rows offer, for the Changes menu. Empty while All
    /// changes is in the selection: it wins the detail pane, so the rows beside it are
    /// not what the reader is looking at.
    var selectedWriteGroups: [FileAction.WriteGroup] {
        switch detailSelection {
        case .file, .files: FileAction.writeGroups(for: selectedFiles)
        case .allChanges, .nothing: []
        }
    }

    /// The selected file's id, or nil unless exactly one file row is selected. Read-only:
    /// every rule about the selection is written on `selection`, which can tell an
    /// explicit "All changes" from "nothing".
    var selectedFileID: ChangedFile.ID? {
        if case let .file(id) = detailSelection { return id }
        return nil
    }

    var selectedFile: ChangedFile? {
        files.first { $0.id == selectedFileID }
    }

    var unstagedFiles: [ChangedFile] { files.filter { $0.area == .unstaged } }
    var stagedFiles: [ChangedFile] { files.filter { $0.area == .staged } }
    /// The selected commit's files. Empty in working-tree scope.
    var commitFiles: [ChangedFile] { files.filter(\.area.isCommit) }

    /// The files in the order the sidebar draws them, which is not the order of `files`:
    /// `GitClient.status()` sorts staged first, and the sidebar lists unstaged first.
    /// Any rule that speaks of "the row above" or "the next row" means an index here.
    var sidebarRows: [ChangedFile] { unstagedFiles + stagedFiles + commitFiles }

    /// The rows `list` draws, in sidebar order.
    func rows(in list: SidebarList) -> [ChangedFile] {
        switch list {
        case .changes: unstagedFiles + commitFiles
        case .staged: stagedFiles
        }
    }

    /// The sidebar docks the staged files and the commit button below the other rows. A
    /// merge keeps it with nothing staged, because the merge itself is still to commit.
    var showsStagingTray: Bool {
        scope == .workingTree && (!stagedFiles.isEmpty || commitDefaults.isMerging)
    }

    /// Files worth warming in the difft cache: everything in the current scope but the
    /// selection, which is the loader's job at foreground priority.
    var filesToWarm: [ChangedFile] {
        // All changes is already reading and diffing every file at foreground priority;
        // prefetching would read and hash the same files a second time.
        guard detailSelection != .allChanges else { return [] }
        // Unstaged first, as before: that is the list a reader works down. The working
        // tree can fill both of its lists at once; a commit fills only the third.
        return sidebarRows.filter { !selection.contains(.file($0.id)) }
    }
}
