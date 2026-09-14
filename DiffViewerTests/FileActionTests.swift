import Foundation
import Testing

@testable import DiffViewer

struct FileActionTests {
    private static let commit = ChangedFile.Area.commit(
        CommitRef(sha: objectID("c"), shortSha: "c000000", firstParentSHA: objectID("p")))

    // MARK: The menu

    @Test func menuMatchesTheTable() {
        let readOnly: [FileAction] = [.revealInFinder, .openInEditor, .copyPath]
        let table: [(ChangedFile.Area, ChangedFile.Kind, Bool, [FileAction])] = [
            (.unstaged, .modified, true, [.stage, .discard] + readOnly),
            (.unstaged, .typeChanged, true, [.stage, .discard] + readOnly),
            (.unstaged, .deleted, false, [.stage, .discard, .copyPath]),
            (.unstaged, .untracked, true, [.stage, .trash] + readOnly),
            (.unstaged, .unmerged, true, [.stage] + readOnly),
            // Cannot occur unstaged, but the menu must still be total.
            (.unstaged, .added, true, [.stage] + readOnly),
            (.unstaged, .renamed, true, [.stage] + readOnly),
            (.unstaged, .copied, true, [.stage] + readOnly),
            (.staged, .modified, true, [.unstage] + readOnly),
            (.staged, .added, true, [.unstage] + readOnly),
            (.staged, .typeChanged, true, [.unstage] + readOnly),
            (.staged, .deleted, false, [.unstage, .copyPath]),
            // `git rm --cached` stages a deletion but leaves the file on disk, so the
            // read-only items still have something to point at.
            (.staged, .deleted, true, [.unstage] + readOnly),
            // And a file git thinks is only modified can be gone from the worktree.
            (.unstaged, .modified, false, [.stage, .discard, .copyPath]),
            (Self.commit, .modified, true, readOnly),
            (Self.commit, .added, true, readOnly),
            (Self.commit, .deleted, false, [.copyPath]),
            // A path deleted in some commit can exist again now.
            (Self.commit, .deleted, true, readOnly),
        ]
        for (area, kind, existsOnDisk, expected) in table {
            let file = changedFile("a.txt", area: area, kind: kind)
            #expect(
                FileAction.menu(for: file, existsOnDisk: existsOnDisk) == expected,
                "\(area) \(kind) exists=\(existsOnDisk)")
        }
    }

    /// History is read-only: nothing offered on a commit row may touch the repository.
    @Test func commitScopeOffersNoWrites() {
        for kind in allKinds {
            let file = changedFile("a.txt", area: Self.commit, kind: kind)
            let menu = FileAction.menu(for: file, existsOnDisk: true)
            #expect(menu.allSatisfy { !$0.isRepositoryWrite }, "\(kind)")
            #expect(menu.allSatisfy { $0.gitAction == nil }, "\(kind)")
        }
    }

    /// Reveal and Open need a file on disk, whatever git calls the change; Copy Path is
    /// offered either way, and a missing file is often exactly why it is copied.
    @Test func aMissingFileNeverOffersRevealOrOpen() {
        for area in [ChangedFile.Area.unstaged, .staged, Self.commit] {
            for kind in allKinds {
                let file = changedFile("a.txt", area: area, kind: kind)
                let menu = FileAction.menu(for: file, existsOnDisk: false)
                #expect(!menu.contains(.revealInFinder), "\(area) \(kind)")
                #expect(!menu.contains(.openInEditor), "\(area) \(kind)")
                #expect(menu.contains(.copyPath), "\(area) \(kind)")
            }
        }
    }

    /// The divider in the menu sits between the writes and the rest, which only works
    /// if the writes come first.
    @Test func writesComeBeforeHarmlessItems() {
        for area in [ChangedFile.Area.unstaged, .staged, Self.commit] {
            for kind in allKinds {
                let file = changedFile("a.txt", area: area, kind: kind)
                let menu = FileAction.menu(for: file, existsOnDisk: true)
                let writes = menu.prefix { $0.isRepositoryWrite }
                #expect(writes.count == menu.filter(\.isRepositoryWrite).count, "\(area) \(kind)")
            }
        }
    }

    // MARK: Titles

    @Test func stageIsNamedForWhatItDoes() {
        #expect(FileAction.stage.title(for: changedFile("a.txt", kind: .modified)) == "Stage")
        #expect(FileAction.stage.title(for: changedFile("a.txt", kind: .untracked)) == "Stage")
        #expect(FileAction.stage.title(for: changedFile("a.txt", kind: .deleted)) == "Stage Deletion")
        #expect(FileAction.stage.title(for: changedFile("a.txt", kind: .unmerged)) == "Mark Resolved")
    }

    @Test func discardIsNamedRestoreForADeletedFile() {
        #expect(FileAction.discard.title(for: changedFile("a.txt", kind: .modified)) == "Discard Changes…")
        #expect(FileAction.discard.title(for: changedFile("a.txt", kind: .deleted)) == "Restore File")
    }

    @Test func remainingTitles() {
        let file = changedFile("a.txt")
        #expect(FileAction.unstage.title(for: file) == "Unstage")
        #expect(FileAction.trash.title(for: file) == "Delete File…")
        #expect(FileAction.revealInFinder.title(for: file) == "Reveal in Finder")
        #expect(FileAction.openInEditor.title(for: file) == "Open in Default Editor")
        #expect(FileAction.copyPath.title(for: file) == "Copy Path")
    }

    // MARK: Destructiveness and git commands

    @Test func onlyTrashAndALosingDiscardConfirm() {
        let modified = changedFile("a.txt", kind: .modified)
        #expect(FileAction.trash.isDestructive(for: modified))
        #expect(FileAction.discard.isDestructive(for: modified))
        // Bringing a deleted file back loses nothing, so it asks nothing.
        #expect(!FileAction.discard.isDestructive(for: changedFile("a.txt", kind: .deleted)))
        for action in [FileAction.stage, .unstage, .revealInFinder, .openInEditor, .copyPath] {
            #expect(!action.isDestructive(for: modified), "\(action)")
        }
    }

    @Test func gitActionsMapToTheirCommands() {
        #expect(FileAction.stage.gitAction == .stage)
        #expect(FileAction.unstage.gitAction == .unstage)
        #expect(FileAction.discard.gitAction == .discard)
        for action in [FileAction.trash, .revealInFinder, .openInEditor, .copyPath] {
            #expect(action.gitAction == nil, "\(action)")
        }
        #expect(FileAction.trash.isRepositoryWrite, "trash writes the worktree")
    }

    private var allKinds: [ChangedFile.Kind] {
        [.modified, .added, .deleted, .renamed, .copied, .typeChanged, .untracked, .unmerged]
    }
}
