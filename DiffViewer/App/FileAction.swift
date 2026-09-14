import Foundation

/// One item of the sidebar's context menu.
///
/// Which items a row offers is a property of the file, not of the view, so the whole
/// menu is decided here and the view only renders it. The first four write (to the
/// repository or the worktree); the last three are harmless and always available for a
/// path that can be pointed at.
enum FileAction: CaseIterable, Sendable {
    case stage
    case unstage
    case discard
    case trash
    case revealInFinder
    case openInEditor
    case copyPath

    /// The menu for `file`, writes first and harmless items after.
    ///
    /// Reveal and Open are dropped when the path is not on disk: there is nothing to show,
    /// and offering them would only produce an error. Kind cannot answer that — `git rm
    /// --cached` leaves a staged deletion whose file is still there, and a file deleted in
    /// some commit may exist again now — so the caller stats the path and says.
    /// Commit scope offers no writes at all — the diff being read is history, and nothing
    /// in it can be staged.
    static func menu(for file: ChangedFile, existsOnDisk: Bool) -> [FileAction] {
        writes(for: file) + harmless(existsOnDisk: existsOnDisk)
    }

    /// The repository writes `file` offers, if any.
    private static func writes(for file: ChangedFile) -> [FileAction] {
        switch file.area {
        case .unstaged:
            switch file.kind {
            case .modified, .typeChanged, .deleted: [.stage, .discard]
            case .untracked: [.stage, .trash]
            // `.unmerged` gets Stage (as "Mark Resolved") but no Discard: throwing away
            // a conflict resolution is not a one-click action. `.added`, `.renamed` and
            // `.copied` cannot appear unstaged, but the switch stays total.
            case .unmerged, .added, .renamed, .copied: [.stage]
            }
        case .staged:
            [.unstage]
        case .commit:
            []
        }
    }

    /// The items that only read. Reveal and Open need something on disk to point at;
    /// Copy Path works either way, and a missing file is often exactly why it is copied.
    private static func harmless(existsOnDisk: Bool) -> [FileAction] {
        existsOnDisk ? [.revealInFinder, .openInEditor, .copyPath] : [.copyPath]
    }

    /// The menu title, which depends on what the same command means for this file:
    /// `git add` records a deletion and resolves a conflict as well as staging an edit,
    /// and `git restore` brings a deleted file back as well as throwing edits away.
    func title(for file: ChangedFile) -> String {
        switch self {
        case .stage:
            switch file.kind {
            case .deleted: "Stage Deletion"
            case .unmerged: "Mark Resolved"
            default: "Stage"
            }
        case .unstage: "Unstage"
        case .discard: file.kind == .deleted ? "Restore File" : "Discard Changes…"
        case .trash: "Delete File…"
        case .revealInFinder: "Reveal in Finder"
        case .openInEditor: "Open in Default Editor"
        case .copyPath: "Copy Path"
        }
    }

    /// Whether the action destroys work, which is what the confirmation sheet asks about.
    /// Restoring a deleted file is a discard that loses nothing, so it does not confirm.
    func isDestructive(for file: ChangedFile) -> Bool {
        switch self {
        case .trash: true
        case .discard: file.kind != .deleted
        default: false
        }
    }

    /// The git command behind the action, or nil for the ones git does not run.
    var gitAction: GitFileAction? {
        switch self {
        case .stage: .stage
        case .unstage: .unstage
        case .discard: .discard
        case .trash, .revealInFinder, .openInEditor, .copyPath: nil
        }
    }

    /// True for the items that change the repository or the worktree. The menu puts a
    /// divider between these and the rest.
    var isRepositoryWrite: Bool { gitAction != nil || self == .trash }
}
