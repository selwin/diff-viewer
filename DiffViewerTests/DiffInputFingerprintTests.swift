import Foundation
import Testing

@testable import DiffViewer

struct DiffInputFingerprintTests {
    private let stat = DiffInputFingerprint.Worktree.file(mtimeNs: 1, ctimeNs: 1, size: 10, inode: 1)

    private func unstaged(
        old: DiffInputFingerprint.Blob = .object("abc"), worktree: DiffInputFingerprint.Worktree? = nil,
        kind: ChangedFile.Kind = .modified
    ) -> DiffInputFingerprint {
        DiffInputFingerprint(old: old, new: .notApplicable, worktree: worktree ?? stat, kind: kind, originalPath: nil)
    }

    private func staged(
        old: DiffInputFingerprint.Blob = .object("abc"), new: DiffInputFingerprint.Blob = .object("def"),
        kind: ChangedFile.Kind = .modified, originalPath: String? = nil
    ) -> DiffInputFingerprint {
        DiffInputFingerprint(old: old, new: new, worktree: .notApplicable, kind: kind, originalPath: originalPath)
    }

    @Test func equalKnownFingerprintsHaveNotChanged() {
        #expect(!DiffInputFingerprint.mayHaveChanged(unstaged(), unstaged()))
        #expect(!DiffInputFingerprint.mayHaveChanged(staged(), staged()))
    }

    @Test func anyDifferingFieldIsAChange() {
        #expect(DiffInputFingerprint.mayHaveChanged(staged(), staged(old: .object("zzz"))))
        #expect(DiffInputFingerprint.mayHaveChanged(staged(), staged(new: .absent)))
        #expect(
            DiffInputFingerprint.mayHaveChanged(
                unstaged(), unstaged(worktree: .file(mtimeNs: 2, ctimeNs: 1, size: 10, inode: 1))))
        #expect(DiffInputFingerprint.mayHaveChanged(unstaged(), unstaged(worktree: .missing)))
        #expect(DiffInputFingerprint.mayHaveChanged(staged(), staged(kind: .added)))
        #expect(DiffInputFingerprint.mayHaveChanged(staged(), staged(originalPath: "old.txt")))
    }

    @Test func aMissingSideIsAChange() {
        #expect(DiffInputFingerprint.mayHaveChanged(nil, unstaged()))
        #expect(DiffInputFingerprint.mayHaveChanged(unstaged(), nil))
        #expect(DiffInputFingerprint.mayHaveChanged(nil, nil))
    }

    /// Equal but unknown proves nothing: the field the engine reads was never described.
    @Test func anUnknownFieldIsAChangeEvenWhenEqual() {
        let unknownBlob = unstaged(old: .unknown)
        #expect(DiffInputFingerprint.mayHaveChanged(unknownBlob, unknownBlob))
        #expect(DiffInputFingerprint.mayHaveChanged(unstaged(), unknownBlob))
        #expect(DiffInputFingerprint.mayHaveChanged(unknownBlob, unstaged()))

        let unknownStat = unstaged(worktree: .unknown)
        #expect(DiffInputFingerprint.mayHaveChanged(unknownStat, unknownStat))
        #expect(DiffInputFingerprint.mayHaveChanged(unstaged(), unknownStat))
    }

    @Test func notApplicableOnBothSidesNeverInvalidates() {
        let file = DiffInputFingerprint(
            old: .notApplicable, new: .notApplicable, worktree: .notApplicable, kind: .modified, originalPath: nil)
        #expect(!DiffInputFingerprint.mayHaveChanged(file, file))
        #expect(file.isKnown)
    }

    /// `.missing` and `.absent` are confirmed answers, not gaps.
    @Test func isKnownIsFalseOnlyWithAnUnknownField() {
        #expect(unstaged().isKnown)
        #expect(staged().isKnown)
        #expect(unstaged(old: .absent, worktree: .missing).isKnown)
        #expect(!unstaged(old: .unknown).isKnown)
        #expect(!staged(new: .unknown).isKnown)
        #expect(!unstaged(worktree: .unknown).isKnown)
    }

    @Test func withWorktreeReplacesOnlyTheStat() {
        let before = unstaged(worktree: .unknown)
        let after = before.with(worktree: stat)
        #expect(after.worktree == stat)
        #expect(after.old == before.old)
        #expect(after.new == before.new)
        #expect(after.kind == before.kind)
        #expect(after.isKnown)
    }

    @Test func statOfAMissingPathIsMissing() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DiffViewerNoSuchFile-\(UUID())")
        #expect(DiffInputFingerprint.worktree(at: url) == .missing)
    }

    /// `ENOTDIR`: a path component that is a file, which is not "not there".
    @Test func statFailingForAnotherReasonIsUnknown() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DiffViewerStat-\(UUID())")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(DiffInputFingerprint.worktree(at: file.appendingPathComponent("child")) == .unknown)
    }
}
