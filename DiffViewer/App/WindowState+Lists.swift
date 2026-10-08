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
        /// The set contains All changes, which is only ever selected alone: the `selection`
        /// setter drops it from a multi-selection.
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

    /// `selection` minus All changes when files are in it too. ⌘A and a ⇧-click range from
    /// the top both take in that row; All changes is a view, not a file, so the files win.
    static func withoutAllChangesBesideFiles(_ selection: Set<DiffSelection>) -> Set<DiffSelection> {
        // Anything beside All changes is a file row: the set holds no other kind.
        guard selection.contains(.allChanges), selection.count > 1 else { return selection }
        return selection.subtracting([.allChanges])
    }

    /// `selection` kept to one sidebar list, so it always has one staging action. When it
    /// holds rows of both, the list of the first newly added row (not in `previous`) wins.
    static func withinOneList(
        _ selection: Set<DiffSelection>, previous: Set<DiffSelection>, rows: [ChangedFile]
    ) -> Set<DiffSelection> {
        guard selection.count > 1 else { return selection }
        let listOfID = Dictionary(
            rows.map { ($0.id, SidebarList(area: $0.area)) }, uniquingKeysWith: { first, _ in first })
        func list(of item: DiffSelection) -> SidebarList? { item.fileID.flatMap { listOfID[$0] } }
        guard Set(selection.compactMap(list)).count > 1 else { return selection }
        let added = selection.subtracting(previous)
        guard let firstAdded = rows.first(where: { added.contains(.file($0.id)) }) else { return selection }
        let kept = SidebarList(area: firstAdded.area)
        return selection.filter { list(of: $0).map { $0 == kept } ?? true }
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

    /// The file actions that write (stage, unstage, discard, trash) available to the
    /// selected file rows, for the Changes menu. Empty for All changes, which is a view
    /// rather than files and is only ever selected alone.
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
    /// What Stage All writes: staging a conflict marks it resolved, which a bulk action
    /// should not do silently. Those rows keep Mark Resolved on their own menu.
    var stageableUnstagedFiles: [ChangedFile] { unstagedFiles.filter { $0.kind != .unmerged } }
    /// The selected commit's files. Empty in working-tree scope.
    var commitFiles: [ChangedFile] { files.filter(\.area.isCommit) }

    /// Whether a staging control (the capsule and the Changes menu's staging items) may start: the
    /// working tree is shown and no branch switch, confirmation, commit or overlay is in
    /// progress. Other repository writes may still be queued; this does not wait for them.
    var canStartStagingAction: Bool {
        session != nil && !isClosed && scope == .workingTree && !isSwitchingBranch && !isConfirmingFileAction
            && !isCommitting && !isCommitSheetPresented && !isCommitPickerPresented && !isBranchPickerPresented
            && !isStashPickerPresented && !isNewBranchSheetPresented && pendingMerge == nil
    }

    /// Whether Stage All can run: a staging action can start and Changes holds something to stage.
    var canStageAll: Bool { canStartStagingAction && !stageableUnstagedFiles.isEmpty }

    /// Sidebar order: unstaged, staged, then commit files. `files` puts staged first;
    /// directory order is kept within each area. Any rule that speaks of "the row above"
    /// or "the next row" means an index here.
    var sidebarRows: [ChangedFile] { unstagedFiles + stagedFiles + commitFiles }

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
