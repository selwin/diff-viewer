import Foundation
import Testing

@testable import DiffViewer

struct ExactMovePairingTests {
    private let stat = DiffInputFingerprint.Worktree.file(mtimeNs: 1, ctimeNs: 1, size: 10, inode: 1)

    private func deleted(_ path: String, blob: String, mode: String = "100644") -> ChangedFile {
        let fingerprint = DiffInputFingerprint(
            old: .object(blob), new: .notApplicable, worktree: .missing, kind: .deleted, originalPath: nil)
        return ChangedFile(
            path: path, originalPath: nil, kind: .deleted, area: .unstaged, fingerprint: fingerprint, indexMode: mode)
    }

    private func untracked(_ path: String, worktree: DiffInputFingerprint.Worktree? = nil) -> ChangedFile {
        let fingerprint = DiffInputFingerprint(
            old: .absent, new: .notApplicable, worktree: worktree ?? stat, kind: .untracked, originalPath: nil)
        return ChangedFile(path: path, originalPath: nil, kind: .untracked, area: .unstaged, fingerprint: fingerprint)
    }

    private func sized(_ size: Int64) -> DiffInputFingerprint.Worktree {
        .file(mtimeNs: 1, ctimeNs: 1, size: size, inode: 1)
    }

    /// (new path, old path) for every rename in `files`.
    private func renames(_ files: [ChangedFile]) -> Set<[String]> {
        Set(files.filter { $0.kind == .renamed }.map { [$0.path, $0.originalPath ?? ""] })
    }

    @Test func matchingIDsCollapseIntoOneRename() {
        let files = [deleted("a.txt", blob: "b1"), untracked("dir/b.txt")]

        let result = ExactMovePairing.apply(to: files, rawBlobIDs: ["dir/b.txt": "b1"])

        let fingerprint = DiffInputFingerprint(
            old: .object("b1"), new: .notApplicable, worktree: stat, kind: .renamed, originalPath: "a.txt")
        #expect(
            result == [
                ChangedFile(
                    path: "dir/b.txt", originalPath: "a.txt", kind: .renamed, area: .unstaged,
                    fingerprint: fingerprint)
            ])
    }

    @Test func differentIDsStayUnpaired() {
        let files = [deleted("a.txt", blob: "b1"), untracked("b.txt")]
        #expect(ExactMovePairing.apply(to: files, rawBlobIDs: ["b.txt": "b2"]) == files)
    }

    /// Path order alone would pair `old/a.txt` with `new/b.txt`; the shared name wins, and
    /// the file left over after one-to-one pairing stays untracked.
    @Test func identicalFilesPairOneToOnePreferringTheSameName() {
        let files = [
            deleted("old/a.txt", blob: "b1"), deleted("old/b.txt", blob: "b1"),
            untracked("new/b.txt"), untracked("new/c.txt"), untracked("new/d.txt"),
        ]
        let ids = ["new/b.txt": "b1", "new/c.txt": "b1", "new/d.txt": "b1"]

        let result = ExactMovePairing.apply(to: files, rawBlobIDs: ids)

        #expect(renames(result) == [["new/b.txt", "old/b.txt"], ["new/c.txt", "old/a.txt"]])
        #expect(result.filter { $0.kind == .untracked }.map(\.path) == ["new/d.txt"])
        #expect(!result.contains { $0.kind == .deleted })
    }

    /// A symlink's blob is its target path and a gitlink's is a commit, so an equal id says
    /// nothing about a file's bytes. An executable is still a regular file.
    @Test func onlyRegularFileDeletionsPair() {
        let files = [
            deleted("link", blob: "b1", mode: "120000"), deleted("module", blob: "b2", mode: "160000"),
            deleted("tool.sh", blob: "b3", mode: "100755"),
            untracked("a"), untracked("b"), untracked("c"),
        ]
        #expect(ExactMovePairing.candidates(in: Array(files.prefix(2)) + [untracked("a")]) == nil)

        let result = ExactMovePairing.apply(to: files, rawBlobIDs: ["a": "b1", "b": "b2", "c": "b3"])

        #expect(renames(result) == [["c", "tool.sh"]])
        #expect(result.filter { $0.kind == .deleted }.map(\.path) == ["link", "module"])
    }

    @Test func aRenameAlreadyInTheListIsLeftAlone() {
        let existing = ChangedFile(
            path: "b.txt", originalPath: "a.txt", kind: .renamed, area: .unstaged,
            fingerprint: DiffInputFingerprint(
                old: .object("b2"), new: .notApplicable, worktree: stat, kind: .renamed, originalPath: "a.txt"))
        let files = [existing, deleted("c.txt", blob: "b2"), untracked("d.txt")]

        let result = ExactMovePairing.apply(to: files, rawBlobIDs: ["b.txt": "b2", "d.txt": "b2"])

        #expect(result.first == existing)
        #expect(renames(result) == [["b.txt", "a.txt"], ["d.txt", "c.txt"]])
    }

    @Test func candidatesLeaveOutEmptyFilesNestedRepositoriesAndUnknownStats() {
        let files = [
            deleted("a.txt", blob: "b1"), deleted("b.txt", blob: "b1"), deleted("c.txt", blob: "b0"),
            untracked("empty.txt", worktree: sized(0)), untracked("nested/", worktree: sized(96)),
            untracked("unknown.txt", worktree: .unknown), untracked("kept.txt", worktree: sized(5)),
        ]
        #expect(
            ExactMovePairing.candidates(in: files)
                == ExactMovePairing.Candidates(deletedBlobIDs: ["b0", "b1"], untrackedSizes: ["kept.txt": 5]))
        let onlyEmpty = [deleted("a.txt", blob: "b1"), untracked("e.txt", worktree: sized(0))]
        #expect(ExactMovePairing.candidates(in: onlyEmpty) == nil)
    }

    @Test func candidatesAreNilWithoutADeletionOrWithoutAnUntrackedFile() {
        let stagedDeletion = changedFile("a.txt", area: .staged, kind: .deleted)
        #expect(ExactMovePairing.candidates(in: [stagedDeletion, untracked("b.txt")]) == nil)
        #expect(ExactMovePairing.candidates(in: [deleted("a.txt", blob: "b1"), changedFile("b.txt")]) == nil)
    }
}
