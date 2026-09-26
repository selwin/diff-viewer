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

    // MARK: The menu for a selection

    @Test func unstagedFilesAllGetTheirWrites() {
        let a = changedFile("a.txt", kind: .modified)
        let b = changedFile("b.txt", kind: .modified)
        #expect(
            FileAction.writeGroups(for: [a, b]) == [
                .init(action: .stage, files: [a, b]),
                .init(action: .discard, files: [a, b]),
            ])
    }

    @Test func stagedFilesOnlyUnstage() {
        let a = changedFile("a.txt", area: .staged, kind: .modified)
        let b = changedFile("b.txt", area: .staged, kind: .added)
        #expect(FileAction.writeGroups(for: [a, b]) == [.init(action: .unstage, files: [a, b])])
    }

    /// Stage and Unstage each fit only half of a mixed selection, so neither is offered.
    @Test func aMixedSelectionOffersNoWrites() {
        let staged = changedFile("a.txt", area: .staged, kind: .modified)
        let unstaged = changedFile("b.txt", kind: .modified)
        #expect(FileAction.writeGroups(for: [unstaged, staged]) == [])
    }

    /// Discard fits only the modified file and Trash only the untracked one; Stage fits both.
    @Test func untrackedAndModifiedShareOnlyStage() {
        let modified = changedFile("a.txt", kind: .modified)
        let untracked = changedFile("b.txt", kind: .untracked)
        #expect(
            FileAction.writeGroups(for: [modified, untracked]) == [
                .init(action: .stage, files: [modified, untracked])
            ])
    }

    @Test func anEmptySelectionOffersNoWrites() {
        #expect(FileAction.writeGroups(for: []) == [])
    }

    /// Discarding a conflict resolution is not a one-click action, even in a batch.
    @Test func aConflictOffersOnlyStage() {
        let conflicted = changedFile("a.txt", kind: .unmerged)
        #expect(FileAction.writeGroups(for: [conflicted]) == [.init(action: .stage, files: [conflicted])])
    }

    @Test func commitScopeOffersNoWriteGroups() {
        let files = [
            changedFile("a.txt", area: Self.commit, kind: .modified),
            changedFile("b.txt", area: Self.commit, kind: .deleted),
        ]
        #expect(FileAction.writeGroups(for: files) == [])
    }

    /// Non-write items act on the whole selection, so one row missing from disk drops
    /// Reveal and Open for the batch.
    @Test func oneMissingFileDropsRevealAndOpenForTheBatch() {
        let present = changedFile("a.txt", kind: .modified)
        let missing = changedFile("b.txt", kind: .modified)
        let items = FileAction.harmless(for: [present, missing], existsOnDisk: { $0.path == "a.txt" })
        #expect(items == [.copyPath])
    }

    @Test func aMixedSelectionKeepsEveryHarmlessItem() {
        let files = [changedFile("a.txt", kind: .modified), changedFile("b.txt", area: .staged)]
        #expect(
            FileAction.harmless(for: files, existsOnDisk: { _ in true })
                == [.revealInFinder, .openInEditor, .copyPath])
        #expect(FileAction.harmless(for: [], existsOnDisk: { _ in true }) == [])
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

    /// A batch is counted rather than named, and Copy Path counts paths: a file with both
    /// staged and unstaged edits is two rows but one path on the pasteboard.
    @Test func batchTitlesCountRowsAndPaths() {
        let two = [changedFile("a.txt"), changedFile("b.txt")]
        #expect(FileAction.stage.title(for: two) == "Stage 2 Files")
        #expect(FileAction.unstage.title(for: two) == "Unstage 2 Files")
        #expect(FileAction.discard.title(for: two) == "Discard Changes to 2 Files…")
        #expect(FileAction.trash.title(for: two) == "Delete 2 Files…")
        #expect(FileAction.revealInFinder.title(for: two) == "Reveal in Finder")
        #expect(FileAction.openInEditor.title(for: two) == "Open in Default Editor")
        #expect(FileAction.copyPath.title(for: two) == "Copy 2 Paths")

        let deleted = [changedFile("a.txt", kind: .deleted), changedFile("b.txt", kind: .deleted)]
        #expect(FileAction.discard.title(for: deleted) == "Restore 2 Files")

        let samePath = [changedFile("a.txt"), changedFile("a.txt", area: .staged)]
        #expect(FileAction.copyPath.title(for: samePath) == "Copy Path")
    }

    /// One row still reads as one row, whichever form the view calls.
    @Test func aSingleFileKeepsItsOwnTitles() {
        let file = changedFile("a.txt", kind: .deleted)
        #expect(FileAction.stage.title(for: [file]) == "Stage Deletion")
        #expect(FileAction.discard.title(for: [file]) == "Restore File")
        #expect(FileAction.trash.title(for: [changedFile("a.txt")]) == "Delete File…")
        #expect(FileAction.copyPath.title(for: [file]) == "Copy Path")
    }

    @Test func compactTitlesMatchTheTable() {
        let one = [changedFile("a.txt", kind: .modified)]
        let two = [changedFile("a.txt", kind: .modified), changedFile("b.txt", kind: .modified)]
        let oneDeleted = [changedFile("a.txt", kind: .deleted)]
        let twoDeleted = [changedFile("a.txt", kind: .deleted), changedFile("b.txt", kind: .deleted)]
        #expect(FileAction.stage.compactTitle(for: one) == "Stage")
        #expect(FileAction.stage.compactTitle(for: two) == "Stage 2 files")
        #expect(FileAction.unstage.compactTitle(for: one) == "Unstage")
        #expect(FileAction.unstage.compactTitle(for: two) == "Unstage 2 files")
        #expect(FileAction.discard.compactTitle(for: one) == "Discard Changes…")
        #expect(FileAction.discard.compactTitle(for: two) == "Discard Changes…")
        // One file with edits is enough to make it a discard.
        #expect(FileAction.discard.compactTitle(for: [oneDeleted[0], one[0]]) == "Discard Changes…")
        #expect(FileAction.discard.compactTitle(for: oneDeleted) == "Restore")
        #expect(FileAction.discard.compactTitle(for: twoDeleted) == "Restore 2 files")
        #expect(FileAction.trash.compactTitle(for: one) == "Move to Trash…")
        #expect(FileAction.trash.compactTitle(for: two) == "Move to Trash…")
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

    /// One row with something to lose is enough to ask, and a batch that loses nothing
    /// asks nothing.
    @Test func aBatchConfirmsWhenAnyRowHasSomethingToLose() {
        let modified = [changedFile("a.txt", kind: .modified), changedFile("b.txt", kind: .modified)]
        let deleted = [changedFile("a.txt", kind: .deleted), changedFile("b.txt", kind: .deleted)]
        #expect(FileAction.discard.isDestructive(for: modified))
        #expect(!FileAction.discard.isDestructive(for: deleted))
        #expect(FileAction.discard.isDestructive(for: [deleted[0], modified[1]]))
        #expect(!FileAction.stage.isDestructive(for: modified))
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
