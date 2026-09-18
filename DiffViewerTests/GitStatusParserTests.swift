import Foundation
import Testing

@testable import DiffViewer

struct GitStatusParserTests {
    private func data(_ records: [String]) -> Data {
        Data((records.joined(separator: "\0") + "\0").utf8)
    }

    @Test func modifiedInWorktreeOnly() {
        let files = GitStatusParser.parse(data(["1 .M N... 100644 100644 100644 abc def src/a.swift"]))
        let fingerprint = DiffInputFingerprint(
            old: .object("def"), new: .notApplicable, worktree: .unknown, kind: .modified, originalPath: nil)
        #expect(
            files == [
                ChangedFile(
                    path: "src/a.swift", originalPath: nil, kind: .modified, area: .unstaged, fingerprint: fingerprint)
            ])
    }

    @Test func stagedAndUnstagedProducesTwoEntries() {
        let files = GitStatusParser.parse(data(["1 MM N... 100644 100644 100644 abc def a.txt"]))
        #expect(files.map(\.area) == [.staged, .unstaged])
        #expect(files.allSatisfy { $0.path == "a.txt" && $0.kind == .modified })
    }

    @Test func stagedAddition() {
        let files = GitStatusParser.parse(data(["1 A. N... 000000 100644 100644 000 def new.txt"]))
        let fingerprint = DiffInputFingerprint(
            old: .absent, new: .object("def"), worktree: .notApplicable, kind: .added, originalPath: nil)
        #expect(
            files == [
                ChangedFile(path: "new.txt", originalPath: nil, kind: .added, area: .staged, fingerprint: fingerprint)
            ])
    }

    @Test func renameCarriesOriginalPath() {
        let files = GitStatusParser.parse(
            data(["2 R. N... 100644 100644 100644 abc abc R100 new/name.txt", "old/name.txt"]))
        let fingerprint = DiffInputFingerprint(
            old: .object("abc"), new: .object("abc"), worktree: .notApplicable, kind: .renamed,
            originalPath: "old/name.txt")
        #expect(
            files == [
                ChangedFile(
                    path: "new/name.txt", originalPath: "old/name.txt", kind: .renamed, area: .staged,
                    fingerprint: fingerprint)
            ])
    }

    @Test func untrackedAndConflict() {
        let files = GitStatusParser.parse(
            data([
                "? notes.md",
                "u UU N... 100644 100644 100644 100644 a b c d conflict.txt",
            ]))
        #expect(files.map(\.kind) == [.untracked, .unmerged])
        #expect(files.allSatisfy { $0.area == .unstaged })
    }

    @Test func pathsWithSpacesSurvive() {
        let files = GitStatusParser.parse(data(["1 .M N... 100644 100644 100644 abc def dir with space/file name.txt"]))
        #expect(files.first?.path == "dir with space/file name.txt")
    }

    @Test func emptyInputYieldsNothing() {
        #expect(GitStatusParser.parse(Data()).isEmpty)
    }

    // MARK: Fingerprints

    /// The staged entry reads HEAD against the index; the unstaged one reads the index
    /// against a worktree the parser cannot stat.
    @Test func aModifiedRecordFingerprintsBothAreas() {
        let files = GitStatusParser.parse(data(["1 MM N... 100644 100644 100644 abc def a.txt"]))
        #expect(
            files[0].fingerprint
                == DiffInputFingerprint(
                    old: .object("abc"), new: .object("def"), worktree: .notApplicable, kind: .modified,
                    originalPath: nil))
        #expect(
            files[1].fingerprint
                == DiffInputFingerprint(
                    old: .object("def"), new: .notApplicable, worktree: .unknown, kind: .modified, originalPath: nil))
        #expect(files[0].fingerprint?.isKnown == true)
        #expect(files[1].fingerprint?.isKnown == false, "the worktree is stat'ed by the client, not the parser")
    }

    @Test func aZeroHashIsAnAbsentBlob() {
        let staged = GitStatusParser.parse(data(["1 A. N... 000000 100644 100644 0000000 def new.txt"]))
        #expect(staged.first?.fingerprint?.old == .absent)
        #expect(staged.first?.fingerprint?.new == .object("def"))

        let deleted = GitStatusParser.parse(data(["1 D. N... 100644 000000 000000 abc 0000000 gone.txt"]))
        #expect(deleted.first?.fingerprint?.old == .object("abc"))
        #expect(deleted.first?.fingerprint?.new == .absent)
    }

    /// A rename's fingerprint names the original path: the engine reads HEAD at that path.
    @Test func aRenameRecordFingerprintsWithTheOriginalPath() {
        let files = GitStatusParser.parse(
            data(["2 RM N... 100644 100644 100644 abc def R100 new/name.txt", "old/name.txt"]))
        #expect(files.map(\.area) == [.staged, .unstaged])
        #expect(files[0].fingerprint?.originalPath == "old/name.txt")
        #expect(files[0].fingerprint?.old == .object("abc"))
        #expect(files[0].fingerprint?.new == .object("def"))
        // The worktree edit is to the new path alone.
        #expect(files[1].fingerprint?.originalPath == nil)
        #expect(files[1].fingerprint?.old == .object("def"))
    }

    /// A "u" record reports the conflict stages, not HEAD, which is what the engine reads.
    @Test func aConflictIsNeverKnown() {
        let files = GitStatusParser.parse(data(["u UU N... 100644 100644 100644 100644 a b c d conflict.txt"]))
        #expect(files.first?.fingerprint?.old == .unknown)
        #expect(files.first?.fingerprint?.new == .notApplicable)
        #expect(files.first?.fingerprint?.kind == .unmerged)
        #expect(files.first?.fingerprint?.isKnown == false)
    }

    @Test func anUntrackedFileHasNoOldSide() {
        let files = GitStatusParser.parse(data(["? notes.md"]))
        #expect(
            files.first?.fingerprint
                == DiffInputFingerprint(
                    old: .absent, new: .notApplicable, worktree: .unknown, kind: .untracked, originalPath: nil))
    }
}
