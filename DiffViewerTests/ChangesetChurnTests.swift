import Foundation
import Testing

@testable import DiffViewer

struct ChangesetChurnTests {
    /// A section for `file` with no rows; only `.text` carries counts of its own.
    private func section(
        _ file: ChangedFile, outcome: FileOutcome, added: Int = 0, deleted: Int = 0
    ) -> ChangesetSection {
        ChangesetSection(
            file: file, rowRange: 0..<0, oldLineOffset: 0, newLineOffset: 0, oldLineCount: 0, newLineCount: 0,
            added: added, deleted: deleted, outcome: outcome)
    }

    private func total(_ sections: [ChangesetSection], files: [ChangedFile]) -> (added: Int, deleted: Int) {
        ChangesetChurn.total(sections: sections, files: files)
    }

    @Test func textSectionsSumTheirOwnCounts() {
        let a = changedFile("a.swift").with(lineStats: .counted(added: 100, deleted: 100))
        let b = changedFile("b.swift")
        let sections = [
            section(a, outcome: .text(language: "Swift"), added: 3, deleted: 1),
            section(b, outcome: .text(language: nil), added: 2, deleted: 4),
        ]
        // The file's own stats are ignored: the rows are the truth for text.
        #expect(total(sections, files: [a, b]) == (added: 5, deleted: 5))
        #expect(total(sections, files: []) == (added: 5, deleted: 5))
    }

    @Test func binarySectionUsesCurrentStatsWhenFingerprintMatches() {
        let file = changedFile("image.png")
        let current = file.with(lineStats: .counted(added: 7, deleted: 2))
        #expect(total([section(file, outcome: .binary)], files: [current]) == (added: 7, deleted: 2))
    }

    @Test func sectionWhoseFileMovedOnContributesNothing() {
        let file = changedFile("a.swift")
        let edited = file.edited().with(lineStats: .counted(added: 7, deleted: 2))
        #expect(file.fingerprint != edited.fingerprint)
        #expect(total([section(file, outcome: .tooLarge)], files: [edited]) == (added: 0, deleted: 0))
    }

    @Test func fileMissingFromListContributesNothing() {
        let file = changedFile("a.swift").with(lineStats: .counted(added: 7, deleted: 2))
        #expect(total([section(file, outcome: .notShown)], files: [changedFile("b.swift")]) == (added: 0, deleted: 0))
    }

    @Test func uncountedStatsContributeNothing() {
        let file = changedFile("a.swift")
        let sections = [section(file, outcome: .tooLarge)]
        #expect(total(sections, files: [file.with(lineStats: .binary(nil))]) == (added: 0, deleted: 0))
        #expect(total(sections, files: [file.with(lineStats: nil)]) == (added: 0, deleted: 0))
    }

    /// Equal unknown fingerprints prove nothing: an unmerged file's HEAD side is unknown,
    /// so its content can change without the fingerprint moving.
    @Test func equalUnknownWorkingTreeFingerprintsContributeNothing() {
        let file = changedFile("conflict.txt", kind: .unmerged)
        #expect(file.fingerprint?.isKnown == false)
        let current = file.with(lineStats: .counted(added: 7, deleted: 2))
        #expect(total([section(file, outcome: .tooLarge)], files: [current]) == (added: 0, deleted: 0))
    }

    @Test func nilWorkingTreeFingerprintsContributeNothing() {
        let file = changedFile("a.swift").with(fingerprint: nil)
        let current = file.with(lineStats: .counted(added: 7, deleted: 2))
        #expect(total([section(file, outcome: .binary)], files: [current]) == (added: 0, deleted: 0))
    }

    @Test func commitScopeFilesWithoutFingerprintsMatch() {
        let commit = CommitRef(sha: objectID("c1"), shortSha: "c1", firstParentSHA: objectID("c0"))
        let file = changedFile("a.swift", area: .commit(commit)).with(fingerprint: nil)
        let current = file.with(lineStats: .counted(added: 4, deleted: 1))
        #expect(total([section(file, outcome: .notShown)], files: [current]) == (added: 4, deleted: 1))
    }

    @Test func textSectionStatsAreItsOwnCountsWhateverTheFileSays() {
        let file = changedFile("a.swift").with(lineStats: .counted(added: 100, deleted: 100))
        let text = section(file, outcome: .text(language: "Swift"), added: 3, deleted: 1)
        #expect(ChangesetChurn.stats(for: text, currentFile: file) == .counted(added: 3, deleted: 1))
        #expect(ChangesetChurn.stats(for: text, currentFile: nil) == .counted(added: 3, deleted: 1))
        #expect(ChangesetChurn.stats(for: text, currentFile: file.edited()) == .counted(added: 3, deleted: 1))
    }

    @Test func binarySectionStatsAreTheCurrentFilesWhileInputsMatch() {
        let file = changedFile("image.png")
        let binary = section(file, outcome: .binary)
        let sizes = BinarySizes(oldByteCount: 10, newByteCount: 20)
        #expect(ChangesetChurn.stats(for: binary, currentFile: file.with(lineStats: .binary(sizes))) == .binary(sizes))
        #expect(ChangesetChurn.stats(for: binary, currentFile: nil) == nil)
        #expect(ChangesetChurn.stats(for: binary, currentFile: file.edited().with(lineStats: .binary(sizes))) == nil)
    }

    @Test func commitSectionStatsMatchWithoutAFingerprint() {
        let commit = CommitRef(sha: objectID("c1"), shortSha: "c1", firstParentSHA: objectID("c0"))
        let file = changedFile("a.swift", area: .commit(commit)).with(fingerprint: nil)
        let current = file.with(lineStats: .counted(added: 4, deleted: 1))
        #expect(
            ChangesetChurn.stats(for: section(file, outcome: .tooLarge), currentFile: current)
                == .counted(added: 4, deleted: 1))
    }

    @Test func mixedSectionsCombine() {
        let text = changedFile("a.swift")
        let binary = changedFile("b.bin")
        let stale = changedFile("c.swift")
        let sections = [
            section(text, outcome: .text(language: "Swift"), added: 10, deleted: 5),
            section(binary, outcome: .binary),
            section(stale, outcome: .tooLarge),
        ]
        let files = [
            text,
            binary.with(lineStats: .counted(added: 1, deleted: 1)),
            stale.edited().with(lineStats: .counted(added: 100, deleted: 100)),
        ]
        #expect(total(sections, files: files) == (added: 11, deleted: 6))
    }
}
