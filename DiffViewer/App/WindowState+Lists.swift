import Foundation

/// The lists and names derived from `session`, `files` and `selection`: what the sidebar
/// draws, what the detail area shows, and what the prefetcher warms.
///
/// An extension rather than more of the class body, which is long enough already. Every
/// member here only reads state, so none of it has to live in the file that owns it.
extension WindowState {
    var repositoryRoot: RepositoryRoot? { session?.root }
    var isEmpty: Bool { session == nil }
    var repoName: String { repositoryRoot?.name ?? "DiffViewer" }

    /// The selected file's id, or nil while All changes or nothing is selected. Read-only:
    /// every rule about the selection is written on `selection`, which can tell an
    /// explicit "All changes" from "nothing".
    var selectedFileID: ChangedFile.ID? { selection?.fileID }

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

    /// Files worth warming in the difft cache: everything in the current scope but the
    /// selection, which is the loader's job at foreground priority.
    var filesToWarm: [ChangedFile] {
        // All changes is already reading and diffing every file at foreground priority;
        // prefetching would read and hash the same files a second time.
        guard selection != .allChanges else { return [] }
        // Unstaged first, as before: that is the list a reader works down. The working
        // tree can fill both of its lists at once; a commit fills only the third.
        return sidebarRows.filter { $0.id != selectedFileID }
    }
}
